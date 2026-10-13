//
//  ReplacementTests.swift
//  voximTests
//

import Testing
@testable import voxim

struct ReplacementTests {
    private func apply(_ pairs: [(String, String)], _ text: String) -> String {
        ReplacementEngine.apply(pairs.map { Replacement(spoken: $0.0, written: $0.1) }, to: text)
    }

    @Test func fixesDay1SpikeMisrecognitions() {
        // Verbatim engine outputs from docs/asr-spike.md.
        let rules = [("mux", "tmux"), ("t mux", "tmux"), ("within PM", "with npm")]
        #expect(apply(rules, "Write a test for that MUX adapter when the pain is gone.")
            == "Write a test for that tmux adapter when the pain is gone.")
        #expect(apply(rules, "Install the dependencies within PM and start the dev server.")
            == "Install the dependencies with npm and start the dev server.")
    }

    @Test func caseInsensitiveAndWrittenFormIsExact() {
        #expect(apply([("fluid audio", "FluidAudio")], "add Fluid Audio to the project") == "add FluidAudio to the project")
    }

    @Test func wholeWordsOnly() {
        #expect(apply([("mux", "tmux")], "demux the stream; muxer; mux.") == "demux the stream; muxer; tmux.")
    }

    @Test func spacingAndHyphensInPhraseAreFlexible() {
        #expect(apply([("t mux", "tmux")], "start T-mux and t  mux") == "start tmux and tmux")
    }

    @Test func longerPhraseWinsOverShorterRule() {
        #expect(apply([("mux", "MUX-CHIP"), ("t mux", "tmux")], "open t mux") == "open tmux")
    }

    @Test func regexCharactersAreLiteral() {
        #expect(apply([("c++", "C++"), ("$home", "$HOME")], "learn c++ in $home") == "learn C++ in $HOME")
        #expect(apply([("dot", "$1.")], "dot") == "$1.")
    }

    @Test func emptyRulesAreIgnored() {
        #expect(apply([("", "x"), ("  ", "y")], "unchanged text") == "unchanged text")
    }

    @Test func unicodeWordBoundaries() {
        #expect(apply([("cafe", "café")], "the cafe's menu, cafeteria") == "the café's menu, cafeteria")
    }
}
