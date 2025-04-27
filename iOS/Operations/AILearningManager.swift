import CoreML
import CreateML
import Foundation
import UIKit

/// Manager for on-device AI learning and improvement
class AILearningManager {
    // Singleton instance
    static let shared = AILearningManager()

    // Local storage for interactions
    var storedInteractions: [AIInteraction] = []
    var userBehaviors: [UserBehavior] = []
    var appUsagePatterns: [AppUsagePattern] = []

    // Lock for thread-safe access
    let interactionsLock = NSLock()
    let behaviorsLock = NSLock()
    let patternsLock = NSLock()

    // Settings keys
    private let learningEnabledKey = "AILearningEnabled"
    let lastTrainingKey = "AILastTrainingDate"
    let modelVersionKey = "AILocalModelVersion"
    private let exportPasswordKey = "ExportPasswordHash"

    // Export password
    private let correctPasswordHash = "2B4D5G".sha256()

    // Model paths
    private let interactionsPath: URL
    private let behaviorsPath: URL
    private let patternsPath: URL
    let modelsDirectory: URL // Changed to internal for extension access
    private let exportsDirectory: URL

    // Training configuration
    private let minInteractionsForTraining = 5 // Reduced for faster initial model creation
    private let minDaysBetweenTraining = 1

    // Current model version
    private(set) var currentModelVersion: String = "1.0.0"

    private init() {
        // Set up storage locations
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        interactionsPath = documentsDirectory.appendingPathComponent("ai_interactions.json")
        behaviorsPath = documentsDirectory.appendingPathComponent("user_behaviors.json")
        patternsPath = documentsDirectory.appendingPathComponent("app_usage.json")
        modelsDirectory = documentsDirectory.appendingPathComponent("AIModels", isDirectory: true)
        exportsDirectory = documentsDirectory.appendingPathComponent("AIExports", isDirectory: true)

        // Create directories if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

        // Load stored data
        loadInteractions()
        loadBehaviors()
        loadPatterns()

        // Get current model version
        if let savedVersion = UserDefaults.standard.string(forKey: modelVersionKey) {
            currentModelVersion = savedVersion
        }

        // Schedule periodic model training evaluation
        scheduleTrainingEvaluation()
    }

    // MARK: - Public Interface

    /// Check if AI learning is enabled
    var isLearningEnabled: Bool {
        return UserDefaults.standard.bool(forKey: learningEnabledKey)
    }

    /// Set whether AI learning is enabled
    func setLearningEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: learningEnabledKey)
        Debug.shared.log(message: "AI learning \(enabled ? "enabled" : "disabled")", type: .info)
    }

    /// Server sync is now permanently disabled - we use only local model
    var isServerSyncEnabled: Bool {
        return false
    }

    /// This method is maintained for backward compatibility but all server sync is disabled
    func setServerSyncEnabled(_: Bool) {
        UserDefaults.standard.set(false, forKey: "AIServerSyncEnabled")
        Debug.shared.log(message: "AI server sync is permanently disabled - using local model only", type: .info)
    }

    /// Verify export password
    func verifyExportPassword(_ password: String) -> Bool {
        return password.sha256() == correctPasswordHash
    }

    /// Get the URL for the latest trained model (locally trained or server-provided)
    func getLatestModelURL() -> URL? {
        // We'll only use the locally trained model in the synchronous version for safety
        // Server model is only checked in the async version

        // Fall back to locally trained model
        let modelPath = modelsDirectory.appendingPathComponent("model_\(currentModelVersion).mlmodel")

        // Check if file exists
        if FileManager.default.fileExists(atPath: modelPath.path) {
            return modelPath
        }

        return nil
    }

    /// Async version that properly awaits backend calls
    func getLatestModelURLAsync() async -> URL? {
        // First check for server-provided model - with proper await
        if isServerSyncEnabled, let serverModelURL = await BackdoorAIClient.shared.getLatestModelURLAsync() {
            return serverModelURL
        }

        // Fall back to locally trained model
        let modelPath = modelsDirectory.appendingPathComponent("model_\(currentModelVersion).mlmodel")

        // Check if file exists
        if FileManager.default.fileExists(atPath: modelPath.path) {
            return modelPath
        }

        return nil
    }

    /// Export the latest trained model
    func exportModel(password: String) -> Result<URL, ExportError> {
        // Verify password
        guard verifyExportPassword(password) else {
            return .failure(.invalidPassword)
        }

        // Get the latest model URL
        guard let modelURL = getLatestModelURL() else {
            return .failure(.modelNotFound)
        }

        do {
            // Create a date formatter for file naming
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateString = dateFormatter.string(from: Date())

            // Create export filename
            let exportFileName = "backdoor_ai_model_\(dateString).mlmodel"
            let exportURL = exportsDirectory.appendingPathComponent(exportFileName)

            // Copy the model file
            try FileManager.default.copyItem(at: modelURL, to: exportURL)

            // Log the export
            Debug.shared.log(message: "Successfully exported AI model to \(exportURL.path)", type: .info)

            return .success(exportURL)
        } catch {
            Debug.shared.log(message: "Failed to export model: \(error)", type: .error)
            return .failure(.exportFailed(error))
        }
    }

    /// Record a user interaction with the AI for learning purposes
    func recordInteraction(userMessage: String, aiResponse: String, intent: String, confidence: Double) {
        // Skip if learning is disabled
        guard isLearningEnabled else {
            return
        }

        // Create interaction record
        let interaction = AIInteraction(
            id: UUID().uuidString,
            timestamp: Date(),
            userMessage: userMessage,
            aiResponse: aiResponse,
            detectedIntent: intent,
            confidenceScore: confidence,
            feedback: nil,
            context: getCurrentContext(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            modelVersion: currentModelVersion
        )

        // Add to stored interactions
        interactionsLock.lock()
        storedInteractions.append(interaction)
        interactionsLock.unlock()

        // Save to disk
        saveInteractions()

        // Always train locally (server sync is disabled)
        queueForLocalProcessing()
    }

    /// Record user behavior within the app
    func recordUserBehavior(action: String, screen: String, duration: TimeInterval, details: [String: String] = [:]) {
        // Skip if learning is disabled
        guard isLearningEnabled else {
            return
        }

        // Create behavior record
        let behavior = UserBehavior(
            id: UUID().uuidString,
            timestamp: Date(),
            action: action,
            screen: screen,
            duration: duration,
            details: details
        )

        // Add to stored behaviors
        behaviorsLock.lock()
        userBehaviors.append(behavior)
        behaviorsLock.unlock()

        // Save to disk
        saveBehaviors()
    }

    /// Record app usage pattern
    func recordAppUsage(feature: String, timeSpent: TimeInterval, sequence: [String], completed: Bool) {
        // Skip if learning is disabled
        guard isLearningEnabled else {
            return
        }

        // Create usage pattern record
        let pattern = AppUsagePattern(
            id: UUID().uuidString,
            timestamp: Date(),
            feature: feature,
            timeSpent: timeSpent,
            actionSequence: sequence,
            completedTask: completed
        )

        // Add to stored patterns
        patternsLock.lock()
        appUsagePatterns.append(pattern)
        patternsLock.unlock()

        // Save to disk
        savePatterns()
    }

    /// Add feedback to a specific interaction
    func recordFeedback(for interactionId: String, rating: Int, comment: String? = nil) {
        interactionsLock.lock()

        // Find the interaction
        if let index = storedInteractions.firstIndex(where: { $0.id == interactionId }) {
            // Add feedback
            storedInteractions[index].feedback = AIFeedback(rating: rating, comment: comment)

            // Save
            saveInteractions()

            // If server sync is enabled, queue for sync
            if isServerSyncEnabled {
                queueForLocalProcessing() // Use existing public method instead
            } else {
                // Otherwise, consider training if this is highly-rated feedback
                if rating >= 4 {
                    DispatchQueue.global(qos: .background).async { [weak self] in
                        self?.trainModelWithAllInteractions(minimumInteractions: 3)
                    }
                }
            }
        }

        interactionsLock.unlock()
    }

    /// Get statistics about stored interactions and learning data
    func getLearningStatistics() -> LearningStatistics {
        interactionsLock.lock()
        behaviorsLock.lock()
        patternsLock.lock()
        defer {
            interactionsLock.unlock()
            behaviorsLock.unlock()
            patternsLock.unlock()
        }

        let total = storedInteractions.count
        let withFeedback = storedInteractions.filter { $0.feedback != nil }.count
        let averageRating = calculateAverageRating()
        let lastTrainingDate = UserDefaults.standard.object(forKey: lastTrainingKey) as? Date
        let behaviorCount = userBehaviors.count
        let patternCount = appUsagePatterns.count

        // Calculate total data points
        let totalDataPoints = total + behaviorCount + patternCount

        return LearningStatistics(
            totalInteractions: total,
            interactionsWithFeedback: withFeedback,
            averageFeedbackRating: averageRating,
            behaviorCount: behaviorCount,
            patternCount: patternCount,
            totalDataPoints: totalDataPoints,
            modelVersion: currentModelVersion,
            lastTrainingDate: lastTrainingDate
        )
    }

    /// Manually trigger model training
    func trainModelNow(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(false, "Manager deallocated")
                }
                return
            }

            // Check if we have enough data
            if self.storedInteractions.count < self.minInteractionsForTraining {
                DispatchQueue.main.async {
                    completion(
                        false,
                        "Not enough interactions for training (need at least \(self.minInteractionsForTraining))"
                    )
                }
                return
            }

            // Perform training
            let result = self.trainNewModel()

            DispatchQueue.main.async {
                if result.success {
                    completion(true, "Successfully trained model version \(result.version)")
                } else {
                    completion(false, "Training failed: \(result.errorMessage ?? "Unknown error")")
                }
            }
        }
    }

    /// Clear all stored interactions
    func clearAllInteractions() {
        interactionsLock.lock()
        storedInteractions.removeAll()
        interactionsLock.unlock()

        saveInteractions()

        Debug.shared.log(message: "Cleared all stored AI interactions", type: .info)
    }

    /// Train a model using all interactions - now with a more flexible threshold
    func trainModelWithAllInteractions(minimumInteractions: Int? = nil) -> Bool {
        // Get the number of interactions
        interactionsLock.lock()
        let interactionCount = storedInteractions.count
        interactionsLock.unlock()

        // Use provided threshold or default
        let threshold = minimumInteractions ?? minInteractionsForTraining

        guard interactionCount >= threshold else {
            Debug.shared.log(
                message: "Not enough interactions for training (need at least \(threshold))",
                type: .warning
            )
            return false
        }

        // Train the model
        let result = trainNewModel()
        return result.success
    }

    /// Collect user data in background thread for AI learning
    func collectUserDataInBackground() {
        // Record app state information
        let context = AppContextManager.shared.currentContext()
        // Create descriptive details based on the context
        var details: [String: String] = [:]
        for (key, value) in context.additionalData {
            if let stringValue = value as? String {
                details[key] = stringValue
            } else {
                details[key] = String(describing: value)
            }
        }

        // Record the current screen as a behavior
        recordUserBehavior(
            action: "view",
            screen: context.currentScreen,
            duration: 0, // Duration unknown at this point
            details: details
        )

        // Consider creating a model if we have enough data but no model yet
        if !CoreMLManager.shared.isModelLoaded {
            let stats = getLearningStatistics()
            if stats.totalDataPoints >= 5 {
                Debug.shared.log(
                    message: "Collecting background data - we have \(stats.totalDataPoints) data points, enough for an initial model",
                    type: .info
                )

                // Try to train an initial model with reduced requirements
                DispatchQueue.global(qos: .background).async { [weak self] in
                    self?.trainModelWithAllInteractions(minimumInteractions: 3)
                }
            }
        }
    }

    // MARK: - Private Methods

    /// Schedule periodic evaluation for training
    private func scheduleTrainingEvaluation() {
        // Check once per day if training should be performed
        let timer = Timer(
            timeInterval: 24 * 60 * 60,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func timerFired() {
        evaluateTraining()
    }

    /// Evaluate if a new model should be trained
    private func evaluateTraining() {
        // Only train if learning is enabled
        guard isLearningEnabled else {
            return
        }

        // Check if we have enough interactions
        interactionsLock.lock()
        let interactionCount = storedInteractions.count
        interactionsLock.unlock()

        guard interactionCount >= minInteractionsForTraining else {
            return
        }

        // Check when we last trained
        let lastTraining = UserDefaults.standard.object(forKey: lastTrainingKey) as? Date ?? Date.distantPast
        let daysSinceLastTraining = Calendar.current.dateComponents([.day], from: lastTraining, to: Date()).day ?? Int
            .max

        guard daysSinceLastTraining >= minDaysBetweenTraining else {
            return
        }

        // We meet all criteria, start training
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let result = self.trainNewModel()
            if !result.success {
                Debug.shared.log(message: "Training failed: \(result.errorMessage ?? "Unknown error")", type: .error)
            }
        }
    }

    /// Train a new model using all collected data
    func trainNewModel() -> (success: Bool, version: String, errorMessage: String?) {
        Debug.shared.log(message: "Starting comprehensive AI model training", type: .info)

        do {
            // Lock and copy all data
            interactionsLock.lock()
            behaviorsLock.lock()
            patternsLock.lock()

            let interactionsToUse = storedInteractions
            let behaviorsToUse = userBehaviors
            let patternsToUse = appUsagePatterns

            interactionsLock.unlock()
            behaviorsLock.unlock()
            patternsLock.unlock()

            // Generate new version
            let timestamp = Int(Date().timeIntervalSince1970)
            let newVersion = "1.0.\(timestamp)"

            // Prepare training data - now more flexible for initial model creation
            var trainingData = interactionsToUse

            // If we have feedback, prioritize interactions with positive feedback for better quality
            let withFeedback = interactionsToUse.filter { $0.feedback != nil }
            if withFeedback.count >= 3 {
                trainingData = interactionsToUse.filter {
                    if let feedback = $0.feedback {
                        return feedback.rating >= 3 // Only use moderate to positive examples
                    }
                    return false
                }
            }

            // Handle case where we don't have enough examples (more flexible now)
            if trainingData.count < 3 {
                // If we don't have enough feedback data but have some regular interactions, use those
                if interactionsToUse.count >= 3 {
                    Debug.shared.log(
                        message: "Using all available interactions without feedback filtering",
                        type: .info
                    )
                    trainingData = interactionsToUse
                } else {
                    Debug.shared.log(message: "Not enough training examples", type: .warning)
                    return (false, newVersion, "Not enough training examples (need at least 3)")
                }
            }

            // Create MLDataTable from interactions
            var textInput: [String] = []
            var intentOutput: [String] = []
            var contextData: [[String: String]] = []

            // Add message data
            for interaction in trainingData {
                textInput.append(interaction.userMessage)
                intentOutput.append(interaction.detectedIntent)

                // Add context when available
                if let context = interaction.context {
                    contextData.append(context)
                } else {
                    contextData.append([:])
                }
            }

            // Add behavior data to enhance the model
            if !behaviorsToUse.isEmpty {
                Debug.shared.log(
                    message: "Incorporating \(behaviorsToUse.count) behavior records into training",
                    type: .info
                )

                // Convert behaviors to training features
                for behavior in behaviorsToUse {
                    // Create a composite feature from the behavior
                    let behaviorText = "User performed \(behavior.action) on \(behavior.screen) screen"
                    let behaviorIntent = getIntentFromBehavior(behavior)

                    textInput.append(behaviorText)
                    intentOutput.append(behaviorIntent)
                    contextData.append(behavior.details)
                }
            }

            // Add usage patterns to enhance the model
            if !patternsToUse.isEmpty {
                Debug.shared.log(
                    message: "Incorporating \(patternsToUse.count) usage patterns into training",
                    type: .info
                )

                // Convert patterns to training features
                for pattern in patternsToUse where pattern.completedTask {
                    // Only use completed tasks as they represent successful flows
                    let patternText = "User worked with \(pattern.feature) feature"
                    let patternIntent = "use:\(pattern.feature)"

                    textInput.append(patternText)
                    intentOutput.append(patternIntent)
                    contextData.append(["sequence": pattern.actionSequence.joined(separator: ","),
                                        "completed": String(pattern.completedTask)])
                }
            }

            // Create enhanced text classifier with context features
            let modelURL = modelsDirectory.appendingPathComponent("model_\(newVersion).mlmodel")

            // Create data table for CreateML - Using the appropriate constructor format
            let dataTable = try MLDataTable(
                dictionary: [
                    "text": textInput,
                    "label": intentOutput,
                ]
            )

            // Train model with simplified approach
            let textClassifier = try MLTextClassifier(
                trainingData: dataTable,
                textColumn: "text",
                labelColumn: "label"
            )

            // Save the model
            try textClassifier.write(to: modelURL)

            // Update current version
            currentModelVersion = newVersion
            UserDefaults.standard.set(newVersion, forKey: modelVersionKey)
            UserDefaults.standard.set(Date(), forKey: lastTrainingKey)

            Debug.shared.log(
                message: "Successfully trained new comprehensive model version: \(newVersion)",
                type: .info
            )

            // Notify that a new model is available
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("AIModelUpdated"), object: nil)
            }

            return (true, newVersion, nil)
        } catch {
            Debug.shared.log(message: "Failed to train model: \(error)", type: .error)
            return (false, currentModelVersion, error.localizedDescription)
        }
    }

    /// Calculate average rating from feedbacks
    private func calculateAverageRating() -> Double {
        let feedbacks = storedInteractions.compactMap { $0.feedback }

        if feedbacks.isEmpty {
            return 0.0
        }

        let sum = feedbacks.reduce(0) { $0 + $1.rating }
        return Double(sum) / Double(feedbacks.count)
    }

    /// Save interactions to disk
    func saveInteractions() {
        interactionsLock.lock()
        defer { interactionsLock.unlock() }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(storedInteractions)
            try data.write(to: interactionsPath)
        } catch {
            Debug.shared.log(message: "Failed to save interactions: \(error)", type: .error)
        }
    }

    /// Save user behaviors to disk
    func saveBehaviors() {
        behaviorsLock.lock()
        defer { behaviorsLock.unlock() }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(userBehaviors)
            try data.write(to: behaviorsPath)
        } catch {
            Debug.shared.log(message: "Failed to save user behaviors: \(error)", type: .error)
        }
    }

    /// Save app usage patterns to disk
    func savePatterns() {
        patternsLock.lock()
        defer { patternsLock.unlock() }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(appUsagePatterns)
            try data.write(to: patternsPath)
        } catch {
            Debug.shared.log(message: "Failed to save app usage patterns: \(error)", type: .error)
        }
    }

    /// Get the current app context
    private func getCurrentContext() -> [String: String]? {
        // Convert AppContext to a string dictionary
        let context = AppContextManager.shared.currentContext()

        // Extract relevant fields as strings
        var contextDict: [String: String] = [:]
        contextDict["screen"] = context.currentScreen

        // Get session ID from additional data if available
        if let sessionId = context.additionalData["currentChatSession"] as? String {
            contextDict["session"] = sessionId
        }

        // Only return if we have at least one valid value
        return contextDict.isEmpty ? nil : contextDict
    }

    /// Map user behavior to an intent
    func getIntentFromBehavior(_ behavior: UserBehavior) -> String {
        switch behavior.action {
        case "open":
            return "navigate:\(behavior.screen)"
        case "search":
            return "search:\(behavior.screen)"
        case "download":
            return "download"
        case "install":
            return "install"
        case "sign":
            return "sign"
        default:
            return "action:\(behavior.action)"
        }
    }

    /// Load interactions from disk
    private func loadInteractions() {
        guard FileManager.default.fileExists(atPath: interactionsPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: interactionsPath)
            let decoder = JSONDecoder()
            let interactions = try decoder.decode([AIInteraction].self, from: data)

            interactionsLock.lock()
            storedInteractions = interactions
            interactionsLock.unlock()

            Debug.shared.log(message: "Loaded \(interactions.count) stored interactions", type: .info)
        } catch {
            Debug.shared.log(message: "Failed to load stored interactions: \(error)", type: .error)
        }
    }

    /// Load user behaviors from disk
    private func loadBehaviors() {
        guard FileManager.default.fileExists(atPath: behaviorsPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: behaviorsPath)
            let decoder = JSONDecoder()
            let behaviors = try decoder.decode([UserBehavior].self, from: data)

            behaviorsLock.lock()
            userBehaviors = behaviors
            behaviorsLock.unlock()

            Debug.shared.log(message: "Loaded \(behaviors.count) stored user behaviors", type: .info)
        } catch {
            Debug.shared.log(message: "Failed to load stored user behaviors: \(error)", type: .error)
        }
    }

    /// Load app usage patterns from disk
    private func loadPatterns() {
        guard FileManager.default.fileExists(atPath: patternsPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: patternsPath)
            let decoder = JSONDecoder()
            let patterns = try decoder.decode([AppUsagePattern].self, from: data)

            patternsLock.lock()
            appUsagePatterns = patterns
            patternsLock.unlock()

            Debug.shared.log(message: "Loaded \(patterns.count) stored app usage patterns", type: .info)
        } catch {
            Debug.shared.log(message: "Failed to load stored app usage patterns: \(error)", type: .error)
        }
    }
}

// MARK: - Model Types

/// Represents a single user interaction with the AI
struct AIInteraction: Codable, Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let userMessage: String
    let aiResponse: String
    let detectedIntent: String
    let confidenceScore: Double
    var feedback: AIFeedback?
    let context: [String: String]?
    let appVersion: String
    let modelVersion: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id
    }
}

/// User feedback on an AI interaction
struct AIFeedback: Codable {
    let rating: Int // 1-5 rating
    let comment: String?
}

/// Represents a user behavior within the app
struct UserBehavior: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let action: String
    let screen: String
    let duration: TimeInterval
    let details: [String: String]
}

/// Represents a pattern of app usage
struct AppUsagePattern: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let feature: String
    let timeSpent: TimeInterval
    let actionSequence: [String]
    let completedTask: Bool
}

/// Statistics about stored interactions and learning
struct LearningStatistics {
    let totalInteractions: Int
    let interactionsWithFeedback: Int
    let averageFeedbackRating: Double
    let behaviorCount: Int
    let patternCount: Int
    let totalDataPoints: Int
    let modelVersion: String
    let lastTrainingDate: Date?
}

/// Errors that can occur during model export
enum ExportError: Error, LocalizedError {
    case invalidPassword
    case modelNotFound
    case exportFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password provided for model export"
        case .modelNotFound:
            return "No trained model found to export"
        case let .exportFailed(error):
            return "Export failed: \(error.localizedDescription)"
        }
    }
}
