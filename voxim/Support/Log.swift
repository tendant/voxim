//
//  Log.swift
//  voxim
//
//  Never log transcript text, selected text, or clipboard contents.
//

import os

nonisolated enum Log {
    static let app = Logger(subsystem: "ai.weilabs.voxim", category: "app")
    static let agent = Logger(subsystem: "ai.weilabs.voxim", category: "agent")
    static let asr = Logger(subsystem: "ai.weilabs.voxim", category: "asr")
}
