import AppKit
import SwiftUI

@MainActor
final class EchoFloatingPlayer {
    static let shared = EchoFloatingPlayer()
    private var panel: NSPanel?

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil) } else { show() }
    }

    func show() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 350),
                                 styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.title = "Echo"
            window.level = .floating
            window.collectionBehavior = [.managed, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("EchoFloatingPlayer")
            if !window.setFrameUsingName("EchoFloatingPlayer") { window.center() }
            window.setContentSize(NSSize(width: 390, height: 350))
            window.contentView = NSHostingView(rootView: EchoFloatingPlayerView())
            panel = window
        }
        panel?.orderFront(nil)
    }

    func close() { panel?.close(); panel = nil }
}

struct EchoFloatingPlayerView: View {
    @ObservedObject private var player = PlaybackEngine.shared
    @ObservedObject private var completions = CompletionSubscriptionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(player.currentItem?.title ?? "Ready for your next reply")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button { MenuBarController.shared.openSettings(initialSection: .karen) } label: {
                    Image(systemName: "gearshape")
                }.help("Voices and settings").accessibilityLabel("Voices and settings")
            }
            HStack {
                Text(completions.subscription.map { "Connected: \($0.task.title)" } ?? "No chat connected")
                    .lineLimit(1)
                Spacer()
                Toggle("Auto read", isOn: Binding(get: { completions.subscription?.isEnabled ?? false }, set: { completions.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(completions.subscription == nil)
            }.font(.caption)
            Text(player.lastError ?? completions.lastError ?? "\(completions.state.label) · Connected chat")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                Text(player.currentSentence ?? completions.preparingSentence ?? player.currentItem?.text ?? "New replies from your connected chat will appear here.")
                    .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(player.state == .playing ? Color.accentColor.opacity(0.10) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }.frame(height: 64)
            HStack {
                if completions.preparingActivityID != nil && player.currentItem == nil {
                    ProgressView().controlSize(.small)
                    Text("Preparing \(completions.preparingVoiceName ?? "your voice")…")
                } else if player.state == .loading && player.isReceivingAudio {
                    ProgressView().controlSize(.small)
                    Text("Preparing the next sentence…")
                } else { Text(player.state.rawValue.capitalized) }
                Spacer()
                if let index = player.sentenceIndex {
                    Text("Sentence \(index + 1) of \(player.sentences.count)")
                }
            }.font(.caption).foregroundStyle(.secondary)
            if player.currentItem != nil {
                HStack {
                    Text(timeLabel(player.currentTime)).monospacedDigit()
                    Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                           in: 0...max(player.duration, 0.01))
                        .accessibilityLabel("Playback position")
                    Text(player.isReceivingAudio ? "More coming" : timeLabel(player.duration)).monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                Spacer()
                Button { player.previousSentence() } label: { Image(systemName: "backward.end.fill") }
                    .disabled(player.sentences.isEmpty)
                    .help("Previous sentence").accessibilityLabel("Previous sentence")
                Button { try? player.togglePlayback() } label: {
                    Image(systemName: player.state == .playing || player.state == .loading ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 32, height: 28)
                }.disabled(player.currentItem == nil && player.queue.isEmpty)
                    .help(player.state == .playing || player.state == .loading ? "Pause" : "Play")
                    .accessibilityLabel(player.state == .playing || player.state == .loading ? "Pause" : "Play")
                Button { player.nextSentence() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(player.sentenceIndex.map { $0 + 1 >= player.sentences.count } ?? true)
                    .help("Next sentence").accessibilityLabel("Next sentence")
                Spacer()
            }.buttonStyle(.bordered)
            HStack {
                Text("Speed").font(.caption)
                Picker("Speed", selection: Binding(get: { player.playbackRate }, set: { player.setPlaybackRate($0) })) {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                        Text("\(rate, specifier: "%g")×").tag(rate)
                    }
                }.labelsHidden().frame(width: 86)
                Spacer()
                if player.currentItem == nil && completions.preparingActivityID == nil,
                   let activity = completions.mostRecentActivity,
                   activity.taskID == completions.subscription?.task.id {
                    Button("Replay") { completions.replay(activity.id) }
                        .help("Read the last reply again").accessibilityLabel("Replay last reply")
                }
                Button("More") { MenuBarController.shared.toggleFullPlayer() }
                Button("Stop") { completions.stopReading() }
                    .disabled(player.currentItem == nil && completions.preparingActivityID == nil)
            }
            if player.currentItem != nil && player.sentences.isEmpty {
                Text("Sentence navigation is available for newly generated Karen voices.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 390, height: 350)
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
