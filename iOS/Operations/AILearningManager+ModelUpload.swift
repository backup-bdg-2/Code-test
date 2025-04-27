import CoreML
import Foundation

/// Extension to AILearningManager for enhanced local model functionality
extension AILearningManager {
    /// Perform deep personal learning based on user data
    func performDeepPersonalLearning() {
        Debug.shared.log(message: "Starting deep personal learning process", type: .info)

        // Get the latest model URL
        if getLatestModelURL() == nil {
            Debug.shared.log(message: "No trained model found for enhancement", type: .error)
            return
        }

        // Ensure we have user data to learn from
        interactionsLock.lock()
        let hasInteractions = !storedInteractions.isEmpty
        interactionsLock.unlock()

        behaviorsLock.lock()
        let hasBehaviors = !userBehaviors.isEmpty
        behaviorsLock.unlock()

        if !hasInteractions, !hasBehaviors {
            Debug.shared.log(message: "Insufficient user data for deep learning", type: .info)
            return
        }

        // Trigger the learning process in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.trainNewModel()
        }
    }

    /// Check if a trained model exists and is usable
    func isTrainedModelAvailable() -> Bool {
        if let modelURL = getLatestModelURL() {
            return FileManager.default.fileExists(atPath: modelURL.path)
        }
        return false
    }

    /// Get information about the trained model
    func getTrainedModelInfo() -> (version: String, date: Date?) {
        let version = currentModelVersion
        let date = UserDefaults.standard.object(forKey: lastTrainingKey) as? Date
        return (version, date)
    }

    /// Handle web search data collection for AI improvement
    /// Internal implementation to avoid duplicate method declaration
    func handleWebSearchData(query: String, results: [String]) {
        // Only process if learning is enabled
        guard isLearningEnabled else {
            return
        }

        // Record the search behavior
        let searchDetails: [String: String] = [
            "query": query,
            "resultCount": "\(results.count)",
        ]

        // Add to user behaviors
        recordUserBehavior(
            action: "search",
            screen: "WebSearch",
            duration: 0,
            details: searchDetails
        )

        // Schedule training evaluation
        internalQueueForLocalProcessing()
    }
}
