# Echo architecture

## Intended outcome

Listen to long Codex replies on a personal Mac, with clear local voices and immediate playback controls. The integration belongs to Echo; the Codex application remains unmodified.

## Components

| Component | Responsibility |
| --- | --- |
| `app/Sources/SpeakEasy/` | SwiftUI/AppKit native shell, menu bar, floating player, settings and AVFoundation playback |
| `CompletionSubscriptionController.swift` | Tracks configured Codex chat subscriptions and finished replies |
| `EchoCompletionPresenter.swift` | Converts a completed reply to spoken text locally; preserves the full reply instead of a cloud summary |
| `Resources/codex-desktop-bridge.cjs` | Inherited Node bridge to Codex desktop session events |
| `KarenVoice.swift` | Chooses a local voice, launches the renderer and owns private output files |
| `karen-voice/` | Rust helper for Supertonic/Kokoro through sherpa-onnx |
| `Resources/karen-qwen.py` | Offline Qwen3-TTS generation through MLX Audio |
| `SpeechSentences.swift` | Sentence splitting, validation of actual generated audio boundaries and sentence lookup |
| `PlaybackEngine.swift` | Queue, play/pause, speed and actual previous/next sentence seeks |
| `EchoFloatingPlayer.swift` | Small draggable native player on the desktop where it is opened |

## Reply flow

A configured chat emits a completed reply. Echo prepares narration locally, splits it into sentences and invokes the selected neural renderer. The renderer writes a private WAV plus a JSON sidecar containing actual start/end positions for each sentence. The player validates the timeline against the WAV duration, plays it and uses those boundaries for sentence navigation.

The Qwen renderer loads a local model, requests English CustomVoice speech and writes audio without playing it. All playback belongs to the Swift player so pause, rate and seeking work consistently. Generation currently completes before playback begins.

## Boundaries

Echo is the separate development edition selected by its bundle identity. Settings and IPC endpoints are separated from the original app. Pad/LAN and Deck startup are disabled for the development edition. Other inherited cloud-capable providers remain in the source tree; local-only use requires the Karen provider.

This repository contains source, tests, build scripts, upstream documentation/assets and licenses. Runtime chat records, subscriptions, credentials, user settings, generated speech, model weights, virtual environments, build products and private workspace records are deliberately excluded.

## Follow-up work

- Stream or progressively queue local speech for faster first audio.
- Confirm desktop behavior through interactive use.
- Make setup independent of an installed upstream resource bundle.
- Improve model provisioning and developer installation instructions.
