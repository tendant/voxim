//
//  String+Trimmed.swift
//  voxim
//

import Foundation

extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
