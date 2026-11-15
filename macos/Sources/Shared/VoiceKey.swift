// 语音键：设置里的 VoiceKey 用 键名（和以前一样，一份 mytype.conf 两边通用），
// 这里翻成 macOS 的键码。修饰键（右 Option 等）在 flagsChanged 里看按下 / 松开，F 键看 keyDown / keyUp。
// 不依赖 Foundation / AppKit：按键测试不依赖 AppKit 也能编。

public struct VoiceKey: Equatable, Sendable {
    /// macOS 虚拟键码（kVK_*）
    public let keyCode: UInt16
    /// 修饰键在 NSEvent.modifierFlags 里的「分左右」那一位（NX_DEVICE*KEYMASK）；不是修饰键为 0
    public let deviceMask: UInt
    /// 设置里写的键名
    public let name: String

    public var isModifier: Bool { deviceMask != 0 }

    /// 键名 → 键；留空、none、Mac 上没有的键（Menu）返回 nil，语音输入就不用热键。
    public init?(name: String) {
        guard let (code, mask) = VoiceKey.table[name] else { return nil }
        keyCode = code
        deviceMask = mask
        self.name = name
    }

    /// 这次 flagsChanged 里语音键是不是按着（rawFlags 是 NSEvent.modifierFlags.rawValue）。
    /// 正常看分左右的设备位；有的应用/输入法桥会把设备位抹掉，只剩通用修饰位，
    /// 这时按通用位判断（分不出左右，但至少能用）。
    public func isDown(rawFlags: UInt) -> Bool {
        guard deviceMask != 0 else { return false }
        if rawFlags & deviceMask != 0 { return true }
        let (sideBits, generic) = VoiceKey.modifierBits(for: keyCode)
        if rawFlags & sideBits != 0 { return false }
        return rawFlags & generic != 0
    }

    /// 这个修饰键左右两个设备位、和通用修饰位（NSEventModifierFlag*）
    private static func modifierBits(for keyCode: UInt16) -> (UInt, UInt) {
        switch keyCode {
        case 0x3A, 0x3D: return (0x20 | 0x40, 1 << 19) // Option
        case 0x3B, 0x3E: return (0x01 | 0x2000, 1 << 18) // Control
        case 0x38, 0x3C: return (0x02 | 0x04, 1 << 17) // Shift（keyCode 0x3C 少见）
        case 0x37, 0x36: return (0x08 | 0x10, 1 << 20) // Command
        default: return (0, 0)
        }
    }

    // 键码见 Carbon 的 Events.h（kVK_RightOption 等），分左右的位见 IOKit 的 NX_DEVICE*KEYMASK
    private static let table: [String: (UInt16, UInt)] = [
        "Alt_R": (0x3D, 0x40), "Alt_L": (0x3A, 0x20),
        "Control_R": (0x3E, 0x2000), "Control_L": (0x3B, 0x01),
        "Super_R": (0x36, 0x10), "Super_L": (0x37, 0x08),
        "F1": (0x7A, 0), "F2": (0x78, 0), "F3": (0x63, 0), "F4": (0x76, 0),
        "F5": (0x60, 0), "F6": (0x61, 0), "F7": (0x62, 0), "F8": (0x64, 0),
        "F9": (0x65, 0), "F10": (0x6D, 0), "F11": (0x67, 0), "F12": (0x6F, 0),
    ]

    /// 设置窗口里能选的（和 spec/config.json 里 VoiceKey 的 presets.macos 一样）
    public static let presets: [(label: String, name: String)] = [
        ("右 Option", "Alt_R"), ("右 Control", "Control_R"), ("F8", "F8"), ("F9", "F9"), ("F10", "F10"),
    ]
}

/// 正在听时音量画成一排竖条（不足 6 个时左边补最低的）。
public func voiceWave(_ levels: [Int]) -> String {
    let bars = Array("▁▂▃▄▅▆▇█")
    let shown = levels.suffix(6)
    var out = String(repeating: bars[0], count: 6 - shown.count)
    for level in shown {
        out.append(bars[min(max(level, 0), 100) * (bars.count - 1) / 100])
    }
    return out
}
