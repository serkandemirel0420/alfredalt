import Foundation
import AppKit

@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()
    
    @Published private(set) var isUpdating = false
    @Published private(set) var updateProgress: String = ""
    @Published var showUpdateAvailableAlert = false
    @Published var showRestartAlert = false
    @Published var showErrorAlert = false
    @Published var errorMessage: String = ""
    
    private var downloadedDMGURL: URL?
    private var newVersion: String?
    
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
        errorMessage = ""
        
        Task {
            do {
                print("[AutoUpdater] Starting update to version: \(version)")
                print("[AutoUpdater] Current app path: \(currentAppPath)")
                
                // Step 1: Download DMG
                print("[AutoUpdater] Downloading from: \(downloadURL)")
                let dmgURL = try await downloadDMG(from: downloadURL)
                downloadedDMGURL = dmgURL
                print("[AutoUpdater] Downloaded to: \(dmgURL.path)")
                
                await MainActor.run {
                    updateProgress = "Mounting update..."
                }
                
                // Step 2: Verify DMG and find app
                let (mountPoint, appPath) = try await mountAndFindApp(dmgURL: dmgURL)
                print("[AutoUpdater] Found app at: \(appPath)")
                
                await MainActor.run {
                    updateProgress = "Installing update..."
                }
                
                // Step 3: Create and run update script
                try await runUpdateScript(dmgURL: dmgURL, mountPoint: mountPoint, appPath: appPath)
                print("[AutoUpdater] Update script started")
                
                await MainActor.run {
                    isUpdating = false
                    updateProgress = ""
                    showRestartAlert = true
                }
                
            } catch {
                print("[AutoUpdater] Error: \(error)")
                await MainActor.run {
                    isUpdating = false
                    updateProgress = ""
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
    
    private func downloadDMG(from url: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        
        // Verify we got reasonable data (at least 1MB for a DMG)
        guard data.count > 1_000_000 else {
            throw UpdateError.downloadFailed("File too small (\(data.count) bytes)")
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let dmgURL = tempDir.appendingPathComponent("AlfredAlternative_Update_\(Int(Date().timeIntervalSince1970)).dmg")
        
        try data.write(to: dmgURL)
        return dmgURL
    }
    
    private func mountAndFindApp(dmgURL: URL) async throws -> (mountPoint: URL, appPath: String) {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("alfred_update_\(Int(Date().timeIntervalSince1970))")
        
        // Clean up any previous attempts
        _ = try? await runScript("hdiutil detach \"\(mountPoint.path)\" -force 2>/dev/null; rm -rf \"\(mountPoint.path)\"")
        
        // Create mount directory
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        
        // Mount DMG
        let mountOutput = try await runScript("hdiutil attach \"\(dmgURL.path)\" -mountpoint \"\(mountPoint.path)\" -nobrowse")
        print("[AutoUpdater] Mount output: \(mountOutput)")
        
        guard !mountOutput.isEmpty else {
            throw UpdateError.mountFailed("Empty mount output")
        }
        
        // Find the app in the mounted DMG
        let appName = "AlfredAlternative.app"
        let mountedAppPath = mountPoint.appendingPathComponent(appName).path
        
        var appPath = mountedAppPath
        
        if !FileManager.default.fileExists(atPath: appPath) {
            print("[AutoUpdater] App not at root, searching subdirectories...")
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
                        print("[AutoUpdater] Found app in subdirectory: \(item)")
                        break
                    }
                }
            }
            
            if !foundApp {
                _ = try? await runScript("hdiutil detach \"\(mountPoint.path)\" -force 2>/dev/null")
                throw UpdateError.appNotFound("Searched in: \(contents?.joined(separator: ", ") ?? "none")")
            }
        }
        
        return (mountPoint, appPath)
    }
    
    private func runUpdateScript(dmgURL: URL, mountPoint: URL, appPath: String) async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alfred_update_\(Int(Date().timeIntervalSince1970)).sh")
        
        // Create update script with detailed logging
        let scriptContent = """
        #!/bin/bash
        set -e
        
        LOG_FILE="/tmp/alfred_update_$(date +%s).log"
        exec > "$LOG_FILE" 2>&1
        
        echo "=== Alfred Alternative Updater ==="
        echo "Started at: $(date)"
        echo "Current app: \(currentAppPath)"
        echo "New app: \(appPath)"
        
        sleep 3
        
        # Check if source exists
        if [ ! -d "\(appPath)" ]; then
            echo "ERROR: Source app not found at \(appPath)"
            exit 1
        fi
        
        # Unmount first (in case still mounted)
        echo "Unmounting..."
        hdiutil detach "\(mountPoint.path)" -force 2>/dev/null || true
        
        # Mount again to be sure
        echo "Mounting DMG..."
        hdiutil attach "\(dmgURL.path)" -mountpoint "\(mountPoint.path)" -nobrowse
        
        # Verify source still exists after remount
        if [ ! -d "\(appPath)" ]; then
            echo "ERROR: Source app not found after remount"
            exit 1
        fi
        
        # Remove old app
        echo "Removing old app..."
        rm -rf "\(currentAppPath)"
        
        # Copy new app
        echo "Copying new app..."
        cp -R "\(appPath)" "\(currentAppPath)"
        
        # Verify copy succeeded
        if [ ! -d "\(currentAppPath)" ]; then
            echo "ERROR: Copy failed"
            exit 1
        fi
        
        echo "Copy successful"
        
        # Unmount DMG
        echo "Unmounting DMG..."
        hdiutil detach "\(mountPoint.path)" -force 2>/dev/null || true
        
        # Remove downloaded DMG
        echo "Cleaning up..."
        rm -f "\(dmgURL.path)"
        rm -f "\(scriptURL.path)"
        
        # Restart app
        echo "Restarting app..."
        open "\(currentAppPath)"
        
        echo "Done at: $(date)"
        """
        
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        // Make script executable
        try await runScript("chmod +x \"\(scriptURL.path)\"")
        
        // Run the update script - it will run synchronously until it backgrounds itself
        // We use a different approach: run it in a way that allows it to continue after we exit
        let launcherScript = """
        nohup "\(scriptURL.path)" > /dev/null 2>&1 &
        disown
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", launcherScript]
        try process.run()
        process.waitUntilExit()
        
        // Give the script a moment to start
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
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
            throw UpdateError.scriptFailed("Exit code \(process.terminationStatus): \(output)")
        }
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    enum UpdateError: LocalizedError {
        case downloadFailed(String)
        case mountFailed(String)
        case appNotFound(String)
        case scriptFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason):
                return "Download failed: \(reason)"
            case .mountFailed(let reason):
                return "Mount failed: \(reason)"
            case .appNotFound(let reason):
                return "App not found: \(reason)"
            case .scriptFailed(let output):
                return "Installation failed: \(output)"
            }
        }
    }
}
