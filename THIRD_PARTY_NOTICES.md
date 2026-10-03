# Third-party notes

Echo is a modified source distribution of [SpeakEasy](https://github.com/arach/SpeakEasy), copyright 2026 Arach Tchoupani, under its retained MIT license. Echo modifications are copyright 2026 Osiris Medici. Nested licenses and notices are preserved, including the plugin license and Caddy notice.

Dependency manifests and locks identify additional dependencies, which retain their own licenses. The Swift app references HudsonKit XCFrameworks and Vox from their upstream repositories; the Rust helper references sherpa-onnx; Qwen rendering uses MLX Audio and Qwen3-TTS model weights downloaded separately. No downloaded XCFrameworks, Python environments or model weights are included in this repository.

- [HudsonKit package](https://github.com/arach/hudsonkit-xcframework)
- [Vox](https://github.com/arach/vox)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- [MLX Audio](https://github.com/Blaizzy/mlx-audio)
- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [Selected Qwen MLX model and its model card](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit)

Source MIT licensing does not replace separately applicable model or binary dependency terms. Inherited branding, sample assets and documentation remain attributed to their upstream authors.
