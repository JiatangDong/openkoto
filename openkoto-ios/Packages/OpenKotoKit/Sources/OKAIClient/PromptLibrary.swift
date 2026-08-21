import Foundation

/// Prompt 常量库（设计文档 §4.3）。
///
/// 以**语义与输出 schema 对齐**为准移植桌面 `ai_service.rs`，而非依赖易漂移的源码行号。
/// 每个 Prompt 分配稳定 `version`；Prompt 变化时 bump version，并让共享 golden fixtures 发现漂移。
public enum PromptLibrary {
    /// 逐句精讲 Prompt 版本。写入 `explanation_json.prompt_version`，
    /// 正文/目标语言/Prompt 变化时据此判定精讲结果是否过期（设计文档 §3.2）。
    public static let segmentExplainVersion = "explain-v1"

    /// 纯翻译 Prompt 版本（快翻/全文翻译，无精讲）。
    public static let segmentTranslateVersion = "translate-v1"

    /// 单词释义 Prompt 版本。
    public static let wordGlossVersion = "gloss-v1"

    /// 网页素材清洗 Prompt 版本。
    public static let webCleanVersion = "webclean-v1"

    /// 目标语言代码 → prompt 内使用的母语名（对齐 `segment_translate_explain` 映射表）。
    public static func nativeLanguageName(for targetLanguage: String) -> String {
        switch targetLanguage {
        case "zh", "zh-CN": return "中文"
        case "zh-TW": return "繁體中文"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "es": return "Español"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "ru": return "Русский"
        case "ar": return "العربية"
        default: return "中文"
        }
    }

    /// 逐句精讲 system prompt（对齐 `segment_translate_explain`，输出 schema 与桌面一致）。
    /// user message 固定为 `"Analyze this: {text}"`。
    public static func segmentExplainSystemPrompt(text: String, targetLanguage: String) -> String {
        let lang = nativeLanguageName(for: targetLanguage)
        return """
        You are a professional language learning assistant. The user's native language is \(lang). Please analyze the following text segment comprehensively and return the result strictly in the following JSON format. Do NOT add any extra explanations or markdown formatting outside the JSON block.

        User's Native Language: \(lang)

        Text to Analyze:
        ---
        \(text)
        ---

        Please strictly adhere to this JSON structure (all keys must be in English):
        {
          "translation": "Translate the text into natural, fluent \(lang)",
          "explanation": "Explain the text in \(lang), covering context, tone, and cultural background. Use Markdown formatting.",
          "vocabulary": [
            {
              "word": "The word or phrase from the text",
              "reading": "Pronunciation/Reading (e.g., Hiragana for Japanese, IPA for English)",
              "meaning": "Core meaning in the context, explained in \(lang)",
              "usage": "Usage notes and collocations in \(lang)",
              "example": "Example sentence containing the word, with \(lang) translation"
            }
          ],
          "grammar_points": [
            {
              "point": "Name of the grammar point",
              "explanation": "Detailed explanation in \(lang)",
              "example": "Example sentence using the grammar point, with \(lang) translation"
            }
          ],
          "cultural_context": "Cultural background info in \(lang) (if applicable, else null)",
          "difficulty_level": "beginner | intermediate | advanced",
          "learning_tips": "Learning advice for this segment in \(lang)"
        }

        Ensure all explanations, meanings, and descriptive text are written in \(lang).
        """
    }

    /// 精讲请求的 user message（对齐 Rust `format!("Analyze this: {}", text)`）。
    public static func analyzeUserMessage(text: String) -> String {
        "Analyze this: \(text)"
    }

    /// 纯翻译 system prompt（对齐桌面 `ai_service.rs::translate`）。
    /// user message 直接为原文；只返回译文，不带解释。
    public static func segmentTranslateSystemPrompt(targetLanguage: String) -> String {
        let lang = nativeLanguageName(for: targetLanguage)
        return "You are a professional translator. Translate the following text to \(lang). "
            + "Preserve the original meaning and tone. Only return the translated text without any explanations."
    }

    /// 单词释义 system prompt。
    ///
    /// 与精讲**刻意保持极简**：schema 只有 5 个键、要求简短、不要 markdown。
    /// 精讲一次要吐 600–1200 token（翻译+讲解+词表+语法+文化背景+学习建议），
    /// 而用户最高频的动作只是"这个词啥意思"。这条路径把输出压到 80–150 token，
    /// 便宜一个数量级——**省钱靠的是输出短，与用哪个模型无关**。
    ///
    /// 输出 schema 与 `VocabularyItem` 对齐，解出来能直接进生词本。
    public static func wordGlossSystemPrompt(targetLanguage: String) -> String {
        let lang = nativeLanguageName(for: targetLanguage)
        return """
            You are a bilingual dictionary. The user's native language is \(lang).
            Given a word and the sentence it appears in, explain that word **as used in \
            that sentence**. Return ONLY this JSON, with no markdown fences and no extra text:

            {
              "word": "the dictionary form of the word",
              "reading": "Pronunciation (Hiragana for Japanese, Pinyin for Chinese, IPA for \
            English); omit if not applicable",
              "meaning": "A concise meaning in \(lang), one line",
              "usage": "Part of speech and a short note on how it is used here, in \(lang)",
              "example": "One short example sentence using the word"
            }

            Keep every field short. Write meaning and usage in \(lang).
            """
    }

    /// 单词释义的 user message：词 + 它所在的句子（上下文决定义项）。
    public static func wordGlossUserMessage(word: String, sentence: String) -> String {
        "Word: \(word)\nSentence: \(sentence)"
    }

    /// 网页素材清洗 system prompt（对齐桌面 `ai_service.rs::detect_web_noise_lines`）。
    ///
    /// **模型只返回行号，不返回改写后的正文。** 学习素材必须与原文逐字一致：
    /// 让模型整篇重写既费 token，又有漏字/改写/幻觉的风险——用户拿去精讲的那句话
    /// 如果不是网页上原本那句，整个产品的前提就没了。
    public static func webCleanSystemPrompt(wantTitle: Bool) -> String {
        let schema = wantTitle
            ? #"{"drop": [2, 5, 6], "title": "the clean article title, or an empty string if unclear"}"#
            : #"{"drop": [2, 5, 6]}"#
        return """
            You are cleaning a web page that was converted to plain text, so it can be used as language-learning material.

            You will receive numbered lines. Decide which lines are NOT part of the main article body.

            DROP a line when it is:
            - site navigation, menus, breadcrumbs, buttons, search boxes, login/subscribe prompts
            - advertisements, promotional blurbs, paywall or membership pitches
            - related/recommended article lists, "hot posts", tag clouds, category lists, pagination
            - share widgets, like/favorite/view counters, comment threads, comment forms
            - author bio boxes, editor signatures, copyright and legal footers, contact info, ICP/registration numbers
            - cookie or privacy banners, app-download prompts, "click here", "read more", "back to top"
            - standalone metadata that is not part of the text: bare timestamps, view counts, image credits, source attributions

            KEEP a line when it is:
            - the article title, headings and subheadings
            - any paragraph, sentence, dialogue or list item of the main body
            - lyrics, poems, quotes, or code that belong to the article
            - anything you are not sure about — when in doubt, KEEP it

            Rules:
            - Judge each line only by whether it belongs to the article body, never by whether it is interesting or well written.
            - Never rewrite, translate, summarize or reorder anything. You only report line numbers.
            - Long lines are truncated for review and marked with "(len=N)", where N is the real character count. A long line is almost always body text.
            - Return ONLY raw JSON, with no markdown fences and no explanation:
            \(schema)
            """
    }

    /// 清洗请求的 user message：带原始行号的待审行（对齐 Rust `"Lines to review:\n{}"`）。
    public static func webCleanUserMessage(lines: [(index: Int, preview: String)]) -> String {
        let numbered = lines.map { "[\($0.index)] \($0.preview)" }.joined(separator: "\n")
        return "Lines to review:\n\(numbered)"
    }
}
