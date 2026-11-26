// 设置侧栏「关于」：版本、检查更新（发布页 302，不用 API）、下载并安装、链接和许可。

import AppKit
import SwiftUI

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

struct AboutPage: View {
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
