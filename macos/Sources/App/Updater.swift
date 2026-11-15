// 应用更新：检查发布页、下载安装包、交给系统的 installer。
//
// 检查走 https://github.com/<repo>/releases/latest 的 302，只看它跳到哪个 /releases/tag/<tag>，
// 不请求 api.github.com，也不下载发布页。安装包和 SHA256SUMS 从同一页的资产地址下。
// 安装用 /usr/sbin/installer -target CurrentUserHomeDirectory：和 install.sh 一样只装给当前用户，
// 不要管理员密码。pkg 的 preinstall 会停掉正在跑的 MyType，postinstall 重新登记并切回来。

import Foundation

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct UpdateRelease: Equatable {
    let tag: String
    let version: String
    var package: String { Update.packageName(version: version) }
    var page: String { Update.releasePage(tag: tag) }
}

/// 菜单、设置窗口共用的「发布页上有什么」：存在 UserDefaults 里，输入法进程和设置进程都能读。
enum UpdateState {
    static var known: UpdateRelease? {
        let defaults = UserDefaults.standard
        guard let tag = defaults.string(forKey: Updater.knownTagKey),
              let version = defaults.string(forKey: Updater.knownVersionKey), !tag.isEmpty, !version.isEmpty else {
            return nil
        }
        return UpdateRelease(tag: tag, version: version)
    }

    /// 比现在的新才留；发布页还没更新时把旧的记下来。
    static func note(_ release: UpdateRelease, current: String) {
        let defaults = UserDefaults.standard
        if Update.isNewer(release.version, than: current) {
            defaults.set(release.tag, forKey: Updater.knownTagKey)
            defaults.set(release.version, forKey: Updater.knownVersionKey)
        } else {
            defaults.removeObject(forKey: Updater.knownTagKey)
            defaults.removeObject(forKey: Updater.knownVersionKey)
        }
    }

    static func available(current: String) -> UpdateRelease? {
        guard let known, Update.isNewer(known.version, than: current) else { return nil }
        return known
    }
}

final class Updater {
    static let shared = Updater()
    static let checkedAtKey = "MyTypeUpdateCheckedAt"
    static let knownTagKey = "MyTypeKnownUpdateTag"
    static let knownVersionKey = "MyTypeKnownUpdateVersion"
    /// 自动检查最多一天一次（和设置里「关于」页写的一样）
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private init() {}

    // MARK: 检查

    /// 问发布页：302 跳到 /releases/tag/<tag> 就是最新正式版。回调在主线程。
    func checkLatest(completion: @escaping (Result<UpdateRelease, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.fetchLatest() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 启动后在后台查一次，最多一天一次；有新版本记下来，输入法菜单和设置窗口会看到。
    /// 只在输入法进程（main.swift）里调，命令行工具和测试不联网。
    func checkAutomatically(current: String) {
        guard MyTypeConfig.load(path: AppState.shared.configPath).checkUpdate else { return }
        let last = UserDefaults.standard.object(forKey: Updater.checkedAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Updater.checkInterval else { return }
        UserDefaults.standard.set(Date(), forKey: Updater.checkedAtKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.checkLatest { result in
                if case .success(let release) = result {
                    UpdateState.note(release, current: current)
                }
            }
        }
    }

    /// 测试时可以指到本机的假发布页（MYTYPE_UPDATE_LATEST_URL），平时就是 GitHub 的 /releases/latest。
    private var latestURL: URL {
        let override = ProcessInfo.processInfo.environment["MYTYPE_UPDATE_LATEST_URL"] ?? ""
        return URL(string: override.isEmpty ? Update.latestPage : override)!
    }

    /// 测试时把资产目录指到本机（MYTYPE_UPDATE_BASE_URL）；平时用发布页的下载地址。
    private var downloadBase: String? {
        let override = (ProcessInfo.processInfo.environment["MYTYPE_UPDATE_BASE_URL"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return override.isEmpty ? nil : override
    }

    private func packageURL(_ release: UpdateRelease) -> URL? {
        if let base = downloadBase { return URL(string: base + "/" + release.package) }
        return URL(string: Update.packageURL(tag: release.tag, version: release.version))
    }

    private func checksumsURL(_ release: UpdateRelease) -> URL? {
        if let base = downloadBase { return URL(string: base + "/" + Update.checksumFile) }
        return URL(string: Update.checksumsURL(tag: release.tag))
    }

    private func fetchLatest() throws -> UpdateRelease {
        let probe = RedirectProbe()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        var request = URLRequest(url: latestURL)
        request.setValue("MyType/\(appVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
        probe.wait()
        session.finishTasksAndInvalidate()
        if let failure = probe.failure { throw failure }
        guard let url = probe.location, let tag = Update.tag(fromURL: url.absoluteString),
              let version = Update.version(fromTag: tag) else {
            throw UpdateError("发布页上没有找到版本号（连不上 GitHub？）")
        }
        return UpdateRelease(tag: tag, version: version)
    }

    // MARK: 下载

    /// 下载 pkg 并按同一页的 SHA256SUMS 校验，返回临时文件。调用方负责删。
    func download(_ release: UpdateRelease, progress: @escaping (Int64, Int64) -> Void) throws -> URL {
        guard let sumsURL = checksumsURL(release), let packageURL = packageURL(release) else {
            throw UpdateError("发布页上的地址不对")
        }
        let sumsText = try HTTP.text(sumsURL)
        let expected: String
        switch LexiconPack.checksums(sumsText, wanted: [release.package]) {
        case .success(let sums): expected = sums[release.package]!
        case .failure(let error): throw error
        }
        let file = try DownloadTask(url: packageURL, progress: progress).run()
        let digest = try FileHash.sha256(of: file)
        guard digest == expected else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError("\(release.package) 校验和不对，可能没下完整，请重试")
        }
        return file
    }

    // MARK: 安装

    /// 交给系统的 installer（只装给当前用户）。pkg 的 preinstall 会停掉 MyType，所以这个进程很快就会退出。
    /// 只在 ~/Library/Input Methods 里装的版本能这样升级；系统目录装的要用户自己下 pkg。
    func install(package: URL) throws {
        let prefix = NSHomeDirectory() + "/Library/Input Methods/"
        guard Bundle.main.bundleURL.path.hasPrefix(prefix) else {
            throw UpdateError("MyType 装在系统目录，不能自动更新。请到发布页下载安装包。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", package.path, "-target", "CurrentUserHomeDirectory"]
        // pkg 的脚本输出写进临时日志；安装器把 MyType 停掉后这边就没有界面了
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mytype-install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
    }
}

/// 跟着 /releases/latest 的 302：等到地址里有 /releases/tag/<tag> 就停，不下载发布页。
private final class RedirectProbe: NSObject, URLSessionTaskDelegate {
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    var location: URL?
    var failure: Error?

    func wait() { done.wait() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, Update.tag(fromURL: url.absoluteString) != nil {
            location = url
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if location == nil, let url = task.currentRequest?.url,
           Update.tag(fromURL: url.absoluteString) != nil {
            location = url
        }
        if location == nil, let error {
            failure = error
        }
        if !finished {
            finished = true
            done.signal()
        }
    }
}
