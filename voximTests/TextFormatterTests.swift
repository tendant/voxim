//
//  TextFormatterTests.swift
//  voximTests
//

import Testing
@testable import voxim

struct TextFormatterTests {
    private func prose(_ preceding: String?) -> InsertionContext {
        InsertionContext(precedingText: preceding, isTerminal: false)
    }

    private func terminal(_ preceding: String? = nil) -> InsertionContext {
        InsertionContext(precedingText: preceding, isTerminal: true)
    }

    @Test func unknownContextOnlyTrims() {
        #expect(TextFormatter.format("  The build is green.  ", context: .unknown) == "The build is green.")
    }

    @Test func collapsesRepeatedSpaces() {
        #expect(TextFormatter.format("ship  it   today.", context: .unknown) == "ship it today.")
    }

    @Test func startOfFieldKeepsCapitalAndNoSpace() {
        #expect(TextFormatter.format("Hello there.", context: prose("")) == "Hello there.")
    }

    @Test func afterSentenceEndAddsSpaceKeepsCapital() {
        #expect(TextFormatter.format("Next one.", context: prose("ne.")) == " Next one.")
        #expect(TextFormatter.format("Why not?", context: prose("ok!")) == " Why not?")
    }

    @Test func afterTrailingSpaceAddsNoExtraSpace() {
        #expect(TextFormatter.format("Then deploy.", context: prose("it. ")) == "Then deploy.")
    }

    @Test func midSentenceLowercasesAndAddsSpace() {
        #expect(TextFormatter.format("The dog ran.", context: prose("saw")) == " the dog ran.")
        #expect(TextFormatter.format("Then retry.", context: prose("ok,")) == " then retry.")
        #expect(TextFormatter.format("Then retry.", context: prose("so ")) == "then retry.")
    }

    @Test(arguments: ["I think so.", "API keys rotate.", "iPhone works.", "McDonald called.", "I'm in."])
    func midSentenceKeepsSpecialFirstWords(transcript: String) {
        #expect(TextFormatter.format(transcript, context: prose("and ")) == transcript)
    }

    @Test func noSpaceAfterOpeningBracketsAndPrefixes() {
        #expect(TextFormatter.format("Optional.", context: prose("(")) == "optional.")
        #expect(TextFormatter.format("Docs", context: prose("~/")) == "docs")
        #expect(TextFormatter.format("Alice", context: prose("@")) == "alice")
    }

    @Test func terminalDropsTrailingPeriodAndLowercases() {
        #expect(TextFormatter.format("Git status.", context: terminal()) == "git status")
        #expect(TextFormatter.format("Run the unit tests and fix the failures.", context: terminal())
            == "run the unit tests and fix the failures")
    }

    @Test func terminalKeepsQuestionsEllipsesAndAcronyms() {
        #expect(TextFormatter.format("Why is CI failing?", context: terminal()) == "why is CI failing?")
        #expect(TextFormatter.format("Wait...", context: terminal()) == "wait...")
        #expect(TextFormatter.format("NPM install.", context: terminal()) == "NPM install")
    }

    @Test func terminalAddsSpaceAfterTypedCommand() {
        #expect(TextFormatter.format("Fix the login test.", context: terminal("-m")) == " fix the login test")
        #expect(TextFormatter.format("Main.", context: terminal("out ")) == "main")
    }
}
