import Foundation
import Testing
@testable import OKFeatures

/// `PinyinIPA` 拼音→IPA 转换 golden 用例。
/// 重点覆盖多音字（同字不同拼音应得不同 IPA）与声调、ü、y/w 零声母、连写切分、安全回退。
@Suite struct PinyinIPATests {

    // MARK: - 声母 + 韵母 + 声调

    @Test func diacriticBasics() {
        #expect(PinyinIPA.convert("háng") == "xaŋ˧˥")   // 行(银行)
        #expect(PinyinIPA.convert("xíng") == "ɕiŋ˧˥")   // 行(行走)
        #expect(PinyinIPA.convert("zhòng") == "ʈʂʊŋ˥˩") // 重(重要)
        #expect(PinyinIPA.convert("zài") == "tsai˥˩")   // 在
    }

    /// 多音字：同一个字的两个读音必须转出不同 IPA（这正是纠音的意义）。
    @Test func polyphoneReadingsDiffer() {
        #expect(PinyinIPA.convert("háng") != PinyinIPA.convert("xíng"))
        #expect(PinyinIPA.convert("zhòng") != PinyinIPA.convert("chóng"))
        #expect(PinyinIPA.convert("dé") != PinyinIPA.convert("děi"))
    }

    // MARK: - ü / y / w 零声母

    @Test func umlautAndGlides() {
        #expect(PinyinIPA.convert("lǜ") == "ly˥˩")        // 绿/律
        #expect(PinyinIPA.convert("yīn") == "in˥")        // 音
        #expect(PinyinIPA.convert("yuè") == "ɥɛ˥˩")       // 乐/月
        #expect(PinyinIPA.convert("wǔ") == "u˨˩˦")        // 五
        #expect(PinyinIPA.convert("jū") == "tɕy˥")        // 居 (j 后 u 实为 ü)
    }

    // MARK: - 多音节（空格分隔 / 连写切分）

    @Test func multiSyllableSpaced() {
        #expect(PinyinIPA.convert("yīn yuè") == "in˥ ɥɛ˥˩")
        #expect(PinyinIPA.convert("nǐ hǎo") == "ni˨˩˦ xau˨˩˦")
    }

    @Test func multiSyllableJoined() {
        // 连写也应能贪心切分为与空格版一致的结果
        #expect(PinyinIPA.convert("yīnyuè") == PinyinIPA.convert("yīn yuè"))
    }

    // MARK: - 数字声调

    @Test func numberedTones() {
        #expect(PinyinIPA.convert("hang2") == "xaŋ˧˥")
        #expect(PinyinIPA.convert("zhong4") == "ʈʂʊŋ˥˩")
        #expect(PinyinIPA.convert("lv4") == "ly˥˩")            // v 记 ü
        #expect(PinyinIPA.convert("ni3 hao3") == "ni˨˩˦ xau˨˩˦")
        #expect(PinyinIPA.convert("ma1 ma5") == "ma˥ ma")      // 轻声不标
    }

    // MARK: - 整体舌尖元音（zh/ch/sh/r + z/c/s 的 i）

    @Test func syllabicVowels() {
        // 是: sh + 舌尖后 i；只断言前缀与声调，避开组合字符字面量比较陷阱
        let shi = PinyinIPA.convert("shì")
        #expect(shi?.hasPrefix("ʂ") == true)
        #expect(shi?.hasSuffix("˥˩") == true)
        #expect(shi != PinyinIPA.convert("sì"))   // 是 vs 四：舌尖后 vs 舌尖前
    }

    // MARK: - 安全回退

    @Test func returnsNilForNonPinyin() {
        #expect(PinyinIPA.convert("") == nil)
        #expect(PinyinIPA.convert("   ") == nil)
        #expect(PinyinIPA.convert("hello!") == nil)   // 含标点 → 直接判非拼音
        #expect(PinyinIPA.convert("123") == nil)
    }
}
