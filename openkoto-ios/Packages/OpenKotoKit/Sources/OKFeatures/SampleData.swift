import Foundation
import OKModels

/// 内置示例内容（公版文本），保证零配置（无 API Key）也能体验核心交互——
/// 同时满足 App Review 需要可验证 UI 的要求（设计文档 §10.1 / §433a）。
/// 注意：这不是 mock 数据，是发布必需的产品功能；用户数据（收藏等）不在此预置。
enum SampleData {
    struct Bundle {
        var articles: [Article]
        var segments: [UUID: [ArticleSegment]]
    }

    /// **固定 id，不能用 `UUID()` 现生成。**
    ///
    /// 每台设备各自随机生成的话，iCloud 同步会认为它们是不同的文章，
    /// 于是每接入一台新设备就多出两篇一模一样的示例；而且在示例上生成的精讲
    /// 也传不到另一台（id 对不上）。固定 id 让三台设备天然指向同一篇。
    ///
    /// 只影响新安装：`seedIfEmpty` 只在文章表为空时种，老设备保持原样
    /// —— 它们之间的去重由 `applyCloudPayloads` 的同名同正文判断兜底。
    static let yumeID = UUID(uuidString: "0e8a1f52-0000-4000-a000-00006b756d65")!
    static let aliceID = UUID(uuidString: "0e8a1f52-0000-4000-a000-0000616c6963")!

    static func make() -> Bundle {
        let yumeID = Self.yumeID
        let aliceID = Self.aliceID

        // created_at 错开 1 分钟，保证书库按时间倒序时示例顺序稳定（夢十夜在前）
        let now = Date.now
        let yume = Article(
            id: yumeID,
            title: "夢十夜 第一夜（節選）",
            content: "",
            sourceType: .article,
            createdAt: now
        )
        let alice = Article(
            id: aliceID,
            title: "Alice's Adventures in Wonderland (excerpt)",
            content: "",
            sourceType: .article,
            createdAt: now.addingTimeInterval(-60)
        )

        // 夏目漱石《夢十夜》（1908，公版）。前几句带注音/翻译/精讲，演示三种 chip 状态。
        var order = 0
        func seg(
            _ text: String, reading: String? = nil, translation: String? = nil,
            explanation: SegmentExplanation? = nil, newParagraph: Bool = false
        ) -> ArticleSegment {
            defer { order += 1 }
            return ArticleSegment(
                articleId: yumeID, order: order, text: text,
                readingText: reading, translation: translation,
                explanation: explanation, isNewParagraph: newParagraph
            )
        }

        let yumeSegments: [ArticleSegment] = [
            seg(
                "こんな夢を見た。",
                reading: "こんな ゆめ を みた。",
                translation: "我做了这样一个梦。",
                explanation: SegmentExplanation(
                    translation: "我做了这样一个梦。",
                    explanation: "「夢を見る」是固定搭配，字面是“看见梦”，即“做梦”。"
                        + "「こんな」为近称指示词，指代下文将要叙述的内容，是日语叙事开篇的常见写法。",
                    readingText: "こんな ゆめ を みた。",
                    vocabulary: [
                        VocabularyItem(
                            word: "夢", meaning: "梦",
                            usage: "夢を見る＝做梦",
                            example: "昨夜、不思議な夢を見た。",
                            reading: "ゆめ"
                        ),
                    ],
                    grammarPoints: [
                        GrammarPoint(
                            point: "〜を見る（惯用）",
                            explanation: "「夢を見る」为惯用搭配，表示“做梦”，不能直译为“看”。",
                            example: "彼はよく同じ夢を見るそうだ。"
                        ),
                    ],
                    culturalContext: "出自夏目漱石《梦十夜》（1908）开篇，是日本近代文学中最著名的起笔之一。",
                    difficultyLevel: "beginner",
                    learningTips: "记住「夢を見る」整体记忆，不要拆开逐词翻译。"
                ),
                newParagraph: true
            ),
            seg(
                "腕組をして枕元に坐っていると、仰向に寝た女が、静かな声でもう死にますと云う。",
                reading: "うでぐみ を して まくらもと に すわって いると、あおむけ に ねた おんな が、しずかな こえ で もう しにます と いう。",
                translation: "我抱着胳膊坐在枕边，仰卧着的女子用平静的声音说：我就要死了。",
                explanation: SegmentExplanation(
                    translation: "我抱着胳膊坐在枕边，仰卧着的女子用平静的声音说：我就要死了。",
                    explanation: "「〜ていると」表示在某动作持续期间发生了另一件事。"
                        + "「もう死にます」用郑重体直接引语，平静的语气与内容形成强烈反差，是本篇的名句。",
                    readingText: "うでぐみ を して まくらもと に すわって いると…",
                    vocabulary: [
                        VocabularyItem(word: "腕組", meaning: "抱着胳膊、环抱双臂", reading: "うでぐみ"),
                        VocabularyItem(word: "枕元", meaning: "枕边、床头", reading: "まくらもと"),
                        VocabularyItem(word: "仰向け", meaning: "仰卧、脸朝上", reading: "あおむけ"),
                    ],
                    grammarPoints: [
                        GrammarPoint(
                            point: "〜ていると",
                            explanation: "表示动作/状态持续中，另一件事发生。",
                            example: "本を読んでいると、電話が鳴った。"
                        ),
                    ],
                    difficultyLevel: "intermediate"
                ),
                newParagraph: true
            ),
            seg(
                "女は長い髪を枕に敷いて、輪郭の柔らかな瓜実顔をその中に横たえている。",
                reading: "おんな は ながい かみ を まくら に しいて、りんかく の やわらかな うりざねがお を その なか に よこたえて いる。",
                translation: "女子把长发铺在枕上，轮廓柔和的瓜子脸卧在发间。"
            ),
            seg(
                "真白な頬の底に温かい血の色がほどよく差して、唇の色は無論赤い。",
                reading: "まっしろな ほお の そこ に あたたかい ち の いろ が ほどよく さして、くちびる の いろ は むろん あかい。",
                translation: "雪白的脸颊深处透着恰到好处的温热血色，嘴唇自然是红的。"
            ),
            seg("とうてい死にそうには見えない。"),
            seg("しかし女は静かな声で、もう死にますと判然云った。", newParagraph: true),
            seg("自分も確にこれは死ぬなと思った。"),
            seg("そこで、そうかね、もう死ぬのかね、と上から覗き込むようにして聞いて見た。"),
            seg("死にますとも、と云いながら、女はぱっちりと眼を開けた。"),
        ]

        // Lewis Carroll, Alice in Wonderland (1865, 公版)。全部 plain 状态。
        var aliceOrder = 0
        func aseg(_ text: String, newParagraph: Bool = false) -> ArticleSegment {
            defer { aliceOrder += 1 }
            return ArticleSegment(
                articleId: aliceID, order: aliceOrder, text: text,
                isNewParagraph: newParagraph
            )
        }
        let aliceSegments: [ArticleSegment] = [
            aseg("Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.", newParagraph: true),
            aseg("Once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it."),
            aseg("\"And what is the use of a book,\" thought Alice, \"without pictures or conversations?\""),
            aseg("So she was considering in her own mind whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.", newParagraph: true),
        ]

        return Bundle(
            articles: [yume, alice],
            segments: [yumeID: yumeSegments, aliceID: aliceSegments]
        )
    }
}
