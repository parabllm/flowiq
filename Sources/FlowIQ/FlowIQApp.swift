// One import line per module for the whole app target (B3).
@_exported import AppKit
@_exported import AVFoundation
@_exported import FlowIQCloud
@_exported import FlowIQDevices
@_exported import FlowIQInput
@_exported import FlowIQInsert
@_exported import FlowIQSpeech
@_exported import FlowIQStore
@_exported import Observation
@_exported import os
@_exported import ServiceManagement

@main
struct FlowIQMain {
    static func main() {
        let app = NSApplication.shared, delegate = AppDelegate(profile: .resolve(.main), info: BuildInfo(.main))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Main thread: menu, pill and windows only; nothing asks for a permission at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let profile: Profile, info: BuildInfo, correction = CorrectionModel()
    private var model: AppModel?
    private var loginLaunch = false, forced: pid_t?
    init(profile: Profile, info: BuildInfo) { (self.profile, self.info) = (profile, info) }
    func applicationWillFinishLaunching(_ notification: Notification) {
        loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let own = Bundle.main.bundleIdentifier ?? "", old = Self.restarted(from: CommandLine.arguments)
        if let old { waitOut(old, bundle: own) }  // "Neu starten": nothing shows before the old instance is gone
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: own).filter { !$0.isTerminated }
        let elder = Self.elder(others.map { ($0.processIdentifier, $0.launchDate) },
                               own: (me.processIdentifier, me.launchDate), ended: old)
        if let first = others.first(where: { $0.processIdentifier == elder }) {  // one instance per profile
            DistributedNotificationCenter.default().postNotificationName(Self.wake, object: nil,
                                                                         deliverImmediately: true)
            NSApp.yieldActivation(to: first)
            first.activate()
            return NSApp.terminate(nil)  // still accessory, nothing built: this one was never visible
        }
        NSApp.setActivationPolicy(.regular)  // in the Dock while it runs (16.11.); never activates by itself
        NSApp.mainMenu = quitMenu()
        let model = AppModel(profile: profile, settings: .defaults(for: profile))
        let menu = StatusMenu(profile: profile) { model.menuState }
        menu.perform = { model.perform($0) }
        menu.onOpen = { Task { await model.parts.runtime?.sample("menu"); await model.refresh() } }
        menu.onClose = { model.ui.crashNote = nil }
        model.parts.menu = menu
        model.pill.onClick = { menu.popUp(in: $0) }  // stop runs over the keys and the menu (16.11.)
        DistributedNotificationCenter.default().addObserver(forName: Self.wake, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.openMain(.history) }  // a second start woke this instance
        }
        model.setupWindow.onKey = { Task { await model.setup.refresh(); await model.refresh() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in  // v1: waking, no network monitor
            Task { @MainActor in await model.parts.recorder?.filing.aftercare.trigger(.networkBack) }
        }
        self.model = model
        Task {
            await start(model)
            if !loginLaunch { model.openMain(.history) }  // opened by hand: the window; at login only the menu bar
            if !model.ui.missing.isEmpty { model.setupWindow.show() }  // after the window: a missing right in front
        }
    }
    /// Opening the app again shows the main window: the way in when the menu bar hides the icon (16.11.).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.openMain(.history)
        return false
    }
    nonisolated static var wake: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "de.flowiq.app") + ".zeigen")
    }
    nonisolated static func restarted(from args: [String]) -> pid_t? {
        args.firstIndex(of: "--nach-neustart").flatMap { $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil }
    }
    nonisolated static func isSecond(_ pid: pid_t, own: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        pid != own
    }
    /// The instance this one gives way to: the earlier launch, the lower pid on a tie; two starts at once never
    /// both quit. `ended` is the old instance of a restart and never counts.
    nonisolated static func elder(_ others: [(pid: pid_t, launched: Date?)], own: (pid: pid_t, launched: Date?),
                                  ended: pid_t? = nil) -> pid_t? {
        others.first { other in
            guard isSecond(other.pid, own: own.pid), other.pid != ended else { return false }
            if let theirs = other.launched, let mine = own.launched, theirs != mine { return theirs < mine }
            return other.pid < own.pid
        }?.pid
    }
    nonisolated enum Takeover: Equatable { case wait, force }
    nonisolated static func takeover(waited: Double, limit: Double = FlowIQTheme.Motion.restartWait) -> Takeover {
        waited < limit ? .wait : .force
    }
    /// Waits for the old instance; after the limit it is ended hard and this one takes over (16.11.: it hung).
    private func waitOut(_ old: pid_t, bundle: String) {
        let m = FlowIQTheme.Motion.self, start = Date.now
        func alive() -> NSRunningApplication? {  // only a FlowIQ of this profile is ever waited for or ended
            NSRunningApplication(processIdentifier: old).flatMap {
                $0.bundleIdentifier == bundle && !$0.isTerminated ? $0 : nil
            }
        }
        while let app = alive() {
            let waited = Date.now.timeIntervalSince(start)
            if Self.takeover(waited: waited) == .force, forced == nil {
                forced = old
                Runtime.fallback.error("restart: old instance \(old) did not end, forced")
                app.forceTerminate()
            }
            if waited > m.restartWait + m.restartGrace {  // still there after the grace: the signal, then go on
                kill(old, SIGKILL)
                break
            }
            Thread.sleep(forTimeInterval: m.restartPoll)
        }
    }
    /// terminate never runs inside a block of the main dispatch queue: the reply to .terminateLater comes from a
    /// MainActor task, and that queue does not drain while one of its own blocks waits in AppKit's nested loop
    /// (16.11., sampled at the hanging app). A run loop block is outside the queue, so the task runs.
    nonisolated static func outsideMainQueue(_ work: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(work) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    static var restarting = false
    /// Every quit of the app's own goes through here; `restart` starts the new instance once this one may end.
    static func quit(restart: Bool = false) {
        outsideMainQueue {
            restarting = restart
            NSApp.terminate(nil)
        }
    }
    @objc private func quitFromMenu() { Self.quit() }
    private func quitMenu() -> NSMenu {  // ⌘Q needs a main menu once the app is regular
        let bar = NSMenu(), app = NSMenuItem(), sub = NSMenu()
        sub.addItem(withTitle: "\(profile.displayName) beenden", action: #selector(quitFromMenu),
                    keyEquivalent: "q").target = self
        app.submenu = sub
        bar.addItem(app)
        return bar
    }
    /// The new instance gets this pid and waits for its end; started only after the question was answered.
    private func relaunch() async {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--nach-neustart", String(ProcessInfo.processInfo.processIdentifier)]
        let url = Bundle.main.bundleURL
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) } catch {
            Runtime.fallback.error("restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    /// Recording, import or after-run ask first (R-050, review M1); the default keeps recording.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let again = Self.restarting, runtime = model?.parts.runtime
        Self.restarting = false
        if runtime == nil, !again { return .terminateNow }
        if let model, runtime != nil,
           !model.ui.running.isEmpty || model.ui.post != .idle || model.pill.scene.importing != nil {
            let alert = NSAlert()
            let what = model.ui.running.first.map { "\($0.kind.rawValue) läuft" }
                ?? (model.ui.post != .idle ? "genauere Fassung wartet" : "Import läuft")
            (alert.messageText, alert.informativeText) = ("\(what). \(profile.displayName) trotzdem beenden?",
                "Die Aufnahme wird sauber geschlossen, die genauere Fassung kommt beim nächsten Start.")
            alert.addButton(withTitle: "Weiter aufnehmen")
            alert.addButton(withTitle: "Beenden")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await model?.parts.recorder?.stopAll()
            await runtime?.stop()
            if again { await relaunch() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func start(_ model: AppModel) async {
        do {
            let (runtime, loaded) = try await Runtime.start(profile: profile, info: info)
            (model.parts.runtime, model.settings) = (runtime, loaded.settings)
            model.keep.withLock { $0 = loaded.settings.keepDictationInClipboard }
            model.ui.problem = loaded.problem.map(Runtime.describe)
            if let forced {
                runtime.log.record(LogEvent("app.restart_forced", level: .error, ["old_pid": .int(Int64(forced))]))
            }
            let sleep = [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)]
            for (name, asleep) in sleep {
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { model.slept(asleep) }  // a recording paused by sleep, in the menu
                }
            }
            let stack = await DictationStack.start(
                profile: profile, keys: loaded.settings.keyScheme, log: runtime.log,
                pill: PillRelay(model.pill) { state in Task { @MainActor in await model.dictation(state) } },
                oracle: SystemWordOracle(), window: correction, keepText: { model.keep.withLock { $0 } },
                onLock: { Task { @MainActor in model.pill.update { $0.locked = true } } })
            model.parts.stack = stack
            model.ui.keysShared = model.panottiShares()
            model.startTap()
            correction.session = stack.correction
            model.parts.words = WordsModel(lexicon: stack.lexicon, ledger: stack.ledger)
            await wire(model, stack, runtime)
            model.parts.hotKeys = HotKeys(profile: loaded.settings.keyScheme, log: runtime.log, running: { key in
                let kind: SessionKind = key == .call ? .call : .room  // running or starting: it stops, nothing waits
                return model.parts.starting[kind] != nil || model.ui.running.contains { $0.kind == kind }
            }, deliver: { model.shortcut($0) })
            model.registerKeys()
        } catch {
            model.ui.problem = "Datenordner nicht anlegbar"
            Runtime.fallback.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
        await model.refresh()
        do { try await Task.sleep(for: .seconds(FlowIQTheme.Motion.iconCheck)) } catch { return }
        model.checkIcon()
    }
    /// Call, room and after-run (P5): the store writes into the chosen place, the cloud only with a key (M.9).
    private func wire(_ model: AppModel, _ stack: DictationStack, _ runtime: Runtime) async {
        let (paths, profile, log, lexicon) = (Paths(profile: profile), profile, runtime.log, stack.lexicon)
        let keys = CloudKeys(keychain: SystemKeychain(), profile: profile), badge = CloudBadge()
        let oracle = SystemWordOracle()
        let orKeys = CloudKeys(keychain: SystemKeychain(), profile: profile, provider: .openRouter)  // 16.11.
        let meter = UsageMeter(folder: paths.support.appending(path: "cloud", directoryHint: .isDirectory),
                               fs: SafeFS(paths: paths), log: log)
        for name in ["fassungen", "nachlauf"] {  // the store's upgrade and queue folders (A.9, A.10)
            log.attempt("folder_failed") { try SafeFS(paths: paths).makeFolder(paths.support.appending(path: name)) }
        }
        let policy: CloudGate.Policy = { [weak model] in
            await MainActor.run { AppModel.policy(model?.settings ?? .defaults(for: .development), profile,
                                                  key: keys.hasKey, openRouterKey: orKeys.hasKey) }
        }
        // Development builds the services under an explicit order; the policy lets them send only on the switch (W3).
        let order: CloudOrder? = profile == .development ? .explicit(reason: "Schalter Testversion") : nil
        var live = false, service: (any PostProcessor)?
        do {
            _ = try CloudGate.realtimeTransport(profile: profile, order: order, log: log)
            live = true
            let pieces = paths.support.appending(path: "nachlauf/stuecke", directoryHint: .isDirectory)
            service = try CloudGate.batchService(profile: profile, order: order, log: log,
                                                 speakerName: Recorder.speaker,
                                                 badge: badge, policy: policy, pieces: { file, window, format in
                try AudioPieces.cut(file, window, format, fs: SafeFS(paths: paths), folder: pieces) }, costs: meter)
        } catch { log.record(LogEvent("cloud_unavailable", ["profile": .string(profile.rawValue)])) }
        let cloud = CloudParts(keys: keys, usage: MonthUsage(meter: meter,
            limitMinutes: model.settings.cloudLimitMinutes),
                               badge: badge, live: live, post: service, profile: profile, log: log, policy: policy,
                               order: order)
        let post = service
        // The storage place with its writer, vault side and after-run; built again when the place changes.
        let filing: @MainActor @Sendable (StoreLocations) -> Filing = { [weak model] place in
            let fs = SafeFS(paths: paths, vault: [place.transcripts, place.archiveAudio]), settings = model?.settings
            let store = TranscriptStore(locations: place, fs: fs, log: log, speakerName: Recorder.speaker,
                                        textStage: { await lexicon.stage() }, oracle: { await oracle.answer($0,
                                            since: .now) })
            let enabled = Dictionary(uniqueKeysWithValues: RecordingMode.allCases.map {
                ($0, post != nil && settings?.effective($0, hasKey: keys.hasKey, openRouterKey: orKeys.hasKey).post
                    == .elevenLabs) })
            return Filing(fs: fs, store: store, aftercare: Aftercare(
                store: store, queue: PostQueue(folder: paths.support.appending(path: "nachlauf"), fs: fs, log: log),
                processor: post ?? NoPost(), postEnabled: enabled, usage: cloud.usage, ledger: stack.ledger,
                confirmedTerms: { CloudTerms.post(from: await lexicon.entries()) }))
        }
        let recorder = Recorder(paths: paths, conductor: stack.conductor, log: log,
                                filing: filing(model.settings.locations(paths)), cloud: cloud, busy: stack.busy,
                                terms: { CloudTerms.live(from: await lexicon.entries()) })
        (model.parts.cloud, model.parts.recorder, model.parts.filing, model.ui.hasKey) = (cloud, recorder, filing,
            keys.hasKey)
        await stack.coordinator.observe(DictationLink(recorder: recorder))
        runtime.monitor.start(log: log) { await recorder.isRecording }
        // Devices with the archive of the current place, built again when it changes (A.11, review T1, T2).
        let devices: @MainActor @Sendable (StoreLocations) -> DevicesModel = { [weak model, pill = model.pill] place in
            let importer = DeviceImporter(
                profile: profile, folders: .init(data: paths.support.appending(path: "geraete"),
                    archive: place.archiveAudio),
                fs: SafeFS(paths: paths, vault: [place.archiveAudio]), log: log, transcriber: DeviceSpeech(log: log),
                filing: DeviceStore(recorder: recorder), post: { [weak model] in await MainActor.run {
                    model?.settings.effective(.device, hasKey: keys.hasKey, openRouterKey: orKeys.hasKey).post
                        == .elevenLabs } },
                gate: ThrottleGate(stack.busy), busy: stack.busy)
            Task {  // the ring at the pill (R-072)
                for await p in importer.progress {
                    pill.importing(p)
                    await model?.imported(p)  // the menu's line and, after a failure, its warning
                }
            }
            let model = DevicesModel(importer, adopted: { model?.change { $0.panottiLink = true } })
            Task { await model.start() }
            return model
        }
        (model.parts.orKeys, model.parts.models, model.parts.meter) = (orKeys, OpenRouterModels.load(), meter)
        (model.parts.makeDevices, model.parts.devices) = (devices, devices(model.settings.locations(paths)))
        model.parts.words?.adopted = { [weak model] in model?.change { $0.panottiLink = true } }
        Task {  // device switch and a source that went down reach menu and pill (review T3)
            for await event in stack.conductor.events {
                switch event {
                case .sourceDown(let kind): model.ui.down.insert(kind)
                case .sourceRestored(let kind): model.ui.down.remove(kind)
                case .deviceSwitched(_, let lost): model.micSwitched(lost: lost)
                }
                await model.refresh()
            }
        }
        Task {  // a new standard device or Bluetooth headset reaches the menu at once
            for await _ in stack.conductor.deviceChanges { await model.refresh() }
        }
        let rescued = await recorder.rescue()  // after a crash: one line in the menu, gone once it closed (16.11.)
        if runtime.crashed { model.ui.crashNote = AppModel.crashNote(profile.displayName, rescued) }
        await recorder.filing.aftercare.trigger(.appStart)
    }
}

/// A dictation during a call or room, and the dictation after-run (R-102, R-108).
nonisolated struct DictationLink: DictationObserver {
    let recorder: Recorder
    func window(started: Bool, host: UInt64) async { await recorder.dictation(started: started, host: host) }
    func inserted(_ job: DictationJob) async {
        await recorder.dictated(job.insertedText, speaker: Recorder.speaker)
        await recorder.inserted(job)
    }
}

/// Without a key or an order nothing is sent: every after-run job waits visibly (R-062, appendix D).
nonisolated struct NoPost: PostProcessor {
    let name = "aus"
    func process(_ job: PostJob) async throws -> PostTranscript { throw PostFailure.keyMissing }
}
