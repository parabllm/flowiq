import Foundation
import Testing
@testable import FlowIQCore

/// Each test gets its own temp root with both profile folders; writes go through SafeFS as in the app.
struct SettingsTests {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_763_036_400)
    let broken = Data("nicht json".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-settings-\(UUID().uuidString)")
        for profile in Profile.allCases { try paths(profile).prepare(using: SafeFS(paths: paths(profile))) }
    }

    private func cleanup() { remove(root) }
    private func paths(_ profile: Profile) -> Paths { Paths(profile: profile, applicationSupport: root) }
    private func file(_ profile: Profile) -> URL { paths(profile).settingsFile }
    private func store(_ profile: Profile) -> SettingsStore {
        SettingsStore(paths: paths(profile), fs: SafeFS(paths: paths(profile)))
    }

    @Test func missingFileGivesProfileDefaultsAndWritesNothing() async {
        defer { cleanup() }
        let loaded = await store(.production).load()
        #expect(loaded == .init(settings: .defaults(for: .production), problem: nil))
        #expect(loaded.settings.launchAtLogin)
        #expect(await store(.development).load().settings.launchAtLogin == false)
        #expect(!FileManager.default.fileExists(atPath: file(.production).path))
        #expect(!FileManager.default.fileExists(atPath: file(.development).path))
    }

    @Test func roundTrip() async throws {
        defer { cleanup() }
        let changed = Settings(launchAtLogin: true)
        try await store(.development).save(changed)
        #expect(await store(.development).load() == .init(settings: changed, problem: nil))
    }

    @Test func missingKeysTakeDefaultsUnknownKeysAreIgnored() async throws {
        defer { cleanup() }
        try Data(#"{"version": 1, "futureField": 7}"#.utf8).write(to: file(.production))
        #expect(await store(.production).load() == .init(settings: .defaults(for: .production), problem: nil))
    }

    @Test func unreadableFileIsSetAsideAndLeftUntouched() async throws {
        defer { cleanup() }
        try broken.write(to: file(.production))
        let loaded = await store(.production).load(now: now)
        #expect(loaded.settings == .defaults(for: .production))
        guard case .settingsUnreadable(let copy?) = loaded.problem else {
            Issue.record("expected an aside copy, got \(String(describing: loaded.problem))")
            return
        }
        #expect(copy.lastPathComponent == "settings.unlesbar-20251113T122000Z.json")
        #expect(try Data(contentsOf: file(.production)) == broken)
        #expect(try Data(contentsOf: copy) == broken)
    }

    @Test func saveWithoutLoadNeverOverwritesAnUnreadableFile() async throws {
        defer { cleanup() }
        try broken.write(to: file(.production))
        let store = store(.production)
        await #expect(throws: SettingsStore.SaveRefused.self) { try await store.save(Settings(launchAtLogin: false)) }
        #expect(try Data(contentsOf: file(.production)) == broken)
    }

    @Test func saveAfterSetAsideKeepsTheOriginalAndTheCopy() async throws {
        defer { cleanup() }
        try broken.write(to: file(.development))
        let store = store(.development)
        guard case .settingsUnreadable(let copy?) = await store.load().problem else {
            Issue.record("expected an aside copy")
            return
        }
        await #expect(throws: SettingsStore.SaveRefused.self) { try await store.save(Settings(launchAtLogin: false)) }
        await #expect(throws: SettingsStore.SaveRefused.self) { try await store.save(Settings(launchAtLogin: true)) }
        #expect(try Data(contentsOf: file(.development)) == broken)
        #expect(try Data(contentsOf: copy) == broken)
    }

    @Test func failedCopyStillLeavesTheFileUntouched() async throws {
        defer { cleanup() }
        try broken.write(to: file(.development))
        // The copy target already exists, so setting aside fails.
        try Data().write(to: paths(.development).support.appending(path: "settings.unlesbar-20251113T122000Z.json"))
        let store = store(.development)
        #expect(await store.load(now: now).problem == .settingsUnreadable(copy: nil))
        await #expect(throws: SettingsStore.SaveRefused.self) { try await store.save(Settings(launchAtLogin: false)) }
        #expect(try Data(contentsOf: file(.development)) == broken)
    }

    @Test func fileWithoutReadPermissionIsNeverOverwritten() async throws {
        let target = file(.production)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) } catch {
                Issue.record("chmod back failed: \(error)")
            }
            cleanup()
        }
        let valid = Data(#"{"version": 1, "launchAtLogin": false}"#.utf8)
        try valid.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: target.path)
        let store = store(.production)
        #expect(await store.load().problem == .settingsUnreadable(copy: nil))
        await #expect(throws: SettingsStore.SaveRefused.self) { try await store.save(Settings(launchAtLogin: true)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #expect(try Data(contentsOf: target) == valid)
    }

    @Test func savingWorksAgainOnceTheFileIsRepaired() async throws {
        defer { cleanup() }
        try broken.write(to: file(.production))
        let store = store(.production)
        _ = await store.load()
        try Data(#"{"version": 1, "launchAtLogin": true}"#.utf8).write(to: file(.production))
        try await store.save(Settings(launchAtLogin: false))
        #expect(await store.load() == .init(settings: Settings(launchAtLogin: false), problem: nil))
    }

    @Test func newerVersionIsReadButNeverOverwritten() async throws {
        defer { cleanup() }
        let newer = Data(#"{"version": 99, "launchAtLogin": false}"#.utf8)
        try newer.write(to: file(.production))
        let store = store(.production)
        let loaded = await store.load()
        #expect(loaded.problem == .settingsNewer(version: 99))
        #expect(loaded.settings.launchAtLogin == false)
        await #expect(throws: SettingsStore.SaveRefused.self) { try await store.save(Settings(launchAtLogin: true)) }
        #expect(try Data(contentsOf: file(.production)) == newer)
    }
}

struct LaunchAtLoginTests {
    typealias Loaded = SettingsStore.Loaded

    @Test func anySettingsProblemLeavesTheLoginItemUnchanged() {
        let unreadable = Loaded(settings: .defaults(for: .production), problem: .settingsUnreadable(copy: nil))
        #expect(LaunchAtLogin.decide(.production, unreadable) == .leaveUnchanged(.settingsUnreadable(copy: nil)))
        let newer = Loaded(settings: Settings(version: 9, launchAtLogin: true), problem: .settingsNewer(version: 9))
        #expect(LaunchAtLogin.decide(.production, newer) == .leaveUnchanged(.settingsNewer(version: 9)))
    }

    @Test func productionFollowsTheSetting() {
        #expect(LaunchAtLogin.decide(.production, Loaded(settings: Settings(launchAtLogin: true), problem: nil))
            == .apply(enabled: true))
        #expect(LaunchAtLogin.decide(.production, Loaded(settings: Settings(launchAtLogin: false), problem: nil))
            == .apply(enabled: false))
    }

    @Test func developmentNeverRegistersEvenIfTheFileSaysSo() {
        #expect(LaunchAtLogin.decide(.development, Loaded(settings: Settings(launchAtLogin: true), problem: nil))
            == .apply(enabled: false))
    }
}
