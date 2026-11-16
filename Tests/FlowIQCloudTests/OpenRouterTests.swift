import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQCloud

/// OpenRouter after-run (16.11.) against an artificial service: no network, no real key.
struct OpenRouterTests {
    typealias Keychain = PolicyGateTests.Keychain

    /// Answers by window start; records every request.
    final class Service: Sendable {
        let requests = Mutex<[URLRequest]>([])
        let answer: @Sendable (Double, Int) -> (Data, Int)  // window start, call number
        init(_ answer: @escaping @Sendable (Double, Int) -> (Data, Int)) { self.answer = answer }
        func send(_ r: URLRequest) async throws -> (Data, Int) {
            let n = requests.withLock { $0.append(r); return $0.count }
            let body = try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
            let audio = (body["input_audio"] as? [String: Any])?["data"] as? String ?? ""
            let start = Double(String(decoding: Data(base64Encoded: audio) ?? Data(), as: UTF8.self)) ?? -1
            return answer(start, n)
        }
        func bodies() throws -> [[String: Any]] {
            try requests.withLock { $0 }.map {
                try #require(JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any])
            }
        }
    }

    static func json(_ object: Any) -> Data {
        do { return try JSONSerialization.data(withJSONObject: object) } catch { return Data() }
    }
    static func word(_ text: String, _ start: Double, _ speaker: String?) -> [String: Any] {
        var w: [String: Any] = ["word": text, "start": start, "end": start + 0.4, "type": "word"]
        if let speaker { w["speaker"] = speaker }
        return w
    }

    static let mai = OpenRouterModel(id: "microsoft/mai-transcribe-2", name: "MAI", usdPerHour: 0.1, words: true,
                                     speakers: true, format: "flac", hint: "")
    static func batch(_ service: Service, seconds: Double = 1_500, key: Bool = true, costs: UsageMeter? = nil,
                      allowed: Bool = true) throws -> OpenRouterBatch {
        let keys = CloudKeys(keychain: Keychain(), profile: .production, provider: .openRouter)
        if key { try keys.store("sk-or-test") }
        return OpenRouterBatch(keys: keys, speakerName: "Anna", badge: nil, permit: { _ in allowed },
                               send: { try await service.send($0) },
                               cut: { _, w, _ in (Data(String(w.lowerBound).utf8), seconds) },
                               catalog: OpenRouterModels.fallback + [mai], costs: costs)
    }

    static func job(_ mode: RecordingMode = .room, _ file: String = "raum.m4a") -> PostJob {
        PostJob(audio: [URL(filePath: "/nonexistent/\(file)")], language: "de", terms: ["Sorbal"], mode: mode)
    }

    @Test func theRequestFollowsTheDocumentedWireFormat() async throws {
        let service = Service { _, _ in (Self.json(["words": [Self.word("hallo", 1, "speaker_0")]]), 200) }
        _ = try await Self.batch(service, seconds: 30).run(Self.job(), model: "elevenlabs/scribe-v2")
        let r = try #require(service.requests.withLock { $0.first })
        #expect(r.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(!(r.url?.absoluteString.contains("sk-or") ?? true), "the key never goes into the URL")
        let body = try #require(try service.bodies().first)
        #expect(body["model"] as? String == "elevenlabs/scribe-v2" && body["language"] as? String == "de")
        #expect(body["response_format"] as? String == "verbose_json")
        #expect(body["timestamp_granularities"] as? [String] == ["word"] && body["keyterms"] as? [String] == ["Sorbal"])
        #expect((body["input_audio"] as? [String: Any])?["format"] as? String == "m4a")
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["data_collection"] as? String == "deny" && provider["allow_fallbacks"] as? Bool == false)
        let options = (provider["options"] as? [String: Any])?["elevenlabs"] as? [String: Any]
        #expect(options?["diarize"] as? Bool == true && options?["num_speakers"] as? Int == 8)
    }

    /// 1,500 s give two pieces, windows 0..<610 and 590..<1500; the overlap words come twice, once each piece keeps;
    /// the second piece calls the same voice "speaker_1", matched back over the overlap.
    @Test func piecesMergeWithoutDoublingAndSpeakersFollowTheOverlap() async throws {
        let service = Service { start, _ in
            let words = start == 0
                ? [Self.word("eins", 100, "speaker_0"), Self.word("naht", 595, "speaker_0"),
                   Self.word("zwei", 605, "speaker_0")]
                : [Self.word("naht", 5, "speaker_1"), Self.word("zwei", 15, "speaker_1"),
                   Self.word("drei", 400, "speaker_1")]
            return (Self.json(["words": words]), 200)
        }
        let result = try await Self.batch(service).run(Self.job(), model: "elevenlabs/scribe-v2")
        #expect(service.requests.withLock { $0.count } == 2)
        #expect(result.segments.map(\.text) == ["eins naht zwei drei"])
        #expect(result.segments.map(\.speaker) == ["speaker_0"] && result.source == "openrouter/elevenlabs/scribe-v2")
    }

    @Test func aPieceThatFailsTwiceIsMarkedTheRestStays() async throws {
        let service = Service { start, _ in
            start == 0 ? (Self.json(["words": [Self.word("eins", 100, "speaker_0")]]), 200) : (Data(), 500)
        }
        let result = try await Self.batch(service).run(Self.job(), model: "elevenlabs/scribe-v2")
        #expect(service.requests.withLock { $0.count } == 3, "one try for the first, two for the failing piece")
        #expect(result.segments.map(\.text) == ["eins", "[Abschnitt 00:10:00 bis 00:25:00 nicht erkannt]"])
        let all = Service { _, _ in (Data(), 500) }
        await #expect(throws: PostFailure.piecesFailed) { try await Self.batch(all).run(Self.job(), model: "x") }
    }

    @Test func aModelWithoutWordTimesOrSpeakersGivesOneSpeakerPerPiece() async throws {
        let service = Service { start, _ in (Self.json(["text": start == 0 ? "erster teil" : "zweiter teil"]), 200) }
        let costs = UsageMeter(folder: FileManager.default.temporaryDirectory.appending(path: "flowiq-or-\(UUID())"),
                               fs: SafeFS(confinedTo: FileManager.default.temporaryDirectory))
        let result = try await Self.batch(service, costs: costs).run(Self.job(), model: "elevenlabs/scribe-v2")
        #expect(result.segments.map(\.text) == ["erster teil zweiter teil"] && result.speakersDetected == 1)
        #expect(result.segments.map(\.speaker) == ["Raum"], "a model without speakers names the track")
        let expected = 0.2196 * (610 + 910) / 3600  // catalog price per hour, windows 0..<610 and 590..<1500
        #expect(abs(await costs.costUSD("openrouter") - expected) < 1e-9)
    }

    @Test func noSendingWithoutKeyOrSwitch() async throws {
        let service = Service { _, _ in (Data(), 200) }
        await #expect(throws: PostFailure.keyMissing) {
            try await Self.batch(service, key: false).run(Self.job(), model: "elevenlabs/scribe-v2")
        }
        await #expect(throws: PostFailure.notAllowed) {
            try await Self.batch(service, allowed: false).run(Self.job(), model: "elevenlabs/scribe-v2")
        }
        #expect(service.requests.withLock { $0.isEmpty })
        #expect(throws: CloudGateError.self) {
            try CloudGate.batchService(profile: .development, order: nil,
                                              pieces: { _, _, _ in (Data(), 0) })
        }
    }

    /// Auto: ElevenLabs without its key falls back to OpenRouter; OpenRouter alone needs its own key.
    @Test func autoFallsBackToOpenRouterAndThePolicyPicksTheService() async throws {
        let service = Service { _, _ in (Self.json(["words": [Self.word("hallo", 1, "speaker_0")]]), 200) }
        let keychain = Keychain()
        try CloudKeys(keychain: keychain, profile: .production, provider: .openRouter).store("sk-or-test")
        let elevenLabs = ElevenLabsBatch(keys: CloudKeys(keychain: keychain, profile: .production),
                                         permit: { _ in true })
        var settings = Settings.defaults(for: .production)
        settings[.room] = ModeConfig(live: .appleLocal, post: .elevenLabs, language: .de)
        for (service2, hasKey, orKey, expected) in [(PostService.auto, true, true, PostService.auto),
                                                     (.auto, false, true, .openRouter),
                                                     (.openRouter, true, false, nil)] {
            settings.postService = service2
            let policy = CloudPolicy(settings: settings, hasKey: hasKey, openRouterKey: orKey)
            #expect(policy.service == expected)
        }
        settings.postService = .auto
        let policy = CloudPolicy(settings: settings, hasKey: true, openRouterKey: true)
        let post = CloudPost(elevenLabs: elevenLabs, openRouter: try Self.batch(service, seconds: 30),
                             policy: { policy }, log: nil)
        let result = try await post.process(Self.job())
        #expect(result.source == "openrouter/elevenlabs/scribe-v2" && service.requests.withLock { $0.count } == 1)
        let off = CloudPost(elevenLabs: elevenLabs, openRouter: try Self.batch(service, seconds: 30),
                            policy: { [settings] in CloudPolicy(settings: settings, hasKey: false) }, log: nil)
        await #expect(throws: PostFailure.notAllowed) { try await off.process(Self.job()) }
    }

    @Test func eachModelGetsItsUploadFormatAndTheCatalogLoads() async throws {
        let service = Service { _, _ in (Self.json(["words": [Self.word("hallo", 1, "speaker_0")]]), 200) }
        _ = try await Self.batch(service, seconds: 30).run(Self.job(), model: "microsoft/mai-transcribe-2")
        #expect((try service.bodies().first?["input_audio"] as? [String: Any])?["format"] as? String == "flac")
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Cloud/openrouter-modelle.json")
        let list = OpenRouterModels.load(file)
        #expect(list.map(\.id).sorted() == ["elevenlabs/scribe-v2", "microsoft/mai-transcribe-2",
                                            "moondream/parakeet-ultra", "x-ai/grok-stt-2.0"])
        #expect(OpenRouterModels.load(nil) == OpenRouterModels.fallback)
    }
}
