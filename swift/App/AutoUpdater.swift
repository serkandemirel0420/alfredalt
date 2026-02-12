import Foundation
import AppKit

@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()
    
    @Published private(set) var isUpdating = false
    @Published private(set) var updateProgress: String = ""
    @Published var showUpdateAvailableAlert = false
    @Published var showRestartAlert = false
    
    private var downloadedDMGURL: URL?
    private var newVersion: String?
    
    private var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.Codex.alfred_alt"
    }
    
    private var currentAppPath: String {
        Bundle.main.bundlePath
    }
    
    func promptForUpdate(version: String, downloadURL: URL) {
        newVersion = version
        downloadedDMGURL = nil
        showUpdateAvailableAlert = true
    }
    
    func startAutoUpdate(downloadURL: URL, version: String) {
        guard !isUpdating else { return }
        
        isUpdating = true
        updateProgress = "Downloading update..."
        newVersion = version
        
        Task {
            do {
                // Step 1: Download DMG
                let dmgURL = try await downloadDMG(from: downloadURL)
                downloadedDMGURL = dmgURL
                
                await MainActor.run {
                    updateProgress = "Installing update..."
                }
                
                // Step 2: Install update
                try await installUpdate(dmgURL: dmgURL)
                
                await MainActor.run {
                    isUpdating = false
                    updateProgress = ""
                    showRestartAlert = true
                }
                
            } catch {
                await MainActor.run {
                    isUpdating = false
                    updateProgress = "Update failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func downloadDMG(from url: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let dmgURL = tempDir.appendingPathComponent("AlfredAlternative_Update.dmg")
        
        try data.write(to: dmgURL)
        return dmgURL
    }
    
    private func installUpdate(dmgURL: URL) async throws {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("alfred_update_mount")
        
        // Clean up any previous mount
        _ = try? await runScript("hdiutil detach \"\(mountPoint.path)\" -force 2>/dev/null; rm -rf \"\(mountPoint.path)\"")
        
        // Create mount directory
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        
        // Mount DMG
        let mountOutput = try await runScript("hdiutil attach \"\(dmgURL.path)\" -mountpoint \"\(mountPoint.path)\" -nobrowse -quiet")
        
        guard !mountOutput.isEmpty else {
            throw UpdateError.mountFailed
        }
        
        // Find the app in the mounted DMG
        let appName = "AlfredAlternative.app"
        let mountedAppPath = mountPoint.appendingPathComponent(appName).path
        
        var appPath = mountedAppPath
        
        if !FileManager.default.fileExists(atPath: appPath) {
            // Try to find it in subdirectories
            let contents = try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)
            var foundApp = false
            for item in contents ?? [] {
                let itemPath = mountPoint.appendingPathComponent(item).path
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir) && isDir.boolValue {
                    let potentialApp = (item as NSString).appendingPathComponent(appName)
                    let potentialPath = mountPoint.appendingPathComponent(potentialApp).path
                    if FileManager.default.fileExists(atPath: potentialPath) {
                        appPath = potentialPath
                        foundApp = true
                        break
                    }
                }
            }
            
            if !foundApp {
                _ = try? await runScript("hdiutil detach \"\(mountPoint.path)\" -force 2>/dev/null")
                throw UpdateError.appNotFound
            }
        }
        
        // Copy update script to temp location (to avoid modifying running bundle)
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("alfred_update.sh")
        let scriptContent = """
        #!/bin/bash
        set -e
        
        sleep 2
        
        # Unmount DMG if still mounted
        hdiutil detach "\(mountPoint.path)" -force 2>/dev/null || true
        
        # Mount DMG again
        hdiutil attach "\(dmgURL.path)" -mountpoint "\(mountPoint.path)" -nobrowse -quiet
        
        # Replace the app
        rm -rf "\(currentAppPath)"
        cp -R "\(appPath)" "\(currentAppPath)"
        
        # Unmount DMG
        hdiutil detach "\(mountPoint.path)" -force 2>/dev/null || true
        
        # Remove downloaded DMG
        rm -f "\(dmgURL.path)"
        
        # Remove script
        rm -f "\(scriptURL.path)"
        
        # Restart the app
        open "\(currentAppPath)"
        """
        
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        // Make script executable
        try await runScript("chmod +x \"\(scriptURL.path)\"")
        
        // Run the update script in background (it will replace us)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup \"\(scriptURL.path)\" > /dev/null 2>&1 &"]
        process.standardOutput = nil
        process.standardError = nil
        try? process.run()
    }
    
    func restartApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 1; open \"\(currentAppPath)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
    
    private func runScript(_ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        guard process.terminationStatus == 0 else {
            throw UpdateError.scriptFailed(output)
        }
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    enum UpdateError: LocalizedError {
        case downloadFailed
        case mountFailed
        case appNotFound
        case scriptFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                return "Failed to download update"
            case .mountFailed:
                return "Failed to mount update file"
            case .appNotFound:
                return "Application not found in update"
            case .scriptFailed(let output):
                return "Installation failed: \(output)"
            }
        }
    }
}
