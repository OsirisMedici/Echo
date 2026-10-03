# Echo

A personal macOS reader for Codex replies, built on [SpeakEasy](https://github.com/arach/SpeakEasy).

Echo connects a Codex chat, reads completed replies with local neural voices, and puts playback controls in a small menu-bar player. The Karen section contains our voice integrations. Echo is a separate development edition; the original SpeakEasy installation and settings stay separate.

## Current features

- Automatic reading of connected Codex chats and manual speech controls.
- A draggable floating player with play/pause, stop, speed, and previous/next sentence.
- Sentence navigation uses generated audio boundaries, rather than estimating position from the number of words.
- Local Supertonic, Kokoro and Qwen3-TTS voice adapters. Qwen requests use English.
- A configurable shortcut; the personal setup uses Option + Z.
- Separate Echo settings, player socket and support directory.

The inherited SpeakEasy source also includes optional cloud providers, a CLI, Pad and Deck. **Use the Karen provider for local-only narration.** Model files and personal settings are not included in this repository.

## Development build

This is a source repository, not a notarized Echo release. The current Echo packaging script requires the original **SpeakEasy 0.3.0** app in `/Applications/SpeakEasy.app` as a source of companion resources. It verifies that installation, builds our Swift app and Rust helper, then creates `app/Echo.app` without replacing the installed original.

Prerequisites: Apple Silicon Mac, macOS 14+, a Swift toolchain/macOS SDK (tested with Swift 6.2.3), Rust/Cargo, and the verified SpeakEasy 0.3.0 app. Full Xcode is needed for the XCTest suite. Node.js 22.12+ or Bun is needed when developing the inherited CLI; use pnpm for JavaScript dependencies.

```sh
git clone https://github.com/OsirisMedici/Echo.git
cd Echo
cargo fetch --locked --manifest-path karen-voice/Cargo.toml
bash scripts/build-karen-dev.sh
```

Quit Echo before rebuilding its bundle. Launch `app/Echo.app` from Finder. To compile only the native source, run `cd app && swift build`.

The development edition uses `~/.config/speakeasy-karen-dev/settings.json` and `~/Library/Application Support/SpeakEasy Karen Dev/`. Configure the connection to your own Codex chat in the app. No personal chat IDs or subscriptions are shipped.

## Qwen3 voices

The adapter runs a pre-downloaded model through an isolated Python runtime. Speech generation explicitly enables offline mode and disables Hugging Face telemetry. Downloads happen only during setup. See [local voice setup](docs/ECHO_LOCAL_VOICES.md).

The current model is `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`. Its presets are Serena, Vivian, Ryan, Aiden, Uncle Fu, Dylan, Eric, Ono Anna and Sohee. Ryan and Aiden are native English presets; Echo requests English from every preset.

## Architecture and checks

[Architecture](docs/ECHO_ARCHITECTURE.md) describes the Swift player, Rust helper, Python MLX renderer and Codex bridge.

```sh
swiftc app/Sources/SpeakEasy/SpeechSentences.swift scripts/verify-speech-sentences.swift -o /tmp/echo-sentence-check
/tmp/echo-sentence-check
cargo test --locked --manifest-path karen-voice/Cargo.toml
# With full Xcode selected:
cd app && swift test
```

Current limitations: Qwen prepares the complete reply before playback, so long replies can take time to start. The 0.6B quantized local model may sound different from larger web-demo models. Desktop switching behavior still needs interactive acceptance. Echo does not highlight spoken text inside Codex. Installation and model provisioning are still a developer workflow.

## Origin and license

Echo began from SpeakEasy v0.3.0, upstream commit `1b23c403cd053557e04d764e8e81fe0acf8d54ca`, with our current application and voice changes applied as a clean source snapshot. This initial repository intentionally does not include private development history.

SpeakEasy is by Arach Tchoupani. The original MIT license and component notices are retained. See [LICENSE](LICENSE), [third-party notes](THIRD_PARTY_NOTICES.md) and the preserved [upstream README](README-UPSTREAM.md). Internal module names still use SpeakEasy for compatibility. The root npm package is marked private to prevent accidental publication under the upstream package name.
