import Foundation
import CloudKit
import AppKit
import OSLog

private let spikeLogger = Logger(subsystem: "app.theindie.FastTab", category: "CloudKitSpike")

@MainActor
enum CloudKitSpike {
    static func run() {
        Task {
            await runAsync()
        }
    }

    static func runAsync() async {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.trungluong.FastTab", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let logFileURL = appSupportDir.appendingPathComponent("cloudkit-spike.log")

        func log(_ msg: String) {
            print(msg)
            spikeLogger.info("\(msg, privacy: .public)")
            if let data = (msg + "\n").data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        try? fileHandle.close()
                    }
                } else {
                    try? data.write(to: logFileURL)
                }
            }
        }

        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        log("==> [CloudKitSpike] Starting CloudKit Spike Test at \(Date())...")

        let containerID = "iCloud.app.theindie.FastTab"
        let container = CKContainer(identifier: containerID)

        log("==> [CloudKitSpike] Checking account status for container: \(containerID)...")
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                log("✅ [CloudKitSpike] iCloud Account Status: Available")
            case .noAccount:
                log("❌ [CloudKitSpike] iCloud Account Status: No Account (Please sign into iCloud in System Settings)")
                await showAlert(title: "CloudKit Spike: No iCloud Account", message: "Please sign into iCloud in macOS System Settings.")
                return
            case .restricted:
                log("❌ [CloudKitSpike] iCloud Account Status: Restricted")
                await showAlert(title: "CloudKit Spike: Restricted", message: "iCloud access is restricted.")
                return
            case .couldNotDetermine:
                log("❌ [CloudKitSpike] iCloud Account Status: Could Not Determine")
                await showAlert(title: "CloudKit Spike: Could Not Determine", message: "Could not determine iCloud account status.")
                return
            case .temporarilyUnavailable:
                log("❌ [CloudKitSpike] iCloud Account Status: Temporarily Unavailable")
                await showAlert(title: "CloudKit Spike: Temporarily Unavailable", message: "iCloud is temporarily unavailable.")
                return
            @unknown default:
                log("❌ [CloudKitSpike] iCloud Account Status: Unknown (\(status.rawValue))")
                return
            }

            let database = container.privateCloudDatabase
            let testUUID = UUID().uuidString
            let recordID = CKRecord.ID(recordName: "spike-test-\(testUUID)")
            let record = CKRecord(recordType: "SpikeTest", recordID: recordID)
            record["timestamp"] = Date()
            record["device"] = Host.current().localizedName ?? "Mac"
            record["message"] = "Hello from FastTab Developer ID CloudKit Spike"

            log("==> [CloudKitSpike] Writing test record \(recordID.recordName) to private database...")
            let savedRecord = try await database.save(record)
            log("✅ [CloudKitSpike] Successfully saved record to CloudKit! ID: \(savedRecord.recordID.recordName)")

            log("==> [CloudKitSpike] Fetching back test record...")
            let fetchedRecord = try await database.record(for: recordID)
            let device = fetchedRecord["device"] as? String ?? "unknown"
            let message = fetchedRecord["message"] as? String ?? "unknown"
            log("✅ [CloudKitSpike] Successfully fetched record! device='\(device)' message='\(message)'")

            log("==> [CloudKitSpike] Deleting test record...")
            try await database.deleteRecord(withID: recordID)
            log("✅ [CloudKitSpike] Successfully deleted test record.")

            log("\n🎉 [CloudKitSpike] CLOUDKIT SPIKE TEST PASSED! Developer ID + CloudKit is fully working.\n")

            await showAlert(
                title: "🎉 CloudKit Spike Passed!",
                message: "Successfully connected to iCloud.app.theindie.FastTab, wrote a test record to the private database, fetched it back, and deleted it."
            )
        } catch {
            log("❌ [CloudKitSpike] CloudKit operation failed with error: \(error)")
            await showAlert(
                title: "CloudKit Spike Error",
                message: "Error: \(error.localizedDescription)\n\nCheck cloudkit-spike.log for details."
            )
        }
    }

    private static func showAlert(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
