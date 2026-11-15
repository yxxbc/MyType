// 品牌色：和菜单栏的锦鲤图标一套——暖纸、墨色、朱砂。候选框、语音浮层、设置窗口都从这里取色。

import AppKit
import SwiftUI

enum Brand {
    /// 朱砂（浅色）
    static let accent: UInt32 = 0xB84A32
    /// 深色外观下亮一点的朱砂
    static let accentDark: UInt32 = 0xD06A50
    /// 暖纸
    static let paper: UInt32 = 0xFFFDF9
    static let paperDark: UInt32 = 0x202321
    /// 设置窗口的内容底色
    static let content: UInt32 = 0xF6F1E8
    static let contentDark: UInt32 = 0x191C1A
    static let card: UInt32 = 0xFFFFFF
    static let cardDark: UInt32 = 0x272B28
    static let border: UInt32 = 0xE8E0D3
    static let borderDark: UInt32 = 0x3A3F3B
    static let text: UInt32 = 0x23241F
    static let textDark: UInt32 = 0xEDE9E0
    static let muted: UInt32 = 0x7D776C
    static let mutedDark: UInt32 = 0xA39C90
    static let sidebarTop: UInt32 = 0xF3E8DA
    static let sidebarBottom: UInt32 = 0xFBF6EE
    static let sidebarTopDark: UInt32 = 0x2A211C
    static let sidebarBottomDark: UInt32 = 0x1C1F1D
    static let warning: UInt32 = 0xB86E00
    static let warningDark: UInt32 = 0xF8C66D
}

extension NSColor {
    static func brand(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
