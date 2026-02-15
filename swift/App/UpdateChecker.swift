import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var isChecking = false

    private static let releasesURL = URL(string: "https://api.github.com/repos/serkandemirel0420/alfredalt/releases/latest")!
    private static let apiUserAgent = "AlfredAlternative-Updater"
    private var hasCheckedThisSession = false
    var autoUpdateEnabled = true  // Enable automatic updates by default

    var currentVersion: String {
        RustBridgeClient.version()
    }

    func checkOncePerSession() {
        guard !hasCheckedThisSession else { return }
        hasCheckedThisSession = true
        checkForUpdate()
    }
    
    func performAutoUpdate() {
        guard autoUpdateEnabled,
              updateAvailable,
              let version = latestVersion,
              let url = downloadURL else {
            return
        }
        
        // Start automatic update in background
        AutoUpdater.shared.startAutoUpdate(downloadURL: url, version: version)
    }

    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true
        let localVersion = currentVersion
        print("[UpdateChecker] Checking for updates...")
        print("[UpdateChecker] Current version: \(localVersion)")

        Task { [weak self] in
            do {
                let release = try await Self.fetchLatestRelease()

                await MainActor.run {
                    guard let self else { return }
                    let isNewer = self.isNewer(remote: release.version, local: localVersion)
                    print("[UpdateChecker] Remote version: \(release.version)")
                    print("[UpdateChecker] Is newer: \(isNewer)")
                    self.latestVersion = release.version
                    self.downloadURL = release.downloadURL
                    self.updateAvailable = isNewer
                    self.isChecking = false
                }
            } catch {
                print("[UpdateChecker] Error checking for update: \(error)")
                await MainActor.run {
                    self?.isChecking = false
                }
            }
        }
    }

    private static func fetchLatestRelease() async throws -> ReleaseMetadata {
        var request = URLRequest(
            url: releasesURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(apiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateCheckError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateCheckError.invalidPayload
        }

        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        let browserURL: URL? = {
            if let htmlURL = json["html_url"] as? String {
                return URL(string: htmlURL)
            }
            return nil
        }()

        let dmgURL: URL? = {
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let urlString = asset["browser_download_url"] as? String {
                        return URL(string: urlString)
                    }
                }
            }
            return nil
        }()

        return ReleaseMetadata(version: remoteVersion, downloadURL: dmgURL ?? browserURL)
    }

    private func isNewer(remote: String, local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(remoteParts.count, localParts.count)

        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    private struct ReleaseMetadata {
        let version: String
        let downloadURL: URL?
    }

    private enum UpdateCheckError: LocalizedError {
        case httpStatus(Int)
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "GitHub API returned HTTP \(code)"
            case .invalidPayload:
                return "GitHub API response missing release metadata"
            }
        }
    }
}
