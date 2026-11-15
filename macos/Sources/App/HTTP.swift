// GitHub 的普通请求和带进度的下载。词库包（LexiconPackInstaller）和应用更新（Updater）共用。

import Foundation

enum HTTP {
    /// 不走缓存：发布页上的 SHA256SUMS 重试时可能刚换过，测试里也会改。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// 同步 GET，给后台队列用。GitHub 的 API 要 GitHub 的 Accept，其余按 */*。
    static func get(_ url: URL, timeout: TimeInterval = 20) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(url.host == "api.github.com" ? "application/vnd.github+json" : "*/*",
                         forHTTPHeaderField: "Accept")
        request.setValue("MyType/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(PackError("连不上 GitHub"))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(PackError("GitHub 返回 \(http.statusCode)"))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    static func text(_ url: URL, timeout: TimeInterval = 20) throws -> String {
        String(decoding: try get(url, timeout: timeout), as: UTF8.self)
    }
}

/// 带进度的下载（URLSession 的下载任务），下到临时文件。
final class DownloadTask: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let progress: (Int64, Int64) -> Void
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<URL, Error> = .failure(PackError("下载没完成"))

    init(url: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.url = url
        self.progress = progress
    }

    func run() throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("MyType/\(appVersion)", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request).resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return try result.get()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(PackError("下载失败：GitHub 返回 \(http.statusCode)"))
            return
        }
        // location 在这个回调返回后就被删掉，先挪走
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent("mytype-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            result = .success(keep)
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            result = .failure(error)
        }
        done.signal()
    }
}
