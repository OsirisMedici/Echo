"""Offline packaged-adapter check with disposable synthetic text; no playback."""
import json
import os
import resource
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

os.umask(0o077)
support = Path.home() / "Library/Application Support/SpeakEasy Karen Dev"
repository = Path(__file__).resolve().parents[1]
adapter = repository / "app/Echo.app/Contents/Resources/SpeakEasy_SpeakEasy.bundle/karen-qwen.py"
if len(sys.argv) > 1:
    adapter = Path(sys.argv[1])
sentences = ["A quiet room helps me focus.", "Music can also help me focus.", "I prefer silence after all."]
environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")

with tempfile.TemporaryDirectory(prefix="echo-qwen-check-") as temporary:
    output = Path(temporary) / "reply.wav"
    request = dict(text=" ".join(sentences), sentences=sentences, voice=201, speed=1,
                   model_dir=str(support / "voices/qwen3-0.6b-customvoice-8bit"), output=str(output), progressive=True)
    started = time.monotonic()
    with (Path(temporary) / "stderr.log").open("w") as errors:
        process = subprocess.Popen([str(support / "qwen-runtime/bin/python3"), str(adapter)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True, env=environment)
        try:
            process.stdin.write(json.dumps(request))
            process.stdin.close()
            timings = []
            for line in process.stdout:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "segment" in event:
                    index = event["segment"]
                    assert index == len(timings)
                    chunk = Path(str(output) + f".segment-{index}.wav")
                    assert chunk.stat().st_mode & 0o077 == 0
                    with wave.open(str(chunk)) as audio:
                        assert audio.getnchannels() == 1 and audio.getframerate() == 24000 and audio.getnframes() > 0
                    marks = json.loads(Path(str(chunk) + ".sentences.json").read_text())
                    assert marks[0]["text"] == sentences[index]
                    timings.append(round(time.monotonic() - started, 3))
                    print(json.dumps(dict(segment=index, elapsed_seconds=timings[-1])), flush=True)
            assert process.wait(timeout=10) == 0
            assert len(timings) == len(sentences)
            with wave.open(str(output)) as audio:
                full_pcm = audio.readframes(audio.getnframes())
            parts = []
            for index in range(len(sentences)):
                with wave.open(str(output) + f".segment-{index}.wav") as audio:
                    parts.append(audio.readframes(audio.getnframes()))
            assert b"".join(parts) == full_pcm, "Progressive audio must preserve the complete reply"
            result = dict(first_sentence_seconds=timings[0], complete_reply_seconds=round(time.monotonic() - started, 3),
                          peak_process_rss_mb=round(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1048576, 1),
                          gpu_memory_included=False, voice="Vivian", segments=len(timings), offline=True, complete_audio_preserved=True)
            print(json.dumps(result), flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
