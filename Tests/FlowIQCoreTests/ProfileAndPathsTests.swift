import Foundation
import Testing
@testable import FlowIQCore

struct ProfileTests {
    @Test(arguments: [
        ("de.flowiq.app", "production", Profile.production),
        ("de.flowiq.app", "development", .development),
        ("de.flowiq.app", nil, .development),
        ("de.flowiq.app.dev", "development", .development),
        ("de.flowiq.app.dev", "production", .development),
        ("com.example.other", "production", .development),
        (nil, nil, .development),
    ] as [(String?, String?, Profile)])
    func resolvesOnlyMatchingProductionBundle(id: String?, declared: String?, expected: Profile) {
        #expect(Profile.resolve(bundleIdentifier: id, declared: declared) == expected)
    }

    @Test func withoutInfoPlistTheProfileIsDevelopment() {
        // The test runner has no FlowIQ Info.plist, like `swift run`.
        #expect(Profile.resolve(.main) == .development)
    }

    @Test(arguments: [nil, "production"] as [String?])
    func bundleOnDiskNeedsBothKeysForProduction(declared: String?) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-bundle-\(UUID().uuidString)")
        defer { remove(root) }
        let contents = root.appending(path: "Probe.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: String] = ["CFBundleIdentifier": "de.flowiq.app", "CFBundlePackageType": "APPL"]
        info[Profile.infoKey] = declared
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        let bundle = try #require(Bundle(url: root.appending(path: "Probe.app")))
        #expect(bundle.bundleIdentifier == "de.flowiq.app")
        #expect(Profile.resolve(bundle) == (declared == nil ? .development : .production))
    }

    @Test func profileValues() {
        #expect(Profile.production.supportFolderName == "FlowIQ")
        #expect(Profile.development.supportFolderName == "FlowIQ-Dev")
        #expect(Profile.development.bundleIdentifier == "de.flowiq.app.dev")
        #expect(Profile.production.launchAtLoginDefault)
        #expect(!Profile.development.launchAtLoginDefault)
    }
}

struct PathsTests {
    let base = URL(filePath: "/private/var/folders/flowiq-test/Application Support", directoryHint: .isDirectory)

    @Test func foldersAndLinksPerProfile() {
        let prod = Paths(profile: .production, applicationSupport: base)
        let dev = Paths(profile: .development, applicationSupport: base)
        #expect(prod.support.lastPathComponent == "FlowIQ")
        #expect(dev.support.lastPathComponent == "FlowIQ-Dev")
        #expect(dev.log.deletingLastPathComponent().lastPathComponent == "FlowIQ-Dev")
        #expect(dev.settingsFile.lastPathComponent == "settings.json")
        #expect(dev.liveLink.path == "/tmp/flowiq-dev-live.md")
        #expect(prod.liveLink.path == "/tmp/panotti-live.md")
    }
}

struct SafeFSTests {
    let base = URL(filePath: "/private/var/folders/flowiq-test/Application Support", directoryHint: .isDirectory)

    @Test func developmentWritesOnlyBelowItsSupportFolderAndItsLiveLink() {
        let dev = Paths(profile: .development, applicationSupport: base)
        let fs = SafeFS(paths: dev, vault: [URL(filePath: "/private/var/folders/vault")])
        #expect(fs.allows(dev.support))
        #expect(fs.allows(dev.settingsFile))
        #expect(fs.allows(dev.support.appending(path: "laufend/a/b.aac")))
        #expect(fs.allows(URL(filePath: "/tmp/flowiq-dev-live.md")))
        #expect(!fs.allows(URL(filePath: "/tmp/panotti-live.md")))
        #expect(!fs.allows(URL(filePath: "/tmp/flowiq-dev-live.md.bak")))
        #expect(!fs.allows(base.appending(path: "FlowIQ/settings.json")))
        #expect(!fs.allows(base.appending(path: "FlowIQ-Dev2/x")))
        #expect(!fs.allows(dev.support.appending(path: "../FlowIQ/x")))
        #expect(!fs.allows(URL(filePath: "/private/var/folders/vault/raw/x.m4a")), "dev ignores vault targets")
    }

    @Test func productionAddsVaultTargetsAndItsLiveLink() {
        let prod = Paths(profile: .production, applicationSupport: base)
        let fs = SafeFS(paths: prod, vault: [URL(filePath: "/private/var/folders/vault/raw")])
        #expect(fs.allows(prod.settingsFile))
        #expect(fs.allows(URL(filePath: "/private/var/folders/vault/raw/x.m4a")))
        #expect(fs.allows(URL(filePath: "/tmp/panotti-live.md")))
        #expect(!fs.allows(URL(filePath: "/private/var/folders/vault/transcripts/x.md")))
        #expect(!fs.allows(base.appending(path: "FlowIQ-Dev/x")))
    }

    @Test func deniedCallsThrowBeforeTouchingTheDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-safefs-\(UUID().uuidString)")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = Paths(profile: .development, applicationSupport: root.appending(path: "support"))
        let fs = SafeFS(paths: paths)
        let outside = root.appending(path: "outside.txt")
        #expect(throws: SafeFS.Denied.self) { try fs.replace(outside, with: Data("x".utf8)) }
        #expect(throws: SafeFS.Denied.self) { try fs.makeFolder(root.appending(path: "other")) }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "other").path))
    }

    @Test func claimNewNeverOverwritesAndPrepareCreatesOnlyItsFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-safefs-\(UUID().uuidString)")
        defer { remove(root) }
        let paths = Paths(profile: .development, applicationSupport: root)
        let fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        #expect(FileManager.default.fileExists(atPath: paths.log.path))
        #expect(!FileManager.default.fileExists(atPath: paths.settingsFile.path))
        let file = paths.support.appending(path: "a.txt")
        try fs.claimNew(file, with: Data("first".utf8))
        #expect(throws: (any Error).self) { try fs.claimNew(file, with: Data("second".utf8)) }
        #expect(try Data(contentsOf: file) == Data("first".utf8))
        try fs.move(file, to: paths.support.appending(path: "b.txt"))
        let moved = paths.support.appending(path: "b.txt")
        #expect(throws: SafeFS.Denied.self) { try fs.move(moved, to: root.appending(path: "c")) }
        try fs.delete(paths.support.appending(path: "b.txt"))
        #expect(!FileManager.default.fileExists(atPath: paths.support.appending(path: "b.txt").path))
    }
}

struct LanguageTests {
    @Test func presetHoldsForExactlyOneRecording() {
        var next = NextRecordingLanguage()
        next.select(.en)
        #expect(next.consume(shortcut: nil) == .en)
        #expect(next.consume(shortcut: nil) == .de)
    }

    @Test func shortcutAlwaysWins() {
        var next = NextRecordingLanguage()
        next.select(.en)
        #expect(next.consume(shortcut: .de) == .de)
        #expect(next.preset == .de)
        #expect(next.consume(shortcut: .en) == .en)
    }

    @Test func localeIdentifiers() {
        #expect(RecordingLanguage.de.rawValue == "de-DE")
        #expect(RecordingLanguage.en.rawValue == "en-US")
    }
}

func remove(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) } catch { Issue.record("cleanup failed: \(error)") }
}
