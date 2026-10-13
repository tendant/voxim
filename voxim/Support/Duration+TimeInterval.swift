//
//  Duration+TimeInterval.swift
//  voxim
//

import Foundation

extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
