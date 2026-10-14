//
//  ProgressiveTyper.swift
//  voxim
//
//  "Type as you speak": types each committed piece of a dictation as soon as it's
//  transcribed. Committed pieces never change, so this is safe to do while recording.
//  Stops at the first failure (recognition, focus change, secure input…); everything
//  recognized after that is kept for the user to copy.
//

import Foundation

final class ProgressiveTyper {
    /// Formats a piece for typing, given everything typed so far in this dictation.
    typealias Format = (_ text: String, _ typedSoFar: String) -> String
    /// Types the text; returns when the keystroke was posted.
    typealias Insert = (_ text: String) async throws -> ContinuousClock.Instant

    private(set) var typed = ""
    /// Recognized text that wasn't typed because typing stopped.
    private(set) var untyped: [String] = []
    private(set) var recognitionFailed = false
    private(set) var insertionError: (any Error)?
    private(set) var lastTypedAt: ContinuousClock.Instant?
    private var task: Task<Void, Never>?

    var stopped: Bool { recognitionFailed || insertionError != nil }

    init(pieces: AsyncStream<CommittedPiece>, format: @escaping Format, insert: @escaping Insert) {
        task = Task { [weak self] in
            for await piece in pieces {
                guard let self, !Task.isCancelled else { return }
                await self.handle(piece, format: format, insert: insert)
            }
        }
    }

    /// Waits until every piece of the (finished) session has been handled.
    func wait() async {
        await task?.value
    }

    /// Stops typing anything further (Esc, discarded session). Typed text stays.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func handle(_ piece: CommittedPiece, format: Format, insert: Insert) async {
        guard let transcript = piece.transcript else {
            recognitionFailed = true
            return
        }
        let text = format(transcript.text, typed)
        guard !text.trimmed.isEmpty else { return }
        if stopped {
            untyped.append(text.trimmed)
            return
        }
        do {
            lastTypedAt = try await insert(text)
            typed += text
        } catch {
            insertionError = error
            untyped.append(text.trimmed)
        }
    }
}
