//  ListeningIndicator.swift
//  A perimeter-scanned pill with a status dot + live mic history. Green and voice-reactive
//  while listening; quietly ember-orange when off. Clicking toggles audio.

import SwiftUI

struct ListeningIndicator: View {
    @ObservedObject var speech: SpeechListener
    let toggle: () -> Void

    private var on: Bool { speech.isListening }
    private var color: Color { on ? Style.green2 : Style.listenIdle }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color.opacity(on ? 1 : 0.62))
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(on ? 0.85 : 0.2), radius: on ? 4 : 1)
                HStack(spacing: 2.5) {
                    ForEach(0..<SpeechListener.levelBars, id: \.self) { i in
                        Capsule()
                            .fill(color.opacity(on ? 1 : 0.48))
                            .frame(width: 2.5, height: 18)
                            .scaleEffect(x: 1, y: barScale(i))
                    }
                }
                .frame(height: 18)
            }
            .padding(.leading, 9).padding(.trailing, 11).padding(.vertical, 4)
            .frame(height: 26)
            .background(color.opacity(on ? 0.08 : 0.025), in: Capsule())
            .overlay { SignalOutline(shape: Capsule(), speech: speech, scale: .compact, motionEnabled: false) }
        }
        .buttonStyle(.plain)
        .help(on ? "Listening — click to mute" : "Muted — click to listen")
    }

    /// The meter already supplies fast attack and slow decay, so map it directly—no laggy UI easing.
    private func barScale(_ i: Int) -> CGFloat {
        guard on, speech.levels.indices.contains(i) else { return 3 / 18 }
        return (3 + CGFloat(speech.levels[i]) * 15) / 18
    }
}
