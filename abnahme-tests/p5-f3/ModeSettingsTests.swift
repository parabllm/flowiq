// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-1: settings per mode and shortcuts (ARCHITEKTUR M.1, M.2, M.7; R-096, R-103 settings part, R-067 switch,
// R-100 "ElevenLabs locked without a key"). Call and Room choose live recognizer, after-run and language; Dictation
// chooses only the after-run (live is fixed local, language German in v1); Devices choose the after-run. The key that
// unlocks ElevenLabs lives in the keychain, never here. Shortcut "Live-Quelle umschalten" acts on the running
// recording, or only on the next one, and then expires like the language preset (R-057).
import Foundation
import Testing
@testable import FlowIQCore
@testable import FlowIQStore

@Suite(.timeLimit(.minutes(3)))
struct ModeSettingsTests {
    // MARK: defaults and storage

    @Test func defaultsPerMode() {
        let s = Settings.defaults(for: .production)
        #expect(s[.dictation] == ModeConfig(live: .appleLocal, post: .elevenLabs, language: .de), "dictation after-run is ON by default (leadership decision)")  // ASSUMPTION: ModeConfig is Equatable
        for mode in [RecordingMode.call, .room, .device] {
            #expect(s[mode].live == .appleLocal, "\(mode)")  // ASSUMPTION: assumed API, see the Support header
            #expect(s[mode].language == .de, "\(mode)")  // ASSUMPTION: assumed API, see the Support header
        }
    }

    @Test(arguments: [true, false])
    func callRoomAndDeviceTakePanottisSwitchAtTheTakeover(_ panottiPost: Bool) {
        let s = Settings.defaults(for: .production, panottiPostEnabled: panottiPost)  // ASSUMPTION: Settings.defaults(for:panottiPostEnabled:) carries Panotti's after-run switch into call, room and device
        let expected: PostEngine = panottiPost ? .elevenLabs : .off
        #expect(s[.call].post == expected)  // ASSUMPTION: assumed API, see the Support header
        #expect(s[.room].post == expected)  // ASSUMPTION: assumed API, see the Support header
        #expect(s[.device].post == expected)  // ASSUMPTION: assumed API, see the Support header
        #expect(s[.dictation].post == .elevenLabs, "dictation default does not follow Panotti's switch")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func choicesSurviveASaveAndLoadAndUseTheDocumentedRawValues() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        var s = Settings.defaults(for: .development)
        s[.call] = ModeConfig(live: .elevenLabsRealtime, post: .off, language: .en)  // ASSUMPTION: assumed API, see the Support header
        s[.room] = ModeConfig(live: .appleLocal, post: .elevenLabs, language: .de)  // ASSUMPTION: assumed API, see the Support header
        let store = SettingsStore(paths: scratch.paths, fs: scratch.fs)
        try await store.save(s)
        let text = try String(contentsOf: scratch.paths.settingsFile, encoding: .utf8)
        #expect(text.contains("elevenLabsRealtime") && text.contains("appleLocal") && text.contains("elevenLabs"))  // raw values of M.2
        let loaded = await SettingsStore(paths: scratch.paths, fs: scratch.fs).load()
        #expect(loaded.problem == nil)
        #expect(loaded.settings[.call] == s[.call])  // ASSUMPTION: assumed API, see the Support header
        #expect(loaded.settings[.room] == s[.room])  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func anOlderFileWithoutTheModeTableTakesTheDefaults() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data(#"{"version":1,"launchAtLogin":false}"#.utf8).write(to: scratch.paths.settingsFile)
        let loaded = await SettingsStore(paths: scratch.paths, fs: scratch.fs).load()
        #expect(loaded.problem == nil)
        #expect(loaded.settings[.call] == Settings.defaults(for: .development)[.call])  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aMissingKeyInsideOneModeTakesThatModesDefault() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data(#"{"version":1,"launchAtLogin":false,"modes":{"call":{"live":"elevenLabsRealtime"}}}"#.utf8).write(to: scratch.paths.settingsFile)  // ASSUMPTION: key names modes, live, post, language
        let loaded = await SettingsStore(paths: scratch.paths, fs: scratch.fs).load()
        let defaults = Settings.defaults(for: .development)
        #expect(loaded.settings[.call].live == .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        #expect(loaded.settings[.call].post == defaults[.call].post)  // ASSUMPTION: assumed API, see the Support header
        #expect(loaded.settings[.call].language == defaults[.call].language)  // ASSUMPTION: assumed API, see the Support header
    }

    // MARK: what may be chosen

    @Test func withoutAKeyElevenLabsIsLockedEverywhere() {
        let s = Settings.defaults(for: .production)
        for mode in [RecordingMode.dictation, .call, .room, .device] {
            let choices = s.choices(for: mode, hasKey: false)  // ASSUMPTION: Settings.choices(for:hasKey:) -> ModeChoices { live: [LiveEngine], post: [PostEngine], languages: [RecordingLanguage] }
            #expect(!choices.live.contains(.elevenLabsRealtime), "\(mode)")
            #expect(!choices.post.contains(.elevenLabs), "\(mode)")
        }
    }

    @Test func withAKeyCallAndRoomOfferBothSourcesAndBothLanguages() {
        let s = Settings.defaults(for: .production)
        for mode in [RecordingMode.call, .room] {
            let choices = s.choices(for: mode, hasKey: true)  // ASSUMPTION: assumed API, see the Support header
            #expect(Set(choices.live) == [.appleLocal, .elevenLabsRealtime])
            #expect(Set(choices.post) == [.off, .elevenLabs])
            #expect(Set(choices.languages) == [.de, .en])
        }
    }

    @Test func dictationLiveIsFixedLocalAndItsLanguageIsGermanInV1() {
        let choices = Settings.defaults(for: .production).choices(for: .dictation, hasKey: true)  // ASSUMPTION: assumed API, see the Support header
        #expect(choices.live == [.appleLocal], "greyed out: no live choice for the dictation (K-26)")
        #expect(choices.languages == [.de], "English dictation is v1.1 (R-027)")
        #expect(Set(choices.post) == [.off, .elevenLabs])
    }

    @Test func devicesChooseOnlyTheAfterRun() {
        let choices = Settings.defaults(for: .production).choices(for: .device, hasKey: true)  // ASSUMPTION: assumed API, see the Support header
        #expect(choices.live.isEmpty, "files have no live recognition")
        #expect(Set(choices.post) == [.off, .elevenLabs])
    }

    @Test func choosingWhatIsLockedIsRefusedAndChangesNothing() throws {
        var s = Settings.defaults(for: .production)
        let before = s
        #expect(throws: ModeChoiceError.self) { try s.set(.call, live: .elevenLabsRealtime, hasKey: false) }  // ASSUMPTION: Settings.set(_:live:post:language:hasKey:) throws ModeChoiceError for a locked choice
        #expect(throws: ModeChoiceError.self) { try s.set(.dictation, live: .elevenLabsRealtime, hasKey: true) }  // ASSUMPTION: assumed API, see the Support header
        #expect(throws: ModeChoiceError.self) { try s.set(.dictation, language: .en, hasKey: true) }  // ASSUMPTION: assumed API, see the Support header
        #expect(throws: ModeChoiceError.self) { try s.set(.call, post: .elevenLabs, hasKey: false) }  // ASSUMPTION: assumed API, see the Support header
        #expect(s == before)
    }

    @Test func aChoiceIsMadeInTwoStepsAtTheMost() throws {
        var s = Settings.defaults(for: .production)
        try s.set(.call, live: .elevenLabsRealtime, hasKey: true)  // ASSUMPTION: assumed API, see the Support header
        try s.set(.call, language: .en, hasKey: true)  // ASSUMPTION: assumed API, see the Support header
        #expect(s[.call].live == .elevenLabsRealtime && s[.call].language == .en)   // ASSUMPTION: assumed API, see the Support header; one call per segment switch; the panel itself is G-UI
    }

    @Test func aHandEditedFileCannotUnlockWhatTheKeyDoesNotAllow() throws {
        var s = Settings.defaults(for: .production)
        s[.call] = ModeConfig(live: .elevenLabsRealtime, post: .elevenLabs, language: .en)  // ASSUMPTION: assumed API, see the Support header
        let withoutKey = s.effective(.call, hasKey: false)  // ASSUMPTION: Settings.effective(_:hasKey:) resolves a stored choice to what actually runs
        #expect(withoutKey.live == .appleLocal)
        #expect(withoutKey.post == .off)
        #expect(withoutKey.language == .en)
        #expect(s.effective(.call, hasKey: true) == s[.call])  // ASSUMPTION: assumed API, see the Support header
    }

    // MARK: every combination reaches the header (R-096: 16 of 16, R-103 for the after-run)

    @Test(arguments: [RecordingMode.call, .room].flatMap { m in [LiveEngine.appleLocal, .elevenLabsRealtime].flatMap { l in [PostEngine.off, .elevenLabs].flatMap { p in ["de", "en"].map { (m, l, p, $0) } } } })  // COMPILE-FIX (P5 build): Swift Testing takes at most two argument collections; the same 16 combinations as one collection
    func everyCombinationWritesItsHeader(_ mode: RecordingMode, _ live: LiveEngine, _ post: PostEngine, _ language: String) async throws {
        let batch = FakeBatch()
        let rig = try await StoreRig.make(batch: batch, post: [mode: post == .elevenLabs])
        defer { rig.remove() }
        let when = localDate(2026, 11, 13, 10, 45)
        let file = try await rig.begin(mode, at: when, language: language, live: live)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(file, Line(seconds: 1, speaker: "Mara", text: "Probesatz."))
        try await rig.finish(file, seconds: 60, raw: try rig.makeRaw(mode, at: when, seconds: 60))
        let doc = try readDoc(file.url)
        #expect(doc.value("live_quelle") == (live == .appleLocal ? "apple-lokal" : "elevenlabs-scribe-v3-live"))  // M.10
        #expect(doc.value("sprache") == language)
        if post == .elevenLabs {
            #expect(doc.value("panotti_phase") == "final-elevenlabs")
            #expect(doc.value("pipeline") == "panotti-live+elevenlabs-scribe-v2")
            #expect(doc.value("nachlauf_quelle") == "elevenlabs-scribe-v3")
            #expect(await batch.seen.first?.language == language, "the after-run carries the language of the recording")
        } else {
            #expect(doc.value("panotti_phase") == "final-lokal")
            #expect(doc.value("pipeline") == "panotti-live+lokal")
            #expect(doc.value("nachlauf_quelle") == nil)
            #expect(await batch.callCount == 0)
        }
    }

    // MARK: the shortcut "Live-Quelle umschalten" (K-29)

    @Test func whileRecordingTheShortcutSwitchesTheRunningSource() {
        var choice = LiveSourceShortcut()  // ASSUMPTION: LiveSourceShortcut is the pure state of the shortcut; press(running:configured:hasKey:) -> LiveSourcePress
        #expect(choice.press(running: .appleLocal, configured: .appleLocal, hasKey: true) == .switchRunning(to: .elevenLabsRealtime))  // ASSUMPTION: assumed API, see the Support header
        #expect(choice.press(running: .elevenLabsRealtime, configured: .appleLocal, hasKey: true) == .switchRunning(to: .appleLocal))  // ASSUMPTION: assumed API, see the Support header
        #expect(choice.nextRecording(configured: .appleLocal) == .appleLocal, "a press during a recording arms nothing for the next one")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func withoutARecordingItOnlyArmsTheNextOneAndThenExpiresFiveOfFive() {
        for round in 0..<5 {
            var choice = LiveSourceShortcut()  // ASSUMPTION: assumed API, see the Support header
            #expect(choice.press(running: nil, configured: .appleLocal, hasKey: true) == .armedForNext(.elevenLabsRealtime), "round \(round)")  // ASSUMPTION: assumed API, see the Support header
            #expect(choice.nextRecording(configured: .appleLocal) == .elevenLabsRealtime, "round \(round): the armed source applies to the next recording")  // ASSUMPTION: assumed API, see the Support header
            #expect(choice.nextRecording(configured: .appleLocal) == .appleLocal, "round \(round): and expires after it")  // ASSUMPTION: assumed API, see the Support header
        }
    }

    @Test func pressingTwiceBeforeTheNextRecordingTogglesBack() {
        var choice = LiveSourceShortcut()  // ASSUMPTION: assumed API, see the Support header
        _ = choice.press(running: nil, configured: .appleLocal, hasKey: true)  // ASSUMPTION: assumed API, see the Support header
        #expect(choice.press(running: nil, configured: .appleLocal, hasKey: true) == .armedForNext(.appleLocal))  // ASSUMPTION: assumed API, see the Support header
        #expect(choice.nextRecording(configured: .appleLocal) == .appleLocal)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func withoutAKeyTheShortcutRefusesTheCloud() {
        var choice = LiveSourceShortcut()  // ASSUMPTION: assumed API, see the Support header
        #expect(choice.press(running: .appleLocal, configured: .appleLocal, hasKey: false) == .refused(.keyMissing))  // ASSUMPTION: LiveSourcePress.refused(ModeChoiceError)
        #expect(choice.press(running: nil, configured: .appleLocal, hasKey: false) == .refused(.keyMissing))  // ASSUMPTION: assumed API, see the Support header
        #expect(choice.nextRecording(configured: .appleLocal) == .appleLocal)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theLanguagePresetStillExpiresAfterOneRecording() {
        var next = NextRecordingLanguage()
        next.select(.en)
        #expect(next.consume(shortcut: nil) == .en)
        #expect(next.consume(shortcut: nil) == .de, "R-057: nothing sticks")
        #expect(next.consume(shortcut: .en) == .en, "a shortcut always wins")
    }
}

/// A temp data folder for the settings tests.
struct Scratch {
    let root: URL
    let paths: Paths
    let fs: SafeFS

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p5f3s-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(profile: .development, applicationSupport: root)
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        fs = SafeFS(paths: paths)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
