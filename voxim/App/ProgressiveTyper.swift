//
//  ProgressiveTyper.swift
//  voxim
//
//  "Type as you speak": types each committed piece of a dictation as soon as it's
//  transcribed. Committed pieces never change, so this is safe to do while recording.
//  Switching to another app pauses typing: sentences wait, in order, until the original app
//  is in front again. Other failures (recognition, secure input…) stop typing; everything
//  recognized after that is kept for the user to copy.
//

import Foundation

final class ProgressiveTyper {
    /// Formats a piece for typing, given everything typed so far in this dictation.
    typealias Format = (_ text: String, _ typedSoFar: String) -> String
    /// Types the text; returns when the keystroke was posted.
    typealias Insert = (_ text: String) async throws -> ContinuousClock.Instant
    /// Returns true once the original app is in front again; false if waiting was abandoned.
    typealias WaitForFocus = () async -> Bool

    private(set) var typed = ""
    /// Recognized text that wasn't typed because typing stopped.
    private(set) var untyped: [String] = []
    private(set) var recognitionFailed = false
    private(set) var insertionError: (any Error)?
    private(set) var lastTypedAt: ContinuousClock.Instant?
    /// Set while paused: the app to return to.
    private(set) var pausedFor: String?
    private var task: Task<Void, Never>?
    private var focusWait: Task<Bool, Never>?
    private var finishing = false
    private let waitForFocus: WaitForFocus?
    private let onPauseChange: ((String?) -> Void)?

    var stopped: Bool { recognitionFailed || insertionError != nil }

    /// - Parameters:
    ///   - waitForFocus: enables pausing on an app switch; nil stops typing instead.
    ///   - onPauseChange: the app to return to when pausing, nil when typing resumes.
    init(pieces: AsyncStream<CommittedPiece>, format: @escaping Format, insert: @escaping Insert,
         waitForFocus: WaitForFocus? = nil, onPauseChange: ((String?) -> Void)? = nil) {
        self.waitForFocus = waitForFocus
        self.onPauseChange = onPauseChange
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

    /// The dictation is over: don't wait for the user to come back to the app. If paused,
    /// what's left is kept for copying.
    func finishWithoutWaiting() {
        finishing = true
        focusWait?.cancel()
    }

    /// Stops typing anything further (Esc, discarded session). Typed text stays.
    func cancel() {
        task?.cancel()
        task = nil
        focusWait?.cancel()
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
        while true {
            do {
                lastTypedAt = try await insert(text)
                typed += text
                return
            } catch InsertionError.focusChanged(let from, let to) where waitForFocus != nil && !finishing {
                // Another app is in front: hold this sentence (and the ones after it) until
                // the user is back, then try again.
                if await pause(returningTo: from) { continue }
                insertionError = InsertionError.focusChanged(from: from, to: to)
                untyped.append(text.trimmed)
                return
            } catch {
                insertionError = error
                untyped.append(text.trimmed)
                return
            }
        }
    }

    /// Waits for the original app; false if the dictation ended (or was cancelled) first.
    private func pause(returningTo app: String) async -> Bool {
        guard let waitForFocus else { return false }
        pausedFor = app
        onPauseChange?(app)
        let wait = Task { await waitForFocus() }
        focusWait = wait
        let back = await wait.value
        focusWait = nil
        pausedFor = nil
        onPauseChange?(nil)
        return back && !finishing && !Task.isCancelled
    }
}
