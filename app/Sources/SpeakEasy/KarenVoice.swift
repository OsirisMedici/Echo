import Foundation
import Darwin

struct KarenVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let engine: String
}

enum KarenVoiceCatalog {
    static let voices = [
        KarenVoice(id: "0", name: "Karen", engine: "Supertonic 3"),
        KarenVoice(id: "100", name: "Maple", engine: "Kokoro"),
        KarenVoice(id: "101", name: "Sol", engine: "Kokoro"),
        KarenVoice(id: "102", name: "Vale", engine: "Kokoro"),
        KarenVoice(id: "200", name: "Serena", engine: "Qwen3 · warm female"),
        KarenVoice(id: "201", name: "Vivian", engine: "Qwen3 · bright female"),
        KarenVoice(id: "202", name: "Ryan", engine: "Qwen3 · English male"),
        KarenVoice(id: "203", name: "Aiden", engine: "Qwen3 · American male"),
        KarenVoice(id: "204", name: "Uncle Fu", engine: "Qwen3 · mellow male"),
        KarenVoice(id: "205", name: "Dylan", engine: "Qwen3 · youthful male"),
        KarenVoice(id: "206", name: "Eric", engine: "Qwen3 · lively male"),
        KarenVoice(id: "207", name: "Ono Anna", engine: "Qwen3 · light female"),
        KarenVoice(id: "208", name: "Sohee", engine: "Qwen3 · warm female")
    ]
    static func voice(_ id: String) -> KarenVoice? { voices.first { $0.id == id } }
    static func isQwen(_ id: String) -> Bool { (Int(id) ?? 0) >= 200 }
    static var qwenPythonURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpeakEasy Karen Dev/qwen-runtime/bin/python3")
    }
    static var qwenScriptURL: URL? {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("SpeakEasy_SpeakEasy.bundle/karen-qwen.py"),
           FileManager.default.fileExists(atPath: resource.path) { return resource }
        // SwiftPM command-line development builds use the generated bundle accessor.
        if !SpeakEasyEdition.isDevelopment { return Bundle.module.url(forResource: "karen-qwen", withExtension: "py") }
        return nil
    }
    static var helperURL: URL {
        if let path = ProcessInfo.processInfo.environment["KAREN_VOICE_HELPER"] { return URL(fileURLWithPath: path) }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/karen-voice")
    }
    static func modelDirectory(_ id: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if isQwen(id) {
            return home.appendingPathComponent("Library/Application Support/SpeakEasy Karen Dev/voices/qwen3-0.6b-customvoice-8bit")
        }
        if id == "0" {
            if let path = ProcessInfo.processInfo.environment["KAREN_SUPERTONIC_DIR"] { return URL(fileURLWithPath: path) }
            return home.appendingPathComponent("Library/Application Support/com.osirismedici.karen/voices/sherpa-onnx-supertonic-3-tts-int8-2026-05-11")
        }
        if let path = ProcessInfo.processInfo.environment["KAREN_KOKORO_DIR"] { return URL(fileURLWithPath: path) }
        return home.appendingPathComponent("Library/Application Support/com.osirismedici.codex-listen/voices/kokoro-int8-multi-lang-v1_1")
    }
    static func isReady(_ id: String) -> Bool {
        if isQwen(id) {
            guard voice(id) != nil, qwenScriptURL != nil, FileManager.default.isExecutableFile(atPath: qwenPythonURL.path) else { return false }
            return ["config.json", "model.safetensors", "vocab.json", "merges.txt", "speech_tokenizer/model.safetensors"].allSatisfy {
                FileManager.default.fileExists(atPath: modelDirectory(id).appendingPathComponent($0).path)
            }
        }
        guard voice(id) != nil, FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }
        let directory = modelDirectory(id)
        let files = id == "0"
            ? ["duration_predictor.int8.onnx", "text_encoder.int8.onnx", "vector_estimator.int8.onnx", "vocoder.int8.onnx", "tts.json", "unicode_indexer.bin", "voice.bin"]
            : ["voices.bin", "tokens.txt", "espeak-ng-data", id == "102" ? "lexicon-gb-en.txt" : "lexicon-us-en.txt"]
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { return false }
        return id == "0" || ["model.int8.onnx", "model.onnx"].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}

actor KarenVoiceRenderer {
    private struct Request: Encodable {
        let text: String
        let voice: Int
        let speed: Float
        let output: String
        let model_dir: String
        let sentences: [String]
        let progressive: Bool
    }
    static func render(text: String, voice: String, rate: Int,
                       onSegment: (@Sendable (URL) async throws -> Void)? = nil) async throws -> URL {
        guard let id = Int(voice), KarenVoiceCatalog.isReady(voice) else {
            throw ConfiguredResponseNarratorError.generationFailed("This Karen voice pack is not ready on this Mac. Check the Karen section.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("karen-\(UUID().uuidString).wav")
        let log = output.deletingPathExtension().appendingPathExtension("log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errorHandle = try FileHandle(forWritingTo: log)
        defer { try? errorHandle.close(); try? FileManager.default.removeItem(at: log) }
        let sentences = SpeechSentences.split(text)
        let progressive = KarenVoiceCatalog.isQwen(voice) && onSegment != nil
        let data = try JSONEncoder().encode(Request(text: text, voice: id, speed: min(1.5, max(0.8, Float(rate) / 180)), output: output.path, model_dir: KarenVoiceCatalog.modelDirectory(voice).path, sentences: sentences, progressive: progressive))
        let process = Process()
        let input = Pipe()
        let progress = Pipe()
        if KarenVoiceCatalog.isQwen(voice) {
            guard let script = KarenVoiceCatalog.qwenScriptURL else {
                throw ConfiguredResponseNarratorError.generationFailed("Echo's local Qwen adapter is missing. Rebuild Echo before using this voice.")
            }
            process.executableURL = KarenVoiceCatalog.qwenPythonURL
            process.arguments = [script.path]
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
            process.environment = environment
        } else {
            process.executableURL = KarenVoiceCatalog.helperURL
        }
        process.standardInput = input
        process.standardOutput = progressive ? progress : FileHandle.nullDevice
        process.standardError = errorHandle
        do {
            try Task.checkCancellation()
            let status: Int32 = try await withTaskCancellationHandler(operation: {
                if progressive, let onSegment {
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: data)
                    try input.fileHandleForWriting.close()
                    let events = AsyncThrowingStream<Int, Error> { continuation in
                        Task.detached {
                            do {
                                var pending = Data()
                                var buffer = [UInt8](repeating: 0, count: 4096)
                                while true {
                                    // FileHandle.read(upToCount:) fills its requested buffer on
                                    // macOS pipes, hiding short progress messages until EOF.
                                    let count = Darwin.read(progress.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                                    if count == 0 { break }
                                    if count < 0 {
                                        if errno == EINTR { continue }
                                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                    }
                                    pending.append(contentsOf: buffer.prefix(count))
                                    while let end = pending.firstIndex(of: 10) {
                                        let line = pending.prefix(upTo: end)
                                        pending.removeSubrange(...end)
                                        if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                                           let index = value["segment"] as? Int {
                                            continuation.yield(index)
                                        }
                                    }
                                    guard pending.count < 65_536 else {
                                        throw ConfiguredResponseNarratorError.generationFailed("Local voice progress exceeded its limit.")
                                    }
                                }
                                process.waitUntilExit()
                                continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                    }
                    var expected = 0
                    for try await index in events {
                        try Task.checkCancellation()
                        guard index == expected, index < sentences.count else {
                            throw ConfiguredResponseNarratorError.generationFailed("Local voice sentence order was invalid.")
                        }
                        let segment = URL(fileURLWithPath: output.path + ".segment-\(index).wav")
                        try await onSegment(segment)
                        expected += 1
                    }
                    try Task.checkCancellation()
                    guard process.terminationStatus != 0 || expected == sentences.count else {
                        throw ConfiguredResponseNarratorError.generationFailed("Local voice did not finish every sentence.")
                    }
                    return process.terminationStatus
                }
                return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    try input.fileHandleForWriting.write(contentsOf: data)
                    try input.fileHandleForWriting.close()
                    if Task.isCancelled && process.isRunning { process.terminate() }
                } catch {
                    try? input.fileHandleForWriting.close()
                    if process.isRunning { process.terminate() }
                }
                }
            }, onCancel: {
                if process.isRunning { process.terminate() }
            })
            try Task.checkCancellation()
            guard status == 0, let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber, size.intValue > 44 else {
                throw ConfiguredResponseNarratorError.generationFailed("Karen could not prepare audio. Check that the local voice pack is complete.")
            }
            return output
        } catch {
            if process.isRunning {
                process.terminate()
                await Task.detached { process.waitUntilExit() }.value
            }
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: SpeechSentences.metadataURL(for: output))
            for index in sentences.indices {
                let segment = URL(fileURLWithPath: output.path + ".segment-\(index).wav")
                try? FileManager.default.removeItem(at: segment)
                try? FileManager.default.removeItem(at: SpeechSentences.metadataURL(for: segment))
            }
            throw error
        }
    }
}
