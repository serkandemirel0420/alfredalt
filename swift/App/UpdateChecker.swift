import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var isChecking = false

    private static let releasesURL = URL(string: "https://api.github.com/repos/serkandemirel0420/alfredalt/releases/latest")!
    private var hasCheckedThisSession = false

    var currentVersion: String {
        RustBridgeClient.version()
    }

    func checkOncePerSession() {
        guard !hasCheckedThisSession else { return }
        hasCheckedThisSession = true
        checkForUpdate()
    }

    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true

        Task { [weak self] in
            defer { Task { @MainActor in self?.isChecking = false } }

            do {
                var request = URLRequest(url: Self.releasesURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    return
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    return
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

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.latestVersion = remoteVersion
                    self.downloadURL = dmgURL ?? browserURL
                    self.updateAvailable = self.isNewer(remote: remoteVersion, local: self.currentVersion)
                }
            } catch {
                // Silently fail – update checking is best-effort
            }
        }
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
}
