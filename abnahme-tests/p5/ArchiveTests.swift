// Group 6: the audio archive (A.9 "Stopp und Endphasen", 05b 1.1 and 3.3 no. 1, R-059, R-060, R-039). The
// audio moves from raw/ to the archive on every path, size is checked against duration (B/s floor 6,000 for
// call and room, as in P3), and nothing is ever deleted: not by a failure, not by a short file, not by a clash.
import Foundation
import Testing

struct ArchiveTests {
    static let t0 = localDate(2026, 11, 13, 10, 45)

    private func snapshot(_ url: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {  // COMPILE-FIX (P5 build): the key is isDirectoryKey
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                out[name] = try Data(contentsOf: url.appending(path: name))
            }
        } else {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    // MARK: audio always moves

    @Test(arguments: [true, false])
    func callFolderMovesWholeAndByteIdentical(postEnabled: Bool) async throws {
        let rig = try Rig.make(postEnabled: postEnabled)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 60)
        let original = try snapshot(item)
        #expect(original.count == 2)
        try await rig.finish(live, seconds: 60, raw: item)
        let target = rig.archiveAudio.appending(path: item.lastPathComponent)
        #expect(try snapshot(target) == original)  // both tracks, same bytes
        #expect(rig.names(in: rig.raw).isEmpty)
        #expect(item.lastPathComponent.hasSuffix(" Call"))
    }

    @Test(arguments: [true, false])
    func roomFileMovesByteIdentical(postEnabled: Bool) async throws {
        let rig = try Rig.make(postEnabled: postEnabled)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 90)
        let original = try snapshot(item)
        try await rig.finish(live, seconds: 90, raw: item)
        #expect(try snapshot(rig.archiveAudio.appending(path: item.lastPathComponent)) == original)
        #expect(rig.names(in: rig.raw).isEmpty)
    }

    /// Panotti archived only after a successful upload. Here the failing and the switched-off case end the same way.
    @Test func archiveDoesNotDependOnTheUploadResult() async throws {
        var results: [(inRaw: Bool, inArchive: Bool)] = []
        let setups: [(FakePost, Bool)] = [
            (FakePost(), true), (FakePost(script: [], fallback: .fail(.networkDown)), true),
            (FakePost(script: [], fallback: .fail(.quotaExhausted)), true), (FakePost(), false),
        ]
        for (post, enabled) in setups {
            let rig = try Rig.make(post: post, postEnabled: enabled)
            defer { rig.remove() }
            let live = try await rig.begin(.room, at: Self.t0)
            await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz."))
            let item = try rig.makeRaw(.room, at: Self.t0, seconds: 30)
            try await rig.finish(live, seconds: 30, raw: item)
            results.append(rig.locations(of: item))
        }
        #expect(results.allSatisfy { $0.inArchive && !$0.inRaw })  // ASSUMPTION: archive at stop on every path, see FailureQueueTests
    }

    // MARK: nothing is deleted

    /// Bytes below raw/ plus archive stay the same through every kind of ending.
    @Test func totalAudioBytesAreConservedOnEveryPath() async throws {
        let setups: [(FakePost, Bool)] = [
            (FakePost(), true), (FakePost(script: [], fallback: .fail(.networkDown)), true), (FakePost(), false),
        ]
        for (post, enabled) in setups {
            let rig = try Rig.make(post: post, postEnabled: enabled)
            defer { rig.remove() }
            var created = 0
            for (n, kind) in [Kind.call, .room, .call].enumerated() {
                let when = localDate(2026, 11, 13, 9, n * 11)
                let live = try await rig.begin(kind, at: when)
                await rig.add(live, sampleLines[0])
                let item = try rig.makeRaw(kind, at: when, seconds: 40)
                created += rig.bytes(below: item)
                try await rig.finish(live, seconds: 40, raw: item)
            }
            await rig.trigger(.click)
            #expect(rig.bytes(below: rig.raw) + rig.bytes(below: rig.archiveAudio) == created)
        }
    }

    /// A clash in the archive keeps both: the old item is untouched, the new one gets a numbered name.
    @Test func existingArchiveItemIsNeverOverwritten() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 30)
        let incoming = try Data(contentsOf: item)
        let old = Data("older audio with the same name".utf8)
        try old.write(to: rig.archiveAudio.appending(path: item.lastPathComponent))
        try await rig.finish(live, seconds: 30, raw: item)
        #expect(try Data(contentsOf: rig.archiveAudio.appending(path: item.lastPathComponent)) == old)
        let names = rig.names(in: rig.archiveAudio)
        #expect(names.count == 2)
        let extra = try #require(names.first { $0 != item.lastPathComponent })
        #expect(try Data(contentsOf: rig.archiveAudio.appending(path: extra)) == incoming)
        #expect(extra.contains(" 2"))  // ASSUMPTION: Panotti's collision suffix " 2", " 3" in front of the extension or at the end
        #expect(rig.names(in: rig.raw).isEmpty)
    }

    /// Unrelated files in the archive and in raw/ stay where they are.
    @Test func otherItemsAreLeftAlone() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let strayRaw = rig.raw.appending(path: "2026-11-01 08-00-00 raum.m4a")
        let strayArchive = rig.archiveAudio.appending(path: "2026-10-01 08-00-00 raum.m4a")
        try Data("stray one".utf8).write(to: strayRaw)
        try Data("stray two".utf8).write(to: strayArchive)
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        #expect(try Data(contentsOf: strayRaw) == Data("stray one".utf8))
        #expect(try Data(contentsOf: strayArchive) == Data("stray two".utf8))
    }

    /// A blocked archive folder must not lose audio: it stays in raw/, the error is logged, the transcript is written.
    @Test func blockedArchiveKeepsTheAudioInRawAndLogs() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        try FileManager.default.removeItem(at: rig.archiveAudio)
        try Data("blocker".utf8).write(to: rig.archiveAudio)
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 30)
        let original = try Data(contentsOf: item)
        try await rig.finish(live, seconds: 30, raw: item)  // ASSUMPTION: a failing archive step is logged and does not throw out of finish
        #expect(try Data(contentsOf: item) == original)
        let errors = await rig.errorEvents()
        #expect(!errors.isEmpty)
        #expect(try readDoc(live.url).lines.count == 1)
    }

    // MARK: size against duration (the floor of 6,000 B/s as in P3)

    struct SizeCase: Sendable, CustomStringConvertible {
        let bytesPerSecond: Int
        let kind: Kind
        let expectedEvent: String?
        var description: String { "\(kind) at \(bytesPerSecond) B/s" }
    }

    static let sizeCases: [SizeCase] = [
        SizeCase(bytesPerSecond: 12_000, kind: .room, expectedEvent: nil),
        SizeCase(bytesPerSecond: 6_000, kind: .room, expectedEvent: nil),
        SizeCase(bytesPerSecond: 5_999, kind: .room, expectedEvent: "audio_verdaechtig"),  // ASSUMPTION: same event names as the writer's close report (audio_verdaechtig, audio_lost)
        SizeCase(bytesPerSecond: 100, kind: .room, expectedEvent: "audio_lost"),
        SizeCase(bytesPerSecond: 12_000, kind: .call, expectedEvent: nil),
        SizeCase(bytesPerSecond: 5_999, kind: .call, expectedEvent: "audio_verdaechtig"),
        SizeCase(bytesPerSecond: 100, kind: .call, expectedEvent: "audio_lost"),
    ]

    @Test(arguments: sizeCases)
    func archiveChecksSizeAgainstDurationAndStillMoves(_ c: SizeCase) async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(c.kind, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(c.kind, at: Self.t0, seconds: 60, bytesPerSecond: c.bytesPerSecond)
        try await rig.finish(live, seconds: 60, raw: item)
        let place = rig.locations(of: item)
        #expect(place.inArchive && !place.inRaw)  // suspicious or lost audio is archived all the same, never dropped
        let audioErrors = await rig.errorEvents(prefix: "audio_")
        if let expected = c.expectedEvent {
            #expect(audioErrors.contains { ($0["kind"] as? String) == expected })
        } else {
            #expect(audioErrors.isEmpty)
        }
    }

    /// An empty track (a recording of a minute whose file holds nothing) is never "gesichert".
    @Test func emptyAudioIsFlaggedLostAndKeptNotDeleted() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = rig.raw.appending(path: "\(stampString(Self.t0)) raum.m4a")
        try Data().write(to: item)
        try await rig.finish(live, seconds: 60, raw: item)
        #expect(FileManager.default.fileExists(atPath: rig.archiveAudio.appending(path: item.lastPathComponent).path))
        let audioErrors = await rig.errorEvents(prefix: "audio_")
        #expect(audioErrors.contains { ($0["kind"] as? String) == "audio_lost" })
    }

    /// The call's single bad track is enough to flag it, the good one is still archived.
    @Test func oneBadCallTrackIsFlaggedAndBothAreKept() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 60)
        let desktop = item.appending(path: "\(stampString(Self.t0)) desktop.m4a")
        try Data(repeating: 1, count: 2_000).write(to: desktop)  // far below the floor for 60 s
        try await rig.finish(live, seconds: 60, raw: item)
        let archived = rig.archiveAudio.appending(path: item.lastPathComponent)
        #expect(rig.names(in: archived).count == 2)
        let audioErrors = await rig.errorEvents(prefix: "audio_")
        #expect(!audioErrors.isEmpty)
    }

    /// `quelle` always names a path that exists after the stop (Panotti left dangling paths after moves).
    @Test(arguments: [true, false])
    func quelleNamesAnExistingPathInEveryEndPhase(postEnabled: Bool) async throws {
        let rig = try Rig.make(post: FakePost(), postEnabled: postEnabled)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        let quelle = try #require(try readDoc(live.url).value("quelle"))
        #expect(FileManager.default.fileExists(atPath: quelle))
        #expect(samePath(quelle, rig.archiveAudio.appending(path: item.lastPathComponent)))
    }
}
