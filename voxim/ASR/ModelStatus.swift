//
//  ModelStatus.swift
//  voxim
//

import Foundation
import Observation

/// Load state of the primary (Parakeet) model, shown in the menu during first-run download.
@Observable
final class ModelStatus {
    enum State: Equatable {
        case starting
        case downloading(fraction: Double)
        case compiling
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting

    func update(_ newState: State) {
        // Progress callbacks can arrive after the model is ready (e.g. a final 100% tick).
        if state == .ready, newState != .ready { return }
        state = newState
    }

    /// Thread-safe sink for progress callbacks fired on arbitrary queues.
    nonisolated func post(_ newState: State) {
        Task { @MainActor in self.update(newState) }
    }
}
