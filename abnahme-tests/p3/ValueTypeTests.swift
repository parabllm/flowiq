// Group 8: value types instead of shared buffers (Leitsatz 3, E1, G02/S20; Panotti crashed on a
// shared buffer on 25.10.). No consumer can change what another consumer holds.
import Foundation
import Testing
@testable import FlowIQAudio

private func requireSendable<T: Sendable>(_: T.Type) {}

struct ValueTypeTests {
    @Test func chunkAndLeasesAreSendableValues() {
        requireSendable(AudioChunk.self)  // compile-time check
        requireSendable(MicLease.self)
        #expect(Mirror(reflecting: chunk([0.1], at: 0)).displayStyle == .struct)
        for child in Mirror(reflecting: chunk([0.1], at: 0)).children {
            #expect(!(type(of: child.value) is AnyClass))  // no class instance (no PCM buffer object) inside the chunk
        }
    }

    @Test func consumersRewritingTheirCopyDoNotAffectOthers() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let leases = [try await rig.conductor.acquireMic(for: .room), try await rig.conductor.acquireMic(for: .call),
                      try await rig.conductor.acquireMic(for: .dictation)]
        let listeners = leases.map { collect($0.chunks) }
        let mic = try #require(rig.mics.current)
        let source = expectedSine(from: 0, seconds: 5)
        feed(mic, from: 0, seconds: 5)
        for lease in leases { await lease.release(hold: .zero) }
        let received = await withTaskGroup(of: (Int, [AudioChunk]).self) { group -> [[AudioChunk]] in
            for (index, listener) in listeners.enumerated() { group.addTask { (index, await listener.finish()) } }
            var byIndex = [[AudioChunk]](repeating: [], count: listeners.count)
            for await (index, chunks) in group { byIndex[index] = chunks }
            return byIndex
        }

        // Consumer 0 destroys its samples, in parallel with consumer 1 amplifying and 2 reading.
        let results = await withTaskGroup(of: [[Float]].self) { group -> [[[Float]]] in
            group.addTask { received[0].map { c in var s = c.samples; for i in s.indices { s[i] = 99 }; return s } }
            group.addTask { received[1].map { c in var s = c.samples; for i in s.indices { s[i] *= 8 }; return s } }
            group.addTask { received[2].map(\.samples) }
            var all: [[[Float]]] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 3)
        for chunks in received {
            #expect(chunks.map(\.samples) == source.map(\.samples))  // each consumer still holds the untouched signal
        }
        let reference = source.map(\.samples)
        let untouched = results.filter { $0 == reference }
        #expect(untouched.count == 1)  // only the pure reader sees the original, the other two see their own edits
    }
}
