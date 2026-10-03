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
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 265),
                                 styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.title = "Echo"
            window.level = .floating
            window.collectionBehavior = [.managed, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("EchoFloatingPlayer")
            if !window.setFrameUsingName("EchoFloatingPlayer") { window.center() }
            window.contentView = NSHostingView(rootView: EchoFloatingPlayerView())
            panel = window
        }
        panel?.orderFront(nil)
    }

    func close() { panel?.close(); panel = nil }
}

struct EchoFloatingPlayerView: View {
    @ObservedObject private var player = PlaybackEngine.shared

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
            ScrollView {
                Text(player.currentSentence ?? player.currentItem?.text ?? "Click Echo in the menu bar to show or hide this player.")
                    .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }.frame(height: 64)
            HStack {
                Text(player.state.rawValue.capitalized)
                Spacer()
                if let index = player.sentenceIndex {
                    Text("Sentence \(index + 1) of \(player.sentences.count)")
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Spacer()
                Button { player.previousSentence() } label: { Image(systemName: "backward.end.fill") }
                    .disabled(player.sentences.isEmpty)
                    .help("Previous sentence").accessibilityLabel("Previous sentence")
                Button { try? player.togglePlayback() } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 32, height: 28)
                }.disabled(player.currentItem == nil && player.queue.isEmpty)
                    .help(player.state == .playing ? "Pause" : "Play")
                    .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
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
                Button("More") { MenuBarController.shared.toggleFullPlayer() }
                Button("Stop") { player.stop() }.disabled(player.currentItem == nil)
            }
            if player.currentItem != nil && player.sentences.isEmpty {
                Text("Sentence navigation is available for newly generated Karen voices.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 390, height: 265)
    }
}
