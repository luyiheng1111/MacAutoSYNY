import SwiftUI
import AppKit

// MARK: - 「修改 Wi-Fi 设置」教学页

/// 教学内容：为什么要把「私有 Wi-Fi 地址」改成「固定 / 关闭」，以及具体两步怎么点。
///
/// 写在界面里而不是只写在 README 里，是因为**触发这个问题的恰恰是不看 README 的人**：
/// 用户装完直接连网，看到的现象只是「怎么老让重新认证」，
/// 不会想到根因在系统 Wi-Fi 的隐私设置里。所以把它做成首次启动必弹的一页。
struct WifiGuideView: View {
    /// 内容区目标高度，由窗口按屏幕可用高度算好后传入。
    ///
    /// 必须显式给出：本页中间是一个 `ScrollView`，而 ScrollView 在**高度不受约束**时
    /// 会按内容的理想高度撑开（截图很高，实测约 1200pt）。窗口若照此定尺寸，
    /// 底部按钮会被顶到屏幕外。这里把理想高度钉住，ScrollView 才会去滚动。
    var height: CGFloat = 760

    /// 点「我知道了」：视为已读完这一步。
    ///
    /// 与 `onClose` 分开是有意的：只有明确点过「我知道了」才算确认，
    /// 面板主区域的常驻提示卡会随之收起（回看入口留在「高级设置」）；
    /// 顺手用红叉关掉不算，提示卡继续留着兜底。
    var onAcknowledge: () -> Void = {}

    /// 关闭窗口（点「我知道了」与点红叉都会走这里）。
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    whyCard
                    stepView(
                        number: 1,
                        title: "在「已知网络」里点校园网右侧的 ⋯，选「网络设置…」",
                        detail: "点菜单栏右上角的 Wi-Fi 图标，在「已知网络」中找到校园网（本机为 SYNY），"
                              + "点它右侧的「⋯」按钮，在弹出菜单里选「网络设置…」。"
                              + "走「系统设置 → Wi-Fi → 详细信息」也是同一处。",
                        image: "step1"
                    )
                    stepView(
                        number: 2,
                        title: "把「私有 Wi-Fi 地址」由「轮换」改为「固定」或「关闭」",
                        detail: "在详情页找到「私有 Wi-Fi 地址」，把右侧的选项从「轮换」改成「固定」（推荐）"
                              + "或「关闭」，最后点右下角的「好」保存。",
                        image: "step2"
                    )
                    notesCard
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        // 理想尺寸 = 窗口期望的内容尺寸；min/max 放开，用户手动缩放窗口时内容自动跟随。
        .frame(minWidth: 560, idealWidth: 600, maxWidth: .infinity,
               minHeight: 420, idealHeight: height, maxHeight: .infinity)
        .background(Palette.windowBG)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.warn.opacity(0.16))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("首次使用：请先改一处 Wi-Fi 设置")
                        .font(.system(size: 16, weight: .semibold))
                    Text("必做")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.err, in: Capsule())
                }
                Text("只做一次。不改这一步，即使 SYNY 正常工作，也会反复被要求重新认证。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: 为什么

    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("为什么要改")

            Text("macOS 的「私有 Wi-Fi 地址」出厂默认是「轮换」：每连一次网，系统就换一个随机的 "
                 + "MAC 地址发给路由器。而校园网认证门户是按 MAC 地址记住「这台设备已经登录」的——"
                 + "MAC 一变，门户就把它当成一台新设备，要求重新认证。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("表现就是：明明装了 SYNY，还是老弹认证页、或者刚登上就掉线。"
                 + "把这一项设为「固定」，MAC 就稳定下来，一次认证可以长期有效。")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warn.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: 单个步骤

    private func stepView(number: Int, title: String, detail: String, image: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Palette.accent, in: Circle())
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            screenshot(image)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card,
                    in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    /// 截图。取不到图时给一段占位说明，而不是留一片空白让人以为界面坏了。
    @ViewBuilder
    private func screenshot(_ name: String) -> some View {
        if let nsImage = GuideAssets.image(name) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .accessibilityLabel("操作截图 \(name)")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                Text("示意图未随包安装（\(name).png）；可在项目 docs/wifi-guide/ 或 README 中查看。")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: 补充说明

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("补充")

            bullet("改完把 Wi-Fi 断开再连一次，让新的地址立刻生效。")
            bullet("「固定」和「关闭」效果等价，都能让 MAC 稳定；若「固定」之后仍反复要求认证，改用「关闭」再试一次。")
            bullet("若学校门户此前已按旧 MAC 绑定过，改完第一次可能需要重新登录一次，属正常现象。")
            bullet("本教学只在首次启动自动弹出；之后可随时在菜单栏面板点「WiFi 设置教学」重看。")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card,
                    in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                SystemSettingsLink.openWiFi()
            } label: {
                Label("打开 Wi-Fi 设置", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 8)

            Text("设置一次，长期有效")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                onAcknowledge()
                onClose()
            } label: {
                Text("我知道了").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

// MARK: - 教学截图定位

/// 教学截图的查找顺序。
///
/// 正式版从 `.app/Contents/Resources/wifi-guide/` 读（由 `scripts/build-swift.sh` 拷入）；
/// 开发期直接 `swift run` 时 `Bundle.main` 指向 `.build`，因此再兜两层：
/// 已安装副本与「当前目录下的 docs/wifi-guide/」（在仓库根目录启动即可命中）。
enum GuideAssets {
    static func image(_ name: String) -> NSImage? {
        for url in candidates(name) where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    private static func candidates(_ name: String) -> [URL] {
        var list: [URL] = []
        if let resources = Bundle.main.resourceURL {
            list.append(resources.appendingPathComponent("wifi-guide/\(name).png"))
        }
        list.append(URL(fileURLWithPath:
            "/Applications/SYNY.app/Contents/Resources/wifi-guide/\(name).png"))
        list.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/wifi-guide/\(name).png"))
        return list
    }
}

// MARK: - 打开系统设置

/// 跳转「系统设置 → Wi-Fi」。
///
/// 这里**不能**用 `NSWorkspace.open` 的返回值判断成败后就放弃：`x-apple.systempreferences:`
/// 在 macOS 13+ 走的是 ExtensionKit 锚点（本机实测扩展标识为
/// `com.apple.wifi-settings-extension`，位于 `/System/Library/ExtensionKit/Extensions/Wi-Fi.appex`），
/// 但不同小版本上旧锚点（网络面板）也偶有可用，因此按新旧顺序依次尝试，
/// 全部失败时至少把「系统设置」打开，避免按钮点了完全没反应。
enum SystemSettingsLink {
    private static let anchors = [
        "x-apple.systempreferences:com.apple.wifi-settings-extension",  // macOS 13+
        "x-apple.systempreferences:com.apple.Network-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.network",        // 旧锚点兜底
    ]

    static func openWiFi() {
        for anchor in anchors {
            guard let url = URL(string: anchor) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        if let app = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(app)
        }
    }
}
