import SwiftUI
import HudsonUI

struct KarenSettingsView: View {
    @EnvironmentObject private var config: ConfigManager
    @ObservedObject private var completions = CompletionSubscriptionController.shared
    @State private var sampleText = "Osiris, this is Karen. I am here to help you think clearly and keep moving."
    @State private var isPreparing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var message: String?
    @State private var failed = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: HudSpacing.xl) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Karen").font(.title2.bold())
                Text("Our neural voices, running entirely on your Mac.").foregroundColor(theme.textSecondary)
                Text("Your reply text stays here. No API key is needed.").font(.caption).foregroundColor(theme.textTertiary)
            }
            HudCard {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Voice", selection: Binding(get: { config.karenVoice }, set: {
                        config.karenVoice = $0
                        if SpeakEasyEdition.isDevelopment && completions.channel.provider == "karen" {
                            completions.setVoice(nil)
                        }
                    })) {
                        ForEach(KarenVoiceCatalog.voices) { voice in Text("\(voice.name) · \(voice.engine)").tag(voice.id) }
                    }
                    ForEach(KarenVoiceCatalog.voices.filter { !KarenVoiceCatalog.isQwen($0.id) }) { voice in
                        HStack {
                            Text(voice.name)
                            Text(voice.engine).font(.caption).foregroundColor(theme.textTertiary)
                            Spacer()
                            Label(KarenVoiceCatalog.isReady(voice.id) ? "Ready" : "Not installed", systemImage: KarenVoiceCatalog.isReady(voice.id) ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.caption).foregroundColor(KarenVoiceCatalog.isReady(voice.id) ? .green : .orange)
                        }
                    }
                    DisclosureGroup("Nine new Qwen3 voices") {
                        ForEach(KarenVoiceCatalog.voices.filter { KarenVoiceCatalog.isQwen($0.id) }) { voice in
                            HStack {
                                Text(voice.name)
                                Text(voice.engine).font(.caption).foregroundColor(theme.textTertiary)
                                Spacer()
                                Text(KarenVoiceCatalog.isReady(voice.id) ? "Ready" : "Not installed")
                                    .font(.caption).foregroundColor(KarenVoiceCatalog.isReady(voice.id) ? .green : .orange)
                            }
                        }
                    }
                    Text("Qwen3 voices run locally and take longer to prepare. Ryan and Aiden are native English voices; the other presets also speak English.")
                        .font(.caption).foregroundColor(theme.textSecondary)
                    Divider()
                    HStack {
                        Text(config.defaultProvider == "karen" ? "Karen is your default voice" : "Use these voices for your Codex replies")
                        Spacer()
                        Button(config.defaultProvider == "karen" ? "Default voice provider" : "Use Karen") { config.defaultProvider = "karen" }
                            .disabled(config.defaultProvider == "karen")
                    }
                    if SpeakEasyEdition.isDevelopment {
                        Button("Use this voice for automatic replies") {
                            config.defaultProvider = "karen"
                            completions.setProvider("karen")
                            completions.setVoice(nil)
                            config.saveConfig()
                            message = "Automatic replies now follow your selected Karen voice."
                        }
                    }
                }
            }
            HudSectionLabel("Try a voice")
            TextEditor(text: $sampleText).frame(minHeight: 90, maxHeight: 140).padding(8)
                .background(theme.background).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Karen sample text")
            HStack {
                Button(isPreparing ? "Preparing voice…" : "Play sample") { playSample() }
                    .disabled(isPreparing || sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !KarenVoiceCatalog.isReady(config.karenVoice))
                Button("Stop") {
                    previewTask?.cancel(); previewTask = nil; isPreparing = false
                    PlaybackEngine.shared.stop(); message = "Stopped."
                }
            }
            if let message { Text(message).font(.caption).foregroundColor(failed ? .orange : theme.textSecondary) }
            Text("Voice choices and the default provider are saved with the Save button. Playback uses Echo’s pause, speed and skip controls.")
                .font(.caption).foregroundColor(theme.textTertiary)
        }.frame(maxWidth: 760, alignment: .leading)
    }

    private func playSample() {
        let text = sampleText
        let voice = config.karenVoice
        let rate = config.defaultRate
        isPreparing = true; failed = false; message = nil
        previewTask = Task { @MainActor in
            var audio: URL?
            do {
                let prepared = try await KarenVoiceRenderer.render(text: text, voice: voice, rate: rate)
                audio = prepared
                try Task.checkCancellation()
                let item = PlaybackItem(id: UUID(), audioPath: prepared.path, title: "Karen · \(KarenVoiceCatalog.voice(voice)?.name ?? "Voice")", text: text, provider: "karen", createdAt: ISO8601DateFormatter().string(from: Date()), synthesisRateWPM: rate, sourceThreadId: nil, cleanupAfterPlayback: true)
                try PlaybackEngine.shared.enqueue(item, priority: .normal, interrupt: true, autoplay: true)
                audio = nil
                message = "Playing in Echo. Open the menu-bar player for controls."
            } catch {
                if let audio {
                    try? FileManager.default.removeItem(at: audio)
                    try? FileManager.default.removeItem(at: SpeechSentences.metadataURL(for: audio))
                }
                if !Task.isCancelled { failed = true; message = error.localizedDescription }
            }
            isPreparing = false
        }
    }
}
