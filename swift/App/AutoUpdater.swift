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

    private var installTargetAppPath: String {
        let currentPath = currentAppPath
        guard currentPath.contains("/AppTranslocation/") else {
            return currentPath
        }

        let appName = (currentPath as NSString).lastPathComponent
        let candidates = [
            "/Applications/\(appName)",
            "\(NSHomeDirectory())/Applications/\(appName)"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }

        return candidates[1]
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
                print("[AutoUpdater] Install target path: \(installTargetAppPath)")
                
                // Step 1: Download DMG
                print("[AutoUpdater] Downloading from: \(downloadURL)")
                let dmgURL = try await downloadDMG(from: downloadURL)
                downloadedDMGURL = dmgURL
                print("[AutoUpdater] Downloaded to: \(dmgURL.path)")
                
                await MainActor.run {
                    updateProgress = "Preparing installer..."
                }
                
                // Step 2: Prepare deferred installer and wait for user restart.
                let scriptURL = try createDeferredInstallScript(dmgURL: dmgURL)
                try launchUpdateScript(scriptURL)
                print("[AutoUpdater] Deferred installer launched: \(scriptURL.path)")
                
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

    private func createDeferredInstallScript(dmgURL: URL) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alfred_update_\(Int(Date().timeIntervalSince1970)).sh")

        let targetPath = installTargetAppPath
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let quotedTarget = shellEscaped(targetPath)
        let quotedDMG = shellEscaped(dmgURL.path)
        let quotedScript = shellEscaped(scriptURL.path)

        let scriptContent = """
        #!/bin/bash
        set -euo pipefail

        LOG_FILE="/tmp/alfred_update_$(date +%s).log"
        exec > "$LOG_FILE" 2>&1

        TARGET_APP=\(quotedTarget)
        DMG_PATH=\(quotedDMG)
        SELF_SCRIPT=\(quotedScript)
        CURRENT_PID=\(currentPID)
        MOUNT_POINT="$(mktemp -d /tmp/alfred_update_mount.XXXXXX)"
        WORK_DIR="$(mktemp -d /tmp/alfred_update_work.XXXXXX)"

        cleanup() {
            hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
            rm -rf "$MOUNT_POINT" "$WORK_DIR"
            rm -f "$DMG_PATH" "$SELF_SCRIPT"
        }
        trap cleanup EXIT

        echo "=== Alfred Alternative Updater ==="
        echo "Started at: $(date)"
        echo "Current PID: $CURRENT_PID"
        echo "Target app: $TARGET_APP"
        echo "DMG: $DMG_PATH"

        while kill -0 "$CURRENT_PID" >/dev/null 2>&1; do
            sleep 0.25
        done
        echo "Main app exited, continuing update."

        if [ ! -f "$DMG_PATH" ]; then
            echo "ERROR: DMG not found: $DMG_PATH"
            exit 1
        fi

        hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -readonly

        SOURCE_APP="$(find "$MOUNT_POINT" -maxdepth 3 -type d -name 'AlfredAlternative.app' | head -n 1)"
        if [ -z "$SOURCE_APP" ]; then
            echo "ERROR: AlfredAlternative.app not found in mounted DMG"
            exit 1
        fi

        NEW_APP="$WORK_DIR/AlfredAlternative.app"
        ditto "$SOURCE_APP" "$NEW_APP"
        xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true

        mkdir -p "$(dirname "$TARGET_APP")"
        rm -rf "$TARGET_APP"
        mv "$NEW_APP" "$TARGET_APP"

        open "$TARGET_APP"
        echo "Update complete at: $(date)"
        """

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func launchUpdateScript(_ scriptURL: URL) throws {
        let launcherScript = "nohup \(shellEscaped(scriptURL.path)) > /dev/null 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", launcherScript]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.scriptFailed("failed to launch installer script (exit \(process.terminationStatus))")
        }
    }
    
    func restartApp() {
        NSApp.terminate(nil)
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
    
    enum UpdateError: LocalizedError {
        case downloadFailed(String)
        case scriptFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason):
                return "Download failed: \(reason)"
            case .scriptFailed(let output):
                return "Installation failed: \(output)"
            }
        }
    }
}
