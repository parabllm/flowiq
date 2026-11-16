// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 8: the development profile never writes into the real vault or onto Panotti's live link
// (Annex D, R-006, R-005). All paths here lie in a temp folder; the "real vault" is a stand-in folder
// outside the dev support folder, so a leak shows up as a file there. Nothing touches `~/Documents`,
// `~/Library/Application Support/Panotti` or `/tmp/panotti-live.md` (that one is only looked at, never written).
import Foundation
import Testing
@testable import FlowIQCore  // COMPILE-FIX (P5 build): the file names Paths without importing its module

struct DevProfileTests {
    static let t0 = localDate(2026, 11, 13, 10, 45)

    @Test func devSettingsPointNowhereNearPanotti() {
        let dev = Paths(profile: .development)
        let prod = Paths(profile: .production)
        #expect(dev.liveLink.path == "/tmp/flowiq-dev-live.md")
        #expect(prod.liveLink.path == "/tmp/panotti-live.md")
        #expect(dev.support.lastPathComponent == "FlowIQ-Dev")
        #expect(!dev.support.path.contains("/Panotti"))
    }

    @Test func devAllowListDoesNotContainTheVault() throws {
        let dev = try DevRig.make()
        defer { dev.remove() }
        #expect(!dev.fs.allows(dev.outsideVault.appending(path: "transcripts/x.md")))
        #expect(dev.fs.allows(dev.insideVault.appending(path: "transcripts/x.md")))
        #expect(!dev.fs.allows(URL(filePath: "/tmp/panotti-live.md")))
    }

    /// Start, append, stop and aftercare against a vault outside the dev folder: every write is refused and
    /// nothing appears there.
    @Test func writingToAVaultOutsideTheDevFolderIsRefused() async throws {
        let dev = try DevRig.make()
        defer { dev.remove() }
        let link = dev.paths.support.appending(path: "dev-live.md")
        let store = dev.store(vault: dev.outsideVault, link: link)
        await #expect(throws: (any Error).self) {
            _ = try await store.beginLive(kind: .call, startedAt: Self.t0, language: "de")  // ASSUMPTION: refusal surfaces as a thrown error (SafeFS.Denied), not a crash or a silent skip
        }
        let transcripts = try FileManager.default.contentsOfDirectory(atPath: dev.outsideVault.appending(path: "transcripts").path)
        let raw = try FileManager.default.contentsOfDirectory(atPath: dev.outsideVault.appending(path: "raw").path)
        #expect(transcripts.isEmpty && raw.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        await dev.log.flush()
    }

    /// Inside its own folder the dev profile works fully, link included.
    @Test func devProfileWorksInsideItsOwnFolder() async throws {
        let dev = try DevRig.make()
        defer { dev.remove() }
        let link = dev.paths.support.appending(path: "dev-live.md")
        let store = dev.store(vault: dev.insideVault, link: link)
        let live = try await store.beginLive(kind: .call, startedAt: Self.t0, language: "de")  // ASSUMPTION: same beginLive as in Rig
        #expect(live.url.path.hasPrefix(dev.paths.support.path))
        #expect(samePath(linkDestination(link), live.url))
    }

    /// A link target outside the allow list is refused even when the rest is fine.
    @Test func linkOutsideTheAllowListIsRefused() async throws {
        let dev = try DevRig.make()
        defer { dev.remove() }
        let stray = dev.root.appending(path: "elsewhere/live.md")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = dev.store(vault: dev.insideVault, link: stray)
        let live = try? await store.beginLive(kind: .call, startedAt: Self.t0, language: "de")  // ASSUMPTION: a refused link is logged; beginLive may throw or return, but no link appears
        _ = live
        #expect(linkDestination(stray) == nil)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    /// A whole run (live, stop, failing and succeeding aftercare) changes nothing on Panotti's live link and puts
    /// no file outside the temp root. The test rig has its own link inside the temp folder.
    @Test func fullRunLeavesPanottisLinkAndForeignFoldersUntouched() async throws {
        let panottiLink = URL(filePath: "/tmp/panotti-live.md")
        let devLink = URL(filePath: "/tmp/flowiq-dev-live.md")
        let before = (PathFingerprint(panottiLink), PathFingerprint(devLink))
        let post = FakePost(script: [.fail(.networkDown)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        #expect(rig.liveLink.path != panottiLink.path && rig.liveLink.path != devLink.path)
        #expect(rig.liveLink.path.hasPrefix(rig.root.path))
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        rig.clock.advance(61)
        await rig.trigger(.timer)
        await rig.trigger(.appStart)
        let after = (PathFingerprint(panottiLink), PathFingerprint(devLink))
        #expect(before.0 == after.0)
        #expect(before.1 == after.1)
        // Every file the run made lies below the root.
        let all = FileManager.default.enumerator(at: rig.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        #expect(!all.isEmpty)
        let rootPath = try #require(rig.root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) + "/"  // TEST-FIX (geprüft, Prüfnotiz Nr. 2): the enumerator reports /private/var for a /var root; only the root is resolved (canonical path: resolvingSymlinksInPath strips /private again, measured)
        #expect(all.allSatisfy { $0.path.hasPrefix(rootPath) })  // TEST-FIX (geprüft, Prüfnotiz Nr. 2): compares against the resolved root, the found URLs stay as they are
    }

    /// The rig's folders are the temp root, never the user's home folders.
    @Test func rigRootIsATempFolderNotTheHome() throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        #expect(rig.root.resolvingSymlinksInPath().path.hasPrefix(tmp))
        for url in [rig.transcripts, rig.raw, rig.archiveAudio, rig.paths.support, rig.liveLink] {
            let p = url.resolvingSymlinksInPath().path
            #expect(p.hasPrefix(tmp))
            #expect(!p.contains("/Documents/Notizen") && !p.contains("Application Support/Panotti"))
            #expect(!(p.hasPrefix(home + "/Documents") || p.hasPrefix(home + "/Library")) || tmp.hasPrefix(home))
        }
    }

    /// No code path of the store or the aftercare may name the production link or Panotti's data folder;
    /// the profile decides every path (the store only gets its locations handed in).
    @Test func storeLocationsComeOnlyFromTheCaller() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        let journal = try FileManager.default.contentsOfDirectory(atPath: rig.paths.laufend.path)
        #expect(journal.allSatisfy { !$0.contains("aktueller-call") })  // Panotti's WAL name is never reused
        #expect(!FileManager.default.fileExists(atPath: rig.paths.support.deletingLastPathComponent().appending(path: "Panotti").path))
    }
}
