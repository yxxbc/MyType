// 应用更新：发布页的地址、tag 和安装包名在这里定，网络、校验和安装在 App 层（Updater.swift）。
//
// 检查更新走发布页的 302（https://github.com/<repo>/releases/latest → /releases/tag/v<版本>），
// 不碰 api.github.com：没有匿名调用次数限制，也不需要 token。
// 下载用同一页的资产地址：/releases/download/<tag>/MyType-<版本>-macos.pkg 和 SHA256SUMS。

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Update {
    /// 发布仓库，和根目录 install.sh 的默认值一样。
    public static let repo = "yxxbc/MyType"
    public static let packagePrefix = "MyType-"
    public static let packageSuffix = "-macos.pkg"
    public static let checksumFile = "SHA256SUMS"

    public static var latestPage: String { "https://github.com/\(repo)/releases/latest" }

    public static func releasePage(tag: String) -> String {
        "https://github.com/\(repo)/releases/tag/\(tag)"
    }

    /// tag 里的版本：去掉开头的 v，后面的字符得是版本号允许的（和 install.sh 的校验一致）。
    public static func version(fromTag tag: String) -> String? {
        var v = tag
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return isVersion(v) ? v : nil
    }

    /// 发布页 302 的地址里取 tag：.../releases/tag/v0.6.0 → v0.6.0。
    /// 跳到 /releases（还没有正式版）或别的地址时是 nil。
    public static func tag(fromURL url: String) -> String? {
        // 不用 Foundation：按 / 拆开找 .../releases/tag/<tag>
        let parts = url.split(separator: "/")
        guard let i = parts.firstIndex(of: "tag"), i >= 1, parts[i - 1] == "releases", i + 1 < parts.count
        else { return nil }
        var tag = String(parts[i + 1])
        if let cut = tag.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            tag = String(tag[..<cut])
        }
        return tag.isEmpty ? nil : tag
    }

    public static func packageName(version: String) -> String {
        packagePrefix + version + packageSuffix
    }

    public static func packageURL(tag: String, version: String) -> String {
        "https://github.com/\(repo)/releases/download/\(tag)/\(packageName(version: version))"
    }

    public static func checksumsURL(tag: String) -> String {
        "https://github.com/\(repo)/releases/download/\(tag)/\(checksumFile)"
    }

    /// 发布页上的版本比现在的新。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        Version.compare(candidate, current) > 0
    }

    /// 版本号：数字开头，只含 ASCII 字母、数字和 . _ + ~ ^ -（和 install.sh 的 pattern 一样）。
    public static func isVersion(_ v: String) -> Bool {
        guard let first = v.unicodeScalars.first, ("0"..."9").contains(first) else { return false }
        return v.unicodeScalars.allSatisfy { s in
            ("0"..."9").contains(s) || ("a"..."z").contains(s) || ("A"..."Z").contains(s)
                || s == "." || s == "_" || s == "+" || s == "~" || s == "^" || s == "-"
        }
    }
}
