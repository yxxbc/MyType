// 向系统登记输入法（install.sh 装好以后调用）。和 Squirrel 的做法一样：
// TISRegisterInputSource 登记安装包，TISEnableInputSource 打开，TISSelectInputSource 切过去。

import Carbon
import Foundation

enum Installer {
    static let bundleID = Bundle.main.bundleIdentifier ?? "io.github.yxxbc.inputmethod.MyType"
    static var modeID: String { bundleID + ".Hans" }

    static func register() -> Bool {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print(status == noErr ? "已登记 \(Bundle.main.bundleURL.path)" : "登记失败（\(status)）")
        return status == noErr
    }

    /// 这个安装包登记过的输入源（includeAllInstalled：没打开的也要列出来）。
    private static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    private static func mode() -> TISInputSource? {
        sources().first { string($0, kTISPropertyInputSourceID) == modeID }
    }

    /// 打开这个安装包登记的**所有**输入源：组件本身和各个输入模式。
    ///
    /// 只打开 `.Hans` 的话菜单栏的输入法菜单里不出现；组件那一条系统有时不认
    /// `TISEnableInputSource`（返回 noErr 但状态还是关着），这时只能到
    /// 「系统设置 → 键盘 → 文字输入」里加一次，或者注销重新登录。
    static func enable() -> Bool {
        // 按 bundle ID 过滤的列表只有输入模式，没有「组件本身」，所以自己从全量列表里挑
        let all = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let list = all.filter { source in
            guard let id = string(source, kTISPropertyInputSourceID) else { return false }
            return id == bundleID || id.hasPrefix(bundleID + ".")
        }
        guard !list.isEmpty else {
            print("没找到输入源 \(bundleID)：先 --register，可能要等几秒或重新登录")
            return false
        }
        var ok = true
        var changed = 0
        for source in list {
            let name = string(source, kTISPropertyInputSourceID) ?? "?"
            if bool(source, kTISPropertyInputSourceIsEnabled) {
                continue
            }
            let status = TISEnableInputSource(source)
            if status != noErr {
                ok = false
                print("打开失败（\(status)）：\(name)")
            } else if bool(source, kTISPropertyInputSourceIsEnabled) {
                changed += 1
            } else {
                // 系统不认：组件那一条常见，到系统设置里加一次就好
                print("系统没让打开 \(name)：到「系统设置 → 键盘 → 文字输入」里加一次")
            }
        }
        if changed == 0 {
            print("已经打开了")
        } else {
            print("已打开 \(changed) 个输入源（\(modeID)）")
        }
        return ok
    }

    static func select() -> Bool {
        guard let source = mode() else {
            print("没找到输入源 \(modeID)")
            return false
        }
        let status = TISSelectInputSource(source)
        print(status == noErr ? "已切到 MyType" : "切换失败（\(status)）")
        return status == noErr
    }

    static func disable() -> Bool {
        var ok = true
        for source in sources() where bool(source, kTISPropertyInputSourceIsEnabled) {
            ok = TISDisableInputSource(source) == noErr && ok
        }
        print(ok ? "已关闭" : "关闭失败")
        return ok
    }
}
