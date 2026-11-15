// 版本号比较：按数字段逐段比，前面都一样时段多的大
// （2026.10.31.2 > 2026.10.31，1.0 > 1）。词库包和应用更新都用这一份。

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Version {
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = parts(a), y = parts(b)
        for i in 0..<min(x.count, y.count) where x[i] != y[i] {
            return x[i] < y[i] ? -1 : 1
        }
        return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
    }

    private static func parts(_ v: String) -> [Int] {
        var parts: [Int] = []
        var current: Int?
        for s in v.unicodeScalars {
            if let d = Int(String(s)), ("0"..."9").contains(s) {
                current = (current ?? 0) * 10 + d
            } else if let c = current {
                parts.append(c)
                current = nil
            }
        }
        if let c = current { parts.append(c) }
        return parts
    }
}
