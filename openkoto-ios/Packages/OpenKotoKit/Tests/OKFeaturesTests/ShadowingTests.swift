import Foundation
import OKModels
import Testing

@testable import OKFeatures

/// 跟读模式的状态规则。
///
/// 这三个开关（盲听 / 单句循环 / 慢速）用户还能各自单独操作，
/// 所以"现在到底算不算在跟读"必须有唯一判据——否则菜单会出现
/// 已经名不副实的"退出跟读"。
@Suite struct ShadowingTests {
    private let target = UUID()

    @Test func entersWithAllThreeSwitchesOn() {
        let next = Shadowing.toggled(
            isBlind: false, loopingSegmentID: nil, rate: 1, target: target)
        #expect(next == .init(isBlind: true, loopSegmentID: target, rate: Shadowing.rate))
        #expect(
            Shadowing.isActive(
                isBlind: next.isBlind, loopingSegmentID: next.loopSegmentID, rate: next.rate))
    }

    @Test func exitRestoresNormalRateAndSubtitles() {
        let next = Shadowing.toggled(
            isBlind: true, loopingSegmentID: target, rate: Shadowing.rate, target: target)
        #expect(next == .init(isBlind: false, loopSegmentID: nil, rate: 1))
    }

    /// 用户在跟读中单独调回 1×：入口应当变回"进入跟读"，
    /// 再点一次是**重新进入**（恢复慢速），不是退出。
    @Test func changingRateAloneLeavesShadowing() {
        #expect(!Shadowing.isActive(isBlind: true, loopingSegmentID: target, rate: 1))

        let next = Shadowing.toggled(
            isBlind: true, loopingSegmentID: target, rate: 1, target: target)
        #expect(next.rate == Shadowing.rate)
        #expect(next.isBlind)
        #expect(next.loopSegmentID == target)
    }

    @Test func stoppingLoopAloneLeavesShadowing() {
        #expect(!Shadowing.isActive(isBlind: true, loopingSegmentID: nil, rate: Shadowing.rate))
    }

    @Test func showingSubtitlesAloneLeavesShadowing() {
        #expect(
            !Shadowing.isActive(isBlind: false, loopingSegmentID: target, rate: Shadowing.rate))
    }

    /// 没有可循环的句子时什么都不该变——入口本身也应当是隐藏的。
    @Test func withoutATargetNothingChanges() {
        let next = Shadowing.toggled(
            isBlind: false, loopingSegmentID: nil, rate: 1, target: nil)
        #expect(next == .init(isBlind: false, loopSegmentID: nil, rate: 1))
    }

    /// 已在跟读中时即使算不出目标也要能退出——否则用户被困在盲听里。
    @Test func canAlwaysExitEvenWithoutATarget() {
        let next = Shadowing.toggled(
            isBlind: true, loopingSegmentID: target, rate: Shadowing.rate, target: nil)
        #expect(next == .init(isBlind: false, loopSegmentID: nil, rate: 1))
    }

    // MARK: - 可循环判定

    @Test func onlyTimedSegmentsAreLoopable() {
        let articleID = UUID()
        let timed = ArticleSegment(
            articleId: articleID, order: 0, text: "a", startTime: 0, endTime: 1)
        let untimed = ArticleSegment(articleId: articleID, order: 1, text: "b")
        let halfTimed = ArticleSegment(
            articleId: articleID, order: 2, text: "c", startTime: 2, endTime: nil)

        #expect(Shadowing.isLoopable(timed))
        #expect(!Shadowing.isLoopable(untimed))
        #expect(!Shadowing.isLoopable(halfTimed))
    }
}
