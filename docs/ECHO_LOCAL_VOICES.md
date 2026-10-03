# Local voice setup

Model weights are downloaded separately and are subject to their own model licenses. This repository does not redistribute them or pretrained voices as assets. Read the model card before installing a model.

## Qwen3-TTS (Apple Silicon)

The tested runtime is Python 3.13 with `mlx-audio==0.4.1`. The following setup downloads dependencies and the model. Subsequent Echo rendering runs offline. It uses approximately 2 GB for this model plus space for the runtime and caches.

```sh
python3.13 -m venv "$HOME/Library/Application Support/SpeakEasy Karen Dev/qwen-runtime"
"$HOME/Library/Application Support/SpeakEasy Karen Dev/qwen-runtime/bin/python3" -m pip install 'mlx-audio==0.4.1'
"$HOME/Library/Application Support/SpeakEasy Karen Dev/qwen-runtime/bin/python3" - <<'PYTHON'
from pathlib import Path
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
    revision="049ef77fe8816b536193c0c25f9a214d17921282",
    local_dir=Path.home() / "Library/Application Support/SpeakEasy Karen Dev/voices/qwen3-0.6b-customvoice-8bit",
)
PYTHON
```

Open Echo settings, choose the Karen section and a ready Qwen voice, then use the sample player. Use the control to make the chosen voice the automatic reply voice. Model readiness checks require `config.json`, `model.safetensors`, `vocab.json`, `merges.txt` and `speech_tokenizer/model.safetensors`.

## Supertonic and Kokoro

The Rust adapter expects separately installed models. `KarenVoiceCatalog.modelDirectory` in `app/Sources/SpeakEasy/KarenVoice.swift` defines the paths and `karen-voice/src/main.rs` defines the exact required files. These models are not provisioned by the Echo build script. Qwen setup above is the documented neural-voice setup for this source snapshot.

## Privacy and controls

The Qwen script sets `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` and `HF_HUB_DISABLE_TELEMETRY=1` during generation. It accepts JSON over stdin and creates private output files. No cloud API key is needed for Karen narration. The inherited app includes other providers; selecting one may use its corresponding service.
