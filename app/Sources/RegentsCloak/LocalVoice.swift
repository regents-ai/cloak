import AppKit
import AVFoundation
import CloakChat
import Observation
import os
import Speech
import SwiftUI

/// 100% on-device Local Voice for Cloak (macOS 26+):
/// - Offline dictation powered by Apple's macOS 26 `SpeechAnalyzer` +
///   `SpeechTranscriber` (strictly local by design — zero cloud endpoint and
///   never triggers Apple's legacy cloud speech recognition prompt).
/// - Offline read-aloud powered by `AVSpeechSynthesizer` (zero network).
///
/// All dictation and read-aloud lifecycles share a single mutually-exclusive
/// explicit `Phase` state machine so dictation and TTS can never overlap,
/// stale async/delegate callbacks cannot clobber newer sessions, and audio
/// resources are deterministically torn down on every exit path.
@MainActor
@Observable
final class LocalVoice: NSObject, AVSpeechSynthesizerDelegate {
    enum SettingsPane: Equatable, Sendable {
        case microphone
        case keyboardDictation

        var buttonTitle: String {
            switch self {
            case .microphone: "Open Microphone Settings…"
            case .keyboardDictation: "Open Keyboard Settings…"
            }
        }

        var url: URL? {
            switch self {
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .keyboardDictation:
                URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            }
        }
    }

    /// Public, Equatable projection of the voice state machine for UI & tests.
    enum PublicState: Equatable {
        case idle
        case starting
        case downloading
        case listening
        case speaking(UUID)
        case error(String, settingsPane: SettingsPane?)
    }

    /// Owns every live resource for an active dictation session; `teardown()`
    /// is invoked unconditionally on every transition out of `.listening`.
    private final class ListeningSession {
        let token: UUID
        let audioEngine: AVAudioEngine
        let analyzer: SpeechAnalyzer
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        var resultsTask: Task<Void, Never>?
        var configObserver: NSObjectProtocol?
        var prefixText: String
        var finalizedText = ""
        var lastEmittedDraft: String
        let onTranscript: (String) -> Void
        let currentDraft: () -> String

        init(
            token: UUID,
            audioEngine: AVAudioEngine,
            analyzer: SpeechAnalyzer,
            inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
            prefixText: String,
            currentDraft: @escaping () -> String,
            onTranscript: @escaping (String) -> Void
        ) {
            self.token = token
            self.audioEngine = audioEngine
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            self.prefixText = prefixText
            self.lastEmittedDraft = prefixText
            self.currentDraft = currentDraft
            self.onTranscript = onTranscript
        }

        @MainActor
        func teardown() {
            if let observer = configObserver {
                NotificationCenter.default.removeObserver(observer)
                configObserver = nil
            }
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            inputContinuation.finish()
            resultsTask?.cancel()
            resultsTask = nil
            let activeAnalyzer = analyzer
            Task { await activeAnalyzer.cancelAndFinishNow() }
        }
    }

    /// Single mutually-exclusive internal state machine owning all live handles.
    private enum Phase {
        case idle
        case starting(token: UUID, setupTask: Task<Void, Never>)
        case downloading(token: UUID, setupTask: Task<Void, Never>, progress: Progress)
        case listening(ListeningSession)
        case speaking(turnID: UUID, utteranceID: ObjectIdentifier)
        case error(String, settingsPane: SettingsPane?)
    }

    @ObservationIgnored private var phase: Phase = .idle
    /// Observable projection updated strictly by `transition(to:)`.
    private(set) var state: PublicState = .idle
    /// Normalized 0...1 live microphone RMS energy while `.listening`.
    private(set) var level: Float = 0

    var isListening: Bool {
        switch state {
        case .starting, .downloading, .listening: true
        case .idle, .speaking, .error: false
        }
    }

    var speakingTurn: UUID? {
        if case .speaking(let turnID) = state { return turnID }
        return nil
    }

    var isActive: Bool {
        switch state {
        case .starting, .downloading, .listening, .speaking: true
        case .idle, .error: false
        }
    }

    var statusTitle: String {
        switch state {
        case .starting: "Starting offline microphone…"
        case .downloading: "Downloading Apple offline speech model…"
        case .listening: "Listening offline on this Mac…"
        case .idle, .speaking, .error: ""
        }
    }

    var errorInfo: (message: String, settingsPane: SettingsPane?)? {
        if case .error(let message, let pane) = state {
            return (message, pane)
        }
        return nil
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "voice")

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Explicit State Transitions

    /// Single transition point: tears down whatever resources the previous phase
    /// owned before entering `next`, guaranteeing zero leaked engines/tasks/speech.
    private func transition(to next: Phase, preservingSetupTask: Bool = false) {
        switch phase {
        case .idle, .error:
            break
        case .starting(_, let task):
            if !preservingSetupTask { task.cancel() }
        case .downloading(_, let task, let progress):
            if !preservingSetupTask {
                progress.cancel()
                task.cancel()
            }
        case .listening(let session):
            session.teardown()
        case .speaking:
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
        }

        phase = next
        switch next {
        case .idle:
            level = 0
            state = .idle
        case .starting:
            level = 0
            state = .starting
        case .downloading:
            level = 0
            state = .downloading
        case .listening:
            state = .listening
        case .speaking(let turnID, _):
            level = 0
            state = .speaking(turnID)
        case .error(let message, let pane):
            level = 0
            state = .error(message, settingsPane: pane)
        }
    }

    private func isCurrentDictation(_ token: UUID) -> Bool {
        switch phase {
        case .starting(let current, _), .downloading(let current, _, _):
            return current == token
        case .listening(let session):
            return session.token == token
        case .idle, .speaking, .error:
            return false
        }
    }

    func dismissError() {
        if case .error = phase {
            transition(to: .idle)
        }
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = pane.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - On-Device Dictation (macOS 26 SpeechAnalyzer)

    /// Starts or stops strictly offline on-device dictation, merging live
    /// transcription cleanly onto `currentDraft()`.
    func toggleDictation(
        currentDraft: @escaping () -> String,
        onUpdate: @escaping (String) -> Void
    ) {
        if isListening {
            stopDictation()
        } else {
            startDictation(currentDraft: currentDraft, onUpdate: onUpdate)
        }
    }

    func startDictation(
        currentDraft: @escaping () -> String,
        onUpdate: @escaping (String) -> Void
    ) {
        let token = UUID()
        let initialPrefix = currentDraft()

        let task = Task { @MainActor [weak self] in
            guard let self, self.isCurrentDictation(token) else { return }

            // 1. Microphone authorization only (SpeechAnalyzer runs 100% on-device).
            let micGranted = await Self.requestMicrophoneAuthorization()
            guard self.isCurrentDictation(token) else { return }
            guard micGranted else {
                self.transition(
                    to: .error(
                        "Allow Microphone access for Cloak in System Settings to use Local Voice.",
                        settingsPane: .microphone),
                    preservingSetupTask: true)
                return
            }

            // 2. Resolve supported on-device locale & SpeechTranscriber.
            guard SpeechTranscriber.isAvailable else {
                self.transition(
                    to: .error(
                        "On-device SpeechTranscriber is unavailable on this Mac.",
                        settingsPane: .keyboardDictation),
                    preservingSetupTask: true)
                return
            }
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
                ?? Locale(identifier: "en-US")
            guard self.isCurrentDictation(token) else { return }

            // 3. Reserve locale & ensure offline speech assets are installed.
            do {
                let reserved = await AssetInventory.reservedLocales
                if !reserved.contains(where: { $0.identifier == locale.identifier }) {
                    _ = try await AssetInventory.reserve(locale: locale)
                }
            } catch {
                self.logger.notice("locale reserve notice for \(locale.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            guard self.isCurrentDictation(token) else { return }

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

            do {
                if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    guard self.isCurrentDictation(token),
                        case .starting(_, let runningTask) = self.phase
                    else { return }
                    self.transition(
                        to: .downloading(token: token, setupTask: runningTask, progress: installer.progress),
                        preservingSetupTask: true)
                    try await installer.downloadAndInstall()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentDictation(token) else { return }
                self.logger.error("speech asset install failed: \(String(describing: error), privacy: .public)")
                self.transition(
                    to: .error(
                        "Could not install Apple's offline speech model for \(locale.identifier).",
                        settingsPane: .keyboardDictation),
                    preservingSetupTask: true)
                return
            }
            guard self.isCurrentDictation(token) else { return }

            // 4. Configure AVAudioEngine + format converter into SpeechAnalyzer.
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                self.transition(
                    to: .error(
                        "No active microphone input was found on this Mac.",
                        settingsPane: .microphone),
                    preservingSetupTask: true)
                return
            }

            let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: inputFormat) ?? inputFormat
            guard self.isCurrentDictation(token) else { return }

            let converter: AVAudioConverter? = (inputFormat != targetFormat)
                ? AVAudioConverter(from: inputFormat, to: targetFormat)
                : nil

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            do {
                try await analyzer.prepareToAnalyze(in: targetFormat)
                try await analyzer.start(inputSequence: stream)
            } catch {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                guard self.isCurrentDictation(token) else { return }
                self.logger.error("speech analyzer start failed: \(String(describing: error), privacy: .public)")
                self.transition(
                    to: .error(
                        "Could not start offline speech recognition on this Mac.",
                        settingsPane: nil),
                    preservingSetupTask: true)
                return
            }
            guard self.isCurrentDictation(token) else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }

            let session = ListeningSession(
                token: token,
                audioEngine: engine,
                analyzer: analyzer,
                inputContinuation: continuation,
                prefixText: initialPrefix,
                currentDraft: currentDraft,
                onTranscript: onUpdate
            )

            // Stop cleanly if the audio route changes (AirPods/USB mic unplugged, sleep/wake).
            session.configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentDictation(token) else { return }
                    self.logger.notice("audio configuration changed during dictation; stopping cleanly")
                    self.transition(to: .idle)
                }
            }

            let levelUpdate: @Sendable (Float) -> Void = { [weak self] rms in
                Task { @MainActor [weak self] in
                    guard let self, case .listening(let active) = self.phase, active.token == token else { return }
                    self.level = (self.level * 0.65) + (rms * 0.35)
                }
            }

            let sendableConverter = UncheckedSendableBox(converter)
            let sendableTargetFormat = UncheckedSendableBox(targetFormat)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
                let rms = Self.normalizedLevel(buffer)
                levelUpdate(rms)
                if let converted = Self.convert(buffer, using: sendableConverter.value, to: sendableTargetFormat.value) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }

            // Start consuming results BEFORE starting the mic so early tokens are never dropped,
            // and unconditionally transition to `.idle` when the stream ends (error OR normal EOF).
            session.resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let chunk = String(result.text.characters)
                        let isFinal = result.isFinal
                        await MainActor.run {
                            guard let self, case .listening(let active) = self.phase, active.token == token else { return }
                            // Respect manual user edits made to the composer while dictating.
                            let liveDraft = active.currentDraft()
                            if liveDraft != active.lastEmittedDraft {
                                active.prefixText = liveDraft
                                active.finalizedText = ""
                            }
                            let combined: String
                            if isFinal {
                                active.finalizedText = VoiceText.merge(prefix: active.finalizedText, transcript: chunk)
                                combined = active.finalizedText
                            } else {
                                combined = VoiceText.merge(prefix: active.finalizedText, transcript: chunk)
                            }
                            let merged = VoiceText.merge(prefix: active.prefixText, transcript: combined)
                            active.lastEmittedDraft = merged
                            active.onTranscript(merged)
                        }
                    }
                    await MainActor.run {
                        guard let self, self.isCurrentDictation(token) else { return }
                        self.transition(to: .idle)
                    }
                } catch is CancellationError {
                    // Normal stop via transition(to:).
                } catch {
                    await MainActor.run {
                        guard let self, self.isCurrentDictation(token) else { return }
                        self.logger.notice("offline dictation ended: \(String(describing: error), privacy: .public)")
                        self.transition(to: .idle)
                    }
                }
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                session.teardown()
                guard self.isCurrentDictation(token) else { return }
                self.logger.error("audio engine start failed: \(String(describing: error), privacy: .public)")
                self.transition(
                    to: .error(
                        "Could not start the microphone on this Mac.",
                        settingsPane: .microphone),
                    preservingSetupTask: true)
                return
            }

            self.transition(to: .listening(session), preservingSetupTask: true)
        }

        transition(to: .starting(token: token, setupTask: task))
    }

    func stopDictation() {
        if isListening {
            transition(to: .idle)
        }
    }

    // MARK: - On-Device Read Aloud (TTS)

    /// Toggles offline read-aloud for `turnID`.
    func toggleSpeak(_ text: String, turnID: UUID) {
        if speakingTurn == turnID {
            stopSpeaking()
        } else {
            speak(text, turnID: turnID)
        }
    }

    /// Reads `text` aloud strictly on-device using macOS's `AVSpeechSynthesizer`.
    func speak(_ text: String, turnID: UUID) {
        let spoken = VoiceText.spoken(from: text)
        guard !spoken.isEmpty else {
            stopSpeaking()
            return
        }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = preferredOfflineVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let utteranceID = ObjectIdentifier(utterance)
        // Tears down any active dictation or prior speech utterance first.
        transition(to: .speaking(turnID: turnID, utteranceID: utteranceID))
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if case .speaking = phase {
            transition(to: .idle)
        }
    }

    func stopAll() {
        if case .idle = phase { return }
        transition(to: .idle)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, case .speaking(_, let activeID) = self.phase, activeID == finishedID else { return }
            self.transition(to: .idle)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelledID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, case .speaking(_, let activeID) = self.phase, activeID == cancelledID else { return }
            self.transition(to: .idle)
        }
    }

    // MARK: - Helpers

    private func preferredOfflineVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(language.lowercased())
        }
        if let premium = matching.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = matching.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? matching.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter?, to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else {
            return copyPCMBuffer(buffer)
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrames = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Deep-copies any PCM buffer (Float32, Int16, or Int32) so AVAudioEngine's
    /// internal tap ring buffer can never overwrite samples queued in `AsyncStream`.
    private nonisolated static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let bufferCount = buffer.format.isInterleaved ? 1 : channels
        let samplesPerBuffer = buffer.format.isInterleaved ? (frames * channels) : frames
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for i in 0..<bufferCount { dst[i].update(from: src[i], count: samplesPerBuffer) }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for i in 0..<bufferCount { dst[i].update(from: src[i], count: samplesPerBuffer) }
            return copy
        }
        if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for i in 0..<bufferCount { dst[i].update(from: src[i], count: samplesPerBuffer) }
            return copy
        }
        return nil
    }

    private nonisolated static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<count {
                let sample = channel[i]
                sum += sample * sample
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            let scale: Float = 1.0 / Float(Int16.max)
            for i in 0..<count {
                let sample = Float(channel[i]) * scale
                sum += sample * sample
            }
        } else {
            return 0
        }
        let rms = sqrt(sum / Float(count))
        return min(1, max(0, (rms - 0.004) / 0.12))
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Local Voice UI Controls

/// Compact microphone dictation button inside the Chat composer bubble.
struct VoiceMicButton: View {
    let voice: LocalVoice
    let action: () -> Void

    var body: some View {
        let listening = voice.isListening
        Button(action: action) {
            Image(systemName: listening ? "stop.fill" : "mic")
                .font(.system(size: listening ? 11 : 13, weight: .semibold))
                .foregroundStyle(listening ? .white : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(listening ? Color.red : Color.primary.opacity(0.06))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            listening ? Color.red.opacity(0.4) : Color.primary.opacity(0.08),
                            lineWidth: listening ? 1.5 : 0.75)
                        .scaleEffect(listening ? CGFloat(1.0 + Double(voice.level) * 0.25) : 1.0)
                        .animation(.easeOut(duration: 0.08), value: voice.level)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip(listening ? "Stop offline dictation (⌘⇧D)" : "Dictate locally on this Mac — 100% offline, zero cloud audio (⌘⇧D)")
        .accessibilityLabel(listening ? "Stop offline dictation" : "Dictate locally")
    }
}

/// Compact offline read-aloud toggle button placed in an Answer pane's accessory bar.
struct VoiceSpeakButton: View {
    let voice: LocalVoice
    let turnID: UUID
    let text: String

    var body: some View {
        let speaking = voice.speakingTurn == turnID
        Button {
            voice.toggleSpeak(text, turnID: turnID)
        } label: {
            Label(speaking ? "Stop reading" : "Read aloud", systemImage: speaking ? "stop.circle.fill" : "speaker.wave.2")
                .labelStyle(.iconOnly)
                .font(.caption.weight(.medium))
                .foregroundStyle(speaking ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hover(Circle())
        .tip(speaking ? "Stop offline read-aloud" : "Read aloud on this Mac (offline)")
        .accessibilityLabel(speaking ? "Stop reading aloud" : "Read answer aloud")
    }
}

/// Minimal 4-bar live microphone level indicator shown while dictating offline.
struct VoiceLevelBars: View {
    let level: Float
    private let weights: [Float] = [0.55, 1.0, 0.8, 0.45]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<weights.count, id: \.self) { index in
                let height = max(3, CGFloat(3 + level * 11 * weights[index]))
                Capsule()
                    .fill(Color.red)
                    .frame(width: 2.5, height: height)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}
