// 设置窗口通用配色与表单组件（libadwaita 风格的 PrefGroup / ActionRow / SwitchRow / PickerRow / ExpanderRow）。

import AppKit
import SwiftUI

// MARK: 颜色

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct Palette {
    let dark: Bool
    /// 朱砂色；没有环境可取的静态上下文用 accentLight
    var accent: Color { dark ? Color(hex: Brand.accentDark) : Color(hex: Brand.accent) }
    static let accentLight = Color(hex: Brand.accent)

    var sidebar: LinearGradient {
        let stops: [Gradient.Stop] = dark
            ? [.init(color: Color(hex: Brand.sidebarTopDark), location: 0),
               .init(color: Color(hex: 0x23251F), location: 0.45),
               .init(color: Color(hex: Brand.sidebarBottomDark), location: 1)]
            : [.init(color: Color(hex: Brand.sidebarTop), location: 0),
               .init(color: Color(hex: 0xF8F1E7), location: 0.4),
               .init(color: Color(hex: Brand.sidebarBottom), location: 1)]
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .top, endPoint: .bottom)
    }
    var content: Color { dark ? Color(hex: Brand.contentDark) : Color(hex: Brand.content) }
    var card: Color { dark ? Color(hex: Brand.cardDark) : Color(hex: Brand.card) }
    var cardBorder: Color { dark ? Color(hex: Brand.borderDark) : Color(hex: Brand.border) }
    var nested: Color { dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025) }
    var heading: Color { dark ? Color(hex: Brand.mutedDark) : Color(hex: Brand.muted) }
    var hover: Color { accent.opacity(dark ? 0.14 : 0.10) }
    var warning: Color { dark ? Color(hex: Brand.warningDark) : Color(hex: Brand.warning) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(dark: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: 通用输入与表单行

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

/// ⓘ 小按钮，点开弹出说明文字（可以选中拷贝），links 是说明下面的链接。
struct InfoButton: View {
    let text: String
    var links: [(String, URL)] = []
    @State private var shown = false

    init(_ text: String, links: [(String, URL)] = []) {
        self.text = text
        self.links = links
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("说明")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(links.indices, id: \.self) { i in
                    Link(links[i].0, destination: links[i].1)
                }
            }
            .font(.callout)
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// 只有图标的小按钮（从文件安装、删除、导入导出），鼠标停上去显示 help
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).foregroundColor(.secondary) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

struct PrefGroup<Content: View, Trailing: View>: View {
    let title: String
    let description: String?
    let info: String?
    let links: [(String, URL)]
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @Environment(\.palette) private var palette

    init(_ title: String, description: String? = nil, info: String? = nil, links: [(String, URL)] = [],
         @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.info = info
        self.links = links
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                Circle()
                    .fill(palette.accent)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(palette.heading)
                Spacer()
                trailing
                if let info {
                    InfoButton(info, links: links)
                }
            }
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            VStack(spacing: 0) { content }
                .background(palette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.cardBorder, lineWidth: 1))
                .shadow(color: .black.opacity(palette.dark ? 0.18 : 0.045), radius: 10, y: 2)
        }
    }
}

extension PrefGroup where Trailing == EmptyView {
    init(_ title: String, description: String? = nil, info: String? = nil, links: [(String, URL)] = [],
         @ViewBuilder content: () -> Content) {
        self.init(title, description: description, info: info, links: links, content: content,
                  trailing: { EmptyView() })
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

extension View {
    func rowPadding() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 48)
    }
}

struct RowLabel: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundColor(dim ? .secondary : .primary)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundColor(subtitleColor ?? .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActionRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    var dim = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle, dim: dim)
            if let info { InfoButton(info) }
            trailing
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

extension ActionRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil, dim: Bool = false) {
        self.init(title: title, subtitle: subtitle, info: info, dim: dim, action: nil, trailing: { EmptyView() })
    }

    init(title: String, subtitle: String? = nil, info: String? = nil, dim: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, info: info, dim: dim, action: action, trailing: { EmptyView() })
    }
}

struct SwitchRow: View {
    let title: String
    var subtitle: String?
    var info: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            if let info { InfoButton(info) }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(palette.accent)
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
    }
}

struct PickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    var info: String?
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            if let info { InfoButton(info) }
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].0).tag(options[i].1)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .rowPadding()
    }
}

struct StepperRow: View {
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(title: title, subtitle: subtitle)
            Text("\(value)")
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .trailing)
            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
        .rowPadding()
    }
}

struct RadioRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    var info: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundColor(selected ? palette.accent : .secondary)
            RowLabel(title: title, subtitle: subtitle, subtitleColor: subtitleColor)
            if let info { InfoButton(info) }
            trailing
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { action() } }
    }
}

extension RadioRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, subtitleColor: nil, info: info, selected: selected, action: action,
                  trailing: { EmptyView() })
    }
}

/// 可以展开的一行。带开关时（模糊音、自动加空格）：开关打开就展开，关上就收起、不能展开（和 libadwaita 一样）。
/// 不带开关的当「更多选项」「小技巧」这类折叠用。
struct ExpanderRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    var enabled: Binding<Bool>?
    @ViewBuilder var content: Content
    @State private var expanded = false
    @Environment(\.palette) private var palette

    init(title: String, subtitle: String? = nil, info: String? = nil, enabled: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.enabled = enabled
        self.content = content()
    }

    private var canExpand: Bool { enabled?.wrappedValue ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RowLabel(title: title, subtitle: subtitle)
                if let info { InfoButton(info) }
                if let enabled {
                    Toggle("", isOn: Binding(get: { enabled.wrappedValue }, set: { on in
                        enabled.wrappedValue = on
                        withAnimation(.easeInOut(duration: 0.15)) { expanded = on }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded && canExpand ? 90 : 0))
                    .opacity(canExpand ? 1 : 0.35)
            }
            .rowPadding()
            .contentShape(Rectangle())
            .onTapGesture {
                if canExpand {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }
            if expanded && canExpand {
                Divider()
                VStack(spacing: 0) { content }
                    .padding(.leading, 16)
                    .background(palette.nested)
            }
        }
    }
}

struct TextRow: View {
    let title: String
    var subtitle: String?
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
        }
        .rowPadding()
    }
}

struct EntryRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            field
                .textFieldStyle(.plain)
        }
        .rowPadding()
    }
}
