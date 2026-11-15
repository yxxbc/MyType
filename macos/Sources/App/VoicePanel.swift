// 语音输入时的浮层：一张暖纸色的小卡片，左边朱砂麦克风，右边跟着音量动的波形，
// 下面是识别到一半的字；出错/权限提示换成图标 + 一行说明。
// 和候选框分开：语音时只显示这一张，不再往候选框里塞 emoji。

import AppKit

final class VoicePanel {
    private let panel: NSPanel
    private let view = VoiceView()
    /// false：只排版、摆位置，不放上屏幕（外壳测试用）
    var onScreen = true
    private var shown = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: VoiceView.width, height: 120),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.contentView = view
    }

    func show(_ presentation: VoicePresentation, below line: NSRect) {
        guard presentation != .hidden else {
            hide()
            return
        }
        let size = VoiceView.size(for: presentation)
        view.presentation = presentation
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, line: line))
        guard onScreen else { return }
        if shown {
            panel.displayIfNeeded()
            return
        }
        shown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        view.presentation = .hidden
        guard onScreen else {
            shown = false
            return
        }
        guard shown else {
            panel.orderOut(nil)
            return
        }
        shown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    /// 调试/截图用：把卡片画成 PNG（不依赖窗口在不在前台）
    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// 浮层左上角对齐光标；下面放不下就放到这一行上面，左右夹在屏幕里。
    private func origin(for size: NSSize, line: NSRect) -> NSPoint {
        let anchor = line.origin == .zero && line.size == .zero
            ? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 0, height: 18))
            : line
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 10000, height: 10000)
        var x = anchor.minX
        var y = anchor.minY - size.height - 8
        if y < visible.minY + 8 {
            y = anchor.maxY + 8
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

private final class VoiceView: NSView {
    static let width: CGFloat = 344
    var presentation: VoicePresentation = .hidden {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: 17, weight: .medium)
    private static let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let messageFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)

    private static func bodyHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 22 }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width - 36, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont])
        return min(44, max(22, ceil(bounds.height) + 2))
    }

    private static func messageHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width - 78, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: messageFont])
        return ceil(bounds.height) + 2
    }

    static func size(for presentation: VoicePresentation) -> NSSize {
        switch presentation {
        case .hidden:
            return .zero
        case .listening(_, let text), .thinking(let text):
            return NSSize(width: width, height: 66 + bodyHeight(text) + 42)
        case .message(let text, _):
            return NSSize(width: width, height: max(78, 16 + messageHeight(text) + 18))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accent = NSColor.brand(dark ? Brand.accentDark : Brand.accent)
        let ink = NSColor.brand(dark ? Brand.textDark : Brand.text)
        let muted = NSColor.brand(dark ? Brand.mutedDark : Brand.muted)
        let paper = NSColor.brand(dark ? Brand.paperDark : Brand.paper)
        let top = paper.blended(withFraction: dark ? 0.10 : 0.35, of: .white) ?? paper
        let border = NSColor.brand(dark ? Brand.borderDark : Brand.border)
        let warning = NSColor.brand(dark ? Brand.warningDark : Brand.warning)

        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        NSGradient(starting: top, ending: paper)?.draw(in: bounds, angle: -90)
        // 右上角一点朱砂晕开，像纸上化开的颜色
        accent.withAlphaComponent(dark ? 0.10 : 0.055).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 190, y: -80, width: 260, height: 200)).fill()
        NSGraphicsContext.restoreGraphicsState()
        border.setStroke()
        card.lineWidth = 1
        card.stroke()
        drawCardShine(dark: dark)

        switch presentation {
        case .hidden:
            return
        case .listening(let levels, let text):
            drawMic(in: NSRect(x: 18, y: 16, width: 38, height: 38), symbol: "mic.fill", color: accent,
                    dark: dark)
            drawTitle("正在听…", dot: accent, color: muted, y: 16)
            drawBars(levels, color: accent, y: 36)
            drawBody(text.isEmpty ? "说吧，我在听…" : text, color: text.isEmpty ? muted : ink)
            drawHint("松开结束 · Esc 取消", color: muted)
        case .thinking(let text):
            drawMic(in: NSRect(x: 18, y: 16, width: 38, height: 38), symbol: "waveform", color: accent,
                    dark: dark)
            drawTitle("正在识别…", dot: accent, color: muted, y: 16)
            drawThinkingDots(accent, y: 36)
            drawBody(text.isEmpty ? "正在把语音变成文字…" : text, color: text.isEmpty ? muted : ink)
            drawHint("正在识别，请稍等…", color: muted)
        case .message(let text, let error):
            let color = error ? warning : accent
            drawMic(in: NSRect(x: 18, y: 16, width: 34, height: 34),
                    symbol: text.contains("麦克风") ? "mic.slash.fill" : "exclamationmark.circle.fill",
                    color: color, dark: dark)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.messageFont, .foregroundColor: ink,
            ]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.lineBreakMode = .byWordWrapping
            var attrs = attributes
            attrs[.paragraphStyle] = paragraph
            (text as NSString).draw(in: NSRect(x: 64, y: 15, width: bounds.width - 82, height: bounds.height - 28),
                                    withAttributes: attrs)
        }
    }

    private func drawCardShine(dark: Bool) {
        NSColor.white.withAlphaComponent(dark ? 0.05 : 0.55).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 18, y: 1.2))
        line.line(to: NSPoint(x: bounds.width - 18, y: 1.2))
        line.lineWidth = 1
        line.stroke()
    }

    private func drawMic(in rect: NSRect, symbol: String, color: NSColor, dark: Bool) {
        color.withAlphaComponent(dark ? 0.20 : 0.11).setFill()
        NSBezierPath(ovalIn: rect).fill()
        color.withAlphaComponent(0.28).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -4, dy: -4))
        ring.lineWidth = 1
        ring.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        image.draw(in: rect.insetBy(dx: 10, dy: 10), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }

    private func drawTitle(_ text: String, dot: NSColor, color: NSColor, y: CGFloat) {
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 68, y: y + 6, width: 5, height: 5)).fill()
        (text as NSString).draw(at: NSPoint(x: 78, y: y + 1),
                                withAttributes: [.font: Self.titleFont, .foregroundColor: color])
    }

    private func drawBars(_ levels: [Int], color: NSColor, y: CGFloat) {
        color.setFill()
        let height: CGFloat = 16
        let pad = 6 - min(levels.count, 6)
        for i in 0..<6 {
            let level = i >= pad ? levels[i - pad] : 0
            let h = 3 + CGFloat(min(max(level, 0), 100)) / 100 * height
            let rect = NSRect(x: 68 + CGFloat(i) * 8, y: y + (height - h) / 2, width: 4, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawThinkingDots(_ color: NSColor, y: CGFloat) {
        for i in 0..<3 {
            color.withAlphaComponent(i == 2 ? 0.4 : 0.75).setFill()
            NSBezierPath(ovalIn: NSRect(x: 68 + CGFloat(i) * 9, y: y + 6, width: 5, height: 5)).fill()
        }
    }

    private func drawBody(_ text: String, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: NSRect(x: 18, y: 66, width: bounds.width - 36, height: bounds.height - 104),
                                withAttributes: [.font: Self.bodyFont, .foregroundColor: color,
                                                 .paragraphStyle: paragraph])
    }

    private func drawHint(_ text: String, color: NSColor) {
        (text as NSString).draw(at: NSPoint(x: 18, y: bounds.height - 24),
                                withAttributes: [.font: Self.hintFont, .foregroundColor: color])
    }
}
