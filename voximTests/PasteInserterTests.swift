//
//  PasteInserterTests.swift
//  voximTests
//

import AppKit
import Testing
@testable import voxim

/// Records "pastes" by reading the pasteboard at the moment ⌘V would fire.
@MainActor
final class FakePoster: KeystrokePosting {
    let pasteboard: NSPasteboard
    var secure = false
    var pasted: [String?] = []
    var transientMarked: [Bool] = []
    /// Simulates another app writing to the clipboard right after the paste.
    var clobberWith: String?

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    func postPaste() {
        pasted.append(pasteboard.string(forType: .string))
        transientMarked.append(pasteboard.types?.contains(PasteInserter.transientType) ?? false)
        if let clobberWith {
            pasteboard.clearContents()
            pasteboard.setString(clobberWith, forType: .string)
        }
    }

    var isSecureInputEnabled: Bool { secure }
}

@MainActor
struct PasteInserterTests {
    let pasteboard = NSPasteboard(name: .init("voxim-tests-\(UUID().uuidString)"))
    let poster: FakePoster

    init() { poster = FakePoster(pasteboard: pasteboard) }

    private func inserter() -> PasteInserter {
        PasteInserter(pasteboard: pasteboard, poster: poster, checkFocus: false, restoreDelay: .milliseconds(10))
    }

    @Test func pastesTextAndRestoresPreviousClipboard() async throws {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("user's clipboard", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .init("com.example.custom"))
        pasteboard.writeObjects([item])

        try await inserter().insert("hello world", expecting: nil)

        #expect(poster.pasted == ["hello world"])
        #expect(pasteboard.string(forType: .string) == "user's clipboard")
        #expect(pasteboard.data(forType: .init("com.example.custom")) == Data([1, 2, 3]))
    }

    @Test func dictatedTextIsMarkedTransientForClipboardManagers() async throws {
        try await inserter().insert("secret-ish note", expecting: nil)
        #expect(poster.transientMarked == [true])
    }

    @Test func emptyClipboardStaysEmpty() async throws {
        pasteboard.clearContents()
        try await inserter().insert("hello", expecting: nil)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func doesNotOverwriteClipboardChangedByAnotherApp() async throws {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        poster.clobberWith = "copied by the user meanwhile"

        try await inserter().insert("hello", expecting: nil)

        #expect(pasteboard.string(forType: .string) == "copied by the user meanwhile")
    }

    @Test func refusesSecureInputWithoutTouchingClipboard() async {
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        poster.secure = true

        await #expect(throws: InsertionError.secureInput) {
            try await inserter().insert("hello", expecting: nil)
        }
        #expect(poster.pasted.isEmpty)
        #expect(pasteboard.string(forType: .string) == "old")
    }
}
