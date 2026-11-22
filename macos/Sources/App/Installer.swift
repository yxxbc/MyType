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
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter {
            guard let id = string($0, kTISPropertyInputSourceID) else { return false }
            return id == bundleID || id == modeID
        }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    private static func registeredPair() -> (component: TISInputSource, mode: TISInputSource)? {
        let list = sources()
        let components = list.filter { string($0, kTISPropertyInputSourceID) == bundleID }
        let modes = list.filter { string($0, kTISPropertyInputSourceID) == modeID }
        guard components.count == 1, modes.count == 1 else {
            print("MyType 输入源未就绪（组件 \(components.count)，拼音模式 \(modes.count)）；请从系统设置检查输入源")
            return nil
        }
        return (components[0], modes[0])
    }

    /// 打开这个安装包登记的**所有**输入源：组件本身和各个输入模式。
    ///
    /// 只打开 `.Hans` 的话菜单栏的输入法菜单里不出现；组件那一条系统有时不认
    /// `TISEnableInputSource`（返回 noErr 但状态还是关着），这时只能到
    /// 「系统设置 → 键盘 → 文字输入」里加一次，或者注销重新登录。
    static func enable() -> Bool {
        guard let pair = registeredPair() else { return false }
        for source in [pair.component, pair.mode] where !bool(source, kTISPropertyInputSourceIsEnabled) {
            let status = TISEnableInputSource(source)
            guard status == noErr else {
                print("打开失败（\(status)）：\(string(source, kTISPropertyInputSourceID) ?? "?")")
                return false
            }
        }
        // noErr 不代表组件真的启用；重新读取系统状态，不沿用旧的输入源对象。
        guard let current = registeredPair(),
              bool(current.component, kTISPropertyInputSourceIsEnabled),
              bool(current.mode, kTISPropertyInputSourceIsEnabled) else {
            print("系统尚未启用 MyType：请到「系统设置 → 键盘 → 文字输入」里添加")
            return false
        }
        print("MyType 已启用")
        return true
    }

    static func select() -> Bool {
        guard let pair = registeredPair(),
              bool(pair.component, kTISPropertyInputSourceIsEnabled),
              bool(pair.mode, kTISPropertyInputSourceIsEnabled),
              bool(pair.mode, kTISPropertyInputSourceIsSelectCapable) else {
            print("MyType 当前不可切换")
            return false
        }
        if currentSourceID() != modeID {
            let status = TISSelectInputSource(pair.mode)
            guard status == noErr, currentSourceID() == modeID else {
                print("系统未确认切到 MyType（\(status)）；请在普通文本框里手动切换")
                return false
            }
        }
        print("已切到 MyType")
        return true
    }

    private static func currentSourceID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(current, kTISPropertyInputSourceID)
    }

    /// 只读诊断。安全键盘输入是会话状态；这里报告它，但不尝试关闭或绕过。
    static func inputStatus() -> Bool {
        print("当前输入源：\(currentSourceID() ?? "未知")")
        print("安全键盘输入：\(IsSecureEventInputEnabled() ? "开启" : "关闭")")
        let list = sources()
        print("MyType 输入源条目：\(list.count)")
        for source in list {
            let id = string(source, kTISPropertyInputSourceID) ?? "?"
            let enabled = bool(source, kTISPropertyInputSourceIsEnabled) ? "是" : "否"
            let selectable = bool(source, kTISPropertyInputSourceIsSelectCapable) ? "是" : "否"
            print("  \(id)：已启用=\(enabled)，可选择=\(selectable)")
        }
        return true
    }

    static func disable() -> Bool {
        var ok = true
        // 先关闭模式，再关闭组件；别留下一个仅有组件还在启用的输入法。
        let list = sources()
        let modes = list.filter { string($0, kTISPropertyInputSourceID) == modeID }
        let components = list.filter { string($0, kTISPropertyInputSourceID) == bundleID }
        for source in modes + components where bool(source, kTISPropertyInputSourceIsEnabled) {
            ok = TISDisableInputSource(source) == noErr && ok
        }
        print(ok ? "已关闭" : "关闭失败")
        return ok
    }
}
