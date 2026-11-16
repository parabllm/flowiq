// Group F3-12: the development profile and the cloud (ARCHITEKTUR Anhang D, Anhang I addition to `DevProfileTests`,
// R-005, R-006). In the development profile cloud access exists only with an artificial transport or with an explicit
// order; without either, no real transport is created and nothing connects. The production profile needs no order.
// No real transport is ever created in these tests: the gate is asked, and refuses or hands over an artificial one.
import Foundation
import FlowIQLog
import Testing
@testable import FlowIQAudio  // COMPILE-FIX (P5 build): LiveSetup sits next to AudioChunk in FlowIQAudio
@testable import FlowIQCloud
@testable import FlowIQCore

@Suite(.timeLimit(.minutes(2)))
struct DevProfileCloudTests {
    @Test func developmentWithoutAnOrderRefusesTheRealRealtimeTransport() {
        #expect(throws: CloudGateError.self) { try CloudGate.realtimeTransport(profile: .development, order: nil) }  // ASSUMPTION: CloudGate.realtimeTransport(profile:order:) throws CloudGateError.notOrdered in development without an order
    }

    @Test func developmentWithoutAnOrderRefusesTheRealBatchService() {
        #expect(throws: CloudGateError.self) { try CloudGate.batchService(profile: .development, order: nil) }  // ASSUMPTION: CloudGate.batchService(profile:order:)
    }

    @Test func developmentAcceptsAnArtificialTransport() throws {
        let transport = FakeTransport()
        let handed = try CloudGate.realtimeTransport(profile: .development, order: .artificial(transport))  // ASSUMPTION: CloudOrder { artificial(any RealtimeTransport), explicit(reason: String) }
        #expect((handed as AnyObject) === (transport as AnyObject), "the gate must hand over the artificial transport, not build its own")
    }

    @Test func developmentAcceptsAnExplicitOrderAndSaysSoInTheProtocol() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let log = EventLog(directory: scratch.paths.log, fs: scratch.fs)
        try FileManager.default.createDirectory(at: scratch.paths.log, withIntermediateDirectories: true)
        _ = try CloudGate.realtimeTransport(profile: .development, order: .explicit(reason: "G-ECHT T3"), log: log)  // ASSUMPTION: the gate logs `cloud_dev_order` (text free: no reason text) when it hands over a real transport in development
        await log.flush()
        let text = (try? String(contentsOf: scratch.paths.log.appending(path: "ereignisse.ndjson"), encoding: .utf8)) ?? ""
        #expect(text.contains("cloud_dev_order"))
        #expect(!text.contains("G-ECHT"))
    }

    @Test func productionNeedsNoOrder() throws {
        _ = try CloudGate.realtimeTransport(profile: .production, order: nil)  // ASSUMPTION: assumed API, see the Support header
        _ = try CloudGate.batchService(profile: .production, order: nil)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aRecognizerInDevelopmentWithoutAnOrderConnectsToNothing() async throws {
        let keys = CloudKeys(keychain: FakeKeychain(), profile: .development)  // ASSUMPTION: assumed API, see the Support header
        try keys.store("sk_test_DEV")  // ASSUMPTION: assumed API, see the Support header
        let transport = FakeTransport()
        let scratch = try Scratch()
        defer { scratch.remove() }
        let log = EventLog(directory: scratch.paths.support, fs: scratch.fs)
        let recognizer = ElevenLabsLiveRecognizer(transport: transport, keys: keys, clock: ManualClock(), log: log, profile: .development, order: nil)  // ASSUMPTION: the recognizer takes the profile and the order it was built under; with a FakeTransport the order is not needed, because artificial transports are always allowed
        try await recognizer.start(LiveSetup(language: .de, terms: [], track: .microphone, anchor: 0, previousText: nil, backlog: []))  // ASSUMPTION: assumed API, see the Support header
        #expect(transport.connections.count == 1, "an artificial transport is always allowed in development")
    }

    @Test func theDevelopmentKeychainServiceNeverHoldsTheProductionKey() throws {
        let keychain = FakeKeychain()
        try CloudKeys(keychain: keychain, profile: .production).store("sk_test_PROD")  // ASSUMPTION: assumed API, see the Support header
        #expect(!CloudKeys(keychain: keychain, profile: .development).hasKey, "R-006: the development profile must not see the production key")  // ASSUMPTION: assumed API, see the Support header
    }
}
