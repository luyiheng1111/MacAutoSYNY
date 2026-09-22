import SwiftUI

/// 设计系统：颜色 / 圆角 / 间距。用语义色让深浅色自动跟随系统，
/// 交互色对齐设计稿的 Action Blue。
enum Palette {
    static let accent = Color(red: 0.0, green: 0.40, blue: 0.80)   // #0066cc
    static let ok     = Color(red: 0.20, green: 0.78, blue: 0.35)   // 系统绿
    static let warn   = Color.orange
    static let err    = Color.red

    static let card     = Color(nsColor: .controlBackgroundColor)
    static let windowBG = Color(nsColor: .windowBackgroundColor)
    static let field    = Color(nsColor: .textBackgroundColor)
}

enum Metrics {
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let sectionGap: CGFloat = 14
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 560
}

/// 圆角卡片容器（对齐设计稿的白色圆角面板）。
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Metrics.cardPadding)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius,
                                                           style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}
