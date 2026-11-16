@_exported import FlowIQLog
@_exported import Synchronization

/// What a mode offers (K-26, R-100): dictation live local and German, no live for devices, ElevenLabs only with key.
public struct ModeChoices: Sendable, Equatable {
    public let live: [LiveEngine], post: [PostEngine], languages: [RecordingLanguage]
}

extension Settings {
    /// `hasKey` is the ElevenLabs key (live and after-run), `openRouterKey` opens the after-run only (16.11.).
    public func choices(for mode: RecordingMode, hasKey: Bool, openRouterKey: Bool = false) -> ModeChoices {
        let live: [LiveEngine] = mode == .device ? [] : hasKey && mode != .dictation ? LiveEngine.allCases
            : [.appleLocal]
        return ModeChoices(live: live, post: hasKey || openRouterKey ? [.off, .elevenLabs] : [.off],
                           languages: mode == .dictation ? [.de] : RecordingLanguage.allCases)
    }
    /// A locked choice throws and changes nothing; `effective` is what really runs.
    public mutating func set(_ mode: RecordingMode, live: LiveEngine? = nil, post: PostEngine? = nil,
                             language: RecordingLanguage? = nil, hasKey: Bool,
                             openRouterKey: Bool = false) throws(ModeChoiceError) {
        let old = self[mode]
        let wanted = ModeConfig(live: live ?? old.live, post: post ?? old.post, language: language ?? old.language)
        func refused(_ x: ModeConfig) -> Bool {  // only the fields asked for count
            live.map { $0 != x.live } == true || post.map { $0 != x.post } == true
                || language.map { $0 != x.language } == true
        }
        guard !refused(effective(wanted, mode, hasKey: hasKey, openRouterKey: openRouterKey)) else {
            throw refused(effective(wanted, mode, hasKey: true)) ? .notOffered : .keyMissing
        }
        self[mode] = wanted
    }
    public func effective(_ mode: RecordingMode, hasKey: Bool, openRouterKey: Bool = false) -> ModeConfig {
        effective(self[mode], mode, hasKey: hasKey, openRouterKey: openRouterKey)
    }
    func effective(_ c: ModeConfig, _ mode: RecordingMode, hasKey: Bool, openRouterKey: Bool = false) -> ModeConfig {
        let ok = choices(for: mode, hasKey: hasKey, openRouterKey: openRouterKey)
        return ModeConfig(live: ok.live.contains(c.live) || ok.live.isEmpty ? c.live : .appleLocal,
                          post: ok.post.contains(c.post) ? c.post : .off,
                          language: ok.languages.contains(c.language) ? c.language : .de)
    }
}

/// The one rule for what may leave the Mac (M.9, R-067, R-100): dictation live never, else as chosen with a key.
public struct CloudPolicy: Sendable {
    public enum Use: Sendable { case live, post }
    public let settings: Settings, hasKey: Bool, openRouterKey: Bool
    public init(settings: Settings, hasKey: Bool, openRouterKey: Bool = false) {
        (self.settings, self.hasKey, self.openRouterKey) = (settings, hasKey, openRouterKey)
    }
    /// The after-run service that really runs: the setting narrowed to the keys there are (auto needs one of them).
    public var service: PostService? {
        switch settings.postService {
        case .elevenLabs: hasKey ? .elevenLabs : nil
        case .openRouter: openRouterKey ? .openRouter : nil
        case .auto: hasKey && openRouterKey ? .auto : hasKey ? .elevenLabs : openRouterKey ? .openRouter : nil
        }
    }
    public func allows(_ use: Use, for mode: RecordingMode) -> Bool {
        let c = settings.effective(mode, hasKey: hasKey, openRouterKey: openRouterKey)
        return use == .live ? hasKey && (mode == .call || mode == .room) && c.live == .elevenLabsRealtime
            : service != nil && c.post == .elevenLabs  // never live over OpenRouter
    }
}

public enum CloudOrder: Sendable { case artificial(any RealtimeTransport), explicit(reason: String) }
public enum CloudGateError: Error, Sendable { case notOrdered }

/// Development reaches the real service only with an explicit order (appendix D), logged without its text.
public enum CloudGate {
    public static func realtimeTransport(profile: Profile, order: CloudOrder?,
                                         log: EventLog? = nil) throws -> any RealtimeTransport {
        if case .artificial(let transport) = order { return transport }
        try check(profile, order, log)
        return WebSocketTransport()
    }
    /// The only way to a live session on the real service: `policy` is asked before every connection.
    public static func liveRecognizer(mode: RecordingMode, policy: @escaping Policy, profile: Profile,
                                      order: CloudOrder?, keys: CloudKeys,
                                      clock: any Clock<Duration> = ContinuousClock(), log: EventLog) throws
        -> ElevenLabsLiveRecognizer {
        ElevenLabsLiveRecognizer(transport: try realtimeTransport(profile: profile, order: order, log: log), keys: keys,
                                 clock: clock, log: log, profile: profile, order: order,
                                 permit: { await policy().allows(.live, for: mode) })
    }
    /// The after-run service, `policy` asked before every upload (none: nothing is sent); speaker from the account.
    public static func batchService(profile: Profile, order: CloudOrder?, log: EventLog? = nil,
                                    speakerName: String = String(NSFullUserName().split(separator: " ").first ?? "Ich"),
                                    badge: CloudBadge? = nil, keychain: any KeychainPort = SystemKeychain(),
                                    policy: @escaping Policy = { CloudPolicy(settings: .defaults(for: .production),
                                                                             hasKey: false) },
                                    pieces: PieceCut? = nil, costs: UsageMeter? = nil,
                                    models: [OpenRouterModel] = OpenRouterModels.load()) throws -> any PostProcessor {
        try check(profile, order, log)
        let permit: @Sendable (RecordingMode) async -> Bool = { await policy().allows(.post, for: $0) }
        let elevenLabs = ElevenLabsBatch(keys: CloudKeys(keychain: keychain, profile: profile),
                                         speakerName: speakerName, badge: badge, permit: permit)
        let openRouter = pieces.map { cut in  // without a cutter (`AudioPieces.cut`) OpenRouter is not offered
            OpenRouterBatch(keys: CloudKeys(keychain: keychain, profile: profile, provider: .openRouter),
                            speakerName: speakerName, badge: badge, permit: permit, send: OpenRouterBatch.post,
                            cut: cut, catalog: models,
                            costs: costs)
        }
        return CloudPost(elevenLabs: elevenLabs, openRouter: openRouter, policy: policy, log: log)
    }
    public typealias Policy = @Sendable () async -> CloudPolicy
    public typealias PieceCut = @Sendable (URL, Range<Double>, String) async throws -> (data: Data, seconds: Double)
    static func check(_ profile: Profile, _ order: CloudOrder?, _ log: EventLog?) throws {
        guard profile == .development else { return }
        guard case .explicit = order else { throw CloudGateError.notOrdered }
        log?.record(LogEvent("cloud_dev_order"))
    }
}
