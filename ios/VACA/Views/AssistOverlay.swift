import SwiftUI

/// What the assistant is doing: a glowing bar at the bottom of the screen,
/// with what you said and the reply.
struct AssistOverlay: View {
    @ObservedObject private var satellite = Satellite.shared
    @State private var pulse = false

    private var active: Bool { satellite.phase != .idle }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            if let error = satellite.errorText {
                bubble(error, icon: "exclamationmark.triangle.fill", tint: .orange)
            } else if active {
                if !satellite.transcript.isEmpty {
                    bubble(satellite.transcript, icon: "person.wave.2.fill", tint: .white)
                }
                if satellite.phase == .speaking, !satellite.response.isEmpty {
                    bubble(satellite.response, icon: "bubble.left.fill", tint: .accentColor)
                } else if satellite.transcript.isEmpty {
                    bubble(label, icon: "waveform", tint: .accentColor)
                }
            }

            if active {
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor, .purple, .accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6)
                    .opacity(pulse ? 1 : 0.45)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 10)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                    }
                    .onDisappear { pulse = false }
            }
        }
        .padding(.bottom, 24)
        .allowsHitTesting(false)
    }

    private var label: String {
        switch satellite.phase {
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "…"
        case .idle: return ""
        }
    }

    private func bubble(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.title3).foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 720)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
