//
//  ChineseTests.swift
//  voximTests
//

import Testing
@testable import voxim

struct LanguageRoutingTests {
    @Test(arguments: [
        ("zh", "帮我跑一下测试", LanguageRouting.Route.chinese),
        ("yue", "我哋走啦", .chinese),
        ("en", "Run the tests.", .english),
        ("ja", "Com?", .english),             // "Commit" misdetected as ja, no CJK → English
        ("ja", "打开文件", .chinese),          // Mandarin misdetected as ja, has CJK → Chinese
        ("en", "帮我跑一下unit tests", .chinese), // CJK wins over an English tag
        ("nospeech", "", .nothing),
        (nil, "hello", .english),
    ] as [(String?, String, LanguageRouting.Route)])
    func routes(language: String?, text: String, expected: LanguageRouting.Route) {
        #expect(LanguageRouting.route(language: language, text: text) == expected)
    }
}

struct StickyLanguageRoutingTests {
    @Test func shortEnglishInAChineseDictationStaysChinese() {
        #expect(LanguageRouting.route(language: "en", text: "unit tests", hint: "zh", seconds: 1.5) == .chinese)
    }

    @Test func longEnglishSwitchesAChineseDictationToEnglish() {
        #expect(LanguageRouting.route(language: "en", text: "Now let me explain the plan in English.",
                                      hint: "zh", seconds: 6) == .english)
    }

    @Test func chineseCharactersAlwaysWin() {
        #expect(LanguageRouting.route(language: "en", text: "打开 README", hint: "en", seconds: 1) == .chinese)
    }

    @Test func shortChineseTagWithoutChineseTextStaysEnglish() {
        #expect(LanguageRouting.route(language: "zh", text: "OK", hint: "en", seconds: 0.8) == .english)
    }

    @Test func withoutAHintItsTheTag() {
        #expect(LanguageRouting.route(language: "en", text: "Commit", hint: nil, seconds: 0.5) == .english)
        #expect(LanguageRouting.route(language: "zh", text: "ok", hint: nil, seconds: 0.5) == .chinese)
    }
}

struct ChineseTextTests {
    @Test func detectsCJK() {
        #expect(ChineseText.containsCJK("用 npm"))
        #expect(!ChineseText.containsCJK("npm install"))
        #expect(!ChineseText.containsCJK("，。"))   // punctuation alone isn't Chinese text
    }

    @Test func spacesBetweenChineseAndLatin() {
        #expect(ChineseText.spacingCJKAndLatin("用npm安装依赖然后启动dev server") == "用 npm 安装依赖然后启动 dev server")
        #expect(ChineseText.spacingCJKAndLatin("这个bug在main分支上") == "这个 bug 在 main 分支上")
        #expect(ChineseText.spacingCJKAndLatin("已经是 spaced 的") == "已经是 spaced 的")
        #expect(ChineseText.spacingCJKAndLatin("测试，test。") == "测试，test。")  // no space next to full-width punctuation
        #expect(ChineseText.spacingCJKAndLatin("第3次") == "第 3 次")
    }

    @Test func convertsScript() {
        #expect(ChineseText.converting("安装依赖", to: .traditional) == "安裝依賴")
        #expect(ChineseText.converting("安裝依賴", to: .simplified) == "安装依赖")
        #expect(ChineseText.converting("plain English", to: .traditional) == "plain English")
    }

    @Test func countsCharactersAsWords() {
        #expect(ChineseText.wordCount("帮我跑一下 unit tests") == 7)  // 5 characters + 2 words
        #expect(ChineseText.wordCount("Hello, world.") == 2)
        #expect(ChineseText.wordCount("") == 0)
    }
}

struct ChineseFormattingTests {
    private func prose(_ preceding: String?) -> InsertionContext {
        InsertionContext(precedingText: preceding, isTerminal: false)
    }

    @Test func noSpaceBetweenChineseRuns() {
        #expect(TextFormatter.format("然后修复失败的。", context: prose("运行测试，")) == "然后修复失败的。")
        #expect(TextFormatter.format("然后修复。", context: prose("运行测试")) == "然后修复。")
    }

    @Test func spaceBetweenChineseAndEnglishFollowsOption() {
        #expect(TextFormatter.format("React 组件", context: prose("我们用")) == " React 组件")
        #expect(TextFormatter.format("React 组件", context: prose("我们用"), spaceBetweenCJKAndLatin: false) == "React 组件")
        #expect(TextFormatter.format("组件", context: prose("React")) == " 组件")
    }

    @Test func englishAfterChineseKeepsCase() {
        // After Chinese, "React" is a term, not a sentence continuation to lowercase.
        #expect(TextFormatter.format("React 组件", context: prose("用")) == " React 组件")
    }

    @Test func chineseSentenceEndersKeepCapitals() {
        #expect(TextFormatter.format("Then deploy.", context: prose("好了。")) == "Then deploy.")
    }

    @Test func terminalDropsChinesePeriod() {
        let terminal = InsertionContext(precedingText: nil, isTerminal: true)
        #expect(TextFormatter.format("帮我看一下为什么构建失败了。", context: terminal) == "帮我看一下为什么构建失败了")
        #expect(TextFormatter.format("真的吗？", context: terminal) == "真的吗？")
    }
}

struct ChineseReplacementTests {
    private func apply(_ pairs: [(String, String)], _ text: String) -> String {
        ReplacementEngine.apply(pairs.map { Replacement(spoken: $0.0, written: $0.1) }, to: text)
    }

    @Test func latinRuleMatchesInsideChineseText() {
        #expect(apply([("NTM", "npm")], "用NTM安装依赖") == "用npm安装依赖")
        #expect(apply([("mux", "tmux")], "我用mux，还有demux") == "我用tmux，还有demux")
    }

    @Test func chineseRuleMatchesWithoutSpaces() {
        #expect(apply([("派森", "Python")], "我在学派森编程") == "我在学Python编程")
    }
}

struct SenseVoiceSegmentTests {
    @Test func shortAudioIsOneSegment() {
        let samples = [Float](repeating: 0.5, count: 16_000 * 10)
        #expect(SenseVoiceTranscriber.segments(samples.count, samples: samples) == [0..<samples.count])
    }

    @Test func longAudioSplitsUnderTheLimitAndCoversEverything() {
        let samples = [Float](repeating: 0.5, count: 16_000 * 95)  // 95 s, no silence
        let ranges = SenseVoiceTranscriber.segments(samples.count, samples: samples)
        #expect(ranges.count == 4)
        #expect(ranges.allSatisfy { $0.count <= SenseVoiceTranscriber.maxSamples })
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func cutsAtSilenceNearTheBoundary() {
        // Loud audio with a silent 200 ms gap at 26.5 s, inside the last 3 s of the first segment.
        var samples = [Float](repeating: 0.5, count: 16_000 * 40)
        let gap = Int(26.5 * 16_000)
        for i in gap..<(gap + 3_200) { samples[i] = 0 }
        let cut = SenseVoiceTranscriber.segments(samples.count, samples: samples)[0].upperBound
        #expect((gap..<(gap + 3_200)).contains(cut))
    }

    @Test func joinsChineseWithoutSpaces() {
        #expect(SenseVoiceTranscriber.join("先运行测试", "然后修复。") == "先运行测试然后修复。")
        #expect(SenseVoiceTranscriber.join("Run the tests.", "Then fix them.") == "Run the tests. Then fix them.")
        #expect(SenseVoiceTranscriber.join("", "开始") == "开始")
    }
}
