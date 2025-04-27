import UIKit

extension AppDelegate {
    /// Initialize terminal components
    func setupTerminal() {
        // Register terminal tab option (default to true for new installs)
        if UserDefaults.standard.object(forKey: "show_terminal_button") == nil {
            UserDefaults.standard.set(true, forKey: "show_terminal_button")
        }

        // Remove any existing server settings (now hardcoded)
        UserDefaults.standard.removeObject(forKey: "terminal_server_url")
        UserDefaults.standard.removeObject(forKey: "terminal_api_key")

        // Register AI commands for terminal
        registerTerminalCommands()

        // Initialize button manager
        _ = TerminalButtonManager.shared

        Debug.shared.log(message: "Terminal components initialized", type: .info)
    }

    /// Register terminal-related commands for AI assistant
    private func registerTerminalCommands() {
        // Command: open terminal
        AppContextManager.shared.registerCommand("open terminal") { _, completion in
            DispatchQueue.main.async {
                // Show terminal through notification
                NotificationCenter.default.post(name: .showTerminal, object: nil)
                completion("Terminal opened")
            }
        }

        // Command: execute shell
        AppContextManager.shared.registerCommand("shell") { command, completion in
            // Execute command through ProcessUtility
            ProcessUtility.shared.executeShellCommand(command) { output in
                if let result = output {
                    completion("Command result: \n\(result)")
                } else {
                    completion("Command failed or timed out")
                }
            }
        }

        // Command: terminal settings
        AppContextManager.shared.registerCommand("terminal settings") { _, completion in
            DispatchQueue.main.async {
                if let topVC = UIApplication.shared.topMostViewController() {
                    let settingsVC = TerminalSettingsViewController(style: .grouped)

                    // Present in navigation controller
                    let navController = UINavigationController(rootViewController: settingsVC)
                    topVC.present(navController, animated: true)

                    completion("Terminal settings opened")
                } else {
                    completion("Could not open terminal settings")
                }
            }
        }

        Debug.shared.log(message: "Terminal commands registered with AI assistant", type: .info)
    }

    /// Initialize terminal components after app launch
    func initializeTerminalAfterLaunch() {
        // Delay to allow UI to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Show terminal button if enabled
            if UserDefaults.standard.bool(forKey: "show_terminal_button") {
                TerminalButtonManager.shared.show()
            }
        }
    }

    // Call this from applicationDidBecomeActive
    func restoreTerminalButtonIfNeeded() {
        if UserDefaults.standard.bool(forKey: "show_terminal_button") {
            TerminalButtonManager.shared.show()
        }
    }
}
