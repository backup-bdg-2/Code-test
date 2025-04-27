import Foundation

// MARK: - Local Enhanced Learning Extension

extension AILearningManager {
    /// Queue data for local processing - internal implementation
    func internalQueueForLocalProcessing() {
        // Don't queue if learning is disabled
        guard isLearningEnabled else {
            return
        }

        // Set the processing flag - we'll handle it in a background task
        UserDefaults.standard.set(true, forKey: "AINeedsLocalProcessing")

        // Schedule processing if needed
        scheduleLocalProcessing()
    }

    /// Public API for queueing data - keeps original method name for compatibility
    /// This is added to resolve duplication issues across extension files
    func queueForLocalProcessing() {
        internalQueueForLocalProcessing()
    }

    /// Schedule local data processing
    func scheduleLocalProcessing() {
        // Check if processing is already scheduled
        if UserDefaults.standard.bool(forKey: "AILocalProcessingScheduled") {
            return
        }

        // Set the scheduled flag
        UserDefaults.standard.set(true, forKey: "AILocalProcessingScheduled")

        // Schedule the processing after a delay to batch multiple changes
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self else { return }

            // Reset the scheduled flag
            UserDefaults.standard.set(false, forKey: "AILocalProcessingScheduled")

            // Check if processing is still needed
            if UserDefaults.standard.bool(forKey: "AINeedsLocalProcessing") {
                // Reset the needs processing flag before starting
                UserDefaults.standard.set(false, forKey: "AINeedsLocalProcessing")

                // Perform local processing
                self.trainModelWithAllInteractions()
            }
        }
    }

    /// Perform enhanced local training to improve personalization
    /// Internal implementation to avoid duplicate method declaration
    func enhancedLocalTraining() {
        // Don't process if disabled
        guard isLearningEnabled else {
            Debug.shared.log(message: "Enhanced local training skipped - learning disabled", type: .info)
            return
        }

        Debug.shared.log(message: "Starting enhanced local AI training", type: .info)

        // Get data to process
        let processData = getLocalProcessingData()
        let interactionsToProcess = processData.interactions
        let behaviorsToProcess = processData.behaviors
        let patternsToProcess = processData.patterns

        // Only process if we have data
        if interactionsToProcess.isEmpty, behaviorsToProcess.isEmpty, patternsToProcess.isEmpty {
            Debug.shared.log(message: "No data for enhanced local training", type: .info)
            return
        }

        // Process data - this triggers the training algorithm
        DispatchQueue.global(qos: .background).async { [weak self] in
            if let self = self {
                self.trainModelNow { _, _ in }
            }
        }
    }

    /// Helper to get local processing data
    private func getLocalProcessingData()
        -> (interactions: [AIInteraction], behaviors: [UserBehavior], patterns: [AppUsagePattern])
    {
        // Use a dedicated dispatch queue to safely access the shared resources
        let processQueue = DispatchQueue(label: "com.backdoor.ai.localProcessingQueue")

        // Variables to hold the copied data
        var interactionsCopy: [AIInteraction] = []
        var behaviorsCopy: [UserBehavior] = []
        var patternsCopy: [AppUsagePattern] = []

        // Execute synchronously on the queue
        processQueue.sync {
            // Lock data for reading
            interactionsLock.lock()
            behaviorsLock.lock()
            patternsLock.lock()

            // Create copies to avoid threading issues
            interactionsCopy = storedInteractions
            behaviorsCopy = userBehaviors
            patternsCopy = appUsagePatterns

            // Unlock data
            interactionsLock.unlock()
            behaviorsLock.unlock()
            patternsLock.unlock()
        }

        return (interactions: interactionsCopy, behaviors: behaviorsCopy, patterns: patternsCopy)
    }

    /// Initiates background data collection for AI improvement
    /// Internal implementation to avoid duplication in extensions
    func internalCollectUserDataInBackground() {
        // Only collect if learning is enabled
        guard isLearningEnabled else {
            return
        }

        // Start passive data collection in background
        DispatchQueue.global(qos: .background).async { [weak self] in
            // Collect app usage statistics
            let currentContext = AppContextManager.shared.currentContext()
            // Record app context
            let contextData: [String: String] = [
                "screen": currentContext.currentScreen,
                "action": "view",
                "timestamp": "\(Date().timeIntervalSince1970)",
            ]

            // Add to behaviors dataset
            self?.recordUserBehavior(
                action: "view",
                screen: currentContext.currentScreen,
                duration: 0,
                details: contextData
            )
        }
    }

    // Public API is now defined in AILearningManager.swift
    // We're keeping the internal implementation only in this extension
}
