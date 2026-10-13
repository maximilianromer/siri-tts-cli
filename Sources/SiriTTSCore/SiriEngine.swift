import CoreAudioTypes
import Darwin
import Foundation
@preconcurrency internal import SiriTTSService
import SiriTTSProtocol

public final class SiriEngine: @unchecked Sendable {
    private let initialKeepActive: Bool
    private let sessionLock = NSLock()
    private var sessionStorage: DaemonSession?
    private var activeSynthesisSession: DaemonSession?
    private var activePlaybackRequest: SpeechRequest?
    private let inventory = VoiceInventoryCache<[SynthesisVoice]>()
    private let downloadableCatalogLock = NSLock()
    private var downloadableCatalogStorage: [SiriDownloadableVoice]?
    private let lifecycle = SynthesisLifecycle<BaseRequest>()
    private let installationWaitLock = NSLock()
    private var installationWaits: [UUID: Bool] = [:]

    public init(keepActive: Bool = false) {
        initialKeepActive = keepActive
    }

    public var isFrameworkPresent: Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService",
            RTLD_LAZY | RTLD_LOCAL
        ) else { return false }
        dlclose(handle)
        return true
    }

    public func connect() throws {
        guard isFrameworkPresent else {
            throw CLIError(
                "The private Siri TTS framework or resident daemon is unavailable",
                code: .daemonUnreachable
            )
        }
        guard session.invokeDaemon() else {
            throw CLIError(
                "The private Siri TTS framework or resident daemon is unavailable",
                code: .daemonUnreachable
            )
        }
    }

    public func enableKeepActive() {
        guard isFrameworkPresent else { return }
        session.keepActive = true
    }

    public func voices(timeout: TimeInterval = 10) throws -> [VoiceInfo] {
        try connect()
        return try fetchNativeVoices(timeout: timeout, refresh: false).map(Self.describe)
    }

    /// Performs an authoritative `downloadedVoices` query and replaces the
    /// cached installed inventory only after a successful response.
    public func refreshInstalledVoices(timeout: TimeInterval = 10) throws -> [VoiceInfo] {
        try connect()
        return try fetchNativeVoices(timeout: timeout, refresh: true).map(Self.describe)
    }

    /// Invalidates only SiriTTSCore's in-memory snapshot. It does not contact
    /// macOS or change installed assets.
    public func invalidateVoiceCache() {
        inventory.invalidate()
    }

    public func availableVoices(timeout: TimeInterval = 15) throws -> [VoiceInfo] {
        try connect()
        let installed = try fetchNativeVoices(timeout: timeout, refresh: true)
        do {
            let catalog = try downloadableVoices(refresh: true)
            var matchedInstalledKeys = Set<String>()
            var available = catalog.map { voice in
                let matches = installed.filter(voice.matchesInstalled)
                matchedInstalledKeys.formUnion(matches.map(\.assetKey))
                // sirittsd can retain a stale row after MobileAsset has physically
                // deleted the voice, while an unowned bundle can remain after
                // unsubscription. Installed means both usable and present.
                return voice.info(installed: voice.locallyAvailable && !matches.isEmpty)
            }
            // Never hide a daemon-installed voice merely because a future catalog
            // schema no longer contains it.
            available.append(contentsOf: installed
                .filter { !matchedInstalledKeys.contains($0.assetKey) }
                .map(Self.describe))
            return available
        } catch {
            return try availableNativeVoices(timeout: timeout).map { voice in
                var info = Self.describe(voice)
                info.installed = installed.contains { $0.assetKey == voice.assetKey }
                return info
            }
        }
    }

    public func subscriptions(clientID: String? = nil, timeout: TimeInterval = 10) throws -> [VoiceSubscriptionInfo] {
        try SiriRuntimeControls.requireOperation("subscriptions")
        try connect()
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<[VoiceSubscriptionInfo]>()
        session.subscribedVoices(clientId: clientID) { subscriptions in
            state.set(.success(subscriptions.map { VoiceSubscriptionInfo(assetKey: $0.voice.assetKey, clientID: $0.clientId, accessoryID: $0.accessoryId) }))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { throw CLIError("Subscription query timed out", code: .operationTimedOut) }
        return try state.get().get()
    }

    public func presets(_ options: SynthesisOptions) throws -> VoicePresetReport {
        let voice = try VoiceResolver.select(options, from: voices())
        return try ExpressiveVoiceCatalog().report(for: voice)
    }

    public func previewURL(_ options: SynthesisOptions) throws -> URL {
        let voice = try VoiceResolver.select(options, from: voices())
        if voice.assetKey.contains(":fmvoice:") {
            return try ExpressiveVoiceCatalog.previewURL(voice: voice, pace: options.controls.pace ?? 3, expressivity: options.controls.expressivity ?? 3)
        }
        return try previewURL(assetKey: voice.assetKey)
    }

    /// Returns Apple's installed preview audio in place without copying it.
    public func previewURL(for voice: VoiceInfo) throws -> URL {
        try previewURL(assetKey: voice.assetKey)
    }

    public func previewURL(assetKey: String) throws -> URL {
        guard let voice = try SiriDownloadableVoiceCatalog.resolve(
            assetKey,
            in: downloadableVoices()
        ) else {
            throw CLIError(
                "Available Siri voice '\(assetKey)' was not found",
                code: .voiceNotFound
            )
        }
        return try SiriVoicePreview.url(for: voice)
    }

    /// Requests physical deletion of the exact locally installed TTS asset.
    /// No daemon or client subscription is changed by this operation.
    public func purgeVoice(
        identifier: String,
        timeout: TimeInterval = 30
    ) throws -> VoicePurgeResult {
        guard (1...300).contains(timeout) else {
            throw CLIError("Purge timeout must be from 1 through 300 seconds", code: .usage)
        }
        try connect()
        try rejectExpressiveAssetMutation(identifier)
        let catalog = try downloadableVoices(refresh: true)
        guard let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(
            identifier,
            in: catalog
        ) else {
            throw CLIError(
                "Available Siri voice '\(identifier)' was not found",
                code: .voiceNotFound
            )
        }
        guard catalogVoice.locallyAvailable else {
            throw CLIError(
                "Siri voice '\(catalogVoice.name)' is not locally installed",
                code: .voiceNotFound
            )
        }
        let outcome = try SiriDownloadableVoiceCatalog.purge(
            catalogAssetKey: catalogVoice.catalogAssetKey,
            installedNativeAssetKey: catalogVoice.nativeAssetKey,
            timeout: timeout
        )
        inventory.invalidate()
        downloadableCatalogLock.withLock { downloadableCatalogStorage = nil }
        return VoicePurgeResult(
            assetKey: catalogVoice.catalogAssetKey,
            nativeAssetKey: catalogVoice.nativeAssetKey,
            name: catalogVoice.name,
            language: catalogVoice.language,
            status: outcome.localAssetAvailableAfterPurge
                ? .localAssetStillAvailable
                : .purgedLocalAsset,
            localAssetAvailableAfterPurge: outcome.localAssetAvailableAfterPurge
        )
    }

    @discardableResult
    public func installVoice(
        named name: String,
        timeout: TimeInterval = 30
    ) throws -> VoiceSubscriptionAcknowledgement {
        try connect()
        try rejectExpressiveAssetMutation(name)
        if let catalog = try? downloadableVoices() {
            guard let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(
                name,
                in: catalog
            ) else {
                throw CLIError("Available Siri voice '\(name)' was not found", code: .voiceNotFound)
            }
            try subscribe(catalogVoice.makeSynthesisVoice(), timeout: timeout)
            invalidateVoiceCache()
            return VoiceSubscriptionAcknowledgement(assetKey: catalogVoice.catalogAssetKey)
        }
        // Preserve compatibility on builds where predefinedVoices works but the
        // newer TTS asset catalog surface is unavailable.
        let available: [SynthesisVoice]
        do {
            available = try availableNativeVoices(timeout: timeout)
        } catch {
            throw CLIError(
                "This macOS build did not expose an installable Siri voice catalog: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
        guard let voice = available.first(where: {
            $0.name?.caseInsensitiveCompare(name) == .orderedSame ||
            $0.assetKey.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw CLIError("Available Siri voice '\(name)' was not found", code: .voiceNotFound)
        }
        try subscribe(voice, timeout: timeout)
        invalidateVoiceCache()
        return VoiceSubscriptionAcknowledgement(assetKey: voice.assetKey)
    }

    /// Requests a catalog subscription by Apple's stable asset identity.
    /// Success means the request was acknowledged, not that installation has
    /// completed. Poll `refreshInstalledVoices()` for completion.
    @discardableResult
    public func subscribeVoice(
        assetKey: String,
        timeout: TimeInterval = 30
    ) throws -> VoiceSubscriptionAcknowledgement {
        try connect()
        try rejectExpressiveAssetMutation(assetKey)
        if let catalog = try? downloadableVoices() {
            guard let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(
                assetKey,
                in: catalog,
                allowDisplayName: false
            ) else {
                throw CLIError(
                    "Available Siri voice asset '\(assetKey)' was not found",
                    code: .voiceNotFound
                )
            }
            try subscribe(catalogVoice.makeSynthesisVoice(), timeout: timeout)
            invalidateVoiceCache()
            return VoiceSubscriptionAcknowledgement(assetKey: catalogVoice.catalogAssetKey)
        }
        // Preserve the reconstructed predefinedVoices path as a fallback for
        // other compatible macOS builds.
        let available: [SynthesisVoice]
        do {
            available = try availableNativeVoices(timeout: timeout)
        } catch {
            throw CLIError(
                "This macOS build did not expose an installable Siri voice catalog: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
        guard let voice = available.first(where: { $0.assetKey == assetKey }) else {
            throw CLIError(
                "Available Siri voice asset '\(assetKey)' was not found",
                code: .voiceNotFound
            )
        }
        try subscribe(voice, timeout: timeout)
        invalidateVoiceCache()
        return VoiceSubscriptionAcknowledgement(assetKey: voice.assetKey)
    }

    /// Reports installed only when Apple's downloadable catalog proves local
    /// content and the daemon exposes the matching generation.
    public func installationStatus(
        for identifier: String,
        timeout: TimeInterval = 10
    ) throws -> VoiceInstallationResult {
        let installed = try refreshInstalledVoices(timeout: timeout)
        var selection = SynthesisOptions(); selection.voice = identifier
        do {
            let selected = try VoiceResolver.select(selection, from: installed)
            if selected.assetKey.contains(":fmvoice:") {
                return VoiceInstallationResult(identifier: identifier, assetKey: selected.assetKey, state: .installed, voice: selected)
            }
        } catch let error as CLIError where error.code == .voiceNotFound {
            // A downloadable legacy voice can be absent from installed inventory.
        }
        if let catalog = try? downloadableVoices(refresh: true),
           let catalogVoice = try SiriDownloadableVoiceCatalog.resolve(identifier, in: catalog) {
            if catalogVoice.locallyAvailable,
               installed.contains(where: catalogVoice.matchesInstalled) {
                let stableVoice = catalogVoice.info(installed: true)
                return VoiceInstallationResult(
                    identifier: identifier,
                    assetKey: catalogVoice.catalogAssetKey,
                    state: .installed,
                    voice: stableVoice
                )
            }
            return VoiceInstallationResult(
                identifier: identifier,
                assetKey: catalogVoice.catalogAssetKey,
                state: .notInstalled
            )
        }
        if let voice = installed.first(where: {
            $0.assetKey.caseInsensitiveCompare(identifier) == .orderedSame ||
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return VoiceInstallationResult(
                identifier: identifier,
                assetKey: voice.assetKey,
                state: .installed,
                voice: voice
            )
        }
        return VoiceInstallationResult(
            identifier: identifier,
            assetKey: nil,
            state: .notInstalled
        )
    }

    /// Polls for both byte-level local availability and a usable daemon voice
    /// after a subscription request. A timeout does not cancel the request.
    public func waitForVoiceInstallation(
        assetKey: String,
        identifier: String? = nil,
        timeout: TimeInterval = 300,
        pollInterval: TimeInterval = 2,
        onUpdate: (@Sendable (VoiceInstallationResult) -> Void)? = nil
    ) throws -> VoiceInstallationResult {
        guard timeout >= 1, timeout <= 3_600 else {
            throw CLIError("Installation timeout must be from 1 through 3600 seconds", code: .usage)
        }
        guard pollInterval > 0 else {
            throw CLIError("Installation polling interval must be positive", code: .usage)
        }
        let waitID = UUID()
        installationWaitLock.withLock { installationWaits[waitID] = false }
        defer { _ = installationWaitLock.withLock { installationWaits.removeValue(forKey: waitID) } }
        return try VoiceInstallationMonitor.poll(
            identifier: identifier ?? assetKey,
            assetKey: assetKey,
            timeout: timeout,
            pollInterval: pollInterval,
            isCancelled: { [self] in
                installationWaitLock.withLock { installationWaits[waitID] ?? true }
            },
            onUpdate: onUpdate,
            fetchInstalled: { [self] in
                try availableVoices(timeout: min(10, timeout)).filter(\.installed)
            }
        )
    }

    /// Loads the selected Siri voice into the resident service without
    /// producing audio. This call shares the synthesis lane, so it cannot race
    /// an active render.
    @discardableResult
    public func prewarm(
        voice: String? = nil,
        language: String? = nil,
        timeout: TimeInterval = 30,
        controls: SpeechControls = SpeechControls()
    ) throws -> VoiceInfo {
        let token = lifecycle.acquire()
        defer { lifecycle.finish(token) }
        try connect()
        try throwIfCancelled(token)
        let nativeVoices = try fetchNativeVoices()
        var options = SynthesisOptions()
        options.text = "Siri TTS prewarm"
        options.voice = voice
        options.language = language
        options.controls = controls
        let selected = try selectVoice(options, from: nativeVoices)
        let request = SynthesisRequest(text: options.text, voice: selected)
        try SiriRuntimeControls.apply(controls, to: request.synthesisContext)
        let requestSession = DaemonSession()
        _ = try SiriRuntimeControls.configureSession(requestSession, controls: controls, expressive: selected.assetKey.contains(":fmvoice:"))
        guard requestSession.invokeDaemon() else { throw CLIError("Could not connect Siri prewarm session", code: .daemonUnreachable) }
        sessionLock.withLock { activeSynthesisSession = requestSession }
        defer { sessionLock.withLock { activeSynthesisSession = nil } }
        guard lifecycle.attach(request, to: token) else {
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        let result = performPrewarm(request, token: token, timeout: timeout, using: requestSession)
        try throwIfCancelled(token)
        guard let result else {
            requestSession.cancel(request: request)
            throw CLIError("Timed out while prewarming Siri", code: .daemonUnreachable)
        }
        do {
            try result.get()
        } catch {
            throw CLIError(
                "Siri prewarm failed: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
        guard lifecycle.claimCompletion(token) else {
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        return describeSelected(selected, requestedAssetKey: voice)
    }

    /// Daemon playback is provisional: sound precedes terminal voice verification.
    /// Use ordinary synthesis and a local audio player when strict verification is required.
    public func speak(_ options: SynthesisOptions, onStarted: (@Sendable () -> Void)? = nil) throws -> SynthesisDiagnostics {
        try SiriRuntimeControls.requireOperation("speak")
        try options.validate()
        guard options.controls.allowVoiceFallback == true && options.controls.requireVerifiedControls != true else { throw CLIError("Native playback requires explicit allowVoiceFallback; use file synthesis for verification before playback", code: .usage) }
        if options.ssml { try SSML.validate(options.text) }
        guard !options.text.isEmpty, options.text.utf8.count <= 16_000 else { throw CLIError("Native playback needs 1 through 16000 UTF-8 bytes", code: .usage) }
        let token = lifecycle.acquire(); defer { lifecycle.finish(token) }
        try connect()
        let voice = try selectVoice(options, from: fetchNativeVoices())
        let requestSession = DaemonSession()
        let identity = try SiriRuntimeControls.configureSession(requestSession, controls: options.controls, expressive: voice.assetKey.contains(":fmvoice:"))
        guard requestSession.invokeDaemon() else { throw CLIError("Could not connect playback session", code: .daemonUnreachable) }
        let request = SpeechRequest(text: options.text, voice: voice)
        request.synthesisContext.rate = options.rate; request.synthesisContext.pitch = options.pitch; request.synthesisContext.volume = 1
        try SiriRuntimeControls.apply(options.controls, to: request.synthesisContext)
        request.audibleContext.playbackVolume = options.volume
        request.audibleContext.playbackRate = 1
        request.audibleContext.didStartSpeaking = onStarted
        let instrumentation = SiriInstrumentation(); _ = instrumentation.attach(to: request)
        sessionLock.withLock { activeSynthesisSession = requestSession; activePlaybackRequest = request }
        defer { sessionLock.withLock { activeSynthesisSession = nil; activePlaybackRequest = nil } }
        guard lifecycle.attach(request, to: token) else { throw CLIError("Playback cancelled", code: .cancelled) }
        let done = DispatchSemaphore(value: 0); let result = LockedResult<Void>()
        requestSession.speak(speechRequest: request) { error in result.set(error.map { .failure($0) } ?? .success(())); done.signal() }
        let deadline = Date(timeIntervalSinceNow: options.timeout)
        while done.wait(timeout: .now() + 0.05) != .success {
            try throwIfCancelled(token)
            if Date() >= deadline { requestSession.cancel(request: request); throw CLIError("Native playback timed out", code: .operationTimedOut) }
        }
        try throwIfCancelled(token)
        do { try result.get().get() } catch { throw CLIError("Native playback failed: \(error.localizedDescription)", code: .daemonUnreachable) }
        guard lifecycle.claimCompletion(token) else { throw CLIError("Playback cancelled", code: .cancelled) }
        return try instrumentation.result(requestedVoice: voice.assetKey, clientID: identity, controls: options.controls)
    }

    /// These controls only dispatch while this engine owns an active playback request.
    public func pausePlayback() throws {
        try sessionLock.withLock {
            guard let session = activeSynthesisSession, let request = activePlaybackRequest else { throw CLIError("No active native playback", code: .usage) }
            session.pause(request: request)
        }
    }
    public func resumePlayback() throws {
        try sessionLock.withLock {
            guard let session = activeSynthesisSession, let request = activePlaybackRequest else { throw CLIError("No active native playback", code: .usage) }
            session.resume(request: request)
        }
    }
    public func adjustPlayback(rate: Float? = nil, volume: Float? = nil, rampTime: Double = 0) throws {
        if let rate, !rate.isFinite || !(0.5...2).contains(rate) { throw CLIError("Playback rate must be 0.5 through 2", code: .usage) }
        if let volume, !volume.isFinite || !(0...1).contains(volume) { throw CLIError("Playback volume must be 0 through 1", code: .usage) }
        guard rampTime.isFinite, (0...10).contains(rampTime), rate != nil || volume != nil else { throw CLIError("Provide playback rate or volume; rampTime must be 0 through 10 seconds", code: .usage) }
        let session = try sessionLock.withLock {
            guard activePlaybackRequest != nil, let session = activeSynthesisSession else { throw CLIError("No active native playback", code: .usage) }
            return session
        }
        for isRate in [true, false] {
            guard (isRate ? rate : volume) != nil else { continue }
            let done = DispatchSemaphore(value: 0); let result = LockedResult<Void>()
            let completion: (Error?) -> Void = { error in result.set(error.map { .failure($0) } ?? .success(())); done.signal() }
            if isRate { session.adjustRate(rate!, didFinish: completion) }
            else { session.adjustVolume(volume!, rampTime: rampTime, didFinish: completion) }
            guard done.wait(timeout: .now() + 5) == .success else { throw CLIError("Playback adjustment timed out", code: .operationTimedOut) }
            try result.get().get()
        }
    }

    /// Native linguistic analysis. Estimates are heuristic and are not rendered durations.
    public func analyze(_ options: SynthesisOptions, phonemeSystem: PhonemeAlphabet? = nil) throws -> TextAnalysisResult {
        try SiriRuntimeControls.requireOperation(phonemeSystem == nil ? "estimate" : "phonemes")
        try options.validate()
        if options.ssml { try SSML.validate(options.text) }
        guard !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              options.text.utf8.count <= 16_000 else { throw CLIError("Analysis needs 1 through 16000 UTF-8 bytes of text", code: .usage) }
        guard options.engine != .av else { throw CLIError("Text analysis requires Siri", code: .usage) }
        let token = lifecycle.acquire()
        defer { lifecycle.finish(token) }
        try connect()
        let voice = try selectVoice(options, from: fetchNativeVoices())
        let requestSession = DaemonSession()
        _ = try SiriRuntimeControls.configureSession(requestSession, controls: options.controls, expressive: voice.assetKey.contains(":fmvoice:"))
        guard requestSession.invokeDaemon() else { throw CLIError("Could not connect Siri analysis session", code: .daemonUnreachable) }
        sessionLock.withLock { activeSynthesisSession = requestSession }
        defer { sessionLock.withLock { activeSynthesisSession = nil } }
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<TextAnalysisResult>()
        let request: BaseRequest
        if let alphabet = phonemeSystem {
            let raw = [PhonemeAlphabet.nashville: 0, .xsampa: 1, .lhp: 2][alphabet]!
            guard let system = PhonemeRequest.PhonemeSystem(rawValue: raw) else { throw CLIError("Phoneme alphabet unavailable on this macOS build", code: .noCompatibleEngine) }
            let phonemeRequest = PhonemeRequest(text: options.text, voice: voice, phonemeSystem: system)
            request = phonemeRequest
            guard lifecycle.attach(request, to: token) else { throw CLIError("Analysis cancelled", code: .cancelled) }
            requestSession.textToPhoneme(request: phonemeRequest) { text, error in
                if let error { state.set(.failure(error)) }
                else if let text { state.set(.success(TextAnalysisResult(operation: "phonemes", requestedVoice: voice.assetKey, text: options.text, phonemeSystem: alphabet, phonemes: text))) }
                else { state.set(.failure(CLIError("Siri returned no phonemes", code: .noAudio))) }
                done.signal()
            }
        } else {
            let synthesis = SynthesisRequest(text: options.text, voice: voice)
            synthesis.synthesisContext.rate = options.rate
            synthesis.synthesisContext.pitch = options.pitch
            synthesis.synthesisContext.volume = options.volume
            try SiriRuntimeControls.apply(options.controls, to: synthesis.synthesisContext)
            request = synthesis
            guard lifecycle.attach(request, to: token) else { throw CLIError("Analysis cancelled", code: .cancelled) }
            requestSession.estimateDuration(request: synthesis) { seconds, error in
                if let error { state.set(.failure(error)) }
                else if seconds.isFinite && seconds > 0 {
                    state.set(.success(TextAnalysisResult(operation: "estimate", requestedVoice: voice.assetKey, text: options.text, estimatedSeconds: seconds,
                        warnings: ["Heuristic estimate; resolved voice and expressive preset effects are not verified. Render audio for exact duration."])))
                } else { state.set(.failure(CLIError("Siri returned an invalid duration estimate", code: .noAudio))) }
                done.signal()
            }
        }
        let deadline = Date(timeIntervalSinceNow: options.timeout)
        while done.wait(timeout: .now() + 0.05) != .success {
            try throwIfCancelled(token)
            if Date() >= deadline {
                requestSession.cancel(request: request)
                throw CLIError("Siri text analysis timed out", code: .operationTimedOut)
            }
        }
        try throwIfCancelled(token)
        let result: TextAnalysisResult
        do { result = try state.get().get() }
        catch { throw CLIError("Siri text analysis failed: \(error.localizedDescription)", code: .noCompatibleEngine) }
        guard lifecycle.claimCompletion(token) else { throw CLIError("Analysis cancelled", code: .cancelled) }
        return result
    }

    public func synthesize(
        _ options: SynthesisOptions,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil,
        onEvent: (@Sendable (SynthesisStreamEvent) -> Void)? = nil,
        textInput: SpeechTextStream? = nil
    ) throws -> RenderedAudio {
        if textInput != nil { try SiriRuntimeControls.requireOperation("textStream") }
        try options.validate()
        if options.ssml { try SSML.validate(options.text) }
        if textInput != nil && (!options.text.isEmpty || options.requestTimings || options.ssml) {
            throw CLIError("Native text streaming requires empty initial text and does not expose verified word timings", code: .usage)
        }
        let token = lifecycle.acquire()
        defer { lifecycle.finish(token); textInput?.cancel() }
        let callbackQueue = DispatchQueue(
            label: "SiriTTSCore.synthesis-events.\(UUID().uuidString)"
        )
        let callbackQueueKey = DispatchSpecificKey<UInt8>()
        callbackQueue.setSpecific(key: callbackQueueKey, value: 1)
        let emitSerialized: (@Sendable (@Sendable () -> Void) -> Void) = { action in
            if DispatchQueue.getSpecific(key: callbackQueueKey) != nil {
                action()
            } else {
                callbackQueue.sync(execute: action)
            }
        }
        let emitCancellation: @Sendable () -> Void = {
            emitSerialized { onEvent?(.cancelled) }
        }

        try connect()
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        let nativeVoices = try fetchNativeVoices()
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        let voice = try selectVoice(options, from: nativeVoices)
        let expressive = voice.assetKey.contains(":fmvoice:")
        let textMapping = !expressive && !options.ssml && textInput == nil
            ? SpeechTextMapping(options.text) : nil
        let requestText = textMapping?.text ?? options.text
        let request = SynthesisRequest(text: requestText, voice: voice)
        request.synthesisContext.rate = options.rate
        request.synthesisContext.pitch = options.pitch
        request.synthesisContext.volume = 1
        try SiriRuntimeControls.apply(options.controls, to: request.synthesisContext)
        let requestSession = (expressive || options.controls.clientID != nil) ? DaemonSession() : session
        let clientID = try SiriRuntimeControls.configureSession(requestSession, controls: options.controls, expressive: expressive)
        guard requestSession.invokeDaemon() else { throw CLIError("Could not connect the selected Siri client session", code: .daemonUnreachable) }
        sessionLock.withLock { activeSynthesisSession = requestSession }
        defer { sessionLock.withLock { activeSynthesisSession = nil } }
        let instrumentation = SiriInstrumentation()
        _ = instrumentation.attach(to: request)
        // Strict expressive requests cannot release unverified substituted speech.
        // With --allow-voice-fallback callers explicitly accept provisional chunks.
        let verifyBeforeStreaming = (expressive && options.controls.allowVoiceFallback != true) || options.controls.requireVerifiedControls == true
        guard lifecycle.attach(request, to: token) else {
            emitCancellation()
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }

        let accumulator = SiriAccumulator(text: requestText, allowFormatChanges: textInput != nil, volume: options.volume)
        let started = Date()

        let timingsSupported = options.requestTimings ? queryTimings(for: voice, using: requestSession) : false
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        if options.prewarm && textInput == nil {
            _ = performPrewarm(
                request,
                token: token,
                timeout: min(30, options.timeout),
                using: requestSession
            )
        }
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        request.synthesisContext.didGenerateAudio = { chunk in
            callbackQueue.sync {
                guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                let chunks = accumulator.append(chunk)
                for normalized in chunks {
                    guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                    if !verifyBeforeStreaming {
                        onPCMChunk?(normalized.pcm)
                        onEvent?(.audio(normalized))
                    }
                }
            }
        }
        request.synthesisContext.didGenerateWordTimings = { timings in
            callbackQueue.sync {
                guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                let accepted = accumulator.append(timings)
                if !accepted.isEmpty && !verifyBeforeStreaming {
                    onEvent?(.timings(textMapping.map { mapping in accepted.compactMap(mapping.restore) } ?? accepted))
                }
            }
        }

        let done = DispatchSemaphore(value: 0)
        let completion = LockedResult<Void>()
        let synthesisStarted = Date()
        let finish: @Sendable (Error?) -> Void = { error in
            if completion.setOnce(error.map { .failure($0) } ?? .success(())) { done.signal() }
        }
        if let textInput {
            requestSession.stream(synthesisRequest: request, inputHandler: { input in
                // Only this feeder queue appends tokens. Completion/cancellation
                // use the framework's asynchronous session interface.
                let native = NativeStreamFeed(input: input, session: requestSession, request: request)
                DispatchQueue(label: "SiriTTSCore.text-input").async {
                    do {
                        while let fragment = try textInput.next(cancelled: { !self.lifecycle.acceptsCallbacks(for: token) }) {
                            accumulator.appendText(fragment.text)
                            let nativeToken: DaemonSession.SynthesisInputStream.Token
                            switch fragment { case .text(let text): nativeToken = .text(text); case .utterance(let text): nativeToken = .utterance(text) }
                            let ack = DispatchSemaphore(value: 0)
                            let result = LockedResult<Void>()
                            native.input.append(nativeToken) { error in
                                result.set(error.map { .failure($0) } ?? .success(())); ack.signal()
                            }
                            while ack.wait(timeout: .now() + 0.05) != .success {
                                try self.throwIfCancelled(token)
                                guard self.lifecycle.acceptsCallbacks(for: token) else { return }
                            }
                            try result.get().get()
                        }
                        native.input.append(.endOfStream) { error in if let error { finish(error) } }
                    } catch { native.session.cancel(request: native.request); finish(error) }
                }
            }, didFinish: finish)
        } else {
            requestSession.synthesize(request: request, didFinish: finish)
        }

        let deadline = started.addingTimeInterval(options.timeout)
        var completed = false
        while Date() < deadline {
            try throwIfCancelled(token, notifyCancellation: emitCancellation)
            if done.wait(timeout: .now() + 0.05) == .success {
                completed = true
                break
            }
        }
        guard completed else {
            _ = lifecycle.cancelActive()
            requestSession.cancel(request: request)
            throw CLIError("Timed out waiting for Siri synthesis", code: .operationTimedOut)
        }
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        do {
            try completion.get().get()
        } catch {
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                emitCancellation()
                throw CLIError("Synthesis cancelled", code: .cancelled)
            }
            throw CLIError(
                "Siri synthesis failed: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }

        let snapshot = callbackQueue.sync {
            let tail = accumulator.finish()
            for normalized in tail {
                guard lifecycle.acceptsCallbacks(for: token) else { break }
                if !verifyBeforeStreaming {
                    onPCMChunk?(normalized.pcm)
                    onEvent?(.audio(normalized))
                }
            }
            return accumulator.snapshot()
        }
        if let error = snapshot.error { throw error }
        try throwIfCancelled(token, notifyCancellation: emitCancellation)
        let spec = AudioSpec.siriPCM
        let acceptance = try AudioIO.validatePCM(snapshot.data, spec: spec, text: accumulator.inputText, allowSilence: options.volume == 0)
        let nativeTimings = WordTimingMapper.sanitize(
            snapshot.timings,
            in: accumulator.inputText,
            duration: acceptance.durationSeconds
        )
        let validTimings = textMapping.map { mapping in nativeTimings.compactMap(mapping.restore) } ?? nativeTimings
        let diagnostics = try instrumentation.result(requestedVoice: voice.assetKey, clientID: clientID, controls: options.controls)
        var describedVoice = describeSelected(voice, requestedAssetKey: options.voice)
        if diagnostics.voiceSubstituted, let resolved = diagnostics.resolvedVoice {
            let parts = resolved.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 6 {
                describedVoice = VoiceInfo(name: parts[3], language: parts[0], assetKey: resolved, version: Int(parts[5]) ?? 0, engine: "siri")
            }
        }
        if verifyBeforeStreaming {
            if !validTimings.isEmpty { onEvent?(.timings(validTimings)) }
            onPCMChunk?(snapshot.data)
            onEvent?(.audio(NormalizedPCMChunk(pcm: snapshot.data, spec: spec, startFrame: 0, frameCount: acceptance.sampleCount)))
        }
        let elapsed = Date().timeIntervalSince(started)
        let rendered = RenderedAudio(
            pcm: snapshot.data,
            spec: spec,
            voice: describedVoice,
            timings: validTimings,
            timingsSupported: timingsSupported,
            engine: .siri,
            elapsed: elapsed,
            timeToFirstAudio: snapshot.firstAudioAt.map { $0.timeIntervalSince(synthesisStarted) },
            diagnostics: diagnostics,
            nonSilent: acceptance.nonSilent
        )
        guard lifecycle.claimCompletion(token) else {
            emitCancellation()
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
        emitSerialized {
            onEvent?(.completed(SynthesisStreamCompletion(
                frameCount: acceptance.sampleCount,
                durationSeconds: acceptance.durationSeconds,
                timingsSupported: timingsSupported
            )))
        }
        return rendered
    }

    public func cancel() {
        installationWaitLock.withLock {
            for waitID in Array(installationWaits.keys) {
                installationWaits[waitID] = true
            }
        }
        let request = lifecycle.cancelActive()
        if let request {
            let active = sessionLock.withLock { activeSynthesisSession } ?? session
            active.cancel(request: request)
        }
    }

    public func isANECompiled(voiceName: String, timeout: TimeInterval = 5) -> Bool? {
        var selection = SynthesisOptions(); selection.voice = voiceName
        guard (try? connect()) != nil,
              let voices = try? fetchNativeVoices(timeout: timeout),
              let voice = try? selectVoice(selection, from: voices) else { return nil }
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<Bool>()
        session.isANEModelCompiled(matching: voice) { compiled, error in
            if let error { state.set(.failure(error)) }
            else { state.set(.success(compiled)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return try? state.get().get()
    }

    private func performPrewarm(
        _ request: SynthesisRequest,
        token: SynthesisLifecycle<BaseRequest>.Token,
        timeout: TimeInterval,
        using requestSession: DaemonSession? = nil
    ) -> Result<Void, Error>? {
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<Void>()
        (requestSession ?? session).prewarm(request: request) { error in
            if let error {
                state.set(.failure(error))
            } else {
                state.set(.success(()))
            }
            done.signal()
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if lifecycle.isCancelled(token) { return nil }
            if done.wait(timeout: .now() + 0.05) == .success {
                return state.get()
            }
        }
        return nil
    }

    private func queryTimings(for voice: SynthesisVoice, using requestSession: DaemonSession, timeout: TimeInterval = 5) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<Bool>()
        requestSession.queryWordTimingSupport(voice: voice) {
            state.set(.success($0))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return false }
        return (try? state.get().get()) ?? false
    }

    private func fetchNativeVoices(
        timeout: TimeInterval = 10,
        refresh: Bool = false
    ) throws -> [SynthesisVoice] {
        let native = try inventory.value(refresh: refresh) {
            let done = DispatchSemaphore(value: 0)
            let state = LockedResult<[SynthesisVoice]>()
            session.downloadedVoices(matching: nil) {
                state.set(.success($0))
                done.signal()
            }
            guard done.wait(timeout: .now() + timeout) == .success else {
                throw CLIError(
                    "Timed out while asking sirittsd for installed voices",
                    code: .daemonUnreachable
                )
            }
            let voices = try state.get().get()
            return voices
        }
        // sirittsd can retain a downloaded-voice row after MobileAsset removes
        // that generation. Keep unknown future rows for compatibility, but do
        // not expose a catalog-matched row whose exact local content is absent.
        guard let catalog = try? downloadableVoices(refresh: refresh) else {
            return native
        }
        return SiriDownloadableVoiceCatalog.filterLocallyInstalled(
            native,
            against: catalog
        )
    }

    private func availableNativeVoices(timeout: TimeInterval) throws -> [SynthesisVoice] {
        try connect()
        let done = DispatchSemaphore(value: 0)
        let state = LockedResult<[SynthesisVoice]>()
        Task {
            do { state.set(.success(try await session.predefinedVoices())) }
            catch { state.set(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw CLIError("Timed out while reading available Siri voices", code: .daemonUnreachable)
        }
        return try state.get().get()
    }

    private func selectVoice(
        _ options: SynthesisOptions,
        from voices: [SynthesisVoice]
    ) throws -> SynthesisVoice {
        var resolvedOptions = options
        if let wanted = options.voice,
           let catalogVoice = try? downloadableVoices().first(where: { $0.catalogAssetKey == wanted }),
           let native = voices.first(where: catalogVoice.matchesInstalled) {
            resolvedOptions.voice = native.assetKey
        }
        let selected = try VoiceResolver.select(resolvedOptions, from: voices.map(Self.describe))
        guard let native = voices.first(where: { $0.assetKey == selected.assetKey }) else {
            throw CLIError("Selected voice disappeared", code: .voiceNotFound)
        }
        return native
    }

    private static func describe(_ voice: SynthesisVoice) -> VoiceInfo {
        VoiceInfo(
            name: voice.name ?? "Unnamed",
            language: voice.language,
            assetKey: voice.assetKey,
            version: voice.version,
            engine: EngineKind.siri.rawValue
        )
    }

    private static func describeInstalled(_ voice: VoiceInfo, as assetKey: String) -> VoiceInfo {
        VoiceInfo(
            name: voice.name,
            language: voice.language,
            assetKey: assetKey,
            version: voice.version,
            engine: voice.engine,
            installed: true
        )
    }

    /// Strict clients require the terminal response to preserve the catalog
    /// identifier they requested, even though sirittsd itself uses a versioned
    /// synthesis key internally.
    private func describeSelected(
        _ voice: SynthesisVoice,
        requestedAssetKey: String?
    ) -> VoiceInfo {
        let native = Self.describe(voice)
        guard let requestedAssetKey,
              let catalogVoice = try? downloadableVoices().first(where: {
                  $0.catalogAssetKey.caseInsensitiveCompare(requestedAssetKey) == .orderedSame
              }), catalogVoice.matchesInstalled(voice) else {
            return native
        }
        return Self.describeInstalled(native, as: requestedAssetKey)
    }

    private func downloadableVoices(refresh: Bool = false) throws -> [SiriDownloadableVoice] {
        if !refresh, let cached = downloadableCatalogLock.withLock({
            downloadableCatalogStorage
        }) {
            return cached
        }
        let loaded = try SiriDownloadableVoiceCatalog.voices()
        downloadableCatalogLock.withLock { downloadableCatalogStorage = loaded }
        return loaded
    }

    private func rejectExpressiveAssetMutation(_ identifier: String) throws {
        let installed = (try? fetchNativeVoices()) ?? []
        var selection = SynthesisOptions(); selection.voice = identifier
        do { _ = try VoiceResolver.select(selection, from: installed.map(Self.describe)) }
        catch let error as CLIError where error.code == .voiceNotFound { /* Catalog may contain an uninstalled legacy voice. */ }
        let exactFM = installed.contains { $0.assetKey.contains(":fmvoice:") && ($0.assetKey == identifier || $0.name == identifier) }
        if identifier.contains(":fmvoice:") || exactFM {
            throw CLIError("Expressive voices cannot be installed or purged as individual TTS bundles. A missing language frontend may be fetched by installing a legacy voice in the same language; for British English, run siri-tts voices --install Arthur --wait. Use capabilities --voice ID --probe to check readiness.", code: .noCompatibleEngine)
        }
    }

    private func subscribe(_ voice: SynthesisVoice, timeout: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let state = LockedResult<Void>()
        session.subscribe(voices: [voice]) { error in
            if let error {
                state.set(.failure(error))
            } else {
                state.set(.success(()))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CLIError(
                "Timed out while asking macOS to install the voice",
                code: .daemonUnreachable
            )
        }
        do {
            try state.get().get()
        } catch {
            if let error = error as? CLIError { throw error }
            throw CLIError(
                "macOS rejected the voice installation request: \(error.localizedDescription)",
                code: .daemonUnreachable
            )
        }
    }

    private func throwIfCancelled(
        _ token: SynthesisLifecycle<BaseRequest>.Token,
        notifyCancellation: () -> Void = {}
    ) throws {
        if lifecycle.isCancelled(token) {
            notifyCancellation()
            throw CLIError("Synthesis cancelled", code: .cancelled)
        }
    }

    /// Private framework classes are instantiated only after a successful
    /// presence check. This preserves weak-link behavior on unsupported builds.
    private var session: DaemonSession {
        sessionLock.withLock {
            if let sessionStorage {
                return sessionStorage
            }
            let value = DaemonSession()
            value.keepActive = initialKeepActive
            sessionStorage = value
            return value
        }
    }
}

private final class SiriAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String
    var inputText: String { lock.withLock { text } }
    func appendText(_ value: String) { lock.withLock { text += value } }
    private let normalizer: SiriAudioNormalizer
    private let volume: Float
    private var data = Data()
    private var timings: [RawWordTiming] = []
    private var firstAudioAt: Date?
    private var error: Error?
    private var lastTimingStart: Double = -.infinity
    private var lastTimingRangeEnd = 0
    private var closed = false

    init(text: String, allowFormatChanges: Bool = false, volume: Float = 1) {
        self.volume = volume
        self.text = text
        self.normalizer = SiriAudioNormalizer(allowFormatChanges: allowFormatChanges)
    }

    func append(_ chunk: AudioData) -> [NormalizedPCMChunk] {
        lock.withLock {
            guard error == nil, !closed else { return [] }
            do {
                let normalized = try normalizer.append(SiriSourceAudioChunk(
                    audioData: chunk.audioData,
                    format: chunk.asbd,
                    packetDescriptions: chunk.packetDescriptions,
                    packetCount: chunk.packetCount,
                    reportedSampleCount: Int(chunk.sampleCount)
                )).map(applyVolume)
                appendNormalized(normalized)
                return normalized
            } catch let caught {
                error = caught
                return []
            }
        }
    }

    func append(_ values: [WordTimingInfo]) -> [RawWordTiming] {
        lock.withLock {
            guard error == nil, !closed else { return [] }
            let utf16Count = text.utf16.count
            var accepted: [RawWordTiming] = []
            for value in values {
                let start = value.startTime
                let range = value.textRange
                let (rangeEnd, overflow) = range.location.addingReportingOverflow(range.length)
                guard start.isFinite, start >= 0,
                      range.location >= 0, range.length >= 0,
                      !overflow, rangeEnd <= utf16Count,
                      start >= lastTimingStart,
                      range.location >= lastTimingRangeEnd else {
                    continue
                }
                let timing = RawWordTiming(start: start, range: range)
                timings.append(timing)
                accepted.append(timing)
                lastTimingStart = start
                lastTimingRangeEnd = rangeEnd
            }
            return accepted
        }
    }

    func finish() -> [NormalizedPCMChunk] {
        lock.withLock {
            guard error == nil, !closed else { return [] }
            closed = true
            do {
                let normalized = try normalizer.finish().map(applyVolume)
                appendNormalized(normalized)
                return normalized
            } catch let caught {
                error = caught
                return []
            }
        }
    }

    func snapshot() -> (
        data: Data,
        timings: [RawWordTiming],
        firstAudioAt: Date?,
        error: Error?
    ) {
        lock.withLock { (data, timings, firstAudioAt, error) }
    }

    private func applyVolume(_ chunk: NormalizedPCMChunk) -> NormalizedPCMChunk {
        NormalizedPCMChunk(pcm: AudioIO.applyingVolume(volume, to: chunk.pcm), spec: chunk.spec, startFrame: chunk.startFrame, frameCount: chunk.frameCount)
    }

    private func appendNormalized(_ chunks: [NormalizedPCMChunk]) {
        for chunk in chunks where !chunk.pcm.isEmpty {
            guard data.count <= 512 * 1024 * 1024 - chunk.pcm.count else {
                error = CLIError("One native request exceeded 512 MiB of decoded audio; split the input", code: .noAudio)
                return
            }
            if firstAudioAt == nil { firstAudioAt = Date() }
            data.append(chunk.pcm)
        }
    }
}

final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func set(_ newValue: Result<Value, Error>) {
        lock.withLock { value = newValue }
    }

    @discardableResult
    func setOnce(_ newValue: Result<Value, Error>) -> Bool {
        lock.withLock { if value != nil { return false }; value = newValue; return true }
    }

    func get() -> Result<Value, Error> {
        lock.withLock {
            value ?? .failure(CLIError("Operation completed without a result", code: .internalFailure))
        }
    }
}

/// The private framework has no concurrency annotations. Input appends are
/// confined to one queue; the daemon session supplies thread-safe async IPC.
private struct NativeStreamFeed: @unchecked Sendable {
    let input: DaemonSession.SynthesisInputStream
    let session: DaemonSession
    let request: SynthesisRequest
}
