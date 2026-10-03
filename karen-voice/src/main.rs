// Local inference adapted from Osiris's Codex Listen voice engine.
// This helper renders audio only. It does not play, start hooks, or change settings.
use serde::Deserialize;
use serde_json::{json, Value};
use sherpa_onnx::{
    GenerationConfig, OfflineTts, OfflineTtsConfig, OfflineTtsKokoroModelConfig,
    OfflineTtsSupertonicModelConfig,
};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{self, BufWriter, Read, Seek, SeekFrom, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
struct Request {
    text: String,
    voice: i32,
    speed: f32,
    output: PathBuf,
    model_dir: PathBuf,
    #[serde(default)]
    sentences: Vec<String>,
}

fn model(path: &Path) -> Result<OfflineTts, String> {
    let file = |name: &str| Some(path.join(name).to_string_lossy().into_owned());
    let config = OfflineTtsConfig {
        model: sherpa_onnx::OfflineTtsModelConfig {
            supertonic: OfflineTtsSupertonicModelConfig {
                duration_predictor: file("duration_predictor.int8.onnx"),
                text_encoder: file("text_encoder.int8.onnx"),
                vector_estimator: file("vector_estimator.int8.onnx"),
                vocoder: file("vocoder.int8.onnx"),
                tts_json: file("tts.json"),
                unicode_indexer: file("unicode_indexer.bin"),
                voice_style: file("voice.bin"),
            },
            num_threads: 2,
            ..Default::default()
        },
        ..Default::default()
    };
    OfflineTts::create(&config).ok_or("Could not load Karen's local voice pack.".into())
}

fn load(req: &Request) -> Result<OfflineTts, String> {
    if req.voice == 0 {
        return model(&req.model_dir);
    }
    if !(100..=102).contains(&req.voice) {
        return Err("Unknown Karen voice.".into());
    }
    let path = &req.model_dir;
    let file = |name: &str| Some(path.join(name).to_string_lossy().into_owned());
    let british = req.voice == 102;
    let config = OfflineTtsConfig {
        model: sherpa_onnx::OfflineTtsModelConfig {
            kokoro: OfflineTtsKokoroModelConfig {
                model: file(if path.join("model.int8.onnx").is_file() {
                    "model.int8.onnx"
                } else {
                    "model.onnx"
                }),
                voices: file("voices.bin"),
                tokens: file("tokens.txt"),
                data_dir: file("espeak-ng-data"),
                lexicon: file(if british {
                    "lexicon-gb-en.txt"
                } else {
                    "lexicon-us-en.txt"
                }),
                lang: Some(if british { "en-gb" } else { "en-us" }.into()),
                ..Default::default()
            },
            num_threads: 2,
            ..Default::default()
        },
        ..Default::default()
    };
    OfflineTts::create(&config).ok_or("Could not load the local Kokoro voice pack.".into())
}

fn passages(text: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut length = 0;
    for word in text.split_whitespace() {
        let size = word.chars().count();
        if !current.is_empty() && length + size + 1 > 240 {
            parts.push(std::mem::take(&mut current));
            length = 0;
        }
        if !current.is_empty() {
            current.push(' ');
            length += 1;
        }
        current.push_str(word);
        length += size;
    }
    if !current.is_empty() {
        parts.push(current);
    }
    parts
}

fn header(rate: u32, bytes: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(44);
    out.extend(b"RIFF");
    out.extend((bytes + 36).to_le_bytes());
    out.extend(b"WAVEfmt ");
    out.extend(16u32.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(rate.to_le_bytes());
    out.extend((rate * 2).to_le_bytes());
    out.extend(2u16.to_le_bytes());
    out.extend(16u16.to_le_bytes());
    out.extend(b"data");
    out.extend(bytes.to_le_bytes());
    out
}

fn render(req: Request) -> Result<Value, String> {
    if req.text.trim().is_empty() || !req.speed.is_finite() || !(0.8..=1.5).contains(&req.speed) {
        return Err("Invalid Karen speech request.".into());
    }
    let normalized = |text: &str| text.split_whitespace().collect::<Vec<_>>().join(" ");
    let sentences = if req.sentences.is_empty() {
        vec![req.text.clone()]
    } else {
        req.sentences.clone()
    };
    if sentences.iter().any(|text| text.trim().is_empty())
        || normalized(&sentences.join(" ")) != normalized(&req.text)
    {
        return Err("Sentence boundaries must preserve the complete reply.".into());
    }
    let metadata_path = PathBuf::from(format!("{}.sentences.json", req.output.display()));
    let tts = load(&req)?;
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&req.output)
        .map_err(|_| "Cannot create a private audio file.".to_owned())?;
    let result = (|| {
        let mut writer = BufWriter::new(file);
        writer.write_all(&[0; 44]).map_err(|e| e.to_string())?;
        let mut count: u32 = 0;
        let mut rate: u32 = 0;
        let config = GenerationConfig {
            sid: if req.voice >= 100 {
                req.voice - 100
            } else {
                req.voice
            },
            num_steps: 8,
            speed: req.speed,
            extra: Some(HashMap::from([("lang".to_string(), json!("en"))])),
            ..Default::default()
        };
        let mut marks = Vec::new();
        for sentence in &sentences {
            let start_count = count;
            for text in passages(sentence) {
                let audio = tts
                    .generate_with_config(&text, &config, None::<fn(&[f32], f32) -> bool>)
                    .ok_or("The local model could not render this passage.")?;
                let next_rate = audio.sample_rate() as u32;
                if audio.samples().is_empty() || next_rate == 0 || (rate != 0 && rate != next_rate)
                {
                    return Err("Invalid local audio.".into());
                }
                rate = next_rate;
                for sample in audio.samples() {
                    count = count
                        .checked_add(2)
                        .filter(|c| *c <= u32::MAX - 36)
                        .ok_or("Reply audio exceeds WAV size limit.")?;
                    let value = (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16;
                    writer
                        .write_all(&value.to_le_bytes())
                        .map_err(|e| e.to_string())?;
                }
            }
            marks.push(json!({"text":sentence,"start":start_count as f64 / 2.0 / rate as f64,"end":count as f64 / 2.0 / rate as f64}));
        }
        writer.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        writer
            .write_all(&header(rate, count))
            .map_err(|e| e.to_string())?;
        writer.flush().map_err(|e| e.to_string())?;
        let mut metadata = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&metadata_path)
            .map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut metadata, &marks).map_err(|e| e.to_string())?;
        metadata.flush().map_err(|e| e.to_string())?;
        Ok(json!({"ok":true,"sampleRate":rate,"duration":count as f64 / 2.0 / rate as f64}))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&req.output);
        let _ = fs::remove_file(&metadata_path);
    }
    result
}
fn run() -> Result<Value, String> {
    let mut input = String::new();
    io::stdin()
        .take(1_048_577)
        .read_to_string(&mut input)
        .map_err(|_| "Cannot read request.")?;
    if input.len() > 1_048_576 {
        return Err("Reply is too large for this voice renderer.".into());
    }
    let request: Request = serde_json::from_str(&input).map_err(|_| "Invalid speech request.")?;
    render(request)
}
fn main() {
    match run() {
        Ok(value) => println!("{value}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn long_reply_preserves_every_word() {
        let text = format!(
            "नमस्ते. {} Last sentence!",
            "A long Codex reply with numbers 1.25. ".repeat(80)
        );
        let parts = passages(&text);
        assert!(parts.len() > 3);
        assert_eq!(
            parts.join(" "),
            text.split_whitespace().collect::<Vec<_>>().join(" ")
        );
    }
    #[test]
    fn wav_header_matches_pcm_payload() {
        let h = header(24000, 48000);
        assert_eq!(h.len(), 44);
        assert_eq!(&h[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(h[4..8].try_into().unwrap()), 48036);
        assert_eq!(u32::from_le_bytes(h[40..44].try_into().unwrap()), 48000);
    }
}
