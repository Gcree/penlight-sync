import AppKit
import Foundation

/// Release tags such as "v1.4.0", compared part by part; kept free of networking so it can be self-tested.
enum ReleaseVersion {
    /// Numeric parts of "v1.4.0" / "1.4"; nil when the text is not a version.
    static func parts(_ text: String) -> [Int]? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        // Ignore a pre-release or build suffix such as "-beta" or "+abc".
        if let end = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = body[..<end] }
        let numbers = body.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return numbers.map { $0! }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = parts(candidate), let old = parts(current) else { return false }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Asks GitHub for the latest release and offers its download page. Only the version number is read; nothing is sent.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Identifiable {
        let version: String
        var id: String { version }
    }

    static let downloadPage = URL(string: "https://github.com/Gcree/penlight-sync/releases/latest")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Gcree/penlight-sync/releases/latest")!
    private let checkOnLaunchKey = "checkUpdatesOnLaunch"
    private let skippedVersionKey = "skippedUpdateVersion"

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    @Published var checkOnLaunch: Bool {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: checkOnLaunchKey) }
    }
    @Published private(set) var isChecking = false
    /// Short result of the last check, shown next to the button.
    @Published private(set) var note: String?
    /// Set when a newer release should be offered; the window shows it as an alert.
    @Published var offered: Release?

    init() {
        checkOnLaunch = UserDefaults.standard.object(forKey: checkOnLaunchKey) as? Bool ?? true
    }

    func checkOnLaunchIfEnabled() async {
        if checkOnLaunch { await check(manual: false) }
    }

    /// A launch check stays silent unless there is a version the user has not skipped; a manual check always reports.
    func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if manual { note = "正在檢查…" }
        do {
            let tag = try await fetchLatestTag()
            if ReleaseVersion.isNewer(tag, than: currentVersion) {
                note = "有新版本 \(tag)"
                if manual || UserDefaults.standard.string(forKey: skippedVersionKey) != tag { offered = Release(version: tag) }
            } else {
                note = manual ? "已是最新版（v\(currentVersion)）" : nil
            }
        } catch {
            if manual { note = "無法檢查更新，請確認網路連線。" }
        }
    }

    private func fetchLatestTag() async throws -> String {
        // 1. 先嘗試 GitHub API（需帶 User-Agent 否則會被 GitHub 403 阻擋）
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 10)
        request.setValue("PenlightSync/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String {
            return tag
        }

        // 2. 備援方案：當 API 超過存取額度或被擋時，向 releases/latest 送出 HEAD 請求讀取重定向標籤（不受 API 頻率限制）
        var headRequest = URLRequest(url: Self.downloadPage, timeoutInterval: 10)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue("PenlightSync/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: headRequest)
        if let finalURL = response.url, finalURL.pathComponents.contains("tag"), let tag = finalURL.pathComponents.last {
            return tag
        }

        throw URLError(.badServerResponse)
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: skippedVersionKey)
    }
}
