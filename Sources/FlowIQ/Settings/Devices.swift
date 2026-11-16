import SwiftUI

/// Local recognition of a secured device copy (A.11, N.4): the file run of `FlowIQSpeech`, one segment per sentence.
nonisolated struct DeviceSpeech: DeviceTranscriber {
    let log: EventLog
    func transcribe(_ audio: URL, language: RecordingLanguage) async throws -> [LiveSegment] {
        let r = try await FileTranscriber.recognize(audio, locale: Locale(identifier: language.rawValue),
                                                    limit: .seconds(3_600), log: log)
        return r.segments.map { s in
            let words = r.runs.filter { $0.start >= s.start && $0.start < s.end }
            return LiveSegment(words: words.isEmpty ? [TimedWord(text: s.text, start: s.start, end: s.end,
                confidence: nil)]
                               : words, speaker: nil)
        }
    }
}

/// Filing through the current storage place (A.9, R-064): the after-run only with the devices switch.
nonisolated struct DeviceStore: DeviceFiling {
    let recorder: Recorder
    func file(_ r: DeviceRecording) async throws -> URL {
        try await recorder.filing.aftercare.fileDevice(
            device: r.kind == .zephyr ? "ZEPHYR" : r.kind == .dvt1600 ? "DVT1600" : "Test", label: r.label,
            originalName: r.originalName, sha256: r.sha256, deviceSHA256: r.deviceSHA256, recordedAt: r.recordedAt,
            seconds: r.seconds, audio: r.audio, segments: r.segments, language: r.language, post: r.post)
    }
}

/// Geräte (A.12, R-072, R-076): the switch, what each device brought, Panotti's journal on one click (R-008).
@MainActor @Observable
final class DevicesModel {
    let importer: DeviceImporter?, watch: DeviceWatch?, adopted: () -> Void
    var enabled = false
    var rows: [(String, String)] = []
    var unknown: [MountedVolume] = []
    var files: [DeviceImporter.FileRow] = []  // per pen file, newest first (review W2)
    var notice: DeviceNotice?  // the menu's line
    var visible = false  // the Geräte tab is on screen
    nonisolated static let names: [DeviceKind: String] = [.dvt1600: "Stift", .zephyr: "ZEPHYR", .test: "Test"]
    /// The kinds a volume can be made here: production never the test image, development only that.
    var kinds: [DeviceKind] { DeviceKind.allCases.filter { ($0 == .test) == (importer?.profile == .development) } }
    init(_ importer: DeviceImporter?, adopted: @escaping () -> Void = {}) {
        (self.importer, watch, self.adopted) = (importer, importer.map(DeviceWatch.init), adopted)
    }
    /// At launch: the mount observer, and devices that were plugged in already (review T2).
    func start() async {
        await watch?.refresh()
        _ = await importer?.scan()  // switched off this only looks whether a recorder is plugged in
        await load()
    }
    /// Menu or tab opens: what is plugged in now (no observer runs while the switch is off, R-076).
    func look() async {
        await importer?.look()
        await load()
    }
    /// Every step of the import and every mount or unmount: the menu's line, and the list while it is on screen.
    func step(_ p: ImportProgress, was: ImportProgress) async {
        if case .copying = p, case .copying = was { return }
        if visible { await load() } else { notice = await importer?.notice }
    }
    /// A plugged-in volume becomes a known device by its identifier, one click (A.11, review T1).
    func register(_ volume: MountedVolume, as kind: DeviceKind) {
        Task {
            do { try await importer?.register(volume, as: kind) } catch { NSSound.beep() }
            _ = await importer?.scan()
            await load()
        }
    }
    func load() async {
        guard let importer else { return }
        (enabled, notice) = (await importer.config.enabled, await importer.notice)
        files = Array(await importer.fileRows().reversed())
        let entries = await importer.entries().filter { $0.phase == .done }, known = await importer.config.profiles
        // a write-protected volume only if it looks like a recorder (the ZEPHYR), never every disk image
        unknown = DeviceWatch.mounted().filter { v in !known.contains { $0.volumeUUID == v.uuid }
            && v.url.path.hasPrefix("/Volumes/") && (!v.readOnly || DeviceKind.recognize(v) != nil) }
        let names = Self.names
        let groups = Dictionary(grouping: entries, by: \.kind).sorted { $0.key.rawValue < $1.key.rawValue }
        rows = groups.map { kind, list in
            let last = list.compactMap(\.recordedAt).max().map { ", zuletzt " + StatusMenuModel.day($0, now: .now) }
            return (names[kind] ?? kind.rawValue, "\(list.count) Dateien" + (last ?? ""))
        }
    }
    func set(_ on: Bool) {
        enabled = on  // at once: the import that follows may take minutes
        Task {
            do { try await importer?.setEnabled(on) } catch { NSSound.beep() }
            await watch?.refresh()
            _ = await importer?.scan()
            await load()
        }
    }
    /// Panotti's settings as a chosen file for the ZEPHYR clock offset (A.11, review T3); cancel takes none.
    static func settingsFile() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Panottis Einstellungen (.plist) für den ZEPHYR-Zeitversatz, sonst Abbrechen"
        return panel.runModal() == .OK ? panel.url : nil
    }
    func retry() { Task { _ = await importer?.scan(); await load() } }
    /// Dry run first, then one click; Panotti's folder is only read (A.11).
    func takeOver() {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles) = (true, false)
        guard let importer, panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                let plan = try await importer.takeoverPlan(from: folder, settings: Self.settingsFile())
                let alert = NSAlert()
                alert.messageText = "\(plan.entries.count - plan.known) Aufnahmen und \(plan.ignored.count) ignorierte "
                    + "Dateien übernehmen?"
                alert.addButton(withTitle: "Übernehmen")
                alert.addButton(withTitle: "Abbrechen")
                if alert.runModal() == .alertFirstButtonReturn { try await importer.takeover(plan); adopted() }
            } catch { NSSound.beep() }
            await load()
        }
    }
}

struct DevicesPane: View {
    @Bindable var model: DevicesModel
    let panotti: Bool
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s12) {
            Block("Aufnahmegeräte") {
                SettingRow(title: "Diktiergerät automatisch importieren", sub: "Stift oder Rekorder einstecken, FlowIQ "
                           + "kopiert neue Aufnahmen, das Gerät bleibt unverändert") {
                    Toggle(isOn: Binding(get: { model.enabled }, set: { model.set($0) })) { EmptyView() }
                        .toggleStyle(FlowSwitch()).fixedSize().disabled(model.importer == nil)
                }
                if model.enabled && model.rows.isEmpty && model.files.isEmpty && model.unknown.isEmpty {
                    SettingRow(title: "Noch nichts", sub: "Ein eingestecktes Gerät erscheint hier", last: true) {
                        EmptyView() }
                }
                ForEach(model.enabled ? model.rows : [], id: \.0) { name, detail in
                    Row(title: name) { Text(detail).textStyle(t.Font.caption, t.Color.textMuted); Spacer() }
                }
                ForEach(model.enabled ? Array(model.files.prefix(5).enumerated()) : [], id: \.offset) { _, f in
                    HStack(spacing: t.Spacing.s8) {
                        Text(f.name).textStyle(t.Font.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(f.state).textStyle(t.Font.caption, f.retry ? t.Color.warningText : t.Color.textMuted)
                        if f.retry { Button("Erneut versuchen") { model.retry() }.buttonStyle(FlowButton()) }
                    }
                    .frame(minHeight: t.Size.row).overlay(alignment: .bottom) { Hairline() }
                }
                ForEach(model.enabled ? model.unknown : [], id: \.uuid) { v in
                    Row(title: v.name) {
                        Text("eingesteckt, unbekannt").textStyle(t.Font.caption, t.Color.textMuted)
                        Spacer()
                        Menu("Zuordnen …") {
                            ForEach(model.kinds, id: \.self) { k in Button(k.rawValue) { model.register(v,
                                as: k) } }
                        }
                        .menuStyle(.button).buttonStyle(FlowButton()).fixedSize()
                    }
                }
            }
            if panotti && model.importer != nil {
                Button("Panotti-Daten übernehmen …") { model.takeOver() }.buttonStyle(FlowButton())
            }
            Explain(title: "Was passiert beim Einstecken?", text: "FlowIQ kopiert neue Dateien, prüft jede Kopie und "
                    + "erkennt lokal. Auf dem Gerät wird nichts gelöscht, verschoben oder umbenannt. Den Fortschritt "
                    + "zeigt der Ring an der Pille, die genauere Fassung für Geräte steht im Bereich Aufnahme.")
        }
        .task { model.visible = true; await model.look() }
        .onDisappear { model.visible = false }
    }
}
