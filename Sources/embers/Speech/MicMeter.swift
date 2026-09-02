//  MicMeter.swift
//  Pure mic-level metering: RMS of a sample frame → a smoothed 0…1 level with fast attack
//  and slow decay (so the waveform jumps on speech and eases back). No audio framework, no
//  UI — unit-testable on its own.

import Foundation

struct MicMeter {
    /// Linear gain applied to RMS before clamping (mic RMS is small for normal speech).
    var gain: Float = 8
    var attack: Float = 0.6      // toward a louder target — snappy
    var decay: Float = 0.15      // toward a quieter target — gentle

    private(set) var level: Float = 0

    /// Feed one frame's RMS, return the new smoothed level.
    @discardableResult
    mutating func push(rms: Float) -> Float {
        let target = min(1, max(0, rms * gain))
        let coeff = target > level ? attack : decay
        level += (target - level) * coeff
        return level
    }

    mutating func reset() { level = 0 }

    /// RMS of `count` float samples.
    static func rms(_ samples: UnsafePointer<Float>, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { let s = samples[i]; sum += s * s }
        return (sum / Float(count)).squareRoot()
    }
}
