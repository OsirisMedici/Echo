import AVFoundation
import Foundation

@MainActor
final class PlaybackEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = PlaybackEngine()

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentItem: PlaybackItem?
    @Published private(set) var queue: [PlaybackItem] = []
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastFinishedItemID: UUID?
    @Published private(set) var lastStoppedItemID: UUID?
    @Published private(set) var isReceivingAudio = false
    @Published var autoplayEnabled = true
    @Published private(set) var volume: Float = 0.8
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var interactiveBusy = false
    @Published private(set) var sentences: [SpeechSentence] = []

    var sentenceIndex: Int? { SpeechSentences.index(at: currentTime, in: sentences) }
    var currentSentence: String? { sentenceIndex.map { sentences[$0].text } }

    func previousSentence() {
        guard let index = sentenceIndex else { return }
        seek(to: sentences[max(0, index - 1)].start)
    }

    func nextSentence() {
        guard let index = sentenceIndex, index + 1 < sentences.count else { return }
        seek(to: sentences[index + 1].start)
    }

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var progressiveAudio: [UUID: ProgressiveSpeechBuffer] = [:]
    private var segmentIndex = 0

    func beginProgressiveAudio(_ item: PlaybackItem) throws {
        var buffer = ProgressiveSpeechBuffer()
        let url = URL(fileURLWithPath: item.audioPath)
        let audio = try AVAudioPlayer(contentsOf: url)
        try buffer.append(url: url, duration: audio.duration,
                          sentences: SpeechSentences.load(for: url, duration: audio.duration))
        progressiveAudio[item.id] = buffer
        do { try enqueue(item, autoplay: true) }
        catch {
            progressiveAudio.removeValue(forKey: item.id)?.removeFiles()
            throw error
        }
    }

    func appendProgressiveAudio(itemID: UUID, url: URL) throws {
        guard var buffer = progressiveAudio[itemID] else { throw CancellationError() }
        let audio = try AVAudioPlayer(contentsOf: url)
        try buffer.append(url: url, duration: audio.duration,
                          sentences: SpeechSentences.load(for: url, duration: audio.duration))
        progressiveAudio[itemID] = buffer
        guard currentItem?.id == itemID else { return }
        duration = buffer.duration
        sentences = buffer.sentences
        if player == nil, state == .loading { try playProgressiveSegment(at: segmentIndex) }
    }

    func completeProgressiveAudio(itemID: UUID, finalURL: URL) throws {
        guard var buffer = progressiveAudio[itemID] else { throw CancellationError() }
        buffer.isComplete = true
        buffer.finalAudioURL = finalURL
        progressiveAudio[itemID] = buffer
        guard currentItem?.id == itemID else { return }
        isReceivingAudio = false
        if player == nil, segmentIndex >= buffer.segments.count {
            finishCurrentItem(naturallyFinished: true)
            if autoplayEnabled { try playNext() }
        }
    }

    private func playProgressiveSegment(at index: Int, localTime: TimeInterval = 0, paused: Bool = false) throws {
        guard let item = currentItem, let buffer = progressiveAudio[item.id],
              buffer.segments.indices.contains(index) else { return }
        let next = try AVAudioPlayer(contentsOf: buffer.segments[index].url)
        player?.stop()
        next.delegate = self
        next.enableRate = true
        next.volume = volume
        next.rate = playbackRate
        next.isMeteringEnabled = true
        next.prepareToPlay()
        next.currentTime = localTime
        player = next
        segmentIndex = index
        duration = buffer.duration
        sentences = buffer.sentences
        isReceivingAudio = !buffer.isComplete
        if paused {
            state = .paused
            refreshProgress()
        } else {
            guard next.play() else { throw PlayerEngineError.couldNotStartAudio }
            lastError = nil
            state = .playing
            startProgressTimer()
        }
    }

    private override init() {
        super.init()
    }

    deinit {
        progressTimer?.invalidate()
    }

    func enqueue(
        _ item: PlaybackItem,
        priority: QueuePriority = .normal,
        interrupt: Bool = false,
        autoplay: Bool? = nil
    ) throws {
        guard item.audioPath.hasPrefix("/") else {
            throw PlayerEngineError.audioPathMustBeAbsolute
        }
        guard FileManager.default.fileExists(atPath: item.audioPath) else {
            throw PlayerEngineError.audioFileMissing(item.audioPath)
        }

        if interrupt {
            stopCurrent(resetPosition: true)
            queue.insert(item, at: 0)
        } else if priority == .high {
            queue.insert(item, at: 0)
        } else {
            queue.append(item)
        }

        if (autoplay ?? autoplayEnabled) && currentItem == nil && canStartNextItem {
            try playNext()
        }
    }

    /// Completion narration is background work. It may remain queued while a
    /// microphone turn or interactive response owns the player.
    func setInteractiveBusy(_ busy: Bool) {
        interactiveBusy = busy
        guard !busy, currentItem == nil, autoplayEnabled else { return }
        do {
            try playNext()
        } catch {
            state = .failed
            lastError = error.localizedDescription
        }
    }

    func pause() {
        if currentItem.map({ progressiveAudio[$0.id] != nil }) == true, state == .loading {
            state = .paused
            return
        }
        guard let player, currentItem != nil else { return }
        player.pause()
        state = .paused
        refreshProgress()
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func resume() throws {
        if let item = currentItem, let buffer = progressiveAudio[item.id], player == nil {
            if buffer.segments.indices.contains(segmentIndex) {
                try playProgressiveSegment(at: segmentIndex)
            } else { state = .loading }
            return
        }
        if let player, currentItem != nil {
            guard player.prepareToPlay(), player.play() else {
                state = .failed
                lastError = PlayerEngineError.couldNotStartAudio.localizedDescription
                throw PlayerEngineError.couldNotStartAudio
            }
            lastError = nil
            state = .playing
            startProgressTimer()
            return
        }
        try playNext()
    }

    func togglePlayback() throws {
        if state == .playing || state == .loading {
            pause()
        } else {
            try resume()
        }
    }

    func stop() {
        lastStoppedItemID = currentItem?.id
        stopCurrent(resetPosition: true)
    }

    /// Temporarily yield a background completion to an interactive turn
    /// without deleting its audio or activity record.
    func deferCurrentCompletion() {
        guard let item = currentItem, item.effectiveChannel == .completions else { return }
        stopCurrent(resetPosition: true, removeAudio: false)
        queue.insert(item, at: 0)
    }

    func skip() throws {
        lastStoppedItemID = currentItem?.id
        stopCurrent(resetPosition: true)
        try playNext()
    }

    func clearQueue() {
        for item in queue { progressiveAudio.removeValue(forKey: item.id)?.removeFiles() }
        queue.removeAll()
    }

    func removeQueueItem(id: UUID) {
        progressiveAudio.removeValue(forKey: id)?.removeFiles()
        queue.removeAll { $0.id == id }
    }

    func removeQueuedCompletion(activityID: UUID) {
        for item in queue where item.completionActivityID == activityID {
            progressiveAudio.removeValue(forKey: item.id)?.removeFiles()
        }
        queue.removeAll { $0.completionActivityID == activityID }
    }

    func seek(to position: TimeInterval) {
        if let item = currentItem, let buffer = progressiveAudio[item.id],
           let target = buffer.position(at: position) {
            do { try playProgressiveSegment(at: target.index, localTime: target.localTime, paused: state == .paused) }
            catch { lastError = error.localizedDescription; state = .failed }
            return
        }
        guard let player else { return }
        player.currentTime = min(max(position, 0), player.duration)
        refreshProgress()
    }

    func setVolume(_ newVolume: Float) {
        volume = min(max(newVolume, 0), 1)
        player?.volume = volume
    }

    func setPlaybackRate(_ newRate: Float) {
        playbackRate = min(max(newRate, 0.5), 2)
        player?.rate = playbackRate
    }

    #if DEBUG
    /// Which playback state a design snapshot should render.
    enum SnapshotFixture: String, CaseIterable {
        case idle
        case playing
        case queued
        case failed
    }

    /// Populates published state directly so the popover can be rendered without
    /// real audio files. Never called outside `--snapshot-player`.
    func installSnapshotFixture(_ fixture: SnapshotFixture) {
        func item(_ title: String, _ provider: String) -> PlaybackItem {
            PlaybackItem(
                id: UUID(uuidString: "0000000\(abs(title.hashValue % 9))-0000-4000-8000-00000000000\(abs(title.count % 9))")
                    ?? UUID(),
                audioPath: "/tmp/speakeasy-snapshot.mp3",
                title: title,
                text: nil,
                provider: provider,
                createdAt: "2026-07-26T17:00:00Z",
                synthesisRateWPM: 160,
                sourceThreadId: nil
            )
        }

        volume = 0.8
        playbackRate = 1
        interactiveBusy = false
        lastFinishedItemID = nil
        autoplayEnabled = true
        lastError = nil

        switch fixture {
        case .idle:
            state = .idle
            currentItem = nil
            queue = []
            currentTime = 0
            duration = 0
        case .playing:
            state = .playing
            currentItem = item("Popover redesign summary", "elevenlabs")
            queue = [item("Build log digest", "openai"), item("Scout relay update", "groq")]
            currentTime = 41
            duration = 128
        case .queued:
            state = .idle
            currentItem = nil
            queue = [item("Build log digest", "openai"), item("Scout relay update", "groq")]
            currentTime = 0
            duration = 0
        case .failed:
            state = .failed
            currentItem = nil
            queue = []
            currentTime = 0
            duration = 0
            lastError = "could_not_open_audio: the file could not be opened because it is not in a recognised format"
        }
    }
    #endif

    func snapshot() -> PlayerSnapshot {
        PlayerSnapshot(
            state: state,
            currentItem: currentItem,
            queue: queue,
            currentTime: currentTime,
            duration: duration,
            volume: volume,
            playbackRate: playbackRate,
            autoplayEnabled: autoplayEnabled,
            audioLevel: audioLevel,
            sentences: sentences
        )
    }

    func handle(_ request: PlayerCommandRequest) -> PlayerCommandResponse {
        guard request.protocolVersion == playerProtocolVersion else {
            return response(
                to: request,
                error: "unsupported_protocol_version:\(request.protocolVersion)"
            )
        }

        do {
            switch request.command {
            case .enqueue:
                guard let item = request.arguments?.item else {
                    throw PlayerEngineError.missingArgument("item")
                }
                try enqueue(
                    item,
                    priority: request.arguments?.priority ?? .normal,
                    interrupt: request.arguments?.interrupt ?? false,
                    autoplay: request.arguments?.autoplay
                )
            case .pause:
                pause()
            case .resume:
                try resume()
            case .togglePlayback:
                try togglePlayback()
            case .stop:
                stop()
            case .skip:
                try skip()
            case .previousSentence:
                previousSentence()
            case .nextSentence:
                nextSentence()
            case .seek:
                guard let position = request.arguments?.positionSeconds else {
                    throw PlayerEngineError.missingArgument("positionSeconds")
                }
                seek(to: position)
            case .setVolume:
                guard let volume = request.arguments?.volume else {
                    throw PlayerEngineError.missingArgument("volume")
                }
                setVolume(volume)
            case .setPlaybackRate:
                guard let rate = request.arguments?.playbackRate else {
                    throw PlayerEngineError.missingArgument("playbackRate")
                }
                setPlaybackRate(rate)
            case .removeQueueItem:
                guard let itemId = request.arguments?.itemId else {
                    throw PlayerEngineError.missingArgument("itemId")
                }
                removeQueueItem(id: itemId)
            case .clearQueue:
                clearQueue()
            case .status:
                break
            }
            return response(to: request)
        } catch {
            lastError = error.localizedDescription
            return response(to: request, error: error.localizedDescription)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.player === player else { return }
            if let item = self.currentItem, let buffer = self.progressiveAudio[item.id] {
                self.currentTime = buffer.offset(for: self.segmentIndex) + player.duration
                self.segmentIndex += 1
                if buffer.segments.indices.contains(self.segmentIndex) {
                    do { try self.playProgressiveSegment(at: self.segmentIndex) }
                    catch { self.lastError = error.localizedDescription; self.stopCurrent(resetPosition: true); self.state = .failed }
                    return
                }
                if !buffer.isComplete {
                    self.player = nil
                    self.progressTimer?.invalidate()
                    self.progressTimer = nil
                    self.audioLevel = 0
                    self.state = .loading
                    return
                }
            }
            self.finishCurrentItem(naturallyFinished: true)
            if self.autoplayEnabled {
                do {
                    try self.playNext()
                } catch {
                    self.state = .failed
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private var canStartNextItem: Bool {
        guard let next = queue.first else { return false }
        return next.effectiveChannel != .completions || !interactiveBusy
    }

    private func playNext() throws {
        guard !queue.isEmpty else {
            if currentItem == nil {
                state = .idle
            }
            return
        }

        if queue[0].effectiveChannel == .completions && interactiveBusy {
            state = .idle
            return
        }

        let item = queue.removeFirst()
        state = .loading

        do {
            if progressiveAudio[item.id] != nil {
                currentItem = item
                segmentIndex = 0
                playbackRate = VoiceLane.normalizedPlaybackRate(item.playbackRate) ?? playbackRate
                try playProgressiveSegment(at: 0)
                lastError = nil
                HUDWindowManager.shared.showPlayback(item)
                return
            }
            let nextPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: item.audioPath))
            let itemPlaybackRate = VoiceLane.normalizedPlaybackRate(item.playbackRate) ?? playbackRate
            playbackRate = itemPlaybackRate
            nextPlayer.delegate = self
            nextPlayer.enableRate = true
            nextPlayer.volume = volume
            nextPlayer.rate = itemPlaybackRate
            nextPlayer.isMeteringEnabled = true
            nextPlayer.prepareToPlay()

            player = nextPlayer
            currentItem = item
            currentTime = 0
            duration = nextPlayer.duration
            sentences = SpeechSentences.load(for: URL(fileURLWithPath: item.audioPath), duration: duration)
            audioLevel = 0
            lastError = nil
            guard nextPlayer.play() else { throw PlayerEngineError.couldNotStartAudio }
            state = .playing
            HUDWindowManager.shared.showPlayback(item)
            startProgressTimer()
        } catch {
            progressiveAudio.removeValue(forKey: item.id)?.removeFiles()
            player = nil
            currentItem = nil
            isReceivingAudio = false
            state = .failed
            lastError = error.localizedDescription
            throw PlayerEngineError.couldNotOpenAudio(error.localizedDescription)
        }
    }

    private func stopCurrent(resetPosition: Bool, removeAudio: Bool = true) {
        player?.stop()
        if resetPosition {
            player?.currentTime = 0
        }
        finishCurrentItem(naturallyFinished: false, removeAudio: removeAudio)
    }

    private func finishCurrentItem(naturallyFinished: Bool, removeAudio: Bool = true) {
        let finishedItem = currentItem
        if removeAudio, let id = finishedItem?.id {
            progressiveAudio.removeValue(forKey: id)?.removeFiles()
        }
        isReceivingAudio = false
        if naturallyFinished {
            lastFinishedItemID = finishedItem?.id
        }
        HUDWindowManager.shared.playbackDidFinish()
        progressTimer?.invalidate()
        progressTimer = nil
        player = nil
        currentItem = nil
        currentTime = 0
        duration = 0
        sentences = []
        audioLevel = 0
        state = .idle
        if removeAudio, finishedItem?.cleanupAfterPlayback == true {
            try? FileManager.default.removeItem(atPath: finishedItem?.audioPath ?? "")
            if let path = finishedItem?.audioPath {
                try? FileManager.default.removeItem(at: SpeechSentences.metadataURL(for: URL(fileURLWithPath: path)))
            }
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProgress()
            }
        }
        if let progressTimer {
            RunLoop.main.add(progressTimer, forMode: .common)
        }
    }

    private func refreshProgress() {
        guard let player else { return }
        if state == .playing, !player.isPlaying, player.currentTime < player.duration - 0.01 {
            state = .paused
            progressTimer?.invalidate()
            progressTimer = nil
        }
        if let item = currentItem, let buffer = progressiveAudio[item.id] {
            currentTime = buffer.offset(for: segmentIndex) + player.currentTime
            duration = buffer.duration
        } else {
            currentTime = player.currentTime
            duration = player.duration
        }
        player.updateMeters()
        let averagePower = player.averagePower(forChannel: 0)
        let normalized = pow(10, averagePower / 20)
        audioLevel = max(0, min(1, normalized))
        HUDWindowManager.shared.updatePlayback(
            audioLevel: audioLevel,
            currentTime: currentTime,
            duration: duration
        )
    }

    private func response(to request: PlayerCommandRequest, error: String? = nil) -> PlayerCommandResponse {
        PlayerCommandResponse(
            protocolVersion: playerProtocolVersion,
            requestId: request.requestId,
            ok: error == nil,
            snapshot: snapshot(),
            error: error
        )
    }
}

enum PlayerEngineError: LocalizedError {
    case audioPathMustBeAbsolute
    case audioFileMissing(String)
    case couldNotOpenAudio(String)
    case couldNotStartAudio
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .audioPathMustBeAbsolute:
            return "audio_path_must_be_absolute"
        case .audioFileMissing(let path):
            return "audio_file_missing:\(path)"
        case .couldNotOpenAudio(let detail):
            return "could_not_open_audio:\(detail)"
        case .couldNotStartAudio:
            return "Audio playback could not start. Check your Mac's audio output, then try Play again."
        case .missingArgument(let name):
            return "missing_argument:\(name)"
        }
    }
}
