import SwiftUI

nonisolated extension FlowIQCore.Settings {
    /// The storage place (task 4): the chosen folder, else `~/Documents/FlowIQ/`; development below its data folder.
    func folder(_ profile: Profile) -> URL {
        transcriptFolder.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? (profile == .production ? URL.documentsDirectory : Paths(profile: profile).support)
                .appending(path: profile == .production ? "FlowIQ" : "test-vault", directoryHint: .isDirectory)
    }
    func locations(_ paths: Paths) -> StoreLocations {
        let place = folder(paths.profile), audio = audioFolder.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? place.appending(path: "audio", directoryHint: .isDirectory)
        let link = paths.profile == .production && !panottiLink ? URL(filePath: "/tmp/flowiq-live.md") : paths.liveLink
        return StoreLocations(transcripts: place, raw: audio, archiveAudio: audio, liveLink: link,
            dataFolder: paths.support)
    }
}

/// The app's one UI model (A.12): menu, pill, settings, setup and the actions behind them.
@MainActor @Observable
final class AppModel {
    nonisolated enum Tab: Hashable, Sendable { case recording, words, devices, permissions }
    /// What the views show as one observed value (the macro takes one variable per declaration).
    nonisolated struct Shown: Sendable {
        var hasKey = false, keyDraft = "", keyFocus = false, tab = Tab.recording
        var problem: String?, running: [Running] = [], recent: [RecentTranscript] = []
        var alerts: [AppAlert] = [], cloudSeconds = 0.0, mics: [String: String] = [:], mic: String?, newNames = 0
        var missing: [Permission] = [], post = AftercareState.idle, notInserted = false, tapRunning = false
        var rejection: String?  // why the service refused an after-run request (400), shown in the menu
        var keyWrong: Set<CloudProvider> = []  // the pasted text was no key (the key id): said next to the field
        var openRouterKey = false, orDraft = "", openRouterUSD = 0.0, troubles: [SessionKind: LiveTrouble] = [:]
        var section = MainView.Section.history  // the main window's sidebar (16.11.)
        var keysShared = false, iconHint = false  // Panotti holds the same keys; the menu bar hid the icon
        var screenGranted = true, down: Set<TrackKind> = [], folderOK = true
        // the menu's lines for what the pill no longer says (16.11.): a failed dictation (true: audio kept),
        // the headset lost mid-recording, the device import, recordings the Mac slept through
        var dictationFailed: Bool?, micLost: String?, importing = ImportProgress.hidden, importFailed: [String] = []
        var pauses: [SessionKind: String] = [:], device: DeviceNotice?  // what the last look at the recorders found
        var crashNote: String?  // the previous run crashed: one plain line until the menu closed (16.11.)
    }
    /// The running parts, set once at launch.
    struct Parts {
        var runtime: Runtime?, stack: DictationStack?, recorder: Recorder?, cloud: CloudParts?
        var starting: [SessionKind: Date] = [:], afterRun: Set<SessionKind> = []  // the ring waits for the after-run
        var stopping: Set<SessionKind> = []  // the stop runs: the ring stands, no refresh brings the pill back
        var refreshes = 0  // a refresh that a newer one overtook drops its snapshot (review V5)
        var words: WordsModel?, devices: DevicesModel?, menu: StatusMenu?, tick: Timer?
        var filing: (@MainActor (StoreLocations) -> Filing)?
        var makeDevices: (@MainActor (StoreLocations) -> DevicesModel)?
        var orKeys: CloudKeys?, models: [OpenRouterModel] = [], meter: UsageMeter?
        var hotKeys: HotKeys?, pendingKeys = HotKey.allCases, sleptAt: Date?, retrying = false, ticks = 0
    }
    let profile: Profile, panotti: URL?, pill: PillView, setup = PermissionModel(), keep = Mutex(true)  // R-117
    var settings: FlowIQCore.Settings
    var ui = Shown()
    @ObservationIgnored var parts = Parts()
    @ObservationIgnored lazy var history: HistoryModel = makeHistory()
    @ObservationIgnored lazy var recordings = RecordingsModel()
    @ObservationIgnored lazy var names = NamesModel()
    @ObservationIgnored lazy var review = ReviewExchange()
    @ObservationIgnored lazy var mainWindow = MainWindow(MainView(model: self, history: history,
                                                                  recordings: recordings))
    @ObservationIgnored lazy var setupWindow = SmallWindow("\(profile.displayName) einrichten",
                                                           SetupView(model: setup, app: self), plain: true)
    init(profile: Profile, settings: FlowIQCore.Settings, defaults: UserDefaults = .standard,
        pill: PillView = PillView()) {
        (self.profile, self.settings, self.pill) = (profile, settings, pill)
        let found = URL.applicationSupportDirectory.appending(path: "Panotti", directoryHint: .isDirectory)
        panotti = FileManager.default.fileExists(atPath: found.path) ? found : nil  // predecessor app, optional: a stat
    }
    var folder: URL { settings.folder(profile) }
    /// Production sends with a key; the development build only on its explicit switch (review W3).
    var cloudAllowed: Bool { profile == .production || settings.devCloudAllowed }
    /// The policy every upload and live connection asks, with keys only where sending is allowed.
    nonisolated static func policy(_ s: FlowIQCore.Settings, _ profile: Profile, key: Bool,
                                   openRouterKey: Bool) -> CloudPolicy {
        let allowed = profile == .production || s.devCloudAllowed
        return CloudPolicy(settings: s, hasKey: key && allowed, openRouterKey: openRouterKey && allowed)
    }
    var menuState: MenuState {
        MenuState(profile: profile, settings: settings, hasKey: ui.hasKey,
                  running: ui.running.filter { !parts.stopping.contains($0.kind) }, alerts: ui.alerts,
                  recent: ui.recent, newNames: ui.newNames, cloudSeconds: ui.cloudSeconds,
                  limitMinutes: settings.cloudLimitMinutes, mics: ui.mics, mic: ui.mic, openRouterKey: ui.openRouterKey,
                  openRouterUSD: ui.openRouterUSD, activity: (ui.crashNote.map { [$0] } ?? []) + Self.activity(
                      locked: pill.scene.dictation == .dictating && pill.scene.locked,
                      starting: Set(parts.starting.keys), stopping: parts.stopping, afterRun: parts.afterRun,
                      importing: ui.importing, device: ui.device))
    }
    /// After a crash: what the rescue of `laufend/` found, no warning (the pill says nothing).
    nonisolated static func crashNote(_ name: String, _ rescued: (saved: Int, failed: Int)) -> String {
        name + " war unerwartet beendet, " + (rescued.failed > 0 ? "eine Aufnahme ließ sich nicht ganz retten"
            : rescued.saved > 0 ? "unterbrochene Aufnahme gerettet" : "nichts verloren")
    }
    /// What runs besides the recordings, one plain line each (never a warning): as long as the pill shows it.
    nonisolated static func activity(locked: Bool, starting: Set<SessionKind>, stopping: Set<SessionKind>,
                                     afterRun: Set<SessionKind>, importing: ImportProgress,
                                     device: DeviceNotice? = nil) -> [String] {
        var out = locked ? ["Diktat läuft freihändig · Fn beendet"] : []
        for kind in [SessionKind.call, .room] {
            if stopping.contains(kind) { out.append("\(kind.rawValue) wird gespeichert …") } else if
                starting.contains(kind) { out.append("\(kind.rawValue) startet …") }
            if afterRun.contains(kind) { out.append("\(kind.rawValue): genauere Fassung wird erstellt …") }
        }
        if case .copying(let share) = importing {
            out.append("Geräte-Import · \(Int((min(max(share, 0), 1) * 100).rounded())) %")
        }
        if importing == .transcribing { out.append("Geräte-Import · wird verschriftet") }
        // the end of an import, until the device is unplugged: nothing new is no failure
        if importing == .hidden, let device, let name = DevicesModel.names[device.kind] {
            if device.what == .nothingNew { out.append("\(name): nichts Neues") }
            if case .imported(let n) = device.what {
                out.append("\(name): \(n) " + (n == 1 ? "Aufnahme" : "Aufnahmen") + " importiert")
            }
        }
        return out
    }
    func perform(_ action: MenuAction) {
        let p = parts, key = ui.hasKey, or = ui.openRouterKey
        switch action {
        case .start(let kind, let language): Task { await start(kind, language) }
        case .stop(let kind): Task { await stop(kind) }  // the question at the pill is gone (16.11.)
        case .toggleLive(let kind): Task { await p.recorder?.toggleLive(kind); await refresh() }
        case .showLive(let kind):
            Task { if let url = await p.recorder?.liveFile(kind) { NSWorkspace.shared.open(url) } }
        case .insertLast:
            Task { _ = await p.stack?.coordinator.reinsertLast(); ui.notInserted = false; await refresh() }
        case .correctLast: Task { _ = await p.stack?.correction.open(from: .menu) }
        case .open(let url): NSWorkspace.shared.open(url)
        case .openAll: NSWorkspace.shared.open(folder)
        case .words: show(.words)
        case .settings: show(.recording)
        case .openWindow: openMain(.history)
        case .setup: setupWindow.show()
        case .allowScreen: Task {  // the system question (only the first time), then the setting itself
            await setup.request(.screenRecording)  // counts as asked: Einrichten then offers the restart
            if let url = Permission.screenRecording.settingsURL { NSWorkspace.shared.open(url) }
            await refresh()
        }
        case .quit: AppDelegate.quit()
        case .selfTest: selfTest()
        case .liveDefault(let m):
            change { try $0.set(m, live: $0[m].live == .appleLocal ? .elevenLabsRealtime : .appleLocal, hasKey: key) }
        case .post(let m):
            change { s in
                let next: PostEngine = s.effective(m, hasKey: key, openRouterKey: or).post == .off ? .elevenLabs : .off
                try s.set(m, post: next, hasKey: key, openRouterKey: or)
            }
        case .installModel(let l):  // the download only on this click (review M4)
            Task { if await p.recorder?.installModel(l) == true { announce("Sprachmodell geladen") }; await refresh() }
        case .keyField: ui.keyFocus = true; show(.recording)
        case .mic(let uid): chooseMic(uid)
        case .retryPost: Task { await p.recorder?.filing.aftercare.trigger(.click); await refresh() }
        case .chooseFolder: chooseFolder()
        case .reconnect: for r in ui.running where r.fallback != nil { perform(.toggleLive(r.kind)) }
        case .recognizeAgain: Task { await recognizeAgain() }
        case .retryImport: p.devices?.retry()
        case .enableImport: p.devices?.set(true)
        case .devices: show(.devices)
        case .dismissPause(let kind): ui.pauses[kind] = nil; Task { await refresh(full: false) }
        }
    }
    /// The dictation's end as the menu tells it: no text field, or failed; a failure stands until a dictation is
    /// recognized again (the journal knows, and whether the audio of the failed one is kept).
    func dictation(_ state: PillState) async {
        if state == .dictating || state == .notInserted { ui.notInserted = state == .notInserted }
        if state == .failed || ui.dictationFailed != nil && state != .dictating {
            let last = await parts.stack?.journal?.lastFailure()
            ui.dictationFailed = state == .failed ? last?.audio != nil : last == nil ? nil : ui.dictationFailed
        } else if state == .hidden { return }
        await refresh()
    }
    /// "Erneut erkennen": the kept audio once more, locally. The text goes to the cursor and into the history; where
    /// it cannot be inserted it lies in the clipboard and the history opens. A second failure leaves the line.
    func recognizeAgain() async {
        guard !parts.retrying, let stack = parts.stack, let journal = stack.journal,
              let failed = await journal.lastFailure(), let url = failed.audio else { return NSSound.beep() }
        parts.retrying = true
        defer { parts.retrying = false }
        do {
            let text = try await FileTranscriber.recognize(url, locale: Locale(identifier: "de-DE"),
                limit: .seconds(120), log: parts.runtime?.log).text
            guard !text.isEmpty else { return NSSound.beep() }
            let result = await stack.inserter?.insert(text) ?? .failed
            try await journal.append(.recognized(id: failed.id, recognizerText: text, finalText: text,
                                                 interventions: [String]()))
            try await journal.append(.inserted(id: failed.id, result: result.rawValue))
            ui.dictationFailed = nil
            if result != .landed {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                openMain(.history)
            }
        } catch { NSSound.beep() }
        await refresh()
    }
    /// The microphone of the running recordings changed: lost (the built-in one took over) or back, or chosen.
    func micSwitched(lost: Bool) {
        ui.micLost = lost && !ui.running.isEmpty
            ? ui.running.compactMap(\.device).first.flatMap { ui.mics[$0] } ?? "Kopfhörer-Mikrofon" : nil
    }
    /// The device import as the menu tells it: its share while it runs; after a failure which files, until the
    /// next import runs through.
    func imported(_ p: ImportProgress) async {
        await parts.devices?.step(p, was: ui.importing)
        ui.importing = p
        if case .failed = p {
            await parts.devices?.load()
            ui.importFailed = parts.devices?.files.filter(\.retry).map(\.name) ?? []
        }
        await refresh(full: false)
    }
    /// Lid closed while recording (review 2): the Mac sleeps, nothing is recorded meanwhile, the recording goes on
    /// after waking; the menu says from when to when.
    func slept(_ asleep: Bool, now: Date = .now) {
        if asleep { return parts.sleptAt = now }
        guard let from = parts.sleptAt else { return }
        let time = { (d: Date) in d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE"))) }
        for r in ui.running { ui.pauses[r.kind] = "\(time(from)) bis \(time(now))" }
        parts.sleptAt = nil
        Task { await refresh(full: false) }
    }
    /// ⌘⌥U, ⌘⌥R start or stop, E held as well for English (R-056, 16.11.); the live source only in the menu.
    func shortcut(_ s: Shortcut) {
        let kind: SessionKind = s == .callGerman || s == .callEnglish ? .call : .room
        switch s {
        case .callGerman, .callEnglish, .roomGerman, .roomEnglish:
            let english = s == .callEnglish || s == .roomEnglish, running = ui.running.contains { $0.kind == kind }
            let decision = Self.decide(running: running, startedAt: parts.starting[kind], now: .now)
            parts.runtime?.log.record(LogEvent("control", ["source": "shortcut", "mode": .string(kind.rawValue),
                "language": .string(english ? "en" : "de"), "decision": .string(decision.rawValue)]))
            switch decision {
            case .start: Task { await start(kind, english ? .en : .de) }
            case .stop: Task { await stop(kind) }
            case .ignored: break
            }
        case .correctLast: perform(.correctLast)
        case .rawVersion: break  // the raw version lives in the correction window (Fassung 3)
        }
    }
    enum Decision: String, Sendable { case start, stop, ignored }
    /// A press while the start runs: within 150 ms it is a bounce, later it stops what is starting (review V6).
    nonisolated static func decide(running: Bool, startedAt: Date?, now: Date) -> Decision {
        guard let startedAt else { return running ? .stop : .start }
        return now.timeIntervalSince(startedAt) > FlowIQTheme.Pill.bounce ? .stop : .ignored
    }
    func start(_ kind: SessionKind, _ language: RecordingLanguage) async {
        guard let recorder = parts.recorder else { return }
        parts.starting[kind] = .now
        pill.update { $0.pending.insert(kind.pillID) }  // the pill shows at once, before the start stands
        defer {
            parts.starting[kind] = nil
            pill.update { $0.pending.remove(kind.pillID) }
        }
        var engine = settings.effective(kind == .call ? .call : .room, hasKey: ui.hasKey).live
        if parts.cloud?.live != true || !ui.hasKey { engine = .appleLocal }
        do {
            try await recorder.start(kind, language: language, engine: engine)
            announce("\(kind.rawValue) läuft")
        } catch {
            parts.runtime?.log.record(.failure("recording_start_failed", error))
            if error is SafeFS.Denied || error is CocoaError { ui.alerts.insert(.folderMissing, at: 0) } else {
                ui.problem = "\(kind.rawValue) nicht gestartet"
            }
        }
        await refresh()
    }
    /// The ring takes the pill's place at once (V5) and fills until saved, through a first after-run if one is due.
    func stop(_ kind: SessionKind) async {
        guard parts.stopping.insert(kind).inserted else { return }  // a second press while the stop runs
        let ran = ui.running.first { $0.kind == kind }.map { Date().timeIntervalSince($0.started) }
        pill.update { s in if kind == .call { s.call = nil } else { s.room = nil } }
        pill.saving(kind, recorded: ran ?? 0)
        await parts.recorder?.stop(kind)
        parts.refreshes += 1  // a refresh that looked before the stop's end must not bring the recording back
        parts.stopping.remove(kind)
        ui.running.removeAll { $0.kind == kind }
        if await parts.recorder?.filing.aftercare.working(kind == .call ? .call : .room) == true {
            parts.afterRun.insert(kind)
        } else { pill.saved(kind) }
        announce("\(kind.rawValue) beendet")
        await refresh()
    }
    /// The pill is invisible to VoiceOver, so start, stop and a silent track are spoken (review S11).
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text])
    }
    /// Saves, then the after-run switches and the login item follow (M.1, K-14); a locked choice beeps.
    func change(_ edit: (inout FlowIQCore.Settings) throws -> Void) {
        var next = settings
        do { try edit(&next) } catch {
            if error as? ModeChoiceError == .keyMissing { ui.keyFocus = true }
            return NSSound.beep()
        }
        (settings, ui.problem) = (next, nil)
        keep.withLock { $0 = next.keepDictationInClipboard }
        let (p, key, or, production) = (parts, ui.hasKey, ui.openRouterKey, profile == .production)
        Task {
            do { try await p.runtime?.store.save(next) } catch { ui.problem = "Einstellung nicht gespeichert" }
            for m in RecordingMode.allCases {
                let on = p.cloud?.post != nil && next.effective(m, hasKey: key, openRouterKey: or).post == .elevenLabs
                await p.recorder?.filing.aftercare.setPostEnabled(on, for: m)
            }
            if production { await p.runtime?.applyLoginItem(.apply(enabled: next.launchAtLogin)) }
            await refresh()
        }
    }
    /// The key goes straight to the keychain (M.7); an empty field removes it. Nothing is sent to check it, but a
    /// text without the key's prefix (the key id, 16.11.) is not saved. A new key starts refused after-runs again.
    func storeKey(openRouter: Bool = false) {
        guard let keys = openRouter ? parts.orKeys : parts.cloud?.keys else { return }
        let draft = (openRouter ? ui.orDraft : ui.keyDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        (ui.keyDraft, ui.orDraft) = ("", "")
        ui.keyWrong.remove(keys.provider)
        guard draft.isEmpty || draft.hasPrefix(keys.provider.keyPrefix) else {
            ui.keyWrong.insert(keys.provider)
            return
        }
        do { if draft.isEmpty { try keys.remove() } else { try keys.store(draft) } } catch {
            ui.problem = "Schlüsselbund verweigert"
        }
        let usable = keys.hasKey && cloudAllowed
        if openRouter { ui.openRouterKey = usable } else { ui.hasKey = usable }
        change { _ in }
        if !draft.isEmpty { Task { await parts.recorder?.filing.aftercare.trigger(.newKey); await refresh() } }
    }
    nonisolated static func keyHint(_ p: CloudProvider) -> String {
        (p == .elevenLabs ? "Das ist die Schlüssel-ID." : "Das ist nicht der Schlüssel.")
            + " Der Schlüssel beginnt mit \(p.keyPrefix)."
    }
    /// Panotti's `.env`, only on a click (R-066).
    func importKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url, let keys = parts.cloud?.keys else { return }
        do { _ = try keys.importFromEnv(String(contentsOf: url, encoding: .utf8), userClicked: true) } catch {
            NSSound.beep()
        }
        ui.hasKey = keys.hasKey && cloudAllowed
        change { _ in }
    }
    func setLimit(_ minutes: Int?) {
        change { $0.cloudLimitMinutes = minutes }
        Task { [usage = parts.cloud?.usage] in await usage?.setLimit(minutes) }
    }
    /// A new place (or audio archive) takes effect at once (task 3): the old after-run settles first, nothing records.
    func chooseFolder(audio: Bool = false) {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles, panel.canCreateDirectories) = (true, false, true)
        guard ui.running.isEmpty, panel.runModal() == .OK, let url = panel.url else { return }
        change { if audio { $0.audioFolder = url.path } else { $0.transcriptFolder = url.path } }
        Task { await relocate() }
    }
    func relocate() async {
        guard let make = parts.filing, let recorder = parts.recorder else { return }
        await recorder.filing.aftercare.settle()
        let place = settings.locations(Paths(profile: profile)), next = make(place)
        if await recorder.use(next) { await next.aftercare.trigger(.appStart) } else { NSSound.beep() }
        parts.devices?.stop()
        parts.devices = parts.makeDevices?(place)  // the device archive follows as well
        await refresh()
    }
    func chooseMic(_ uid: String?) {
        let system = SystemDevices.current(), conductor = parts.stack?.conductor
        ui.mic = uid
        let device = uid.map { InputDevice(uid: $0, isBuiltIn: $0 == system.fallback?.uid) } ?? system.standard
        Task { if let device { await conductor?.switchMic(to: device) } }
    }
    func show(_ tab: Tab) {
        ui.tab = tab
        openMain(tab == .words ? .words : .settings)
        parts.words?.decide {}
    }
    private func makeHistory() -> HistoryModel {
        HistoryModel(journal: nil) { [weak self] id in
            Task { _ = await self?.parts.stack?.correction.open(from: .menu, dictation: id) }
        }
    }
    /// The main window at a section; the stores it reads are attached on every opening (they come up late).
    func openMain(_ section: MainView.Section) {
        ui.section = section
        (history.journal, history.inserter) = (parts.stack?.journal, parts.stack?.inserter)
        (history.lexicon, history.log) = (parts.stack?.lexicon, parts.runtime?.log)
        recordings.folder = settings.locations(Paths(profile: profile)).transcripts
        recordings.retry = { [weak self] in
            await self?.parts.recorder?.filing.aftercare.trigger(.click)
            await self?.recordings.load()
        }
        (recordings.models, names.lexicon) = (parts.models, parts.stack?.lexicon)
        (review.lexicon, review.journal, review.folder) = (parts.stack?.lexicon, parts.stack?.journal,
                                                           Paths(profile: profile).support)
        history.redo = { [weak self] job in
            guard let after = await self?.parts.recorder?.filing.aftercare else { throw PostFailure.keyMissing }
            return try await after.redo(job)
        }
        recordings.postNow = { [weak self] row, choice, model in
            let mode: RecordingMode = row.kind == "Call" ? .call : row.kind == "Raum" ? .room : .device
            guard let after = await self?.parts.recorder?.filing.aftercare else { return }
            do { try await after.postNow(row.url, mode: mode, choice: choice, model: model) } catch {
                self?.recordings.note = "Genauere Fassung ging nicht los."
            }
            await self?.recordings.load()
        }
        mainWindow.show()
        let (journal, days, log) = (history.journal, settings.historyDays, parts.runtime?.log)
        Task {  // "Verlauf aufbewahren": older dictations go when the window opens, text and audio
            if let days { await log?.attempt("history_prune") { try await journal?.prune(olderThan: days) } }
            await history.load()
            await recordings.load()
        }
    }
    /// Full after every action and at menu open; while busy once a second only the running state, off the main
    /// thread for files, devices and keychain (R-087, review); every minute the after-run gets its `.timer`.
    func refresh(full: Bool = true) async {
        let p = parts, wasSilent = ui.running.contains(where: \.silent)
        for kind in await p.recorder?.diskFullEnded() ?? [] {  // A.5: the audio is kept, the user is told once
            ui.problem = "Platte voll, \(kind.rawValue) gesichert und beendet"
        }
        parts.refreshes += 1
        let generation = parts.refreshes, snapshot = await p.recorder?.snapshot() ?? []
        guard generation == parts.refreshes else { return }  // a newer refresh has a newer picture
        put(\.running, snapshot)
        put(\.post, await p.recorder?.filing.aftercare.visibleState ?? .idle)
        put(\.rejection, await p.recorder?.filing.aftercare.rejection)
        for kind in parts.afterRun {
            if await p.recorder?.filing.aftercare.working(kind == .call ? .call : .room) == true { continue }
            parts.afterRun.remove(kind)
            pill.saved(kind)  // the after-run is done, or waits for a retry that the menu shows
        }
        put(\.troubles, await p.recorder?.troubles() ?? [:])
        parts.ticks += 1
        if !full && parts.ticks % 60 == 0 { await p.recorder?.filing.aftercare.trigger(.timer) }
        if full {
            let (folder, keys, allowed) = (folder, p.cloud?.keys, cloudAllowed)
            (ui.recent, ui.mics, ui.hasKey, ui.folderOK) = await Task.detached {
                let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                             position: .unspecified).devices
                return (Self.recent(in: folder), Dictionary(found.map { ($0.uniqueID, $0.localizedName) }) { a,
                    _ in a },
                        keys?.hasKey ?? false && allowed,
                        FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
            }.value
            let state = await PermissionState.read()
            (ui.missing, ui.screenGranted) = (state.missing, state.granted.contains(.screenRecording))
            let orKeys = p.orKeys
            ui.openRouterKey = await Task.detached { orKeys?.hasKey ?? false }.value && cloudAllowed
            ui.openRouterUSD = await p.meter?.costUSD("openrouter") ?? 0
            (ui.cloudSeconds, ui.newNames) = (await p.cloud?.usage.meter.monthTotalSeconds() ?? 0,
                await p.words?.count() ?? 0)
            ui.keysShared = panottiShares()
            await p.devices?.look()
            startTap()
            registerKeys()
        }
        var settled = ui
        Self.settle(&settled)
        put(\.down, settled.down)
        put(\.micLost, settled.micLost)
        put(\.pauses, settled.pauses)
        put(\.device, parts.devices?.notice)
        let running = ui.running, silent = Self.silent(ui)
        put(\.alerts, Self.alerts(ui, silent: silent, limit: settings.cloudLimitMinutes ?? 0))
        if !wasSilent && silent { announce("Mikrofon liefert keinen Ton") }
        let shown = ui, stopping = parts.stopping
        pill.update { Self.show(shown, in: &$0, except: stopping) }
        let first = running.map(\.started).min().map { Int(Date().timeIntervalSince($0)) }
        p.menu?.showSymbol(recording: !running.isEmpty, cloud: running.contains(where: \.sending)
                           || p.cloud?.badge.isVisible(on: .menuBar) == true, warning: !ui.alerts.isEmpty,
                           elapsed: first)
        let busy = !running.isEmpty || ui.post != .idle
        if busy, p.tick == nil {
            parts.tick = Timer.scheduledTimer(withTimeInterval: FlowIQTheme.Motion.tick,
                repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let self { Task { await self.refresh(full: false) } } }
            }
        } else if !busy {
            p.tick?.invalidate()
            parts.tick = nil
        }
    }
    /// Writes only a changed value: every write of `ui` draws the open window anew, and the busy tick wrote once
    /// a second (16.11.: sampled at 25 % CPU in the history list, the log showed 90 % for hours while idle).
    func put<T: Equatable>(_ path: WritableKeyPath<Shown, T>, _ value: T) {
        if ui[keyPath: path] != value { ui[keyPath: path] = value }
    }

    /// The running recordings as the pill shows them (not those being stopped): the language, and a problem that
    /// turns the pill orange while it lasts. Exactly the cases with a line in the menu (`alerts`): silent or lost
    /// microphone or headset, live text out, cloud fallback or limit, for a call the missing other side.
    nonisolated static func show(_ ui: Shown, in s: inout PillScene, except: Set<SessionKind> = []) {
        let rec = { (kind: SessionKind) in ui.running.first { $0.kind == kind && !except.contains(kind) }.map { r in
            PillScene.Recording(english: r.language == .en, problem: r.silent || ui.down.contains(.microphone)
                || ui.micLost != nil || ui.troubles[kind] != nil || r.fallback == .networkError || r.fallback == .limit
                || kind == .call && (!ui.screenGranted || r.desktopSilent || ui.down.contains(.desktop))) } }
        (s.call, s.room) = (rec(.call), rec(.room))
    }
    /// After each look at the recorder: a failure belongs to its session and ends with it (review V1).
    nonisolated static func settle(_ ui: inout Shown) {
        if ui.running.isEmpty { (ui.down, ui.micLost) = ([], nil) }
        ui.pauses = ui.pauses.filter { p in ui.running.contains { $0.kind == p.key } }
    }
    /// A silent microphone, never a desktop that is down: that one is `noDesktop` (Szenarien, B.5).
    nonisolated static func silent(_ ui: Shown) -> Bool {
        ui.running.contains { $0.silent } || ui.down.contains(.microphone) && !ui.running.isEmpty
    }
    /// The warning lines (review M5, N3): state plus next step, in this order.
    nonisolated static func alerts(_ ui: Shown, silent: Bool, limit: Int) -> [AppAlert] {
        var list: [AppAlert] = (ui.problem.map { [.problem($0)] } ?? []) + ui.missing.map { .permission($0.title) }
        if ui.running.contains(where: { $0.kind == .call }) {  // no standing restart warning without permission
            if !ui.screenGranted {  // said once: from `missing` when the permission check ran, else here
                if !ui.missing.contains(.screenRecording) { list.append(.permission(Permission.screenRecording.title)) }
            } else if
                ui.down.contains(.desktop) || ui.running.contains(where: \.desktopSilent) { list.append(.noDesktop) }
        }
        if ui.keysShared {
            list.append(.panottiKeys)
        } else if !ui.missing.contains(.inputMonitoring) && !ui.tapRunning {
            list.append(.tapStopped)
        }
        for t in ui.troubles.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map(\.value)
        where !list.contains(.trouble(t)) { list.append(.trouble(t)) }
        if silent { list.append(.micSilent) }
        if ui.running.contains(where: { $0.fallback == .networkError }) { list.append(.networkDown) }
        if ui.running.contains(where: { $0.fallback == .limit }) { list.append(.limitReached(limit)) }
        if let why = ui.rejection { list.append(.postRejected(why)) } else if case .paused = ui.post {
            list.append(.keyRejected)
        }
        if case .waiting(let n) = ui.post { list.append(.postWaiting(n)) }
        if ui.notInserted { list.append(.notInserted) }
        if !ui.folderOK { list.append(.folderMissing) }
        if let name = ui.micLost, !ui.running.isEmpty { list.append(.micLost(name)) }
        if let audio = ui.dictationFailed { list.append(.dictationFailed(audio: audio)) }
        if case .failed(let why) = ui.importing {
            list.append(.importFailed(ui.importFailed.count == 1 ? ui.importFailed.first : nil, ui.importFailed.count,
                                      why))
        }
        if let d = ui.device, d.what == .off || d.what == .unknown {
            list.append(d.what == .off ? .recorderOff(d.name) : .recorderUnknown(d.name))
        }
        for kind in [SessionKind.call, .room] { if let span = ui.pauses[kind] { list.append(.paused(kind, span)) } }
        return list.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }

    /// A taken shortcut is shown, not only logged (review T7).
    nonisolated static func taken(_ keys: [HotKey]) -> String {
        let names: [HotKey: String] = [.call: "Call", .room: "Raum", .english: "Englisch (E)", .correct: "Korrigieren"]
        return "Kurzbefehl belegt: " + keys.map { names[$0] ?? $0.rawValue }.joined(separator: ", ")
    }
    /// The predecessor app Panotti (optional) runs with the same keys (16.11.): nothing is registered twice, Fn rests.
    func panottiShares() -> Bool {
        !settings.alternateKeys && NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Panotti" }
    }
    /// Shortcuts not yet registered, again once Panotti is gone; a taken one is shown (review T7).
    func registerKeys() {
        guard !ui.keysShared, let keys = parts.hotKeys, !parts.pendingKeys.isEmpty else { return }
        parts.pendingKeys = keys.register(parts.pendingKeys)
        if !parts.pendingKeys.isEmpty { ui.problem = Self.taken(parts.pendingKeys) }
    }
    /// The menu bar may hide the icon (full bar with notch): one hint in the settings, the pill opens the menu.
    func checkIcon() {
        guard parts.menu?.iconVisible == false, !settings.menuBarHintShown else { return }
        ui.iconHint = true
        change { $0.menuBarHintShown = true }
        show(.recording)
    }
    /// The Fn tap starts again as soon as input monitoring is granted, without a restart (review M2).
    func startTap() {
        guard !ui.tapRunning, !ui.keysShared, !ui.missing.contains(.inputMonitoring), let input = parts.stack?.input
        else { return }
        do { try input.start(); ui.tapRunning = true } catch {
            parts.runtime?.log.record(.failure("input_unavailable", error))
        }
    }
    /// Newest first, from the file names `yyyy-MM-dd-HHmm-call|raum.md` (A.9).
    nonisolated static func recent(in folder: URL) -> [RecentTranscript] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch { return [] }
        let f = DateFormatter()
        (f.dateFormat, f.locale) = ("yyyy-MM-dd-HHmm", Locale(identifier: "en_US_POSIX"))
        return names.sorted(by: >).compactMap { name in
            let kind: SessionKind? = name.hasSuffix("-call.md") ? .call : name.hasSuffix("-raum.md") ? .room : nil
            guard let kind, let date = f.date(from: String(name.prefix(15))) else { return nil }
            return RecentTranscript(url: folder.appending(path: name), kind: kind, date: date)
        }
    }
    /// Development only (A.12, D5): what can be checked without a permission prompt, logged and shown once.
    func selfTest() {
        let icon = Bundle.main.url(forResource: "menueleiste-b", withExtension: "svg") != nil, alert = NSAlert()
        let checks = [("DM Sans gebündelt", FlowIQTheme.Font.isBundled), ("Menüleisten-Symbol", icon),
                      ("Ablage erreichbar", ui.folderOK), ("Fn-Abgriff", ui.tapRunning), ("Rechte", ui.missing.isEmpty),
                      ("ElevenLabs-Schlüssel", ui.hasKey)]
        parts.runtime?.log.record(LogEvent("selftest", .init(uniqueKeysWithValues: checks.map { ($0, .bool($1)) })))
        (alert.messageText, alert.informativeText) = ("Selbsttest", checks.map { ($1 ? "✓ " : "✗ ") + $0 }
            .joined(separator: "\n"))
        alert.runModal()
    }
}

nonisolated extension PermissionState {
    /// Screen recording counts too (16.11.: the log said `permission`, the menu stayed silent while idle).
    var missing: [Permission] {
        [.microphone, .accessibility, .inputMonitoring, .screenRecording].filter { !granted.contains($0) }
    }
}
