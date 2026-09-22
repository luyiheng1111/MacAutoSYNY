import SwiftUI
import AppKit

// MARK: - 菜单栏面板（点击顶部图标呼出）
struct SYNYPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 高度自适应：面板高度 = 内容自然高度（并夹在 [下限, 用户上限] 之间），
        // 折叠/展开高级设置时高度自动跟随，底部不留多余空白；超过上限时内部滚动。
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                HeaderView()
                AccountCard()
                PrimaryButton()
                AdvancedSection()
                Divider().padding(.vertical, 2)
                FooterView()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self,
                                           value: proxy.size.height)
                }
            )
        }
        .frame(width: AppModel.panelWidth)
        .frame(height: model.panelPreferredHeight)
        .background(Palette.windowBG)
        .onPreferenceChange(PanelHeightKey.self) { model.panelContentHeight = $0 }
        .onAppear { model.bootstrap() }
    }
}

/// 收集面板内容的自然高度，用于让弹层高度自适应内容。
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 头部（标题 + 右上角状态提示）
private struct HeaderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.accent)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "wifi")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("校园网自动认证")
                    .font(.system(size: 17, weight: .semibold))
                Text("断网自动登录 · 后台常驻")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)   // 标题优先，不被就地压缩

            // 状态提示上移到标题右侧空白处；占满剩余宽度并右对齐，长文案自动换行
            StatusPill(text: model.message, kind: model.messageKind)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let kind: AppModel.MessageKind

    var body: some View {
        // 紧凑形态：置于标题右侧；长文案最多 2 行，完整显示不截断。
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 3)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .help(text)
    }

    private var color: Color {
        switch kind {
        case .ok:      return Palette.ok
        case .error:   return Palette.err
        case .warn:    return Palette.warn
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - 账号信息
private struct AccountCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("账号信息")

            LabeledRow("校园网账号") {
                TextField("", text: $model.username)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledRow("密码") {
                HStack(spacing: 8) {
                    Group {
                        if model.showPassword {
                            TextField("", text: $model.password)
                        } else {
                            SecureField("", text: $model.password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button(model.showPassword ? "隐藏" : "显示") {
                        model.showPassword.toggle()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("密码仅保存在本机「钥匙串」中。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - 主操作
private struct PrimaryButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.saveAndEnable()
        } label: {
            Text("保存并启用后台认证")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Palette.accent)
        .disabled(model.busy)
    }
}

// MARK: - 高级设置（默认收起）
private struct AdvancedSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        DisclosureGroup(isExpanded: $model.advancedOpen) {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                ServiceCard()
                ActionsCard()
                AppearanceCard()
                LogCard()
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text("高级设置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius,
                                                       style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - 后台服务
private struct ServiceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("后台服务")

            LabeledRow("检测间隔") {
                HStack(spacing: 8) {
                    TextField("", text: $model.checkInterval)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("秒检测一次").foregroundStyle(.secondary)
                }
            }

            LabeledRow("探测地址") {
                TextField("", text: $model.captiveURL)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledRow("认证门户") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $model.portalHint)
                        .textFieldStyle(.roundedBorder)
                    Text("正常情况会自动识别，识别不到时才需手工填写。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("登录后自动启动后台服务", isOn: $model.autoStart)
                .toggleStyle(.switch)
            Toggle("认证结果发送系统通知", isOn: $model.notify)
                .toggleStyle(.switch)
            Toggle("仅 syny WiFi 下认证", isOn: $model.onlySynyWifi)
                .toggleStyle(.switch)
        }
        .card()
    }
}

// MARK: - 操作（自适应换行，窄面板下不挤）
private struct ActionsCard: View {
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("操作")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                Button("仅保存") { model.saveOnly() }
                Button("立即测试认证") { model.testAuth() }
                Button("手动下线") { model.logout() }
                Button("停止后台服务") { model.stopService() }
                Button("重装/修复服务") { model.repairService() }
                Button("打开日志文件") { model.openLog() }
            }
            .buttonStyle(.bordered)
        }
        .disabled(model.busy)
        .card()
    }
}

// MARK: - 界面（面板高度自定义）
private struct AppearanceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("界面")

            LabeledRow("面板高度上限") {
                Stepper(value: Binding(
                    get: { Double(model.panelMaxHeight) },
                    set: { model.setPanelMaxHeight(CGFloat($0)) }
                ), in: 320...900, step: 20) {
                    Text("\(Int(model.panelMaxHeight)) pt")
                        .monospacedDigit()
                }
            }

            Text("面板高度会随高级设置的展开/收起自动调整；超过上限后内部滚动。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - 运行日志
private struct LogCard: View {
    @EnvironmentObject var model: AppModel

    private var loggingBinding: Binding<Bool> {
        Binding(
            get: { model.logging },
            set: { newValue in
                model.logging = newValue
                model.toggleLogging()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("运行日志")
                Spacer()
                Toggle("记录", isOn: loggingBinding)
                    .toggleStyle(.switch)
                Button("刷新") { model.refreshLog() }
                    .buttonStyle(.bordered)
                Button("清空") { model.clearLog() }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                Text(model.logContent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 120)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
        }
        .card()
    }
}

// MARK: - 底部：退出
private struct FooterView: View {
    var body: some View {
        HStack {
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 SYNY", systemImage: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 复用组件
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

struct LabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .frame(width: 72, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
