import SwiftUI

enum SignalOutlineMotionPolicy {
    static func shouldAnimate(
        isListening: Bool,
        supportsListeningTravel: Bool,
        motionEnabled: Bool,
        reduceMotion: Bool
    ) -> Bool {
        guard motionEnabled, !reduceMotion else { return false }
        return isListening && supportsListeningTravel
    }
}

/// A perimeter-bound status signal shared by the hardware notch and listening control.
/// Travel is reserved for active work; live mic history changes only the trailing stroke widths.
struct SignalOutline<S: Shape>: View {
    enum Scale {
        case compact
        case notch
        case expanded

        var activePeriod: TimeInterval {
            switch self {
            case .compact: 3.4
            case .notch: 4.6
            case .expanded: 8.4
            }
        }

        var idlePeriod: TimeInterval { activePeriod * 1.8 }
        var travels: Bool {
            switch self {
            case .compact, .notch: true
            case .expanded: false
            }
        }
        var scannerLength: CGFloat {
            switch self {
            case .compact: 0.22
            case .notch: 0.16
            case .expanded: 0.055
            }
        }
    }

    let shape: S
    @ObservedObject var speech: SpeechListener
    let scale: Scale
    var motionEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var energy: CGFloat { CGFloat(speech.levels.max() ?? 0) }

    /// Listening is a frequent state change, so keep the response crisp: the existing ember
    /// remains underneath while the live signal crossfades in, then its bloom settles a beat
    /// later. Stopping is intentionally faster than starting.
    private var signalTransition: Animation {
        speech.isListening
            ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
            : .timingCurve(0.23, 1, 0.32, 1, duration: 0.13)
    }

    private var bloomTransition: Animation {
        speech.isListening
            ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.22).delay(0.035)
            : .timingCurve(0.23, 1, 0.32, 1, duration: 0.13)
    }

    private var shouldAnimate: Bool {
        SignalOutlineMotionPolicy.shouldAnimate(
            isListening: speech.isListening,
            supportsListeningTravel: scale.travels,
            motionEnabled: motionEnabled,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !shouldAnimate)) { timeline in
            let period = scale.idlePeriod
            let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period)

            ZStack {
                // Keep the idle ember underneath so activation reads as the same signal waking
                // up rather than the perimeter being repainted in a new colour.
                shape.stroke(Style.listenIdle.opacity(0.045), lineWidth: 4)
                    .blur(radius: 2.4)
                    .opacity(speech.isListening ? 0 : 1)
                    .animation(signalTransition, value: speech.isListening)
                shape.stroke(Style.listenIdle.opacity(0.16), lineWidth: 0.9)
                    .opacity(speech.isListening ? 0 : 1)
                    .animation(signalTransition, value: speech.isListening)

                // The precise green edge arrives first; its atmospheric bloom follows just
                // behind it, keeping the transition legible without a celebratory pulse.
                shape.stroke(Style.listenGlow.opacity(0.11), lineWidth: 4)
                    .blur(radius: 2.4)
                    .opacity(speech.isListening ? 1 : 0)
                    .animation(bloomTransition, value: speech.isListening)
                shape.stroke(Style.listenGlow.opacity(0.34), lineWidth: 0.9)
                    .opacity(speech.isListening ? 1 : 0)
                    .animation(signalTransition, value: speech.isListening)

                if !reduceMotion && motionEnabled && scale.travels {
                    ZStack {
                        movingStroke(
                            head: phase,
                            length: scale.scannerLength,
                            color: Style.listenGlow,
                            activeStyle: true,
                            lineWidth: 1.35 + energy * 0.35,
                            opacity: 0.68,
                            blur: 5.2 + energy * 1.8
                        )

                        // The mic history becomes a short wavelength train following the scan.
                        ForEach(Array(speech.levels.enumerated()), id: \.offset) { index, level in
                            let distance = CGFloat(speech.levels.count - index) * 0.021
                            movingStroke(
                                head: phase - scale.scannerLength - distance,
                                length: 0.008,
                                color: Style.listenGlow,
                                activeStyle: true,
                                lineWidth: 0.65 + CGFloat(level) * 1.15,
                                opacity: 0.10 + Double(level) * 0.34,
                                blur: 1.4 + CGFloat(level) * 1.2
                            )
                        }
                    }
                    .opacity(speech.isListening ? 1 : 0)
                    .animation(signalTransition, value: speech.isListening)
                }

            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func movingStroke(
        head rawHead: CGFloat,
        length: CGFloat,
        color: Color,
        activeStyle: Bool,
        lineWidth: CGFloat,
        opacity: Double,
        blur: CGFloat
    ) -> some View {
        let head = wrapped(rawHead)
        let start = head - length
        if start >= 0 {
            stroke(
                from: start, to: head, color: color, activeStyle: activeStyle,
                lineWidth: lineWidth, opacity: opacity, blur: blur
            )
        } else {
            stroke(
                from: 0, to: head, color: color, activeStyle: activeStyle,
                lineWidth: lineWidth, opacity: opacity, blur: blur
            )
            stroke(
                from: 1 + start, to: 1, color: color, activeStyle: activeStyle,
                lineWidth: lineWidth, opacity: opacity, blur: blur
            )
        }
    }

    private func stroke(
        from: CGFloat,
        to: CGFloat,
        color: Color,
        activeStyle: Bool,
        lineWidth: CGFloat,
        opacity: Double,
        blur: CGFloat
    ) -> some View {
        ZStack {
            if activeStyle {
                // Wide atmospheric bleed around the moving signal.
                shape.trim(from: from, to: to)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth + 5.5, lineCap: .round, lineJoin: .round))
                    .opacity(opacity * 0.28)
                    .blur(radius: blur * 1.45)
            }
            shape.trim(from: from, to: to)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth + 2.6, lineCap: .round, lineJoin: .round))
                .opacity(opacity * (activeStyle ? 0.48 : 0.36))
                .blur(radius: blur * 0.62)
            shape.trim(from: from, to: to)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(opacity * (activeStyle ? 0.82 : 1))
        }
    }

    private func wrapped(_ value: CGFloat) -> CGFloat {
        value - floor(value)
    }
}
