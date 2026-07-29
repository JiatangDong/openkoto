#if os(iOS)
import OKLocalization

/// Mac 菜单栏文案。
///
/// App 壳只链接 OKFeatures 一个 product，拿不到 OKLocalization 的 bundle，
/// 所以由这里代为求值——顺带保证菜单与界面走同一套界面语言覆盖。
public enum MenuStrings {
    public static var reading: String { L("menu.reading") }
    public static var togglePane: String { L("menu.togglePane") }
    public static var increaseFontSize: String { L("menu.increaseFontSize") }
    public static var decreaseFontSize: String { L("menu.decreaseFontSize") }
}
#endif
