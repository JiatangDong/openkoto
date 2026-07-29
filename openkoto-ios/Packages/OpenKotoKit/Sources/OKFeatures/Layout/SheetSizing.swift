#if os(iOS)
import SwiftUI

extension View {
    /// 给 sheet 一个在宽屏下合理的尺寸。
    ///
    /// `presentationDetents` 只在 compact 宽度生效；iPad regular 与 Catalyst 下
    /// sheet 走 form/page 形态，不给尺寸的话要么占满整屏、要么缩成一个小方块。
    /// iOS 18 的 `presentationSizing` 正是补这个缺口的。
    ///
    /// - `.form`：设置类表单（模型配置、生词编辑）
    /// - `.page`：内容较多、需要更大阅读面积（章节目录、书签、出处预览）
    func okSheetSizing(_ sizing: OKSheetSizing = .form) -> some View {
        modifier(OKSheetSizingModifier(sizing: sizing))
    }
}

enum OKSheetSizing {
    case form
    case page
}

private struct OKSheetSizingModifier: ViewModifier {
    let sizing: OKSheetSizing

    func body(content: Content) -> some View {
        switch sizing {
        case .form:
            content.presentationSizing(.form)
        case .page:
            content.presentationSizing(.page)
        }
    }
}
#endif
