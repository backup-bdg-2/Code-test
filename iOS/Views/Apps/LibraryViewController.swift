import CoreData
import Foundation
import UniformTypeIdentifiers

class LibraryViewController: UITableViewController {
    // MARK: - Properties

    var signedApps: [SignedApps]?
    var downloadedApps: [DownloadedApps]?

    var filteredSignedApps: [SignedApps] = []
    var filteredDownloadedApps: [DownloadedApps] = []

    var installer: Installer?

    public var searchController: UISearchController!
    var popupVC: PopupViewController!
    var loaderAlert: UIAlertController?

    // MARK: - Lifecycle

    init() {
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupSearchController()
        fetchSources()
        loaderAlert = presentLoader()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setupNavigation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: Notification.Name("lfetch"), object: nil)
        NotificationCenter.default.removeObserver(
            self,
            name: Notification.Name("InstallDownloadedApp"),
            object: nil
        )
    }

    // MARK: - Setup

    private func setupViews() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AppsTableViewCell.self, forCellReuseIdentifier: "RoundedBackgroundCell")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshData),
            name: Notification.Name("lfetch"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstallNotification(_:)),
            name: Notification.Name("InstallDownloadedApp"),
            object: nil
        )
    }

    @objc private func handleInstallNotification(_ notification: Notification) {
        guard let downloadedApp = notification.userInfo?["downloadedApp"] as? DownloadedApps else {
            return
        }

        let signingDataWrapper = SigningDataWrapper(signingOptions: UserDefaults.standard.signingOptions)
        signingDataWrapper.signingOptions.installAfterSigned = true

        let signingVC = SigningsViewController(
            signingDataWrapper: signingDataWrapper,
            application: downloadedApp,
            appsViewController: self
        )

        signingVC.signingCompletionHandler = { success in
            if success {
                backdoor.Debug.shared.log(message: "Signing completed successfully", type: LogType.success)
            }
        }

        let navigationController = UINavigationController(rootViewController: signingVC)
        navigationController.shouldPresentFullScreen()

        present(navigationController, animated: true)
    }

    private func setupNavigation() {
        navigationController?.navigationBar.prefersLargeTitles = true
        title = String.localized("TAB_LIBRARY")
    }

    // MARK: - Data Management

    @objc func refreshData() {
        fetchSources()
    }

    func fetchSources() {
        signedApps = CoreDataManager.shared.getDatedSignedApps()
        downloadedApps = CoreDataManager.shared.getDatedDownloadedApps()

        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.1) {
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - App Update Handling

    private func handleAppUpdate(for signedApp: SignedApps) {
        guard let sourceURL = signedApp.originalSourceURL else {
            backdoor.Debug.shared.log(message: "Missing update version or source URL", type: LogType.error)
            return
        }

        backdoor.Debug.shared.log(
            message: "Fetching update from source: \(sourceURL.absoluteString)",
            type: LogType.info
        )

        if let loaderAlert = loaderAlert {
            present(loaderAlert, animated: true)
        }

        if isDebugMode {
            fetchDebugModeUpdate(for: signedApp)
        } else {
            fetchProductionUpdate(from: sourceURL, for: signedApp)
        }
    }

    private func fetchDebugModeUpdate(for signedApp: SignedApps) {
        let mockSource = SourceRefreshOperation()
        mockSource.createMockSource { [weak self] mockSourceData in
            guard let self = self else { return }

            if let sourceData = mockSourceData {
                self.handleSourceData(sourceData, for: signedApp)
            } else {
                backdoor.Debug.shared.log(message: "Failed to create mock source", type: LogType.error)
                DispatchQueue.main.async {
                    self.loaderAlert?.dismiss(animated: true)
                }
            }
        }
    }

    private func fetchProductionUpdate(from sourceURL: URL, for signedApp: SignedApps) {
        SourceGET().downloadURL(from: sourceURL) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case let .success((data, _)):
                if case let .success(sourceData) = SourceGET().parse(data: data) {
                    self.handleSourceData(sourceData, for: signedApp)
                } else {
                    backdoor.Debug.shared.log(message: "Failed to parse source data", type: LogType.error)
                    DispatchQueue.main.async {
                        self.loaderAlert?.dismiss(animated: true)
                    }
                }
            case let .failure(error):
                backdoor.Debug.shared.log(message: "Failed to fetch source: \(error)", type: LogType.error)
                DispatchQueue.main.async {
                    self.loaderAlert?.dismiss(animated: true)
                }
            }
        }
    }

    private func handleSourceData(_ sourceData: SourcesData, for signedApp: SignedApps) {
        guard let bundleId = signedApp.bundleidentifier,
              let updateVersion = signedApp.updateVersion,
              let app = sourceData.apps.first(where: { $0.bundleIdentifier == bundleId }),
              let versions = app.versions
        else {
            backdoor.Debug.shared.log(message: "Failed to find app in source", type: LogType.error)
            DispatchQueue.main.async {
                self.loaderAlert?.dismiss(animated: true)
            }
            return
        }

        // Look for the version that matches our update version
        for version in versions where version.version == updateVersion {
            // Found the matching version
            backdoor.Debug.shared.log(message: "Found matching version: \(version.version)", type: LogType.info)
            let sourceAppVersion = SourceAppVersion(from: version)
            downloadAndProcessUpdate(version: sourceAppVersion, originalApp: signedApp)
            return
        }

        backdoor.Debug.shared.log(message: "Could not find version \(updateVersion) in source", type: LogType.error)
        DispatchQueue.main.async {
            self.loaderAlert?.dismiss(animated: true)
        }
    }

    private func downloadAndProcessUpdate(version: SourceAppVersion, originalApp: SignedApps) {
        let uuid = UUID().uuidString

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            do {
                let tempDirectory = FileManager.default.temporaryDirectory
                let destinationURL = tempDirectory.appendingPathComponent("\(uuid).ipa")

                // Download the file
                if let data = try? Data(contentsOf: version.downloadURL) {
                    try data.write(to: destinationURL)

                    let downloader = AppDownload()
                    try handleIPAFile(destinationURL: destinationURL, uuid: uuid, dl: downloader)

                    DispatchQueue.main.async {
                        self.loaderAlert?.dismiss(animated: true) {
                            self.prepareAndSignDownloadedUpdate(uuid: uuid, originalApp: originalApp)
                        }
                    }
                }
            } catch {
                backdoor.Debug.shared.log(message: "Failed to handle update: \(error)", type: LogType.error)
                DispatchQueue.main.async {
                    self.loaderAlert?.dismiss(animated: true)
                }
            }
        }
    }

    private func prepareAndSignDownloadedUpdate(uuid: String, originalApp: SignedApps) {
        let downloadedApps = CoreDataManager.shared.getDatedDownloadedApps()
        guard let downloadedApp = downloadedApps.first(where: { $0.uuid == uuid }) else {
            return
        }

        let signingDataWrapper = SigningDataWrapper(signingOptions: UserDefaults.standard.signingOptions)
        signingDataWrapper.signingOptions.installAfterSigned = true

        let signingVC = SigningsViewController(
            signingDataWrapper: signingDataWrapper,
            application: downloadedApp,
            appsViewController: self
        )

        signingVC.signingCompletionHandler = { [weak self] success in
            guard let self = self else { return }

            if success {
                do {
                    try CoreDataManager.shared.deleteAllSignedAppContentWithThrow(for: originalApp)
                    self.fetchSources()
                    self.tableView.reloadData()
                } catch {
                    backdoor.Debug.shared.log(
                        message: "Error deleting original signed app: \(error)",
                        type: LogType.error
                    )
                    self.fetchSources()
                    self.tableView.reloadData()
                }
            }
        }

        let navigationController = UINavigationController(rootViewController: signingVC)
        navigationController.shouldPresentFullScreen()
        present(navigationController, animated: true)
    }

    private var isDebugMode: Bool {
        var isDebug = false
        assert({
            isDebug = true
            return true
        }())
        return isDebug
    }

    // MARK: - Helper Methods

    func getApplicationFilePath(with _: NSManagedObject?,
                                row: Int,
                                section: Int,
                                getuuidonly: Bool = false) -> URL?
    {
        do {
            if section == 0, let apps = signedApps, row < apps.count {
                let signedApp = apps[row]
                return try CoreDataManager.shared.getFilesForSignedApps(
                    for: signedApp,
                    getuuidonly: getuuidonly
                )
            } else if let apps = downloadedApps, row < apps.count {
                let downloadedApp = apps[row]
                return try CoreDataManager.shared.getFilesForDownloadedApps(
                    for: downloadedApp,
                    getuuidonly: getuuidonly
                )
            }
        } catch {
            backdoor.Debug.shared.log(message: "Error getting file path: \(error)", type: LogType.error)
        }
        return nil
    }

    func getApplication(row: Int, section: Int) -> NSManagedObject? {
        switch section {
        case 0:
            guard let apps = signedApps, row < apps.count else { return nil }
            return apps[row]
        case 1:
            guard let apps = downloadedApps, row < apps.count else { return nil }
            return apps[row]
        default:
            backdoor.Debug.shared.log(message: "Unknown section: \(section)", type: LogType.error)
            return nil
        }
    }
}

// MARK: - UITableView DataSource & Delegate

extension LibraryViewController {
    override func numberOfSections(in _: UITableView) -> Int {
        return 2
    }
    
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return isFiltering ? filteredSignedApps.count : signedApps?.count ?? 0
        case 1:
            return isFiltering ? filteredDownloadedApps.count : downloadedApps?.count ?? 0
        default:
            return 0
        }
    }
    
    override func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch section {
        case 0:
            let headerWithButton = GroupedSectionHeader(
                title: String.localized("LIBRARY_VIEW_CONTROLLER_SECTION_TITLE_SIGNED_APPS"),
                subtitle: String.localized(
                    "LIBRARY_VIEW_CONTROLLER_SECTION_TITLE_SIGNED_APPS_TOTAL",
                    arguments: String(signedApps?.count ?? 0)
                ),
                buttonTitle: String.localized("LIBRARY_VIEW_CONTROLLER_SECTION_BUTTON_IMPORT"),
                buttonAction: { [weak self] in
                    self?.startImporting()
                }
            )
            return headerWithButton
            
        case 1:
            let headerWithButton = GroupedSectionHeader(
                title: String.localized("LIBRARY_VIEW_CONTROLLER_SECTION_DOWNLOADED_APPS"),
                subtitle: String.localized(
                    "LIBRARY_VIEW_CONTROLLER_SECTION_TITLE_DOWNLOADED_APPS_TOTAL",
                    arguments: String(downloadedApps?.count ?? 0)
                )
            )
            return headerWithButton
            
        default:
            return nil
        }
    }
    
    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = AppsTableViewCell(style: .subtitle, reuseIdentifier: "RoundedBackgroundCell")
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = .clear
        
        guard let source = getApplication(row: indexPath.row, section: indexPath.section),
              let filePath = getApplicationFilePath(
                with: source,
                row: indexPath.row,
                section: indexPath.section
              )
        else {
            return cell
        }
        
        configureCell(cell, with: source, filePath: filePath)
        return cell
    }
    
    private func configureCell(_ cell: AppsTableViewCell, with app: NSManagedObject, filePath: URL) {
        if let iconURL = app.value(forKey: "iconURL") as? String {
            let imagePath = filePath.appendingPathComponent(iconURL)
            
            if let image = CoreDataManager.shared.loadImage(from: imagePath) {
                SectionIcons.sectionImage(to: cell, with: image)
            } else if let defaultImage = UIImage(named: "unknown") {
                SectionIcons.sectionImage(to: cell, with: defaultImage)
            }
        } else if let defaultImage = UIImage(named: "unknown") {
            SectionIcons.sectionImage(to: cell, with: defaultImage)
        }
        
        cell.configure(with: app, filePath: filePath)
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let app = getApplication(row: indexPath.row, section: indexPath.section),
              let fullPath = getApplicationFilePath(
                with: app,
                row: indexPath.row,
                section: indexPath.section,
                getuuidonly: false
              )
        else {
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }

    let uuidOnlyPath = getApplicationFilePath(
        with: app,
        row: indexPath.row,
        section: indexPath.section,
        getuuidonly: true
    )

    let appName = app.value(forKey: "name") as? String ?? ""

    if !FileManager.default.fileExists(atPath: fullPath.path) {
        backdoor.Debug.shared.log(
            message: "The file has been deleted for this entry, please remove it manually.",
            type: .critical
        )
        tableView.deselectRow(at: indexPath, animated: true)
        return
    }

    popupVC = PopupViewController()
    popupVC.modalPresentationStyle = .pageSheet

    switch indexPath.section {
    case 0:
        handleSignedAppAction(
            app: app,
            uuidPath: uuidOnlyPath,
            fullPath: fullPath,
            appName: appName,
            indexPath: indexPath
        )
    case 1:
        handleDownloadedAppAction(
            app: app,
            uuidPath: uuidOnlyPath,
            appName: appName
        )
    default:
        break
    }

    tableView.deselectRow(at: indexPath, animated: true)
}

private func handleSignedAppAction(
    app: NSManagedObject,
    uuidPath: URL?,
    fullPath: URL,
    appName: String,
    indexPath: IndexPath
) {
    let hasUpdate = (app as? SignedApps)?.value(forKey: "hasUpdate") as? Bool ?? false

    if let signedApp = app as? SignedApps, hasUpdate {
        configureUpdateMenuButtons(for: signedApp, appName: appName, indexPath: indexPath)
    } else {
        configureRegularMenuButtons(
            for: app,
            uuidPath: uuidPath,
            fullPath: fullPath,
            appName: appName,
            indexPath: indexPath
        )
    }

    configurePopupDetents(hasUpdate: hasUpdate)
    present(popupVC, animated: true)
}

private func configureUpdateMenuButtons(
    for signedApp: SignedApps,
    appName: String,
    indexPath: IndexPath
) {
    // Update available menu
    let updateButton = PopupViewControllerButton(
        title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_UPDATE", arguments: appName),
        color: .tintColor.withAlphaComponent(0.9),
        titleColor: .white
    )
    updateButton.onTap = { [weak self] in
        guard let self = self else { return }
        self.popupVC.dismiss(animated: true) {
            self.handleAppUpdate(for: signedApp)
        }
    }

    let clearButton = PopupViewControllerButton(
        title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_CLEAR_UPDATE"),
        color: .quaternarySystemFill,
        titleColor: .tintColor
    )
    clearButton.onTap = { [weak self] in
        guard let self = self else { return }
        self.popupVC.dismiss(animated: true)
        do {
            try CoreDataManager.shared.clearUpdateStateCompat(for: signedApp)
            self.tableView.reloadRows(at: [indexPath], with: .none)
        } catch {
            backdoor.Debug.shared.log(message: "Error clearing update state: \(error)", type: LogType.error)
        }
    }

    popupVC.configureButtons([updateButton, clearButton])
}

private func configureRegularMenuButtons(
    for app: NSManagedObject,
    uuidPath: URL?,
    fullPath: URL,
    appName: String,
    indexPath: IndexPath
) {
    // Install button
    let installButton = PopupViewControllerButton(
        title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_INSTALL", arguments: appName),
        color: .tintColor.withAlphaComponent(0.9)
    )
    installButton.onTap = { [weak self] in
        guard let self = self else { return }
        self.popupVC.dismiss(animated: true)
        self.startInstallProcess(app: app, filePath: uuidPath?.path ?? "")
    }

    // Open button
    let openButton = PopupViewControllerButton(
        title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_OPEN", arguments: appName),
        color: .quaternarySystemFill,
        titleColor: .tintColor
    )
    openButton.onTap = { [weak self] in
        guard let self = self else { return }
        self.popupVC.dismiss(animated: true)

        if let workspace = LSApplicationWorkspace.default(),
           let bundleID = app.value(forKey: "bundleidentifier") as? String
        {
            let success = workspace.openApplication(withBundleID: bundleID)
            if !success {
                backdoor.Debug.shared.log(
                    message: "Unable to open, do you have the app installed?",
                    type: LogType.warning
                )
            }
        }
    }

    // Resign button
    let resignButton = PopupViewControllerButton(
        title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_RESIGN", arguments: appName),
        color: .quaternarySystemFill,
        titleColor: .tintColor
    )
    resignButton.onTap = { [weak self] in
        guard let self = self else { return }
        self.popupVC.dismiss(animated: true) {
            self.handleResignApp(app: app, fullPath: fullPath, indexPath: indexPath)
        }
    }

    // Share button
    let shareButton = PopupViewControllerButton(
        title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_SHARE", arguments: appName),
        color: .quaternarySystemFill,
        titleColor: .tintColor
    )
    shareButton.onTap = { [weak self] in
        guard let self = self else { return }
        self.popupVC.dismiss(animated: true)
        self.shareFile(app: app, filePath: uuidPath?.path ?? "")
    }

    popupVC.configureButtons([installButton, openButton, resignButton, shareButton])
}

private func handleResignApp(app: NSManagedObject, fullPath: URL, indexPath: IndexPath) {
    guard let signedApp = app as? SignedApps else { return }

    if let cert = CoreDataManager.shared.getCurrentCertificate() {
        if let loaderAlert = loaderAlert {
            present(loaderAlert, animated: true)
        }

        resignApp(certificate: cert, appPath: fullPath) { [weak self] success in
            guard let self = self, success else { return }

            if let expirationDate = cert.certData?.expirationDate,
               let teamName = cert.certData?.name
            {
                // Use the explicit error completion version with full type qualification
                let updateSignedApp: (SignedApps, Date, String, @escaping (Error?) -> Void) -> Void = CoreDataManager
                    .shared.updateSignedApp
                updateSignedApp(
                    signedApp,
                    expirationDate,
                    teamName,
                    { _ in
                        DispatchQueue.main.async {
                            self.loaderAlert?.dismiss(animated: true)
                            backdoor.Debug.shared.log(message: "Resign completed")
                            self.tableView.reloadRows(at: [indexPath], with: .left)
                        }
                    }
                )
            }
        } else {
            showNoCertificatesAlert()
        }
    }

    private func showNoCertificatesAlert() {
        let alert = UIAlertController(
            title: String.localized("APP_SIGNING_VIEW_CONTROLLER_NO_CERTS_ALERT_TITLE"),
            message: String.localized("APP_SIGNING_VIEW_CONTROLLER_NO_CERTS_ALERT_DESCRIPTION"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String.localized("LAME"), style: .default))
        present(alert, animated: true)
    }

    private func handleDownloadedAppAction(
        app: NSManagedObject,
        uuidPath: URL?,
        appName: String
    ) {
        let signingDataWrapper = SigningDataWrapper(signingOptions: UserDefaults.standard.signingOptions)

        // Sign button
        let signButton = PopupViewControllerButton(
            title: signingDataWrapper.signingOptions.installAfterSigned
                ? String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_SIGN_INSTALL", arguments: appName)
                : String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_SIGN", arguments: appName),
            color: .tintColor.withAlphaComponent(0.9)
        )
        signButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.popupVC.dismiss(animated: true)
            self.startSigning(app: app)
        }

        // Install button
        let installButton = PopupViewControllerButton(
            title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_INSTALL", arguments: appName),
            color: .quaternarySystemFill,
            titleColor: .tintColor
        )
        installButton.onTap = { [weak self] in
            guard let self = self else { return }
            self.popupVC.dismiss(animated: true) {
                self.showInstallConfirmationAlert(app: app, filePath: uuidPath?.path ?? "")
            }
        }

        popupVC.configureButtons([signButton, installButton])
        configurePopupDetents(hasUpdate: false)
        present(popupVC, animated: true)
    }

    private func showInstallConfirmationAlert(app: NSManagedObject, filePath: String) {
        let alertController = UIAlertController(
            title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_INSTALL_CONFIRM"),
            message: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_INSTALL_CONFIRM_DESCRIPTION"),
            preferredStyle: .alert
        )

        let confirmAction = UIAlertAction(
            title: String.localized("INSTALL"),
            style: .default
        ) { [weak self] _ in
            self?.startInstallProcess(app: app, filePath: filePath)
        }

        let cancelAction = UIAlertAction(
            title: String.localized("CANCEL"),
            style: .cancel
        )

        alertController.addAction(confirmAction)
        alertController.addAction(cancelAction)
        present(alertController, animated: true)
    }

    private func configurePopupDetents(hasUpdate: Bool) {
        let detentHeight = hasUpdate ? 150.0 : 270.0
        let detent: UISheetPresentationController.Detent = ._detent(
            withIdentifier: "PopupDetent",
            constant: detentHeight
        )

        if let presentationController = popupVC.presentationController as? UISheetPresentationController {
            presentationController.detents = [detent, .medium()]
            presentationController.prefersGrabberVisible = true
        }
    }
}

    // Implementation moved to LibraryViewController+Types extension

    // MARK: - Legacy method for backward compatibility

    // This method is kept for compatibility with existing code
    @available(*, deprecated, message: "Use startSigning(app:) instead")
    func startSigning(meow: NSManagedObject) {
        // Call the method with the original parameter name to match caller expectations
        startSigning(meow: meow)
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        // Access method directly without self, ensuring scope is correct
        guard let app = getApplication(row: indexPath.row, section: indexPath.section) else {
            return nil
        }

        let deleteAction = UIContextualAction(
            style: .destructive,
            title: String.localized("DELETE")
        ) { [weak self] _, _, completionHandler in
            guard let self = self else {
                completionHandler(false)
                return
            }

            do {
                switch indexPath.section {
                case 0:
                    if let signedApp = app as? SignedApps {
                        try CoreDataManager.shared.deleteAllSignedAppContentWithThrow(for: signedApp)
                        self.signedApps?.remove(at: indexPath.row)
                        self.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
                    }
                case 1:
                    if let downloadedApp = app as? DownloadedApps {
                        try CoreDataManager.shared.deleteAllDownloadedAppContentWithThrow(for: downloadedApp)
                        self.downloadedApps?.remove(at: indexPath.row)
                        self.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
                    }
                default:
                    break
                }
                completionHandler(true)
            } catch {
                backdoor.Debug.shared.log(
                    message: "Error deleting app: \(error)",
                    type: LogType.error
                )
                completionHandler(false)
            }
        }

        deleteAction.backgroundColor = UIColor.systemRed
        let configuration = UISwipeActionsConfiguration(actions: [deleteAction])
        configuration.performsFirstActionWithFullSwipe = true

        return configuration
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        // Access methods directly without self, ensuring scope is correct
        guard let app = getApplication(row: indexPath.row, section: indexPath.section),
              let filePath = getApplicationFilePath(
                  with: app,
                  row: indexPath.row,
                  section: indexPath.section
              )
        else {
            return nil
        }

        return UIContextMenuConfiguration(
            identifier: nil,
            actionProvider: { [weak self] _ in
                guard let self = self else { return UIMenu() }

                var actions: [UIAction] = []

                // View details action
                let infoAction = UIAction(
                    title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_VIEW_DATEILS"),
                    image: UIImage(systemName: "info.circle")
                ) { [weak self] _ in
                    guard let self = self else { return }

                    let viewController = AppsInformationViewController()
                    viewController.source = app
                    viewController.filePath = filePath
                    let navigationController = UINavigationController(rootViewController: viewController)

                    if #available(iOS 15.0, *) {
                        if let presentationController = navigationController
                            .presentationController as? UISheetPresentationController
                        {
                            presentationController.detents = [.medium(), .large()]
                        }
                    }

                    self.present(navigationController, animated: true)
                }
                actions.append(infoAction)

                // Open in Files action
                let filesAction = UIAction(
                    title: String.localized("LIBRARY_VIEW_CONTROLLER_SIGN_ACTION_OPEN_LN_FILES"),
                    image: UIImage(systemName: "folder")
                ) { _ in
                    let parentPath = filePath.deletingLastPathComponent()
                    let documentURL = parentPath.absoluteString.replacingOccurrences(
                        of: "file://",
                        with: "shareddocuments://"
                    )

                    if let url = URL(string: documentURL) {
                        UIApplication.shared.open(url, options: [:]) { success in
                            if success {
                                backdoor.Debug.shared.log(message: "File opened successfully.")
                            } else {
                                backdoor.Debug.shared.log(message: "Failed to open file.")
                            }
                        }
                    } else {
                        backdoor.Debug.shared.log(message: "Invalid file URL", type: LogType.error)
                    }
                }
                actions.append(filesAction)

                return UIMenu(title: "", children: actions)
            }
        )
    }
}

// MARK: - Fetch Data Extension

extension LibraryViewController {
    @objc func afetch() { fetchSources() }
}

extension LibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let searchText = searchController.searchBar.text ?? ""
        filterContentForSearchText(searchText)
        tableView.reloadData()
    }

    private func filterContentForSearchText(_ searchText: String) {
        let lowercasedSearchText = searchText.lowercased()

        filteredSignedApps = signedApps?.filter { app in
            let name = (app.value(forKey: "name") as? String ?? "").lowercased()
            return name.contains(lowercasedSearchText)
        } ?? []

        filteredDownloadedApps = downloadedApps?.filter { app in
            let name = (app.value(forKey: "name") as? String ?? "").lowercased()
            return name.contains(lowercasedSearchText)
        } ?? []
    }
}

extension LibraryViewController: UISearchControllerDelegate, UISearchBarDelegate {
    func setupSearchController() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = true
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.searchBar.placeholder = String.localized("SETTINGS_VIEW_CONTROLLER_SEARCH_PLACEHOLDER")
        navigationItem.searchController = searchController
        definesPresentationContext = true
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    var isFiltering: Bool {
        return searchController.isActive && !searchBarIsEmpty
    }

    var searchBarIsEmpty: Bool {
        return searchController.searchBar.text?.isEmpty ?? true
    }
}

// Extension to provide loading alert functionality
extension LibraryViewController {
    /// https://stackoverflow.com/a/75310581
    func presentLoader() -> UIAlertController {
        let alert = UIAlertController(title: nil, message: "", preferredStyle: .alert)
        let activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.isUserInteractionEnabled = false
        activityIndicator.startAnimating()

        alert.view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            alert.view.heightAnchor.constraint(equalToConstant: 95),
            alert.view.widthAnchor.constraint(equalToConstant: 95),
            activityIndicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: alert.view.centerYAnchor),
        ])

        return alert
    }
}
