import Combine
import Foundation

enum CompletionSubscriptionPresentationState: String, Sendable {
    case off
    case subscribed
    case watching
    case muted
    case unavailable
    case failed

    var label: String {
        switch self {
        case .off: "Off"
        case .subscribed: "Subscribed"
        case .watching: "Watching"
        case .muted: "Muted"
        case .unavailable: "Unavailable"
        case .failed: "Needs attention"
        }
    }
}

/// Independent completion mode. It has no reference to the listening phase,
/// active lane, microphone, or interactive Codex submission state.
@MainActor
final class CompletionSubscriptionController: ObservableObject {
    static let shared = CompletionSubscriptionController()

    @Published private(set) var subscription: CompletionSubscription?
    @Published private(set) var channel: CompletionChannelConfiguration
    @Published private(set) var activities: [CompletionActivity]
    @Published private(set) var observerState: CompletionSubscriptionPresentationState = .off
    @Published private(set) var lastError: String?
    @Published private(set) var isFeatureEnabled: Bool
    @Published private(set) var preparingActivityID: UUID?
    @Published private(set) var preparingVoiceName: String?

    private let store: CompletionSubscriptionStore
    private let observer: CodexCompletionObserver
    private let presenter: any CompletionPresenting
    private let narrator = ConfiguredResponseNarrator()
    private var playbackObservations: Set<AnyCancellable> = []
    private var processingTail: Task<Void, Never>?
    private var started = false
    private var observationRetry: Task<Void, Never>?
    private var renderTasks: [UUID: Task<URL, Error>] = [:]

    init(
        store: CompletionSubscriptionStore = CompletionSubscriptionStore(),
        observer: CodexCompletionObserver? = nil,
        presenter: (any CompletionPresenting)? = nil,
        featureEnabled: Bool? = nil
    ) {
        self.store = store
        self.observer = observer ?? CodexCompletionObserver()
        if let presenter {
            self.presenter = presenter
        } else if SpeakEasyEdition.isDevelopment {
            self.presenter = EchoCompletionPresenter()
        } else {
            self.presenter = CodexLunaCompletionPresenter()
        }
        self.isFeatureEnabled = featureEnabled ?? ConfigManager.shared.observerPresenterEnabled
        do {
            let snapshot = try store.load()
            subscription = snapshot.subscription
            channel = snapshot.channel
            activities = snapshot.activities
            observerState = isFeatureEnabled && subscription?.isEnabled == true ? .subscribed : .off
        } catch {
            subscription = nil
            channel = .init()
            activities = []
            observerState = .failed
            lastError = error.localizedDescription
        }
        observePlayback()
    }

    var state: CompletionSubscriptionPresentationState { observerState }

    var queueCount: Int {
        activities.filter { $0.state == .queued || $0.state == .playing }.count
    }

    var mostRecentActivity: CompletionActivity? { activities.last }

    var preparingSentence: String? {
        guard let id = preparingActivityID, let activity = activities.first(where: { $0.id == id }) else { return nil }
        return SpeechSentences.split(activity.spokenText ?? activity.response).first
    }

    func start() {
        guard !started else { return }
        started = true
        guard isFeatureEnabled else {
            observerState = .off
            return
        }
        guard subscription?.isEnabled == true else { return }
        startObservation()
        recoverPendingActivities()
    }

    func stop() {
        for task in renderTasks.values { task.cancel() }
        observationRetry?.cancel()
        observer.stop()
        started = false
        processingTail?.cancel()
        processingTail = nil
        if subscription?.isEnabled == true { observerState = .subscribed }
    }

    func isSubscribed(to taskID: String) -> Bool {
        subscription?.task.id == taskID
    }

    func subscribe(to task: ListeningTaskLock) {
        guard isFeatureEnabled else { return }
        for rendering in renderTasks.values { rendering.cancel() }
        observationRetry?.cancel()
        observer.stop()
        subscription = CompletionSubscription(task: task)
        observerState = .subscribed
        lastError = nil
        persist()
        guard started else { return }
        startObservation()
        recoverPendingActivities()
    }

    func setEnabled(_ enabled: Bool) {
        guard isFeatureEnabled || !enabled else { return }
        guard var subscription else { return }
        subscription.isEnabled = enabled
        self.subscription = subscription
        persist()
        if enabled {
            guard started else { return }
            startObservation()
            recoverPendingActivities()
        } else {
            observationRetry?.cancel()
            observer.stop()
            observerState = .off
        }
    }

    func unsubscribe() {
        for rendering in renderTasks.values { rendering.cancel() }
        observationRetry?.cancel()
        observer.stop()
        subscription = nil
        observerState = .off
        lastError = nil
        persist()
    }

    func setMuted(_ muted: Bool) {
        channel.isMuted = muted
        if muted {
            for activity in activities where activity.state == .queued {
                PlaybackEngine.shared.removeQueuedCompletion(activityID: activity.id)
                updateActivity(activity.id) { $0.state = .muted }
            }
        }
        persist()
        guard subscription?.isEnabled == true else { return }
        observerState = muted ? .muted : (observer.isRunning ? .watching : .subscribed)
    }

    func setProvider(_ provider: String?) {
        channel.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persist()
    }

    func setVoice(_ voice: String?) {
        channel.voice = voice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persist()
    }

    func setNarrationCue(_ cue: String?) {
        channel.narrationCue = cue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persist()
    }

    func setPlaybackRate(_ rate: Float) {
        channel.playbackRate = min(max(rate.isFinite ? rate : 1, 0.5), 2)
        persist()
    }

    func setVolume(_ volume: Double) {
        channel.volume = min(max(volume.isFinite ? volume : 0.7, 0), 1)
        persist()
    }

    func dismiss(_ activityID: UUID) {
        guard let index = activities.firstIndex(where: { $0.id == activityID }) else { return }
        renderTasks[activityID]?.cancel()
        if preparingActivityID == activityID {
            preparingActivityID = nil
            preparingVoiceName = nil
        }
        if PlaybackEngine.shared.currentItem?.completionActivityID == activityID {
            PlaybackEngine.shared.stop()
        } else {
            PlaybackEngine.shared.removeQueuedCompletion(activityID: activityID)
        }
        activities[index].state = .dismissed
        activities[index].failure = nil
        persist()
    }

    func stopReading() {
        if let id = preparingActivityID { dismiss(id) }
        if let id = PlaybackEngine.shared.currentItem?.completionActivityID { dismiss(id) }
        else { PlaybackEngine.shared.stop() }
    }

    /// Manual replay is an explicit user action and is allowed while the
    /// channel is muted. It changes only the speech projection, never Codex.
    func replay(_ activityID: UUID) {
        guard let activity = activities.first(where: { $0.id == activityID }) else { return }
        enqueueForReplay(activity)
    }

    private func retryObservation() {
        guard SpeakEasyEdition.isDevelopment, started, isFeatureEnabled, subscription?.isEnabled == true else { return }
        observationRetry?.cancel()
        observationRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.started, self.subscription?.isEnabled == true else { return }
            self.startObservation()
        }
    }

    private func startObservation() {
        observationRetry?.cancel()
        guard isFeatureEnabled, let subscription, subscription.isEnabled else {
            observerState = .off
            return
        }
        observer.stop()
        do {
            try observer.start(
                taskID: subscription.task.id,
                cursorOffset: subscription.cursorOffset,
                rolloutIdentity: subscription.rolloutIdentity,
                onState: { [weak self] state, error in
                    guard let self else { return }
                    switch state {
                    case .watching:
                        self.lastError = nil
                        self.observerState = self.channel.isMuted ? .muted : .watching
                    case .unavailable:
                        self.observerState = .unavailable
                    case .failed:
                        self.observerState = .failed
                    case .subscribed:
                        self.observerState = .subscribed
                    }
                    if let error {
                        self.lastError = error
                        self.persist()
                        self.retryObservation()
                    }
                },
                onMessage: { [weak self] message in
                    self?.handle(message)
                }
            )
        } catch {
            if let bridgeError = error as? CodexCompletionBridgeError,
               bridgeError == .runtimeUnavailable || bridgeError == .bridgeUnavailable {
                observerState = .unavailable
            } else {
                observerState = .failed
            }
            lastError = error.localizedDescription
            persist()
            retryObservation()
        }
    }

    private func handle(_ message: CodexCompletionBridgeMessage) {
        guard let subscription else { return }
        switch message {
        case .baseline(let taskID, let cursorOffset, let rolloutIdentity):
            guard taskID == subscription.task.id else {
                failClosed(CodexCompletionBridgeError.taskMismatch)
                return
            }
            var next = subscription
            next.cursorOffset = max(cursorOffset, 0)
            next.rolloutIdentity = rolloutIdentity
            self.subscription = next
            persist()
        case .cursor(let taskID, let turnID, let cursorOffset):
            guard taskID == subscription.task.id else {
                failClosed(CodexCompletionBridgeError.taskMismatch)
                return
            }
            var next = subscription
            next.lastObservedTurnID = turnID
            next.cursorOffset = max(cursorOffset, next.cursorOffset ?? 0)
            self.subscription = next
            persist()
        case .completion(let event):
            guard event.taskID == subscription.task.id else {
                failClosed(CodexCompletionBridgeError.taskMismatch)
                return
            }
            if let rolloutIdentity = subscription.rolloutIdentity,
               rolloutIdentity != event.provenance.rolloutIdentity {
                failClosed(CodexCompletionBridgeError.invalidProvenance)
                return
            }
            let previous = processingTail
            processingTail = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled else { return }
                await self.process(event)
            }
        }
    }

    private func process(_ event: CodexCompletionEvent) async {
        guard isFeatureEnabled,
              var subscription,
              subscription.isEnabled,
              event.taskID == subscription.task.id
        else { return }

        let key = subscription.dedupeKey(turnID: event.turnID)
        if subscription.enqueuedTurnIDs.contains(key) {
            if let index = activities.firstIndex(where: { $0.dedupeKey == key }) {
                activities[index].deduplicatedCount += 1
                activities[index].state = .deduplicated
            }
            subscription.cursorOffset = max(event.cursorOffset, subscription.cursorOffset ?? 0)
            subscription.lastObservedTurnID = event.turnID
            self.subscription = subscription
            persist()
            return
        }

        let activityID: UUID
        if let existing = activities.first(where: { $0.dedupeKey == key }) {
            activityID = existing.id
        } else {
            let activity = CompletionActivity(
                taskID: event.taskID,
                turnID: event.turnID,
                response: event.response,
                completedAt: event.completedAt,
                state: .detected,
                provider: channel.provider,
                cursorOffset: event.cursorOffset
            )
            activities.append(activity)
            activityID = activity.id
        }
        subscription.cursorOffset = max(event.cursorOffset, subscription.cursorOffset ?? 0)
        subscription.lastObservedTurnID = event.turnID
        self.subscription = subscription
        persist() // detection and cursor survive a crash before TTS finishes

        if channel.isMuted {
            updateActivity(activityID) { $0.state = .muted }
            persist()
            return
        }
        await synthesizeAndEnqueue(activityID: activityID, markDurable: true)
    }

    private func recoverPendingActivities() {
        guard isFeatureEnabled, subscription?.isEnabled == true else { return }
        for activity in activities where activity.taskID == subscription?.task.id {
            switch activity.state {
            case .detected:
                guard !channel.isMuted else {
                    updateActivity(activity.id) { $0.state = .muted }
                    continue
                }
                enqueueActivityTask(activity.id, markDurable: true)
            case .queued, .playing:
                enqueueActivityTask(activity.id, markDurable: false)
            default:
                break
            }
        }
        persist()
    }

    private func enqueueActivityTask(_ activityID: UUID, markDurable: Bool) {
        let previous = processingTail
        processingTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.synthesizeAndEnqueue(activityID: activityID, markDurable: markDurable)
        }
    }

    private func enqueueForReplay(_ activity: CompletionActivity) {
        let previous = processingTail
        processingTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            if let audioPath = activity.audioPath,
               FileManager.default.fileExists(atPath: audioPath) {
                self.enqueuePrepared(activityID: activity.id, audioPath: audioPath, markDurable: false)
            } else {
                await self.synthesizeAndEnqueue(activityID: activity.id, markDurable: false)
            }
        }
    }

    private func synthesizeAndEnqueue(activityID: UUID, markDurable: Bool) async {
        guard isFeatureEnabled,
              renderTasks[activityID] == nil,
              let activity = activities.first(where: { $0.id == activityID }),
              !activity.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if let audioPath = activity.audioPath,
           FileManager.default.fileExists(atPath: audioPath) {
            enqueuePrepared(activityID: activityID, audioPath: audioPath, markDurable: markDurable)
            return
        }

        do {
            let spokenText: String
            if let existing = activity.spokenText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                spokenText = existing
            } else {
                guard let task = subscription?.task, task.id == activity.taskID else { return }
                let presentation = await presenter.present(CompletionPresentationRequest(
                    taskID: activity.taskID,
                    turnID: activity.turnID,
                    taskTitle: task.title,
                    projectPath: task.cwd,
                    response: activity.response
                ))
                guard subscription?.task.id == activity.taskID,
                      activities.contains(where: { $0.id == activityID && $0.turnID == activity.turnID })
                else { return }
                spokenText = presentation.spokenText
                updateActivity(activityID) {
                    $0.spokenText = presentation.spokenText
                    $0.presentationSource = presentation.source
                    $0.presentationModel = presentation.model
                    $0.presentationFailure = presentation.fallbackReason
                }
                persist()
            }
            let narration = channelNarrationConfiguration()
            lastError = nil
            preparingActivityID = activityID
            preparingVoiceName = KarenVoiceCatalog.voice(narration.voice)?.name ?? "your voice"
            defer {
                renderTasks.removeValue(forKey: activityID)
                if preparingActivityID == activityID {
                    preparingActivityID = nil
                    preparingVoiceName = nil
                }
            }
            let progressive = SpeakEasyEdition.isDevelopment && narration.provider == "karen" && KarenVoiceCatalog.isQwen(narration.voice)
            let rendering = Task { [weak self] () throws -> URL in
                guard let self else { throw CancellationError() }
                if progressive {
                    return try await KarenVoiceRenderer.render(
                        text: ConfiguredResponseNarrator.flatten(spokenText), voice: narration.voice, rate: narration.rate,
                        onSegment: { [weak self] url in
                            try await self?.receiveSegment(activityID: activityID, url: url, markDurable: markDurable)
                        })
                }
                return try await self.narrator.render(text: spokenText, configuration: narration)
            }
            renderTasks[activityID] = rendering
            let audioURL = try await withTaskCancellationHandler(operation: {
                try await rendering.value
            }, onCancel: { rendering.cancel() })
            try Task.checkCancellation()
            guard subscription?.task.id == activity.taskID else {
                try? FileManager.default.removeItem(at: audioURL)
                throw CancellationError()
            }
            updateActivity(activityID) {
                $0.audioPath = audioURL.path
                $0.provider = narration.provider
            }
            if progressive {
                do { try PlaybackEngine.shared.completeProgressiveAudio(itemID: activityID, finalURL: audioURL) }
                catch {
                    try? FileManager.default.removeItem(at: audioURL)
                    try? FileManager.default.removeItem(at: SpeechSentences.metadataURL(for: audioURL))
                    throw error
                }
                persist()
            } else {
                enqueuePrepared(activityID: activityID, audioPath: audioURL.path, markDurable: markDurable)
            }
        } catch is CancellationError {
            PlaybackEngine.shared.removeQueuedCompletion(activityID: activityID)
            if PlaybackEngine.shared.currentItem?.completionActivityID == activityID {
                PlaybackEngine.shared.stop()
            }
        } catch {
            PlaybackEngine.shared.removeQueuedCompletion(activityID: activityID)
            if PlaybackEngine.shared.currentItem?.completionActivityID == activityID { PlaybackEngine.shared.stop() }
            updateActivity(activityID) {
                $0.state = .failed
                $0.failure = error.localizedDescription
            }
            lastError = error.localizedDescription
            persist()
        }
    }

    private func receiveSegment(activityID: UUID, url: URL, markDurable: Bool) throws {
        try Task.checkCancellation()
        guard let activity = activities.first(where: { $0.id == activityID }),
              activity.taskID == subscription?.task.id else { throw CancellationError() }
        // Stop cancels the owning render task. A prior dismissed state must
        // still allow a fresh, explicit Replay to deliver its first segment.
        if preparingActivityID == activityID {
            preparingActivityID = nil
            preparingVoiceName = nil
            guard enqueuePrepared(activityID: activityID, audioPath: url.path, markDurable: markDurable, progressive: true) else {
                throw ConfiguredResponseNarratorError.generationFailed("Echo could not start the first sentence.")
            }
        } else {
            try PlaybackEngine.shared.appendProgressiveAudio(itemID: activityID, url: url)
        }
    }

    @discardableResult
    private func enqueuePrepared(activityID: UUID, audioPath: String, markDurable: Bool, progressive: Bool = false) -> Bool {
        guard let index = activities.firstIndex(where: { $0.id == activityID }),
              FileManager.default.fileExists(atPath: audioPath)
        else { return false }
        let activity = activities[index]
        let spokenText = activity.spokenText ?? CompletionSpeechProjector.project(activity.response)
        let narration = channelNarrationConfiguration()
        if markDurable, var subscription {
            let key = subscription.dedupeKey(turnID: activity.turnID)
            subscription.enqueuedTurnIDs.insert(key)
            subscription.lastEnqueuedTurnID = activity.turnID
            self.subscription = subscription
        }
        activities[index].state = .queued
        activities[index].failure = nil
        persist() // the exactly-once enqueue decision is durable before queue handoff

        let item = PlaybackItem(
            // The completion observer matches lastFinishedItemID to activity.id.
            // A different ID leaves finished replies pending across restarts.
            id: activity.id,
            audioPath: audioPath,
            title: subscription?.task.title ?? "Codex completion",
            text: spokenText,
            provider: narration.provider,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            synthesisRateWPM: narration.rate,
            sourceThreadId: activity.taskID,
            cleanupAfterPlayback: true,
            playbackRate: channel.playbackRate,
            channel: .completions,
            completionActivityID: activity.id
        )
        PlaybackEngine.shared.setVolume(Float(channel.volume))
        do {
            if progressive { try PlaybackEngine.shared.beginProgressiveAudio(item) }
            else { try PlaybackEngine.shared.enqueue(item, priority: .normal, interrupt: false, autoplay: true) }
            return true
        } catch {
            updateActivity(activityID) {
                $0.state = .failed
                $0.failure = error.localizedDescription
            }
            lastError = error.localizedDescription
            persist()
            return false
        }
    }

    private func observePlayback() {
        PlaybackEngine.shared.$lastStoppedItemID
            .receive(on: RunLoop.main)
            .sink { [weak self] id in
                guard let self, let id, self.renderTasks[id] != nil else { return }
                self.renderTasks[id]?.cancel()
                self.updateActivity(id) { $0.state = .dismissed }
                self.persist()
            }.store(in: &playbackObservations)
        PlaybackEngine.shared.$currentItem
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                guard let self, let activityID = item?.completionActivityID,
                      let index = self.activities.firstIndex(where: { $0.id == activityID })
                else { return }
                self.activities[index].state = .playing
                self.persist()
            }
            .store(in: &playbackObservations)

        PlaybackEngine.shared.$lastFinishedItemID
            .receive(on: RunLoop.main)
            .sink { [weak self] itemID in
                guard let self, let itemID,
                      let item = self.activities.first(where: { $0.id == itemID })
                else { return }
                self.updateActivity(item.id) {
                    $0.state = .announced
                    $0.failure = nil
                }
                self.persist()
            }
            .store(in: &playbackObservations)
    }

    private func channelNarrationConfiguration() -> SpeechNarrationConfiguration {
        let base = SpeechNarrationConfiguration.configured(from: ConfigManager.shared, provider: channel.provider)
        let voice = channel.voice ?? base.voice
        let instructions = [base.instructions, channel.narrationCue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: "\n\n")
            .nilIfEmpty
        return SpeechNarrationConfiguration(
            provider: base.provider,
            voice: voice,
            model: base.model,
            apiKey: base.apiKey,
            instructions: instructions,
            rate: base.rate
        )
    }

    private func updateActivity(_ activityID: UUID, _ update: (inout CompletionActivity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == activityID }) else { return }
        update(&activities[index])
    }

    private func failClosed(_ error: Error) {
        observer.stop()
        observerState = .failed
        lastError = error.localizedDescription
        persist()
    }

    private func persist() {
        do {
            try store.save(CompletionSubscriptionSnapshot(
                subscription: subscription,
                channel: channel,
                activities: activities
            ))
        } catch {
            lastError = error.localizedDescription
            observerState = .failed
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
