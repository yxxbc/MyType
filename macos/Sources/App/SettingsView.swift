// 设置窗口的界面（SwiftUI，macOS 12 起）。
//
// 页面：常规、输入、输入统计、学习、表情、语音、翻译、自定义词、关于。
// 每行一个标题，副标题最多一行；说明、注意事项、例子、来源、许可放进 ⓘ（InfoButton）或「更多选项」折叠里。
// 样子：薄荷绿渐变侧栏、绿色选中块、白色圆角卡片。

import AppKit
import SwiftUI

// MARK: 颜色

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private struct Palette {
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

private extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: 窗口

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(dark: scheme == .dark)
        HStack(spacing: 0) {
            Sidebar(model: model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(palette.accent)
                            .frame(width: 4, height: 26)
                        Text(model.page.title)
                            .font(.system(size: 26, weight: .heavy))
                    }
                    page
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(palette.content)
            .overlay(alignment: .bottom) { ToastView(model: model) }
        }
        .environment(\.palette, palette)
        .frame(minWidth: 640, minHeight: 460)
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .general: GeneralPage(model: model)
        case .input: InputPage(model: model)
        case .statistics: InputStatisticsPage(model: model)
        case .learning: LearningPage(model: model)
        case .emoji: EmojiPage(model: model)
        case .voice: VoicePage(model: model)
        case .translate: TranslatePage(model: model)
        case .words: WordsPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

// MARK: 学习

private struct LearningPage: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClear = false

    var body: some View {
        PrefGroup("自动学习", info: "只学习你用空格、数字键或鼠标确认上屏的候选；撤销的分段选词和直接上屏的原始拼音不算。\n\n"
                  + "选够 3 次的词会收进用户词库；分几次选出来的四字以内的词用一次就记住。\n\n"
                  + "已经学到的词会按使用热度排序，单字选一次只放到第二位，重复确认后才升到首位。") {
            SwitchRow(title: "自动学习", subtitle: "选够 3 次的词收进用户词库",
                      isOn: $model.config.autoLearn)
        }

        PrefGroup("已学数据") {
            ActionRow(title: "学过的词",
                      subtitle: "\(model.learningCounts.historyWords) 个选词 · \(model.learningCounts.userWords) 个用户词 · \(model.learningCounts.pairs) 个搭配")
            RowDivider()
            ActionRow(title: "清除学习数据",
                      subtitle: "删掉自动学到的词、热度和搭配；自定义词不受影响",
                      action: { confirmClear = true })
        }
        .confirmationDialog("清除学习数据？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { model.clearLearningData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删掉 user.tsv 和 history.tsv 里的内容，之后从头学习。自定义词（custom.tsv）和输入统计不受影响。")
        }
        .onAppear { model.refreshLearning() }
    }
}

// MARK: 输入统计

private struct InputStatisticsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette
    /// 页面显示多少天；数据文件本身保留最近 90 天。
    @State private var days = 14
    @State private var confirmClear = false

    private var today: InputStatistics.Count { model.inputDays.last?.count ?? .init() }
    private var total: Int { model.inputDays.reduce(0) { $0 + $1.count.characters } }
    private var peak: Int { max(1, model.inputDays.map { $0.count.characters }.max() ?? 0) }
    private var rangeTitle: String { "近 \(days) 天" }

    var body: some View {
        let scale = CGFloat(peak)
        PrefGroup(rangeTitle, description: "按本机日期统计经 MyType 上屏的汉字。只存计数，不保存原文或应用名称；最多保留最近 \(InputStatistics.retentionDays) 天。") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    metric(today.characters, "今日汉字")
                    metric(today.commits, "今日上屏次数")
                    metric(total, "近 \(days) 天汉字")
                }
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(model.inputDays) { day in
                        let isToday = day.id == model.inputDays.last?.id
                        Group {
                            if day.count.characters == 0 {
                                Circle()
                                    .fill(palette.cardBorder)
                                    .frame(width: 4, height: 4)
                            } else {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(palette.accent.opacity(isToday ? 1 : 0.58))
                                    .frame(height: max(3, 76 * CGFloat(day.count.characters) / scale))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted))：\(day.count.characters) 字，\(day.count.commits) 次")
                        .accessibilityLabel(Text(day.date, style: .date))
                        .accessibilityValue("\(day.count.characters) 字，\(day.count.commits) 次")
                    }
                }
                .frame(height: 76, alignment: .bottom)
                HStack {
                    if let first = model.inputDays.first {
                        Text(first.date.formatted(.dateTime.month().day()))
                    }
                    Spacer()
                    Text("今天")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                if total == 0 {
                    Text(model.config.inputStatistics ? "还没有统计数据。用 MyType 输入汉字后会显示在这里。" : "开启记录后才开始计数，不会补算历史。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } trailing: {
            Picker("", selection: $days) {
                ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) 天").tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .tint(palette.accent)
            .fixedSize()
        }
        PrefGroup("记录设置") {
            SwitchRow(title: "记录输入统计",
                      subtitle: model.config.inputStatistics ? "正在记录；只在本机保存，最多保留 90 天"
                                                          : "已关闭；已有数据保留，不会补算历史",
                      isOn: $model.config.inputStatistics)
            RowDivider()
            ActionRow(title: "清除输入统计", subtitle: "删除本机保存的每日计数",
                      action: { confirmClear = true })
        }
        .onAppear { model.refreshInputStatistics(days: days) }
        .onChange(of: days) { model.refreshInputStatistics(days: $0) }
        .confirmationDialog("清除输入统计？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { model.clearInputStatistics(days: days) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删掉本机保存的每日汉字数和上屏次数，之后从头记录。学习数据和自定义词不受影响。")
        }
    }

    private func metric(_ value: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted())
                .font(.system(size: 25, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MyType").font(.system(size: 17, weight: .heavy))
                    Text("本地输入法").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 44)  // 红绿灯按钮下面
            .padding(.bottom, 18)
            ForEach(SettingsPage.allCases) { page in
                NavRow(page: page, selected: model.page == page) { model.page = page }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("MyType \(appVersion)").font(.system(size: 10.5, weight: .medium))
                Text("本地运行 · 打字不联网").font(.system(size: 10.5))
            }
            .foregroundColor(.secondary.opacity(0.8))
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(palette.sidebar)
    }
}

private struct NavRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .frame(width: 18)
            Text(page.title)
            Spacer()
        }
        .font(.system(size: 13, weight: selected ? .semibold : .regular))
        .foregroundColor(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? palette.accent : (hovering ? palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, 12)
    }
}

private struct ToastView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Text(toast.text)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if let title = toast.actionTitle {
                        Button(title) { model.runToastAction() }
                            .buttonStyle(.borderless)
                            .foregroundColor(Palette.accentLight)
                            .font(.body.weight(.semibold))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast?.id)
    }
}

// MARK: 常规

private let issuesURL = URL(string: "https://github.com/yxxbc/MyType/issues/new")!
/// 系统设置的「键盘」（只打开，不改系统设置）
private let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

/// 两个快捷键行的说明，（settings/mytype-config 的 TOGGLE_KEY_INFO、TRANSLATE_MODE_KEY_INFO）
private let toggleKeyInfo = "按它在中文、英文之间切（在「译」里按回到中文）。单按 Shift 照常能用。"
private let translateModeKeyInfo = "按它进「译」，在「译」里再按回到原来的模式。设了它，单按 Shift 就只在中文、英文之间切。\n\n"
    + "要先在「翻译」页打开互译；没打开、密码框里这个键交给应用。"
private let systemKeyNote = "\n\n系统的快捷键（比如 Control+空格）先处理，设成它们 MyType 收不到。"

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PrefGroup("候选词") {
            PickerRow(title: "排列方向", selection: $model.config.horizontal,
                      options: [("横排", true), ("竖排", false)])
            RowDivider()
            PickerRow(title: "方向键", subtitle: arrowKeysSubtitle,
                      info: "选「左右键移动光标」时，← → 把光标移进打了一半的拼音，打的字母插在光标处，"
                          + "退格删光标前一个，Home、End、Delete 也管用；↑ ↓ 选词，到了一页的两头接着翻页。"
                          + "翻页用 Page Up / Page Down 或下面的翻页键。「译」里没有光标。",
                      selection: $model.config.arrowKeys,
                      options: [("都用来选词", .candidates), ("左右键移动光标", .caret)])
            RowDivider()
            StepperRow(title: "每页个数", value: $model.config.pageSize, range: 3...9)
            RowDivider()
            ExpanderRow(title: "翻页键", subtitle: "除了 Page Up / Page Down") {
                SwitchRow(title: "- 和 =", isOn: $model.config.pageKeysMinus)
                RowDivider()
                SwitchRow(title: "[ 和 ]", subtitle: "打字途中不再出【】", isOn: $model.config.pageKeysBracket)
                RowDivider()
                SwitchRow(title: ", 和 .", subtitle: "打字途中要先选词再打标点", isOn: $model.config.pageKeysComma)
                RowDivider()
                SwitchRow(title: "Shift+Tab 和 Tab", isOn: $model.config.pageKeysTab)
            }
        }
        PrefGroup("外观") {
            StepperRow(title: "候选字号", value: $model.config.candidateFontSize, range: 10...40)
        }
        PrefGroup("帮助") {
            ExpanderRow(title: "小技巧") {
                ActionRow(title: "简拼", subtitle: "bjdx → 北京大学，zhch → 支持")
                RowDivider()
                ActionRow(title: "长句分段选", subtitle: "先选开头的词，剩下的接着选")
                RowDivider()
                ActionRow(title: "忘掉学错的词", subtitle: "光标移到候选上，按 Control+Delete")
                RowDivider()
                ActionRow(title: "搜符号", subtitle: "表情面板里打 gou → ✓、youjiantou → →")
                RowDivider()
                ActionRow(title: "互译", subtitle: "单按 Shift 切到「译」，打中文出外文")
            }
            RowDivider()
            ActionRow(title: "打开数据目录", action: { NSWorkspace.shared.open(model.supportDir) }) {
                Image(systemName: "folder").foregroundColor(.secondary)
            }
            RowDivider()
            ActionRow(title: "提交问题", action: { NSWorkspace.shared.open(issuesURL) }) {
                Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
            }
        }
    }

    /// 方向键那一行的副标题：这种用法和候选排列下各个方向键做什么
    private var arrowKeysSubtitle: String {
        switch (model.config.arrowKeys, model.config.horizontal) {
        case (.caret, _): return "↑ ↓ 选词，← → 在拼音里移动光标"
        case (.candidates, true): return "← → 选词，↑ 上一页，↓ 展开更多候选"
        case (.candidates, false): return "↑ ↓ 选词，← → 翻页"
        }
    }
}

// MARK: 输入

private let shuangpinSchemes: [(String, String)] = [
    ("自然码", "Ziranma"), ("小鹤双拼", "Xiaohe"), ("微软双拼", "Microsoft"), ("搜狗双拼", "Sogou"),
    ("智能 ABC", "ABC"), ("紫光双拼", "Ziguang"), ("拼音加加", "PinyinJiajia"),
]

private let fuzzyGroups: [(String, WritableKeyPath<MyTypeConfig, Bool>)] = [
    ("z = zh", \.fuzzyZh), ("c = ch", \.fuzzyCh), ("s = sh", \.fuzzySh), ("n = l", \.fuzzyNL),
    ("f = h", \.fuzzyFH), ("r = l", \.fuzzyRL), ("an = ang", \.fuzzyAn), ("an = ai", \.fuzzyAnAi),
    ("ian = iang", \.fuzzyIan), ("uan = uang", \.fuzzyUan), ("huang = wang", \.fuzzyHuangWang),
    ("en = eng", \.fuzzyEn), ("eng = ong", \.fuzzyEngOng), ("in = ing", \.fuzzyIn), ("un = ong", \.fuzzyUn),
    ("un = iong", \.fuzzyUnIong),
]

private struct InputPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("词库", info: "换词库几秒后生效，自定义词和学到的习惯都会保留。\n\n"
                  + "雾凇拼音在安装包里，跟着 MyType 一起更新。\n\n"
                  + "万象拼音词更多，比雾凇多占约 300 MB 内存；从 amzxyz/rime_wanxiang（CC BY 4.0）转换，只用了它的词条。"
                  + "装在 ~/Library/Application Support/MyType/dicts/wanxiang。",
                  links: [("万象拼音项目主页", URL(string: "https://github.com/amzxyz/rime_wanxiang")!)]) {
            RadioRow(title: "雾凇拼音（默认）", subtitle: "在安装包里，不用下载", selected: model.lexiconKind == .rimeIce) {
                model.useRimeIce()
            }
            .disabled(model.lexiconBusy)
            RowDivider()
            RadioRow(title: "万象拼音", subtitle: wanxiangSubtitle, selected: model.lexiconKind == .wanxiang) {
                if model.lexiconKind != .wanxiang { model.useWanxiang() }
            } trailing: {
                if !model.lexiconBusy {
                    // 发布页上没有万象包时不显示「下载」（和以前一样，可以从文件安装）
                    let noAsset = model.release != nil && model.release?.wanxiang == nil
                    if (model.wanxiangVersion == nil || model.wanxiangUpdate != nil) && !noAsset {
                        Button(model.wanxiangVersion == nil ? "下载" : "更新") { model.installWanxiang() }
                    }
                    IconButton(symbol: "folder", help: "从文件安装（wowtype-data-wanxiang-*.tar.gz）") { model.chooseWanxiangFile() }
                    if model.wanxiangVersion != nil && model.lexiconKind != .wanxiang {
                        IconButton(symbol: "trash", help: "删除万象拼音") { model.removeWanxiang() }
                    }
                }
            }
            .disabled(model.lexiconBusy)
            RowDivider()
            RadioRow(title: "自定义词库", subtitle: lexiconSubtitle, subtitleColor: lexiconColor,
                     selected: model.lexiconKind == .custom) {
                if model.lexiconKind != .custom { model.chooseLexicon() }
            } trailing: {
                Button("选择…") { model.chooseLexicon() }
            }
            .disabled(model.lexiconBusy)
        }
        .onAppear { model.checkRelease() }

        PrefGroup("输入方案") {
            RadioRow(title: MyTypeConfig.InputScheme.quanpin.name, subtitle: "全拼，也能只打声母", selected: model.config.inputScheme == .quanpin) {
                model.config.inputScheme = .quanpin
            }
            RowDivider()
            RadioRow(title: MyTypeConfig.InputScheme.shuangpin.name, subtitle: "每个字打两个键", selected: model.config.shuangpin) {
                model.config.inputScheme = .shuangpin
            }
            if model.config.shuangpin {
                RowDivider()
                PickerRow(title: "双拼方案", selection: $model.config.shuangpinScheme, options: schemeOptions)
                RowDivider()
                SwitchRow(title: "编辑区显示打的键", subtitle: "不翻成全拼，中英混打时看得出打了什么",
                          isOn: $model.config.shuangpinShowKeys)
            }
            RowDivider()
            RadioRow(title: MyTypeConfig.InputScheme.wubi86.name,
                     subtitle: model.wubiTableAvailable ? "86 版，z 键临时打拼音"
                         : "没有找到五笔码表 wubi86.tsv，重新安装 MyType 可以修好",
                     selected: model.config.wubi) {
                model.config.inputScheme = .wubi86
            }
            .disabled(!model.wubiTableAvailable)
            if model.config.wubi {
                RowDivider()
                SwitchRow(title: "四码唯一自动上屏", subtitle: "打满四码、只有一个字词时直接上屏",
                          isOn: $model.config.wubiAutoCommit)
                RowDivider()
                SwitchRow(title: "编码提示", subtitle: "候选后面显示还要打的码", isOn: $model.config.wubiHint)
            }
        }

        PrefGroup("中英文切换", info: "单按一下 Shift 切到英文，字母和半角标点直接上屏，再按一下回到中文。"
                  + "打到一半切英文，已经打的字母原样上屏。") {
            // macOS 自己的切换：不经过输入法，哪个应用里都管用
            ActionRow(title: "中/英 键（大写锁定键）", subtitle: "系统设置里打开后，在 MyType 和 ABC 之间切，所有应用里都管用",
                      info: "在「系统设置 → 键盘 → 文字输入 → 输入法」点「编辑…」，打开"
                          + "「使用“中/英”键切换“ABC”输入法」（键盘上没有 中/英 键时叫「使用大写锁定键切换“ABC”输入法」）。"
                          + "打开以后按一下这个键在 MyType 和 ABC 之间切。") {
                Button("打开键盘设置") { NSWorkspace.shared.open(keyboardSettingsURL) }
            }
            RowDivider()
            PickerRow(title: "单按 Shift",
                      info: "个别应用（比如一些用 Electron 做的）里单按 Shift 有时不灵，可以用上面的 中/英 键，或者下面另设的快捷键。",
                      selection: $model.config.shiftToggle,
                      options: [("左右 Shift 都行", .both), ("左 Shift", .left), ("右 Shift", .right), ("不用 Shift 切换", .off)])
            RowDivider()
            PickerRow(title: "另设一个切换键", info: toggleKeyInfo + systemKeyNote,
                      selection: shortcutBinding(\.toggleKey),
                      options: shortcutOptions([("不用（单按 Shift 照常）", "")] + shortcuts(Array(Shortcut.toggleKeyPresets.dropFirst())),
                                               current: model.config.toggleKey?.name ?? ""))
            RowDivider()
            PickerRow(title: "互译的快捷键",
                      subtitle: model.config.translateModeKey != nil && !model.translateReady ? "先在「翻译」页打开互译" : nil,
                      info: translateModeKeyInfo + systemKeyNote,
                      selection: shortcutBinding(\.translateModeKey),
                      options: shortcutOptions([("不用", "")] + shortcuts(Array(Shortcut.translateModeKeyPresets.dropFirst())),
                                               current: model.config.translateModeKey?.name ?? ""))
        }

        PrefGroup("拼音") {
            ExpanderRow(title: "模糊音", subtitle: "比如 n 和 l 不分", enabled: $model.config.fuzzy) {
                ForEach(fuzzyGroups.indices, id: \.self) { i in
                    if i > 0 { RowDivider() }
                    SwitchRow(title: fuzzyGroups[i].0, isOn: $model.config[dynamicMember: fuzzyGroups[i].1])
                }
            }
            RowDivider()
            SwitchRow(title: "按错键自动纠正", subtitle: "zhognguo → 中国（全拼时）", isOn: $model.config.typoCorrection)
            RowDivider()
            SwitchRow(title: "繁体字", isOn: $model.config.traditional)
            RowDivider()
            SwitchRow(title: "更多生僻字", subtitle: "要装能显示它们的字体，比如花园明朝",
                      info: "候选里也列出极少用的生僻字。系统自带的字体一般显示不了，会是方块。",
                      isOn: $model.config.rareExtChars)
            RowDivider()
            PickerRow(title: "标点样式", info: "数字后面的符号总是半角的，比如 3.14。",
                      selection: $model.config.halfwidthPunct, options: [("全角 ，。", false), ("半角 , .", true)])
        }

        PrefGroup("快捷输入") {
            SwitchRow(title: "日期和时间", subtitle: "打 riqi、shijian、xingqi（五笔前面加 z）", isOn: $model.config.dateTime)
            RowDivider()
            SwitchRow(title: "计算器", subtitle: schemeName.map { "\($0)时打大写 V：V1+2*3 → 7" } ?? "v1+2*3 → 7",
                      isOn: $model.config.calculator)
            RowDivider()
            SwitchRow(title: "工具栏",
                      subtitle: schemeName.map { "\($0)时不可用" } ?? "打 v 再按空格：剪贴板、常用语、符号、表情",
                      // 双拼、五笔时用不了：显示成关着（不改设置，换回全拼还是原来的）
                      isOn: Binding(get: { schemeName == nil && model.config.toolbar },
                                    set: { model.config.toolbar = $0 }))
                .disabled(schemeName != nil)
            RowDivider()
            SwitchRow(title: "记录剪贴板历史", subtitle: "复制的密码也可能被记下",
                      info: "给工具栏里的「剪贴板」用，最多记 20 条，只在内存里，关掉开关或重启输入法就清空。"
                          + "密码管理器标了「不要记」的不记，没标的密码会被记下并显示出来。",
                      isOn: $model.config.clipboardHistory)
            RowDivider()
            PickerRow(title: "分号、引号选词", info: "用引号选词后，引号不能再用来隔开拼音（xi'an）。",
                      selection: $model.config.selectKeys,
                      options: [("不用", .off), ("分号选第 2 个", .semicolon), ("分号选第 2 个、引号选第 3 个", .semicolonQuote)])
            RowDivider()
            SwitchRow(title: "以词定字", subtitle: "按 [ 取第一个字，按 ] 取最后一个字", isOn: $model.config.pickChar)
            RowDivider()
            ExpanderRow(title: "中英文之间自动加空格", subtitle: "第5章 → 第 5 章",
                        info: "你好Mac → 你好 Mac。只在程序告诉输入法光标前是什么字时加，有些程序（比如终端）里不起作用。",
                        enabled: $model.config.autoSpace) {
                SwitchRow(title: "汉字和英文字母之间", isOn: $model.config.autoSpaceLetters)
                RowDivider()
                SwitchRow(title: "汉字和数字之间", isOn: $model.config.autoSpaceDigits)
            }
        }
    }

    /// 快捷键下拉框选的键名（同 mytype.conf）；空串是不用
    private func shortcutBinding(_ path: WritableKeyPath<MyTypeConfig, Shortcut?>) -> Binding<String> {
        Binding(get: { model.config[keyPath: path]?.name ?? "" },
                set: { model.config[keyPath: path] = $0.isEmpty ? nil : Shortcut(name: $0) })
    }

    /// 双拼、五笔时 v 是字母键（计算器换大写 V、工具栏不开）：副标题里说是哪个；全拼是 nil。
    private var schemeName: String? {
        model.config.inputScheme == .quanpin ? nil : model.config.shuangpin ? "双拼" : "五笔"
    }

    private var schemeOptions: [(String, String)] {
        let current = model.config.shuangpinScheme
        if shuangpinSchemes.contains(where: { $0.1 == current }) {
            return shuangpinSchemes
        }
        return shuangpinSchemes + [("其他（\(current)）", current)]
    }

    /// 装了的版本、有没有新版、下载进度
    private var wanxiangSubtitle: String {
        if let progress = model.lexiconProgress {
            return progress
        }
        if let version = model.wanxiangVersion {
            return "已下载 \(version)" + (model.wanxiangUpdate.map { "，有新版 \($0)" } ?? "")
        }
        if let release = model.release, release.wanxiang == nil {
            return "暂时没有下载包，可以从文件安装"
        }
        return "词更多，要下载约 20 MB"
    }

    /// 没选时不写（文件格式在选文件的对话框里说）
    private var lexiconSubtitle: String? {
        guard model.lexiconKind == .custom else { return nil }
        let path = model.config.lexicon
        return model.customLexiconMissing ? "找不到 \(path)，现在用的是雾凇拼音" : path
    }

    private var lexiconColor: Color? {
        model.lexiconKind == .custom && model.customLexiconMissing ? palette.warning : nil
    }
}

// MARK: 表情

private struct EmojiPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PrefGroup("表情") {
            SwitchRow(title: "打字时推荐 emoji", subtitle: "打「开心」「点赞」时，候选里有对应的 emoji",
                      isOn: $model.config.emojiSuggest)
            RowDivider()
            PickerRow(title: "表情面板快捷键",
                      info: "按快捷键打开表情面板，打拼音或英文搜 emoji 和符号（xiao、pizza、youjiantou），"
                          + "方向键挑，空格或回车上屏，Esc 关闭。打了一半的拼音再按快捷键，直接拿它来搜。\n\n"
                          + "Command 组合键多半被程序的菜单先拿走，所以用 Control。",
                      selection: emojiKey, options: emojiKeyOptions)
        }
    }

    /// 键名同 mytype.conf 的 EmojiKey；空串是不用快捷键
    private var emojiKey: Binding<String> {
        Binding(get: { model.config.emojiKey?.name ?? "" },
                set: { model.config.emojiKey = $0.isEmpty ? nil : Shortcut(name: $0) })
    }

    private var emojiKeyOptions: [(String, String)] {
        shortcutOptions(shortcuts(["Control+period", "Control+semicolon", "Control+Shift+E"]) + [("不用快捷键", "")],
                        current: emojiKey.wrappedValue)
    }
}

/// 快捷键（键名同 mytype.conf）配上 Mac 键盘上的叫法：Control + .、Option + X
private func shortcuts(_ names: [String]) -> [(String, String)] {
    names.map { (Shortcut(name: $0)?.label ?? $0, $0) }
}

/// 设置文件里写的不是预设的快捷键：加一项「其他（Option + X）」
private func shortcutOptions(_ options: [(String, String)], current: String) -> [(String, String)] {
    options.contains { $0.1 == current } ? options : options + [("其他（\(shortcuts([current])[0].0)）", current)]
}

// MARK: 语音

/// 和设置窗口的「语音」页一样：开关、语音键、复制到剪贴板，下面是识别模型。没有模型时开关灰掉、显示成关着。
private struct VoicePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let ready = model.voiceModelReady
        PrefGroup("语音输入", info: "按住语音键说话，松开就上屏；或者点一下语音键开始说，停顿一会儿自动上屏。"
                  + "说的时候按 Esc 取消。正在打拼音时语音键不起作用。\n\n"
                  + "右 Option 按下时就开始听，Option+方向键这类组合会让麦克风亮一下就停；不想这样可以换成别的键。"
                  + "F8–F10 在 Mac 笔记本上默认是媒体键，要在「系统设置 → 键盘」里打开「将 F1、F2 等键用作标准功能键」。") {
            SwitchRow(title: "语音输入", subtitle: ready ? nil : "先在下面下载语音模型",
                      isOn: Binding(get: { ready && model.config.voice }, set: { model.config.voice = $0 }))
                .disabled(!ready)
            RowDivider()
            PickerRow(title: "语音键", selection: $model.config.voiceKey, options: voiceKeyOptions)
                .disabled(!ready || !model.config.voice)
            RowDivider()
            SwitchRow(title: "同时复制到剪贴板", isOn: $model.config.voiceCopy)
                .disabled(!ready || !model.config.voice)
            if #available(macOS 14.0, *) {
                RowDivider()
                SwitchRow(title: "录音时降低其他声音", subtitle: "结束录音后恢复，不改系统音量",
                          isOn: $model.config.voiceDuckPlayback)
                    .disabled(!ready || !model.config.voice)
            }
        }
        PrefGroup("识别模型", info: "在本机识别，录音不上传。语音模型是微信输入法的离线语音包，属于腾讯，"
                  + "从腾讯的服务器下载，MyType 不分发它；和这台电脑装没装微信输入法无关。\n\n"
                  + "模型放在 ~/Library/Application Support/MyType/wtlocal。第一次用语音时系统会问要不要允许 MyType 使用麦克风；"
                  + "MyType 每次更新后系统可能会再问一次。") {
            HStack(spacing: 10) {
                RowLabel(title: "语音模型", subtitle: model.voiceModelStatus)
                if let (done, total) = model.voiceProgress {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 90)
                    Button("取消") { model.cancelVoiceDownload() }
                } else if ready {
                    IconButton(symbol: "trash", help: "删除语音模型（语音输入会关掉）") { model.removeVoiceModel() }
                } else {
                    Button { model.downloadVoiceModel() } label: {
                        Label(model.voiceError == nil ? "下载" : "重试", systemImage: "arrow.down.circle")
                    }
                }
            }
            .rowPadding()
        }
        PrefGroup("麦克风", info: "第一次按语音键（或点「测试」）时系统会问要不要允许 MyType 使用麦克风。"
                  + "被拒绝后到「系统设置 → 隐私与安全性 → 麦克风」里打开 MyType。") {
            HStack(spacing: 10) {
                RowLabel(title: "麦克风", subtitle: model.voicePermissionText)
                if model.voiceTesting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    Text(model.voiceTestText ?? "正在听…")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Button { model.testMicrophone() } label: {
                        Label("测试", systemImage: "mic.fill")
                    }
                    .disabled(!ready || !model.config.voice)
                }
            }
            .rowPadding()
            if !model.voiceTesting, let text = model.voiceTestText {
                RowDivider()
                ActionRow(title: "上次测试", subtitle: text)
            }
        }
    }

    /// 键名同 mytype.conf 的 VoiceKey；旧版拷过来的 Mac 上没有的键（Menu）单独列出来
    private var voiceKeyOptions: [(String, String)] {
        let options = VoiceKey.presets.map { ($0.label, $0.name) }
        let current = model.config.voiceKey
        if options.contains(where: { $0.1 == current }) { return options }
        let label = current.isEmpty ? "不用语音键"
            : VoiceKey(name: current) == nil ? "\(current)（Mac 上没有这个键）" : "其他（\(current)）"
        return options + [(label, current)]
    }
}

// MARK: 翻译

/// 名字、接口地址、模型框空着时建议的模型。列表在 Shared/Config.swift，
/// 按键测试对照 spec/config.json
private let translateProviders = MyTypeConfig.translateProviders

private let translateLanguages = MyTypeConfig.translateLanguages

private struct TranslatePage: View {
    @ObservedObject var model: SettingsModel
    @State private var key = ""
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("互译", info: "单按 Shift 切到「译」，照常打中文，停一下就翻成外文。"
                  + "回车用译文，Shift+回车用原文，Esc 取消。打的是外文就翻成中文。") {
            SwitchRow(title: "互译", subtitle: translateStatus, isOn: $model.config.translate)
            RowDivider()
            PickerRow(title: "翻译成", info: "中文翻成这种语言；这种语言（和别的外文）翻成中文。",
                      selection: $model.config.translateTarget, options: translateLanguages)
            RowDivider()
            SwitchRow(title: "正式语气", subtitle: "默认是聊天的口吻", isOn: $model.config.translateFormal)
            RowDivider()
            PickerRow(title: "用什么翻译",
                      subtitle: model.config.translateLocal
                          ? "不联网、不用账号，打的字不出这台电脑；一句话等 1–3 秒"
                          : "填你自己的翻译接口（DeepSeek、通义千问、Ollama……），要联网",
                      selection: $model.config.translateLocal,
                      options: [("本地模型（离线）", true), ("自定义翻译服务", false)])
        }
        if model.config.translateLocal {
            localGroup
        } else {
            serviceGroup
        }
    }

    /// 「互译」那一行的状态：还差什么、Shift 关掉了切不到「译」、怎么切
    private var translateStatus: String {
        if !model.translateConfigured {
            return model.config.translateLocal ? "先在下面下载翻译模型" : "先在下面填好翻译服务"
        }
        if let key = model.config.translateModeKey {
            return "按 \(key.label) 进出「译」"
        }
        if model.config.shiftToggle == .off {
            return "「输入」页关掉了 Shift 切换，切不到「译」；可以在那里设一个互译的快捷键"
        }
        return "单按 Shift：中 → 英 → 译 → 中"
    }

    private var serviceGroup: some View {
        PrefGroup("翻译服务", info: "选一家服务商，填它给你的 Key，再挑一个模型。翻译要等服务回话，"
                  + "名字里带 mini、flash、turbo 的小模型更快。\n\n"
                  + "隐私：只在切到「译」时把打的字发给你选的服务，密码框里不翻译；MyType 自己不经手、不收集。"
                  + "Key 只存在这台电脑上（~/Library/Application Support/MyType/translate.key，只有你能读）。") {
            PickerRow(title: "服务商", selection: provider, options: translateProviders.map { ($0.name, $0.name) })
            RowDivider()
            TextRow(title: "接口地址", placeholder: "https://…/v1", text: trimmed(\.translateBaseUrl))
            RowDivider()
            HStack(spacing: 8) {
                RowLabel(title: "API Key", subtitle: model.translateKeySet ? "已设置（不显示）" : "本机服务可以不填")
                SecureField(model.translateKeySet ? "换一个" : "粘贴 Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(saveKey)
                Button("保存", action: saveKey)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.translateKeySet {
                    Button("删除") { model.setTranslateKey("") }
                }
            }
            .rowPadding()
            RowDivider()
            TextRow(title: "模型", placeholder: suggestedModel.isEmpty ? "服务商给的模型名" : suggestedModel,
                    text: trimmed(\.translateModel))
        }
    }

    /// 选了本地模型：一行状态（下载 / 进度 / 已就绪），别的都收进「更多选项」；说明和许可在组标题旁的 ⓘ
    private var localGroup: some View {
        PrefGroup("离线翻译模型", info: "腾讯混元的翻译模型 HY-MT。翻译时占 1.5 GB 左右内存，一会儿不用就自动释放。"
                  + "找不到 llama-server 时一起下载 llama.cpp 官方的（MIT 许可）。\n\n" + LocalModel.terms,
                  links: [("许可协议全文", URL(string: LocalModel.license)!)]) {
            LocalModelRow(model: model)
            RowDivider()
            ExpanderRow(title: "更多选项") {
                TextRow(title: "模型文件", placeholder: "留空用数据目录里的", text: trimmed(\.translateLocalModel))
                RowDivider()
                TextRow(title: "llama-server", subtitle: model.localServerSummary, placeholder: "留空自动找",
                        text: trimmed(\.translateLlamaServer))
                RowDivider()
                StepperRow(title: "闲置几分钟后释放内存", subtitle: "0 表示一直留着",
                           value: $model.config.translateIdleMinutes, range: 0...240)
                if model.localDeletable {
                    RowDivider()
                    ActionRow(title: "删除模型", info: "连同 MyType 下载的 llama-server 一起删；Homebrew 装的、"
                              + "自己写了位置的模型不动。") {
                        Button("删除") { model.removeLocalModel() }
                            .disabled(model.localBusy)
                    }
                }
            }
        }
    }

    /// 服务商：接口地址是哪家的就选哪家；换服务商时填上它的地址，模型框空着就填上建议的模型
    private var provider: Binding<String> {
        Binding(get: {
            let url = model.config.translateBaseUrl
            return translateProviders.first { !$0.url.isEmpty && $0.url == url }?.name ?? translateProviders.last!.name
        }, set: { name in
            guard let p = translateProviders.first(where: { $0.name == name }), !p.url.isEmpty else { return }
            model.config.translateBaseUrl = p.url
            if model.config.translateModel.isEmpty {
                model.config.translateModel = p.model
            }
        })
    }

    private var suggestedModel: String {
        translateProviders.first { $0.url == model.config.translateBaseUrl }?.model ?? ""
    }

    private func trimmed(_ path: WritableKeyPath<MyTypeConfig, String>) -> Binding<String> {
        Binding(get: { model.config[keyPath: path] },
                set: { model.config[keyPath: path] = $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func saveKey() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.setTranslateKey(value)
        key = ""
    }
}

/// 本地模型那一行：没下载给「下载」和大小，下载中给进度和「取消」，好了写「已就绪」。
private struct LocalModelRow: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        let plan = model.localPlan
        HStack(spacing: 10) {
            RowLabel(title: "翻译模型", subtitle: problem(plan), subtitleColor: palette.warning)
            if let progress = model.localProgress {
                ProgressView(value: Double(progress.percent), total: 100)
                    .frame(width: 90)
                Text(status(progress))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Button("取消") { model.cancelLocalDownload() }
            } else if plan.ready {
                Label("已就绪", systemImage: "checkmark.circle.fill")
                    .foregroundColor(palette.accent)
            } else if plan.canDownload {
                Text("要下载 \(LocalModel.sizeText(plan.bytes))")
                    .foregroundColor(.secondary)
                Button("下载") { model.downloadLocalModel() }
            }
        }
        .rowPadding()
    }

    private func status(_ progress: LocalModelInstaller.Progress) -> String {
        switch progress.stage {
        case .connecting: return "正在连接…"
        case .model, .llama: return "下载中 \(progress.percent)%"
        case .unpacking: return "正在安装…"
        }
    }

    /// 只在有问题时写一行：上次没下完的原因、llama-server 下载不了
    private func problem(_ plan: LocalModel.Plan) -> String? {
        if model.localBusy { return nil }
        if let error = model.localError { return error }
        guard plan.llamaUnavailable else { return nil }
        return model.config.translateLlamaServer.isEmpty
            ? "还差 llama-server：要 macOS 13.3 以上才能下载，或者自己装 llama.cpp"
            : "「更多选项」里写的 llama-server 不在"
    }
}

// MARK: 自定义词

private struct WordsPage: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var wordFocused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("添加自定义词", info: "人名、公司名、常用的长句、邮箱地址都可以加。加进来的词总排在候选第一个，"
                  + "简拼也能打出来。\n\n编码按词自动填好拼音，多音字请检查；也可以是 mail、addr 这类字母，"
                  + "正好打这几个字母时出现。\n\n词里写 \\n 表示换行，比如「四川省\\n宜宾市」。") {
            EntryRow(label: "词") {
                TextField("要加的词", text: $model.newWord)
                    .focused($wordFocused)
                    .onSubmit(add)
            }
            RowDivider()
            EntryRow(label: "编码") {
                TextField("拼音或字母", text: $model.newCode)
                    .foregroundColor(model.codeIsInvalid ? .red : .primary)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(model.canAddWord ? palette.accent : Color.gray.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!model.canAddWord)
                .help("添加")
            }
        }

        PrefGroup(model.words.isEmpty ? "已添加" : "已添加（\(model.words.count)）") {
            let shown = model.shownWords
            if shown.isEmpty {
                ActionRow(title: model.words.isEmpty ? "还没有自定义词" : "没找到", dim: true)
            } else {
                ForEach(shown.indices, id: \.self) { i in
                    if i > 0 { RowDivider() }
                    WordRow(entry: shown[i]) { model.removeWord(shown[i].word) }
                }
            }
        } trailing: {
            HStack(spacing: 6) {
                if model.words.count > 8 {
                    SearchField(text: $model.search)
                        .frame(width: 160)
                }
                IconButton(symbol: "square.and.arrow.down", help: "从文件导入", action: model.importWords)
                IconButton(symbol: "square.and.arrow.up", help: "导出到文件", action: model.exportWords)
            }
        }
    }

    private func add() {
        if model.addWord() {
            wordFocused = true
        }
    }
}

private struct WordRow: View {
    let entry: CustomWords.Entry
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CustomWords.shown(entry.word))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.code)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            IconButton(symbol: "trash", help: "删除", action: remove)
        }
        .rowPadding()
    }
}

private struct SearchField: View {
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

// MARK: 分组和行（照 libadwaita 的 PreferencesGroup / ActionRow / SwitchRow / ComboRow / ExpanderRow）
//
// 页面上只放标题和最多一行的副标题。说明、注意事项、例子、来源、许可这类放进 ⓘ：
//   - 组：PrefGroup("词库", info: "…", links: [("项目主页", url)]) { … }，ⓘ 在组标题右边
//   - 行：SwitchRow / PickerRow / RadioRow / ActionRow / ExpanderRow 的 info: "…"，ⓘ 在开关、下拉框前面
//   - 别的地方：InfoButton("…", links: […]) 直接放

/// ⓘ 小按钮，点开弹出说明文字（可以选中拷贝），links 是说明下面的链接。
private struct InfoButton: View {
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
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).foregroundColor(.secondary) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

private struct PrefGroup<Content: View, Trailing: View>: View {
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

private extension PrefGroup where Trailing == EmptyView {
    init(_ title: String, description: String? = nil, info: String? = nil, links: [(String, URL)] = [],
         @ViewBuilder content: () -> Content) {
        self.init(title, description: description, info: info, links: links, content: content,
                  trailing: { EmptyView() })
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

private extension View {
    func rowPadding() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 48)
    }
}

private struct RowLabel: View {
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

private struct ActionRow<Trailing: View>: View {
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

private extension ActionRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil, dim: Bool = false) {
        self.init(title: title, subtitle: subtitle, info: info, dim: dim, action: nil, trailing: { EmptyView() })
    }

    init(title: String, subtitle: String? = nil, info: String? = nil, dim: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, info: info, dim: dim, action: action, trailing: { EmptyView() })
    }
}

private struct SwitchRow: View {
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

private struct PickerRow<Value: Hashable>: View {
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

private struct StepperRow: View {
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

private struct RadioRow<Trailing: View>: View {
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

private extension RadioRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, subtitleColor: nil, info: info, selected: selected, action: action,
                  trailing: { EmptyView() })
    }
}

/// 可以展开的一行。带开关时（模糊音、自动加空格）：开关打开就展开，关上就收起、不能展开（和 libadwaita 一样）。
/// 不带开关的当「更多选项」「小技巧」这类折叠用。
private struct ExpanderRow<Content: View>: View {
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

private struct TextRow: View {
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

private struct EntryRow<Field: View>: View {
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

// MARK: 关于

/// 设置侧栏「关于」：版本、检查更新（发布页 302，不用 API）、下载并安装、链接和许可。
/// GitHub 的猫标（Octicons，MIT；打包在 Resources/github.png）
private struct GitHubMark: View {
    var body: some View {
        Image(nsImage: NSImage(named: "github") ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 17, height: 17)
            .opacity(0.9)
    }
}

private struct LinkRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 18, height: 18)
            RowLabel(title: title, subtitle: subtitle)
            Image(systemName: "arrow.up.right.square")
                .foregroundColor(.secondary)
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct AboutPrinciple: Identifiable {
    let id: String
    let tag: String
    let title: String
    let body: String
    let icon: String
}

let aboutPrinciples: [AboutPrinciple] = [
    AboutPrinciple(id: "load", tag: "认知负荷", title: "少一次选择",
                   body: "每选一次词，都是一次上下文切换。整句输入把决策从每个词一次，降到每句一次；打断少了，心流才接得上。",
                   icon: "brain.head.profile"),
    AboutPrinciple(id: "coord", tag: "协调博弈", title: "默认要稳",
                   body: "打字是人和输入法之间的协调：键位、候选顺序、上屏规则越稳定，协调成本越低。默认不是试验田。",
                   icon: "keyboard"),
    AboutPrinciple(id: "repeat", tag: "重复博弈", title: "本地是承诺",
                   body: "输入内容不出本机，不靠数据变现。一次博弈可以靠聪明，长期合作只能靠可信承诺。",
                   icon: "lock.shield"),
    AboutPrinciple(id: "habit", tag: "习惯与信任", title: "更新要安静",
                   body: "不弹窗、不换布局、不追热点。需要时在「关于」里检查，装完自动回来。",
                   icon: "bell.slash"),
]

private struct PrincipleCard: View {
    let principle: AboutPrinciple
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: principle.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(principle.tag)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1)
            }
            .foregroundColor(palette.accent)
            Text(principle.title)
                .font(.system(size: 14.5, weight: .semibold))
            Text(principle.body)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(palette.dark ? 0.16 : 0.035), radius: 8, y: 2)
    }
}

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            principles
            Text("市面上的输入法越做越大：云同步、广告、皮肤、会员。MyType 只做一件事——在 macOS 上，用最少的打断，打最顺的中文。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            updateGroup
            linksGroup
            licenseLine
        }
        .onAppear { model.checkUpdatesOnce() }
    }

    /// 简单介绍：一点心理学，一点博弈论
    private var hero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 15) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MyType").font(.system(size: 24, weight: .heavy))
                    Text("macOS 拼音输入法 · 版本 \(appVersion)")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                updateButton
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("一点心理学，一点博弈论")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(palette.accent)
                Text("打字是习惯，不是功能列表。")
                    .font(.system(size: 23, weight: .semibold, design: .serif))
                Text("输入法每天被用几千次，却几乎没人愿意为它重新学一套手指动作。MyType 先把默认做稳：整句上屏、少做选择、数据留在本机。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [palette.card, palette.accent.opacity(palette.dark ? 0.12 : 0.055)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(palette.dark ? 0.20 : 0.05), radius: 14, y: 3)
    }

    @ViewBuilder private var updateButton: some View {
        if let latest = model.updateLatest {
            Button { model.updateNow() } label: {
                Label("更新到 \(latest.version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.updateInstalling)
        } else {
            Button { model.checkUpdates(manual: true) } label: {
                Label(model.updateChecking ? "正在检查…" : "检查更新",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(model.updateChecking || model.updateInstalling)
        }
    }

    private var principles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设计原则")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.heading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(aboutPrinciples) { PrincipleCard(principle: $0) }
            }
        }
    }

    private var licenseLine: some View {
        HStack(spacing: 5) {
            Text("代码 MIT / Apache-2.0 · 原项目 Gloridust/WowType")
            Text("·")
            Link("数据许可", destination: URL(string: "https://github.com/yxxbc/MyType/blob/main/THIRD_PARTY_LICENSES.md")!)
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.top, 2)
    }

    private var updateGroup: some View {
        PrefGroup("更新") {
            ActionRow(title: "当前版本", subtitle: "MyType \(appVersion)")
            RowDivider()
            ActionRow(title: "最新版本", subtitle: updateSubtitle) {
                HStack(spacing: 8) {
                    Button { model.checkUpdates(manual: true) } label: {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.updateChecking || model.updateInstalling)
                    if model.updateLatest != nil {
                        Button { model.updateNow() } label: {
                            Label("下载并安装", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.updateInstalling)
                    } else {
                        Button { model.openReleasePage() } label: {
                            Label("打开发布页", systemImage: "safari")
                        }
                    }
                }
            }
            if let progress = model.updateProgress {
                RowDivider()
                ActionRow(title: "进度", subtitle: progress)
            }
            RowDivider()
            SwitchRow(title: "自动检查更新",
                      subtitle: "启动后最多一天检查一次，有新版本在「关于」页提示",
                      info: "只请求 GitHub 上的发布页地址，看最新版本号；不发送任何输入内容，也不用 GitHub API。",
                      isOn: $model.config.checkUpdate)
        }
    }

    private var updateSubtitle: String {
        if model.updateInstalling { return "正在安装…" }
        if model.updateChecking { return "正在检查…" }
        if let latest = model.updateLatest { return "有新版 MyType \(latest.version)（\(latest.package)）" }
        if let error = model.updateError { return error }
        if !model.updateChecked { return "还没检查" }
        return "已经是最新版（MyType \(appVersion)）"
    }

    private var linksGroup: some View {
        PrefGroup("链接") {
            LinkRow(title: "项目主页", subtitle: "github.com/\(Update.repo)",
                    action: { open("https://github.com/\(Update.repo)") }) {
                GitHubMark()
            }
            RowDivider()
            LinkRow(title: "问题反馈", subtitle: "github.com/\(Update.repo)/issues",
                    action: { open("https://github.com/\(Update.repo)/issues") }) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            RowDivider()
            LinkRow(title: "更新记录", subtitle: "github.com/\(Update.repo)/releases",
                    action: { open("https://github.com/\(Update.repo)/releases") }) {
                Image(systemName: "tag")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
