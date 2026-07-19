import SwiftUI

/// 语义颜色 token，与桌面 CSS 变量一一对应（设计文档 §7.1）。
/// 具体色值由 scripts/generate_palettes.py 从桌面 OKLCH 主题转换生成。
public struct ThemeTokens: Sendable {
    public let background: Color
    public let foreground: Color
    public let card: Color
    public let cardForeground: Color
    public let primary: Color
    public let primaryForeground: Color
    public let secondary: Color
    public let secondaryForeground: Color
    public let muted: Color
    public let mutedForeground: Color
    public let accent: Color
    public let accentForeground: Color
    public let destructive: Color
    public let destructiveForeground: Color
    public let border: Color
    public let input: Color
    public let ring: Color

    public init(
        background: Color, foreground: Color,
        card: Color, cardForeground: Color,
        primary: Color, primaryForeground: Color,
        secondary: Color, secondaryForeground: Color,
        muted: Color, mutedForeground: Color,
        accent: Color, accentForeground: Color,
        destructive: Color, destructiveForeground: Color,
        border: Color, input: Color, ring: Color
    ) {
        self.background = background
        self.foreground = foreground
        self.card = card
        self.cardForeground = cardForeground
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.secondary = secondary
        self.secondaryForeground = secondaryForeground
        self.muted = muted
        self.mutedForeground = mutedForeground
        self.accent = accent
        self.accentForeground = accentForeground
        self.destructive = destructive
        self.destructiveForeground = destructiveForeground
        self.border = border
        self.input = input
        self.ring = ring
    }
}

/// 阅读器/卡片状态的语义扩展色（对应桌面 chip 与卡片状态色，设计文档 §7.1）。
extension ThemeTokens {
    public var explained: Color { .green }          // 已精讲
    public var translatedHint: Color { .yellow }    // 已翻译
    public var vocabAccent: Color { .orange }       // 词汇卡（桌面 amber）
    public var grammarAccent: Color { .purple }     // 语法卡
}

/// SRS 记忆保持率标色（规范 docs/specs/vocabulary-srs-spec.md §5,对应桌面 --srs-* token）。
extension ThemeTokens {
    public var srsStrong: Color { .green }          // R ≥ 0.90 保持良好
    public var srsFading: Color { .orange }         // 0.70 ≤ R < 0.90 正在衰减
    public var srsWeak: Color { .red }              // R < 0.70 可能遗忘
}

public struct ThemePalette: Sendable {
    public let light: ThemeTokens
    public let dark: ThemeTokens

    public init(light: ThemeTokens, dark: ThemeTokens) {
        self.light = light
        self.dark = dark
    }
}

public enum ThemeID: String, CaseIterable, Sendable, Identifiable {
    case california
    case tokyo
    case seoul

    public var id: String { rawValue }

    public var palette: ThemePalette {
        switch self {
        case .california: .california
        case .tokyo: .tokyo
        case .seoul: .seoul
        }
    }

    public var displayName: String {
        switch self {
        case .california: "California"
        case .tokyo: "Tokyo"
        case .seoul: "Seoul"
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 圆角 token：California --radius: 0.3rem ≈ 5pt；chip/卡片 8pt、sheet 12pt。
public enum OKRadius {
    public static let control: CGFloat = 5
    public static let chip: CGFloat = 8
    public static let card: CGFloat = 8
    public static let sheet: CGFloat = 12
}

@MainActor
@Observable
public final class ThemeManager {
    private static let themeKey = "appearance.themeID"
    private static let modeKey = "appearance.mode"

    public var themeID: ThemeID {
        didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Self.themeKey) }
    }
    public var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.modeKey) }
    }

    public init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: Self.themeKey).flatMap(ThemeID.init) ?? .california
        appearance = defaults.string(forKey: Self.modeKey).flatMap(AppearanceMode.init) ?? .system
    }

    public func tokens(for colorScheme: ColorScheme) -> ThemeTokens {
        let effective = appearance.colorScheme ?? colorScheme
        return effective == .dark ? themeID.palette.dark : themeID.palette.light
    }
}

public extension EnvironmentValues {
    @Entry var theme: ThemeTokens = ThemePalette.california.light
}
