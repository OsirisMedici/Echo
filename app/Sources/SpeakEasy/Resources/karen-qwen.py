"""Echo's offline Qwen3-TTS adapter. JSON stdin; private WAV + sentence marks.

Requires the isolated mlx-audio runtime and a pre-downloaded model. It never
downloads models or plays audio. Preset voices come from Qwen's CustomVoice model.
"""
import json
import os
import sys
import wave
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.umask(0o077)

VOICES = ["Serena", "Vivian", "Ryan", "Aiden", "Uncle_Fu", "Dylan", "Eric", "Ono_Anna", "Sohee"]


def render(request):
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    text = request["text"]
    sentences = request["sentences"]
    if not sentences or " ".join(" ".join(sentences).split()) != " ".join(text.split()):
        raise ValueError("Sentence boundaries must preserve the complete reply")
    voice = VOICES[request["voice"] - 200]
    model = load_model(request["model_dir"])
    output = Path(request["output"])
    metadata = Path(str(output) + ".sentences.json")
    count, rate, marks = 0, 24000, []
    try:
        with output.open("xb") as file, wave.open(file, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(rate)
            for sentence in sentences:
                start = count / rate
                # Split unusually long sentences only at whitespace, preserving all words.
                parts, current = [], ""
                for word in sentence.split():
                    if current and len(current) + len(word) + 1 > 240:
                        parts.append(current)
                        current = ""
                    current += (" " if current else "") + word
                if current:
                    parts.append(current)
                for part in parts:
                    generated = False
                    for result in model.generate_custom_voice(text=part, speaker=voice, language="English", max_tokens=2048, verbose=False):
                        if result.sample_rate != rate:
                            raise ValueError("Unexpected sample rate")
                        samples = np.asarray(result.audio, dtype=np.float32).reshape(-1)
                        if not samples.size or not np.isfinite(samples).all():
                            raise ValueError("Invalid local audio")
                        pcm = (np.clip(samples, -1, 1) * 32767).round().astype("<i2")
                        audio.writeframes(pcm.tobytes())
                        count += len(pcm)
                        generated = True
                    if not generated:
                        raise ValueError("The model generated no audio")
                    mx.clear_cache()
                marks.append({"text": sentence, "start": start, "end": count / rate})
        with metadata.open("x") as file:
            json.dump(marks, file)
        return {"ok": True, "sampleRate": rate, "duration": count / rate}
    except BaseException:
        output.unlink(missing_ok=True)
        metadata.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    try:
        raw = sys.stdin.buffer.read(1_048_577)
        if len(raw) > 1_048_576:
            raise ValueError("Reply exceeds renderer input limit")
        print(json.dumps(render(json.loads(raw))))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
