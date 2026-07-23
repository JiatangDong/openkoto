import SwiftUI

/// 主行动按钮（桌面 primary button 的对应物）：主题主色底、全宽、卡片圆角。
/// 目前用于首启引导的 CTA；设置页等 Form 场景仍用系统样式。
public struct OKPrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(theme.primaryForeground)
            .background(
                theme.primary.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: OKRadius.card)
            )
    }
}

public extension ButtonStyle where Self == OKPrimaryButtonStyle {
    static var okPrimary: OKPrimaryButtonStyle { .init() }
}
