// Group F3-6: ElevenLabs Realtime on an artificial transport (ARCHITEKTUR M.4, M.5 stage 1, Anhang I new file
// `CloudLiveTests`; R-103, R-104, R-105). The documented wire format [D] was never tried with a key; every wire
// detail therefore sits in `Wire` of the support file, marked ASSUMPTION. Covered here: request building (key as header
// only, parameters), PCM16 16 kHz in 200 ms packets, events and error kinds, commit at pauses (at the latest after
// 15 s, never more often than every 3 s), reconnect with `previous_text` and resending, terms at most 50 of at most
// 20 characters from confirmed entries only, and the latency of a sentence into the event stream with a 150 ms service.
import Foundation
import FlowIQLog
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQStore
import FlowIQText  // COMPILE-FIX (P5 build): the file names CanonEntry without importing its module

/// The PCM bytes of one audio message.
private func pcm(_ message: [String: Any]) -> Data { Data(base64Encoded: (message[Wire.audioField] as? String) ?? "") ?? Data() }

@Suite(.timeLimit(.minutes(5)))
struct CloudLiveWireTests {
    private struct Rig {
        let clock = ManualClock()
        let transport = FakeTransport()
        let scratch: Scratch
        let recognizer: ElevenLabsLiveRecognizer
        var hostTime: UInt64 = 1_000_000_000

        init(language: RecordingLanguage = .de, track: TrackKind = .microphone, terms: [String] = [], anchor: Double = 0) async throws {
            scratch = try Scratch()
            let keys = CloudKeys(keychain: FakeKeychain(), profile: .development)  // ASSUMPTION: assumed API, see the Support header
            try keys.store("sk_test_WIRE")  // ASSUMPTION: assumed API, see the Support header
            let log = EventLog(directory: scratch.paths.support, fs: scratch.fs)
            recognizer = ElevenLabsLiveRecognizer(transport: transport, keys: keys, clock: clock, log: log)  // ASSUMPTION: ElevenLabsLiveRecognizer(transport:keys:clock:log:)
            try await recognizer.start(LiveSetup(language: language, terms: terms, track: track, anchor: anchor, previousText: nil, backlog: []))  // ASSUMPTION: LiveSetup(language:terms:track:anchor:previousText:backlog:); track is a TrackKind
        }

        func remove() { scratch.remove() }

        var connection: FakeConnection? { transport.last }

        /// Audio in 100 ms pieces of 48 kHz while the clock runs.
        mutating func play(_ seconds: Double, loud: Bool = true, piece: Double = 0.1) async {
            for _ in 0..<Int((seconds / piece).rounded()) {
                recognizer.feed(audio(at: hostTime, seconds: piece, loud: loud))  // ASSUMPTION: assumed API, see the Support header
                hostTime += UInt64(piece * 1e9)
                await clock.run(for: .milliseconds(Int(piece * 1000)))
            }
        }

        /// Audio seconds in the audio messages of one connection (200 ms packets, remainders included).
        func sentSeconds(on connection: FakeConnection?) -> Double {
            (connection?.audioMessages ?? []).reduce(0) { $0 + Double(pcm($1).count) / 2 / 16_000 }
        }

        /// Audio seconds before each commit message (the commit flag rides on an audio message).
        func commitTimes() -> [Double] {
            var seconds = 0.0
            var times: [Double] = []
            for message in connection?.audioMessages ?? [] {
                seconds += Double(pcm(message).count) / 2 / 16_000
                if (message[Wire.commitField] as? Bool) == true { times.append(seconds) }
            }
            return times
        }
    }

    // MARK: request

    @Test(arguments: [RecordingLanguage.de, .en])
    func theRequestCarriesTheDocumentedParameters(_ language: RecordingLanguage) async throws {
        let rig = try await Rig(language: language)
        defer { rig.remove() }
        let url = try #require(rig.connection?.request.url)
        let items = Dictionary(grouping: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [], by: \.name).mapValues { $0.compactMap(\.value) }
        #expect(url.path == "/v1/speech-to-text/realtime")
        #expect(items["model_id"] == ["scribe_v3_live"])
        #expect(items["audio_format"] == ["pcm_16000"])
        #expect(items["language_code"] == [language == .de ? "de" : "en"], "the language of the recording, fixed")
        #expect(items["commit_strategy"] == ["manual"])
        #expect(items["include_timestamps"] == ["true"])
        #expect(items["diarize"] == nil, "no speaker separation on the microphone track")
    }

    @Test func theDesktopTrackAsksForSpeakerSeparation() async throws {
        let rig = try await Rig(track: .desktop)
        defer { rig.remove() }
        let query = rig.connection?.request.url?.query ?? ""
        #expect(query.contains("diarize=true"))
    }

    @Test func termsAreOnlyConfirmedEntriesAtMostFiftyOfAtMostTwentyCharacters() throws {
        var entries: [CanonEntry] = []
        for i in 0..<70 { entries.append(entry(i % 3 == 0 ? "Sehr-Langer-Eintragsname-\(i)" : "Begriff\(i)")) }  // every third is longer than 20 characters
        entries += [entry("Vorschlag", status: .proposed), entry("Ausgemustert", status: .retired)]
        let terms = CloudTerms.live(from: entries)  // ASSUMPTION: CloudTerms.live(from:) -> [String]
        #expect(terms.count <= 50)
        #expect(!terms.isEmpty)
        #expect(terms.allSatisfy { $0.count <= 20 })
        #expect(!terms.contains("Vorschlag") && !terms.contains("Ausgemustert"))
        #expect(Set(terms).count == terms.count)
        #expect(Set(terms).isSubset(of: Set(entries.filter { $0.status == .confirmed }.map(\.canonical))))
        #expect(terms == CloudTerms.live(from: entries.reversed()), "the choice must not depend on the order of the entries")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theRequestCarriesExactlyTheGivenTerms() async throws {
        let rig = try await Rig(terms: ["Alpha", "Beta Gamma"])
        defer { rig.remove() }
        let items = URLComponents(url: try #require(rig.connection?.request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "keyterms" }.compactMap(\.value).sorted() == ["Alpha", "Beta Gamma"])  // ASSUMPTION: one `keyterms` query item per term
    }

    // MARK: audio

    @Test func audioGoesOutAsPcm16At16kHzInPacketsOf200ms() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(1.0, piece: 0.02)  // fifty 20 ms chunks of 48 kHz
        let messages = rig.connection?.audioMessages ?? []
        #expect(messages.count == 5)
        for message in messages {
            let bytes = pcm(message)
            #expect(bytes.count == 6400, "200 ms of 16 kHz mono PCM16 are 6400 bytes, got \(bytes.count)")
            #expect((message[Wire.sampleRateField] as? Int) ?? 16_000 == 16_000)
            let peak = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int32(Int16(littleEndian: $0))) }.max() ?? 0 }
            #expect(peak > Int32(0.3 * 32_767) && peak < Int32(0.5 * 32_767), "the converted tone lost or gained level: \(peak)")
        }
    }

    @Test func aRemainderStaysBufferedAndIsFlushedWithTheEnd() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(1.1, piece: 0.02)
        #expect(rig.connection?.audioMessages.count == 5, "the half packet must wait")
        await rig.recognizer.finish()
        let last = try #require(rig.connection?.audioMessages.last)
        #expect(pcm(last).count == 3200, "100 ms remainder = 1600 samples = 3200 bytes")
        #expect((last[Wire.commitField] as? Bool) == true, "the end commits")
    }

    @Test func everyPacketReportsItsSecondsToTheCounter() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        let recognizer = rig.recognizer
        let reader = Task { () -> Double in
            var sent = 0.0
            for await event in recognizer.events {
                if case .sent(let seconds) = event { sent += seconds }  // ASSUMPTION: assumed API, see the Support header
                if sent >= 0.999 { break }
            }
            return sent
        }
        await rig.play(1.0, piece: 0.02)
        let total = await reader.value
        #expect(abs(total - 1.0) < 0.0001, "the .sent events add up to \(total) s for 1.0 s of audio")  // ASSUMPTION: LiveEvent.sent(seconds:) once per 200 ms packet
    }

    // MARK: events and errors

    @Test func partialsAndCommitsBecomeEventsWithTimesFromTheRecordingStart() async throws {
        let rig = try await Rig(anchor: 100)
        defer { rig.remove() }
        var iterator = rig.recognizer.events.makeAsyncIterator()
        rig.connection?.serve(#"{"message_type":"\#(Wire.partial)","text":"hal"}"#)
        rig.connection?.serve(Wire.committedMessage(segment(marks(seconds: 1.0))))
        guard case .partial(let text)? = await iterator.next() else { Issue.record("no partial event"); return }  // ASSUMPTION: assumed API, see the Support header COMPILE-FIX (P5 build): Issue.record returns a value, `return` of it in a Void function does not compile
        #expect(text == "hal")
        guard case .committed(let seg)? = await iterator.next() else { Issue.record("no committed event"); return }  // ASSUMPTION: assumed API, see the Support header COMPILE-FIX (P5 build): Issue.record returns a value, `return` of it in a Void function does not compile
        #expect(seg.words.map(\.text) == ["s0", "s1"])
        #expect(seg.words.map(\.start) == [100.0, 100.5], "word times are seconds from the recording start: the anchor plus the service's time")
        #expect(seg.speaker == nil, "the microphone track gets its speaker name from the store")
    }

    @Test func theDesktopTrackNamesTheOtherSide() async throws {
        let rig = try await Rig(track: .desktop)
        defer { rig.remove() }
        var iterator = rig.recognizer.events.makeAsyncIterator()
        rig.connection?.serve(#"{"message_type":"\#(Wire.committed)","text":"a","words":[{"text":"a","start":0.0,"end":0.4,"type":"word"}]}"#)
        rig.connection?.serve(#"{"message_type":"\#(Wire.committed)","text":"b","words":[{"text":"b","start":1.0,"end":1.4,"type":"word","speaker_id":"speaker_2"}]}"#)  // ASSUMPTION: word field speaker_id
        guard case .committed(let first)? = await iterator.next(), case .committed(let second)? = await iterator.next() else { Issue.record("missing events"); return }  // ASSUMPTION: assumed API, see the Support header COMPILE-FIX (P5 build): Issue.record returns a value, `return` of it in a Void function does not compile
        #expect(first.speaker == "Gegenseite")
        #expect(second.speaker == "Gegenseite (speaker_2)")
    }

    @Test(arguments: Wire.errorTypes.map { ($0.0, $0.1) })
    func everyServiceErrorKindMapsToItsFailure(_ type: String, _ expected: LiveFailure) async throws {  // ASSUMPTION: assumed API, see the Support header
        let rig = try await Rig()
        defer { rig.remove() }
        rig.connection?.serve(#"{"message_type":"\#(type)","error":"x"}"#)
        var iterator = rig.recognizer.events.makeAsyncIterator()
        var failure: LiveFailure?  // ASSUMPTION: assumed API, see the Support header
        while let event = await iterator.next() {
            if case .failure(let f) = event { failure = f; break }  // ASSUMPTION: assumed API, see the Support header
        }
        #expect(failure == expected, "\(type)")
    }

    // MARK: commit rule

    @Test func aPauseOfAtLeast400msCommitsOnce() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(5)
        await rig.play(0.6, loud: false)
        await rig.play(1)
        let commits = rig.commitTimes()
        #expect(commits.count == 1)
        #expect((5.3...5.9).contains(commits.first ?? 0), "commit at \(commits.first ?? 0) s")
    }

    @Test func continuousSpeechCommitsAtTheLatestAfterFifteenSeconds() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(40)
        let commits = rig.commitTimes()
        #expect(commits.count >= 2)
        let gaps = zip([0.0] + commits, commits).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 <= 15.2 }, "gaps between commits: \(gaps)")
    }

    @Test func neverMoreOftenThanEveryThreeSeconds() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        for _ in 0..<12 {  // 1.0 s speech, 0.5 s pause, twelve times
            await rig.play(1.0)
            await rig.play(0.5, loud: false)
        }
        let commits = rig.commitTimes()
        #expect(!commits.isEmpty)
        #expect((commits.first ?? 0) >= 3.0)
        let gaps = zip(commits, commits.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= 3.0 - 0.0001 }, "commits closer than 3 s: \(gaps)")
    }

    // MARK: reconnect (stage 1)

    @Test func aDroppedConnectionIsReplacedWithin1sCarryingPreviousTextAndTheUncommittedAudio() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(4)
        await rig.play(0.6, loud: false)  // the pause makes the recognizer send its commit
        rig.connection?.serve(Wire.committedMessage(segment(marks(seconds: 2.0))))  // the service answers: s0 ... s3
        await rig.clock.run(for: .milliseconds(50))
        await rig.play(3)  // heard after the commit
        rig.connection?.drop()
        await rig.clock.run(for: .seconds(1))
        #expect(rig.transport.connections.count == 2, "no new session within 1 s")
        let first = try #require(rig.connection?.audioMessages.first)
        let previous = try #require(first[Wire.previousTextField] as? String)  // ASSUMPTION: assumed API, see the Support header
        #expect(previous == "s0 s1 s2 s3" && previous.count <= 50)
        #expect(rig.connection?.audioMessages.dropFirst().allSatisfy { $0[Wire.previousTextField] == nil } == true, "previous_text only on the first packet")  // ASSUMPTION: assumed API, see the Support header
        let resent = rig.sentSeconds(on: rig.connection)
        #expect(abs(resent - 3.0) < 0.5, "the new session got \(resent) s of backlog, expected the 3 s since the commit")  // ASSUMPTION: the ring starts at the last commit the recognizer sent
        await rig.play(1)
        #expect((rig.connection?.audioMessages.count ?? 0) > 15, "live audio continues on the new connection")
    }

    @Test func previousTextIsAtMostTheLastFiftyCharacters() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(2)
        let long = LiveSegment(words: (0..<40).map { TimedWord(text: "wort\($0)", start: Double($0) * 0.05, end: Double($0) * 0.05 + 0.04, confidence: nil) }, speaker: nil)
        rig.connection?.serve(Wire.committedMessage(long))
        await rig.clock.run(for: .milliseconds(50))
        rig.connection?.drop()
        await rig.play(1)
        let previous = try #require(rig.connection?.audioMessages.first?[Wire.previousTextField] as? String)  // ASSUMPTION: assumed API, see the Support header
        #expect(previous.count <= 50)
        #expect(previous.hasSuffix("wort39"))
    }

    @Test func whenTheReconnectFailsWithinFiveSecondsTheRecognizerReportsAFailure() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        await rig.play(3)
        rig.transport.refuseConnections(with: TestError())
        rig.connection?.drop()
        let recognizer = rig.recognizer
        let waiter = Task { () -> LiveFailure? in  // ASSUMPTION: assumed API, see the Support header
            var iterator = recognizer.events.makeAsyncIterator()
            while let event = await iterator.next() {
                if case .failure(let f) = event { return f }  // ASSUMPTION: assumed API, see the Support header
            }
            return nil
        }
        await rig.clock.run(for: .seconds(5))
        let failure = await waiter.value
        #expect(failure != nil, "no failure event 5 s after the connection died and could not be restored")
    }

    // MARK: latency with a service that answers in 150 ms (R-105)

    @Test func sentenceEndToCommittedEventTakesAtMostFiveSecondsOver100Sentences() async throws {
        var rig = try await Rig()
        defer { rig.remove() }
        let clock = rig.clock
        let transport = rig.transport
        let sentence = Mutex(0)
        transport.onSend { text in  // the artificial service: 150 ms after a commit it answers with the sentence
            guard (Wire.decode(text)[Wire.commitField] as? Bool) == true else { return }
            let k = sentence.withLock { s -> Int in defer { s += 1 }; return s }
            Task {
                do { try await clock.sleep(for: .milliseconds(150)) } catch { return }
                let base = Double(k) * 3.5
                let words = (0..<6).map { TimedWord(text: "s\(k * 6 + $0)", start: base + Double($0) * 0.5, end: base + Double($0) * 0.5 + 0.4, confidence: nil) }
                transport.last?.serve(Wire.committedMessage(LiveSegment(words: words, speaker: nil)))
            }
        }
        let arrivals = Mutex<[Double]>([])
        let recognizer = rig.recognizer
        let reader = Task {
            for await event in recognizer.events {
                if case .committed = event { arrivals.withLock { $0.append(clock.now.offset.ms / 1000) } }
            }
        }
        for _ in 0..<100 {  // 3.0 s speech, 0.5 s pause
            await rig.play(3.0, piece: 0.5)
            await rig.play(0.5, loud: false, piece: 0.5)
        }
        await rig.clock.run(for: .seconds(2))
        reader.cancel()
        let got = arrivals.withLock { $0 }
        #expect(got.count >= 100, "\(got.count) committed events for 100 sentences")
        let startOffset = 1.0  // the manual clock starts at one second
        let latencies = got.prefix(100).enumerated().map { $1 - (startOffset + Double($0) * 3.5 + 3.0) }
        #expect(percentile(latencies, 0.95) <= 5.0, "p95 \(percentile(latencies, 0.95)) s")
        #expect((latencies.max() ?? 0) <= 15.2)
    }
}
