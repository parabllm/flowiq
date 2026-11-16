import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQCloud

/// The ElevenLabs after-run against an artificial service that checks a request the way the documentation of
/// `POST /v1/speech-to-text` describes it (read 16.11.2026): no network, no real key, invented words only.
struct ElevenLabsWireTests {
    typealias Keychain = PolicyGateTests.Keychain
    struct Part { let name: String, filename: String?, type: String?, value: String }

    /// Refuses what the documentation refuses, with the documented error body; records every request.
    final class Service: Sendable {
        let requests = Mutex<[URLRequest]>([])
        let status: Int?  // a fixed answer status instead of the check
        init(status: Int? = nil) { self.status = status }
        static func parts(_ r: URLRequest) -> [Part] {
            let header = r.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard header.hasPrefix("multipart/form-data; boundary="), let body = r.httpBody else { return [] }
            let boundary = "--" + header.dropFirst("multipart/form-data; boundary=".count)
            let text = String(decoding: body, as: UTF8.self)
            return text.components(separatedBy: boundary).dropFirst().compactMap { piece -> Part? in
                guard piece.hasPrefix("\r\n"), let split = piece.range(of: "\r\n\r\n") else { return nil }
                let head = String(piece[..<split.lowerBound])
                let value = String(piece[split.upperBound...].dropLast())  // the closing CRLF is one character
                func quoted(_ key: String) -> String? {
                    head.range(of: key + "=\"").flatMap { from in
                        head[from.upperBound...].firstIndex(of: "\"").map { String(head[from.upperBound..<$0]) }
                    }
                }
                let type = head.range(of: "Content-Type: ").map { String(head[$0.upperBound...]) }
                return Part(name: quoted(" name") ?? "", filename: quoted("filename"), type: type, value: value)
            }
        }
        static func refusal(_ code: String, _ param: String, _ message: String) -> (Data, Int) {
            (OpenRouterTests.json(["detail": ["type": "validation_error", "code": code, "message": message,
                                              "status": code, "request_id": "req_test", "param": param]]), 400)
        }
        func send(_ r: URLRequest) async throws -> (Data, Int) {
            requests.withLock { $0.append(r) }
            if let status { return (OpenRouterTests.json(["detail": ["message": "fixed"]]), status) }
            guard r.value(forHTTPHeaderField: "xi-api-key")?.isEmpty == false else { return (Data(), 401) }
            let parts = Self.parts(r)
            func values(_ name: String) -> [String] { parts.filter { $0.name == name }.map(\.value) }
            guard ["scribe_v3", "scribe_v2", "scribe_v2_medical"].contains(values("model_id").first ?? "") else {
                return Self.refusal("unsupported_model", "model_id", "The model is not supported.")
            }
            let files = parts.filter { $0.name == "file" }
            guard files.count == 1, let file = files.first, file.filename != nil, !file.value.isEmpty else {
                return Self.refusal("missing_required_field", "file", "Exactly one file must be provided.")
            }
            guard file.type?.isEmpty == false else {
                return Self.refusal("invalid_content_type", "file", "The file part has no content type.")
            }
            let language = values("language_code").first ?? "de"
            guard (2...3).contains(language.count), language.allSatisfy(\.isLetter) else {
                return Self.refusal("invalid_parameters", "language_code", "Not an ISO-639-1 or ISO-639-3 code.")
            }
            let terms = values("keyterms"), forbidden = Set("<>{}[]\\")
            guard terms.count <= 1000, terms.allSatisfy({ $0.count <= 50 && $0.split(separator: " ").count <= 5
                && !$0.isEmpty && !$0.contains(where: forbidden.contains) }) else {
                return Self.refusal("invalid_parameters", "keyterms", "A keyterm is longer than 50 characters.")
            }
            guard values("diarize").allSatisfy({ ["true", "false"].contains($0) }),
                  values("timestamps_granularity").allSatisfy({ ["none", "word", "character"].contains($0) }),
                  values("num_speakers").allSatisfy({ (1...32).contains(Int($0) ?? 0) }) else {
                return Self.refusal("invalid_parameters", "diarize", "A parameter has a value outside its range.")
            }
            let words: [[String: Any]] = [["text": "hallo", "start": 0.1, "end": 0.4, "type": "word",
                                           "speaker_id": "speaker_0"],
                                          ["text": " ", "start": 0.4, "end": 0.5, "type": "spacing"],
                                          ["text": "Sorbal", "start": 0.5, "end": 0.9, "type": "word",
                                           "speaker_id": "speaker_0"]]
            return (OpenRouterTests.json(["language_code": "deu", "text": "hallo Sorbal", "words": words]), 200)
        }
    }

    let folder = FileManager.default.temporaryDirectory.appending(path: "flowiq-el-\(UUID().uuidString)")
    func audio(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ADTS-TESTTON".utf8).write(to: folder.appending(path: name))
        return folder.appending(path: name)
    }
    func remove() {
        do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("cleanup failed: \(error)") }
    }
    static func batch(_ service: Service) throws -> ElevenLabsBatch {
        let keys = CloudKeys(keychain: Keychain(), profile: .production)
        try keys.store("sk_test_WIRE")
        var batch = ElevenLabsBatch(keys: keys, permit: { _ in true })
        batch.send = { try await service.send($0) }
        return batch
    }

    @Test func aDictationUploadIsARequestTheDocumentedServiceAccepts() async throws {
        defer { remove() }
        let service = Service()
        let job = PostJob(audio: [try audio("diktat mit leerzeichen.aac")], language: "de",
                          terms: ["Sorbal", "Quellwerk Nord"], mode: .dictation)
        let result = try await Self.batch(service).process(job)
        #expect(result.segments.map(\.text) == ["hallo Sorbal"] && result.segments.map(\.speaker) == ["Ich"])
        let r = try #require(service.requests.withLock { $0.first })
        #expect(r.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "xi-api-key") == "sk_test_WIRE")
        #expect(!String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("sk_test"), "the key is a header only")
        let parts = Service.parts(r)
        func values(_ name: String) -> [String] { parts.filter { $0.name == name }.map(\.value) }
        #expect(values("model_id") == ["scribe_v3"] && values("language_code") == ["de"])
        #expect(values("diarize") == ["false"] && values("timestamps_granularity") == ["word"])
        #expect(values("keyterms") == ["Sorbal", "Quellwerk Nord"], "one `keyterms` part per term")
        #expect(values("num_speakers").isEmpty, "only a room names its speakers")
        let file = try #require(parts.first { $0.name == "file" })
        #expect(file.filename == "audio.aac" && file.type == "application/octet-stream")
        #expect(file.value == "ADTS-TESTTON", "the bytes of the file, unchanged")
    }

    @Test func aRoomUploadAsksForSpeakers() async throws {
        defer { remove() }
        let service = Service()
        let job = PostJob(audio: [try audio("raum.m4a")], language: "en", terms: [], mode: .room)
        let result = try await Self.batch(service).process(job)
        #expect(result.segments.map(\.speaker) == ["speaker_0"])
        let parts = Service.parts(try #require(service.requests.withLock { $0.first }))
        func values(_ name: String) -> [String] { parts.filter { $0.name == name }.map(\.value) }
        #expect(values("diarize") == ["true"] && values("num_speakers") == ["8"] && values("language_code") == ["en"])
        #expect(parts.first { $0.name == "file" }?.filename == "audio.m4a")
    }

    /// 400 is a wrong request: it ends as `rejected` with the answer's code, field and message, never as a
    /// failure that is tried again every minute (16.11.: seventeen dictations, four tries each within minutes).
    @Test func aRefusedRequestCarriesTheReasonOfTheAnswer() async throws {
        defer { remove() }
        let service = Service(), long = String(repeating: "x", count: 51)
        let job = PostJob(audio: [try audio("diktat.aac")], language: "de", terms: [long], mode: .dictation)
        let expected = "400 invalid_parameters keyterms A keyterm is longer than 50 characters."
        await #expect(throws: PostFailure.rejected(expected)) { try await Self.batch(service).process(job) }
        #expect(PostFailure.rejected(expected).sent, "the audio left the Mac")
    }

    @Test func everyAnswerStatusHasItsFailure() async throws {
        defer { remove() }
        let job = PostJob(audio: [try audio("diktat.aac")], language: "de", terms: [], mode: .dictation)
        for (status, failure) in [(401, PostFailure.keyMissing), (402, .quotaExhausted), (429, .quotaExhausted),
                                  (503, .server(status: 503)), (422, .rejected("422 fixed"))] {
            await #expect(throws: failure) { try await Self.batch(Service(status: status)).process(job) }
        }
        let list = OpenRouterTests.json(["detail": [["loc": ["body", "model_id"], "msg": "Field required",
                                                     "type": "missing"]]])
        #expect(OpenRouterBatch.failure(422, list) == .rejected("422 missing body.model_id Field required"))
        #expect(OpenRouterBatch.failure(400, Data("<html>".utf8)) == .rejected("400 "), "no JSON, no reason")
        let open = OpenRouterTests.json(["error": ["code": 400, "message": "diarize requires verbose_json"]])
        #expect(OpenRouterBatch.failure(400, open) == .rejected("400 400 diarize requires verbose_json"))
        let wordy = OpenRouterTests.json(["detail": ["message": String(repeating: "lang ", count: 100)]])
        guard case .rejected(let text) = OpenRouterBatch.failure(400, wordy) else {
            Issue.record("a 400 must be rejected")
            return
        }
        #expect(text.count == 200, "the reason is cut, the log line stays small")
    }
}
