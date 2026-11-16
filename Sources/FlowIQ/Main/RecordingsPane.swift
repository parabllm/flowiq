import AppKit
import SwiftUI

/// One call, room or device transcript as the list shows it, read from the vault file's header only.
nonisolated struct RecordingRow: Sendable, Equatable, Identifiable {
    enum Post: Hashable, Sendable { case local, waiting, paused, running, done }
    let url: URL, date: Date, kind: String, duration: String, language: String, live: String, post: Post
    let audio: URL?
    var id: URL { url }
    /// The header keys of the vault contract (A.9, M.10): phase, after-run mark, pipeline, live source.
    static func read(_ url: URL) -> RecordingRow? {
        guard let head = FileManager.default.contents(atPath: url.path).map({ String(decoding: $0.prefix(4096),
                                                                                       as: UTF8.self) }),
              head.hasPrefix("---") else { return nil }
        var f: [String: String] = [:]
        for line in head.split(separator: "\n").dropFirst() {
            if line == "---" { break }
            if let c = line.firstIndex(of: ":"), !line.hasPrefix(" ") {
                f[String(line[..<c])] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let name = url.deletingPathExtension().lastPathComponent, stamp = String(name.prefix(15))
        let n = stamp.split(separator: "-").map { Int($0) ?? 0 }, hm = n.count == 4 ? n[3] : 0
        let date = n.count == 4 ? Calendar.current.date(from: DateComponents(year: n[0], month: n[1], day: n[2],
            hour: hm / 100, minute: hm % 100)) ?? .distantPast : .distantPast
        let kind = name.contains("-call") ? "Call" : name.contains("dvt1600") || name.contains("zephyr") ? "Rekorder"
            : "Raum"
        let phase = f["panotti_phase"] ?? "", mark = f["nachlauf"] ?? ""
        let post: Post = phase == "live-stream" ? .running : mark == "wartet" ? .waiting : mark == "angehalten"
            ? .paused : phase == "final-elevenlabs" ? .done : .local
        let live = (f["live_quelle"] ?? "").hasPrefix("elevenlabs") ? "Mitschrift über ElevenLabs"
            : "Mitschrift auf dem Mac"
        let source = f["quelle"].map { URL(filePath: $0) }
        let audio = source.map { kind == "Call" ? $0.appending(path: "mikrofon.m4a") : $0 }
        return RecordingRow(url: url, date: date, kind: kind, duration: f["dauer"] ?? "–",
                            language: (f["sprache"] ?? "de").hasPrefix("en") ? "Englisch" : "Deutsch",
                            live: live, post: post, audio: audio)
    }
    static let text: [Post: String] = [.local: "fertig auf dem Mac", .waiting: "genauere Fassung wartet",
        .paused: "genauere Fassung angehalten: Schlüssel oder Kontingent fehlt", .running: "läuft",
        .done: "genauere Fassung fertig"]
}


/// Aufnahmen: newest first from the transcript folder and its archive.
@MainActor @Observable
final class RecordingsModel {
    @ObservationIgnored var folder: URL?
    @ObservationIgnored var retry: () async -> Void = {}
    /// One after-run now, also for a file that ended local; service and model for this run only.
    @ObservationIgnored var postNow: (RecordingRow, PostService?, String?) async -> Void = { _, _, _ in }
    @ObservationIgnored var models: [OpenRouterModel] = []
    var rows: [RecordingRow] = []
    var note = ""
    init(folder: URL? = nil) { self.folder = folder }
    func load() async {
        guard let folder else { return }
        rows = await Task.detached { Self.scan(folder) }.value
    }
    nonisolated static func scan(_ folder: URL) -> [RecordingRow] {
        [folder, folder.appending(path: "archive", directoryHint: .isDirectory)].flatMap { dir -> [RecordingRow] in
            let urls: [URL]
            do { urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) } catch {
                return []  // a missing archive folder lists nothing
            }
            return urls.filter { $0.pathExtension == "md" }.compactMap(RecordingRow.read)
        }
        .sorted { $0.date > $1.date }
    }
    func play(_ row: RecordingRow) {
        let played = row.audio.flatMap { NSSound(contentsOf: $0, byReference: true)?.play() } ?? false
        if !played { note = "Kein Audio da." }
    }
}

struct RecordingsPane: View {
    @Bindable var model: RecordingsModel
    @Bindable var app: AppModel
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s8) {
            ForEach(app.ui.running, id: \.kind) { r in  // a running recording first, where one looks for it
                Text("\(r.kind.rawValue) läuft seit \(Int(Date().timeIntervalSince(r.started) / 60)) Min.")
                    .textStyle(t.Font.caption).padding(t.Spacing.s8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(t.Color.accentTint, in: RoundedRectangle(cornerRadius: t.Radius.md))
            }
            if !model.note.isEmpty { Text(model.note).textStyle(t.Font.micro, t.Color.textMuted) }
            if model.rows.isEmpty {
                Text("Noch keine Aufnahmen. ⌘⌥U startet einen Call, ⌘⌥R einen Raum.")
                    .textStyle(t.Font.caption, t.Color.textMuted)
            } else {
                ScrollView {
                    let days = Dictionary(grouping: model.rows) { Calendar.current.startOfDay(for: $0.date) }
                    LazyVStack(alignment: .leading, spacing: t.Spacing.s4) {
                        ForEach(days.keys.sorted(by: >), id: \.self) { day in
                            let rows = days[day] ?? []
                            Text(HistoryModel.dayTitle(day)).textStyle(t.Font.label, t.Color.textMuted)
                                .padding(.top, t.Spacing.s6)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { n, r in
                                    row(r, last: n == rows.count - 1)
                                }
                            }
                            .card()
                        }
                    }
                    .padding(.bottom, t.Main.inset)
                }
            }
        }
        .padding(.horizontal, t.Main.inset)
        .task { await model.load() }
    }
    private func row(_ r: RecordingRow, last: Bool) -> some View {
        let t = FlowIQTheme.self, failed = r.post == .paused
        return HStack(spacing: t.Spacing.s10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(r.kind) · \(r.date, format: .dateTime.hour().minute())")
                    .textStyle(t.Font.caption)
                Text([r.duration, r.language, r.live, RecordingRow.text[r.post] ?? ""]
                    .joined(separator: " · "))
                    .textStyle(t.Font.micro, failed ? t.Color.warningText : t.Color.textMuted)
            }
            Spacer()
            if failed || r.post == .waiting || r.post == .local {
                Button(failed ? "Erneut versuchen" : "Genauere Fassung starten") {
                    Task { r.post == .local ? await model.postNow(r, nil, nil) : await model.retry() }
                }
                .buttonStyle(FlowButton()).fixedSize()
            }
            Button { model.play(r) } label: { Image(systemName: "play.fill") }.buttonStyle(.plain)
                .help("Abspielen").accessibilityLabel("Abspielen")
            Button { NSWorkspace.shared.open(r.url) } label: { Image(systemName: "doc.text") }.buttonStyle(.plain)
                .help("Transkript öffnen").accessibilityLabel("Transkript öffnen")
            Menu {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                Menu("Genauere Fassung nur diesmal über") {  // the setting stays as it is
                    Button("ElevenLabs") { Task { await model.postNow(r, .elevenLabs, nil) } }
                    ForEach(model.models, id: \.id) { m in
                        Button("OpenRouter · \(m.name)") { Task { await model.postNow(r, .openRouter, m.id) } }
                    }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Weitere Aktionen: im Finder zeigen, genauere Fassung über einen anderen Dienst")
                .accessibilityLabel("Weitere Aktionen")
        }
        .foregroundStyle(t.Color.textMuted).padding(.horizontal, t.Spacing.s10).padding(.vertical, t.Spacing.s4)
        .frame(minHeight: t.Main.row + t.Spacing.s4)
        .overlay(alignment: .bottom) { Hairline(hidden: last) }
    }
}
