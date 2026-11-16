// Gallery flows E to G: pen, cloud, menu, windows and the stop question (the frame is GalleryTests.swift).
import AppKit
import FlowIQCore
@testable import FlowIQDevices
import FlowIQRecording
import FlowIQStore
import Foundation
import SwiftUI
@testable import FlowIQ

extension GalleryTests {
    /// Flows E and F: what the pen and the cloud show.
    var windowFlows: [(String, [Step])] {
        [
            ("E Stift", [
                // TEST-FIX 16.11.2026 (Pille nach pille-neu.html): ein Kreis neben der Diktat-Pille, kein Punkt
                step("e1-eingesteckt", "Stift eingesteckt: Kreis beginnt", pill: { $0.importing = 0.05 }) { _ in },
                step("e2-kopiert", "Kopiert 70 %", pill: { $0.importing = 0.7 * FlowIQTheme.Pill.ringCap }) { _ in },
                step("e4-abgelegt", "Abgelegt: Ruhe") { _ in },
            ]),
            ("F Cloud", [
                step("f1-live", "ElevenLabs live aktiv: Cloud live in der Beschriftung") {
                    $0.ui.running = [self.call { $0.sending = true }]
                },
                // TEST-FIX 16.11.2026: Bildtext, an der Pille nur Orange
                step("f2-netz-weg", "Netz weg: macht auf dem Mac weiter, Pille orange, Grund im Menü") { m in
                    m.ui.running = [self.call { $0.fallback = .networkError }]
                },
                step("f3-monatsgrenze", "Monatsgrenze erreicht: Warnzeile im Menü, lokal weiter") { m in
                    (m.ui.cloudSeconds, m.settings.cloudLimitMinutes) = (600 * 60, 600)
                    m.ui.running = [self.call { $0.fallback = .limit }]
                },
                step("f4-schluessel-fehlt", "Schlüssel fehlt: alles lokal, Menü zeigt den Weg") {
                    $0.ui.hasKey = false
                },
            ]),
        ]
    }


    /// The windows (flow G): settings, setup, correction, suggestions, hints.
    var windows: [Step] {
        var out: [Step] = []
        for tab in [AppModel.Tab.recording, .devices] {
            out.append(Step(id: "g-einstellungen-\(tab)", caption: "Einstellungen, Reiter \(tab)") {
                let m = self.app()
                m.ui.tab = tab
                m.parts.words = self.words(filled: false)
                m.parts.devices = self.devices()
                return self.page(m)
            })
        }
        out.append(settings("g-ohne-schluessel", "Ohne Schlüssel: ElevenLabs gesperrt, Grund und Schritt darunter") {
            ($0.ui.hasKey, $0.ui.openRouterKey) = (false, false)
        })
        out.append(Step(id: "g-symbol-versteckt", caption: "Menüleisten-Symbol verdeckt: einmaliger Hinweis") {
            let m = self.app { $0.ui.iconHint = true }
            return self.page(m)
        })
        out.append(Step(id: "g-testversion", caption: "Testversion: sendet nicht ohne Schalter") {
            let m = AppModel(profile: .development, settings: .defaults(for: .development),
                             pill: PillView(show: false))
            m.parts.models = self.app().parts.models
            return self.page(m)
        })
        for granted in [0, 2, 4] {
            out.append(Step(id: "g-einrichten-\(granted)", caption: "Einrichten mit \(granted) von 4 Haken") {
                let setup = PermissionModel()
                let all: [Permission] = [.microphone, .accessibility, .inputMonitoring, .screenRecording]
                setup.state = PermissionState(granted: Set(all.prefix(granted)))
                return AnyView(SetupView(model: setup, app: self.app()))
            })
        }
        for (id, caption, edit) in [("g-korrektur", "Korrektur: Wort gewählt", { (c: CorrectionModel) in }),
                                    ("g-korrektur-frage", "Korrektur: Rückfrage", { c in
                                        c.asking = true
                                        c.question = (2, "Angebot", true) }),
                                    ("g-korrektur-leer", "Korrektur: nichts ersetzbar", { c in
                                        c.selection = nil
                                        c.options = CorrectionOptions() })] as [(String, String,
                                                                                (CorrectionModel) -> Void)] {
            out.append(Step(id: id, caption: caption) {
                let c = CorrectionModel()
                c.words = "Schick mir bis Freitag die Zahlen für das Calmora Angebot.".split(separator: " ")
                    .map(String.init)
                (c.changed, c.selection, c.current) = ([8..<9], 8..<9, "a")  // "Calmora", the word the choices fit
                c.options = CorrectionOptions(recognizerAlternatives: ["Kal Mora"], lexiconNeighbors: ["Kalmora"],
                                              rawForm: "Calmora", offersWasRight: false)
                edit(c)
                return AnyView(CorrectionPanel(model: c))
            })
        }
        out.append(step("g-panotti", "Panotti läuft gleichzeitig: Warnzeile, Fn ruht") { $0.ui.keysShared = true })
        out += menus + penList + mainSteps
        out.append(Step(id: "g-modellwahl-offen", caption: "OpenRouter-Modellwahl aufgeklappt: Preis je Stunde, "
                        + "Sprecher und Wortzeiten, eigene ID") {
            let m = self.app()
            let rows = m.parts.models.map { o in
                MenuEntry(id: o.id, title: RecordingPane.modelTitle(o), checked: o.id == m.settings.openRouterModel,
                          action: .settings)
            }
            let own = MenuEntry(id: "own", title: "Eigene Modell-ID …", action: .settings)
            return AnyView(MenuSheet(entries: rows + [MenuEntry(kind: .separator), own]))
        })
        out.append(settings("g-ersatztasten", "Ersatztasten an: ⌃⌥⌘ statt ⌘⌥, ab Neustart") {
            $0.settings.alternateKeys = true
        })
        out.append(Step(id: "g-zum-pruefen", caption: "Zum Prüfen mit zwei Einträgen, darunter Mit Claude prüfen") {
            let w = self.words(filled: false)
            w.review = [(0, "Kalmora statt Calmora", "2 Aufnahmen, 2 Tage"), (1, "Wiebke statt Wipke",
                                                                              "genauere Fassung")]
            let r = ReviewExchange()
            (r.path, r.summary) = ("~/Library/Application Support/FlowIQ/pruefliste.md", "2 bestätigen, 1 ablehnen. "
                                   + "Übernehmen?")
            r.pending = [ReviewExchange.Decision(id: "Kalmora", aktion: "bestaetigen", schreibweise: nil)]
            return AnyView(WordsSection(words: w, panotti: false, names: NamesModel(), review: r)
                .frame(width: FlowIQTheme.Main.window.width, height: FlowIQTheme.Main.window.height)
                .background(FlowIQTheme.Color.background))
        })
        // TEST-FIX 16.11.2026: die Nachfrage an der Pille ist entfernt, ihre zwei Schritte mit ihr
        out.append(step("g-rechte-fehlen", "Rechte fehlen: Warnzeilen mit Einrichten") {
            $0.ui.missing = [.accessibility, .inputMonitoring]
        })
        return out
    }
    /// The main window (16.11.): history in every state, recordings, words, settings.
    var mainSteps: [Step] {
        let now = Date.now, day = 86_400.0
        func item(_ id: String, _ ago: Double, _ text: String, changed: [String] = [], app: String? = "Mail",
                  result: String? = "landed") -> HistoryItem {
            HistoryItem(id: id, date: now.addingTimeInterval(-ago), text: text, rawText: text.lowercased(),
                        changed: changed, app: app, result: result, seconds: 4, msToText: 180)
        }
        let filled = [
            item("1", 300, "Schick mir bis Freitag die Zahlen für das Kalmora Angebot.", changed: ["Kalmora"]),
            item("2", 3_600, "Kurze Notiz an mich: Rückruf bei Wiebke wegen der Lieferung.", app: "Notizen",
                 result: "noTextFocus"),
            item("3", day + 600, "Okay, dann machen wir das so, ich schreibe dir morgen früh noch einmal, sobald "
                 + "ich die Zahlen habe und mit dem Team gesprochen habe.", app: "Slack"),
            item("4", day * 3, "Termin am Donnerstag passt.", app: "Kalender", result: nil)]
        func history(_ edit: (HistoryModel) -> Void) -> HistoryModel {
            let h = HistoryModel(journal: nil) { _ in }
            h.stats = HistoryStats(dictations: 412)
            (h.stats.words, h.stats.wordsToday, h.stats.msToText, h.stats.corrections) = (18_240, 312, 186, 23)
            edit(h)
            return h
        }
        func main(_ id: String, _ caption: String, _ section: MainView.Section = .history,
                  running: [Running] = [], _ edit: @escaping (HistoryModel) -> Void = { _ in }) -> Step {
            Step(id: id, caption: caption) {
                let m = self.app { ($0.ui.section, $0.ui.running) = (section, running) }
                m.parts.words = self.words(filled: true)
                let r = RecordingsModel(), (mac, cloud) = ("Mitschrift auf dem Mac", "Mitschrift über ElevenLabs")
                r.rows = [RecordingRow(url: URL(filePath: "/t/a.md"), date: now.addingTimeInterval(-7_200),
                                       kind: "Call", duration: "42:10", language: "Deutsch", live: mac,
                                       post: .waiting, audio: nil),
                          RecordingRow(url: URL(filePath: "/t/b.md"), date: now.addingTimeInterval(-day), kind: "Raum",
                                       duration: "1:12:03", language: "Deutsch", live: cloud, post: .done,
                                       audio: nil),
                          RecordingRow(url: URL(filePath: "/t/c.md"), date: now.addingTimeInterval(-day * 2),
                                       kind: "Rekorder", duration: "08:40", language: "Deutsch", live: mac,
                                       post: .paused, audio: nil),
                          RecordingRow(url: URL(filePath: "/t/d.md"), date: now.addingTimeInterval(-day * 4),
                                       kind: "Raum", duration: "55:02", language: "Englisch", live: mac,
                                       post: .local, audio: nil)]
                func name(_ n: String, _ heard: [(String, VariantStatus)]) -> CanonEntry {
                    CanonEntry(id: n, canonical: n, kind: .name, family: nil, spokenForms: [],
                               hearingVariants: heard.map { HearingVariant(id: $0.0, heard: $0.0.split(separator: " ")
                                   .map(String.init), context: [], status: $0.1, origin: .userClick,
                                   replacesProtectedWord: false, counters: Counters()) },
                               status: .confirmed, origin: .userClick, compound: .hyphen, counters: Counters(),
                               createdAt: now, confirmedAt: now)
                }
                m.names.names = [name("Kalmora", [("Kal Mora", .active), ("Calmora", .suspended)]),
                                 name("Wiebke", [("Wipke", .active)]), name("FlowIQ", [])]
                let size = FlowIQTheme.Main.window
                return AnyView(MainView(model: m, history: history(edit), recordings: r)
                    .frame(width: size.width, height: size.height))
            }
        }
        return [
            main("v-leer", "Verlauf leer: noch keine Diktate, keine Kennzahlen") {
                $0.stats = HistoryStats(dictations: 0)
            },
            main("v-gefuellt", "Verlauf nach Tagen, Zustand je Diktat, geänderte Wörter gepunktet, Kennzahlen") {
                $0.items = filled
            },
            main("v-suche-ohne-treffer", "Suche ohne Treffer") { $0.query = "Wipke" },
            main("v-auswahl", "Ein Diktat gewählt: Aktionen sichtbar, Rohfassung und neu erkannt aufgeklappt") { h in
                h.items = filled
                (h.selection, h.raw, h.again) = (["1"], ["1"], ["1": "Schick mir bis Freitag die Zahlen für das "
                                                                  + "Calmora Angebot."])
            },
            main("v-mehrfach", "Zwei Diktate gewählt: Kopieren und Löschen für beide") { h in
                h.items = filled
                h.selection = ["1", "2"]
            },
            main("a-aufnahmen", "Aufnahmen nach Tagen: Dauer, Sprache, Mitschrift, Zustand der genaueren Fassung, "
                 + "Abspielen und Transkript sichtbar", .recordings),
            main("a-laeuft", "Ein laufender Call steht oben", .recordings, running: [call()]),
            main("w-woerter", "Wörter: Vorschläge und Zum Prüfen", .words),
            main("s-einstellungen", "Einstellungen im Fenster, mit Verlauf aufbewahren", .settings),
            main("v-lang-und-gescheitert", "Langer Text auf drei Zeilen gekürzt, nicht erkannt mit Erneut erkennen") {
                $0.items = [item("5", 60, String(repeating: "Ein langer Absatz mit vielen Gedanken zum Projekt, der "
                                                 + "weiter und weiter geht. ", count: 6)), filled[3]]
            },
            Step(id: "v-loeschen", caption: "Löschen fragt nach: zwei Diktate, Text und Audio") {
                AnyView(DeleteConfirm(count: 2, onDelete: {}, onCancel: {}))
            },
        ]
    }
    /// The settings as the main window shows them, whole length, no scrolling (16.11.: one grid).
    func page(_ m: AppModel) -> AnyView {
        let t = FlowIQTheme.self
        return AnyView(SettingsView(model: m).padding(t.Spacing.s24).frame(width: t.Main.form + t.Spacing.s24 * 2)
            .fixedSize(horizontal: false, vertical: true).background(t.Color.background))
    }
    /// The settings in a given situation.
    func settings(_ id: String, _ caption: String, _ edit: @escaping (AppModel) -> Void) -> Step {
        Step(id: id, caption: caption) {
            let m = self.app(edit)
            return self.page(m)
        }
    }
    /// The menu in every state: idle, recording with its status rows, each warning line with its next step.
    var menus: [Step] {
        let alerts: [(String, String, (AppModel) -> Void)] = [
            ("mikrofon-stumm", "Mikrofon liefert keinen Ton", { $0.ui.running = [self.room { $0.silent = true }] }),
            ("recht-fehlt", "Recht fehlt", { $0.ui.missing = [.microphone] }),
            ("netz-weg", "Netz weg", { $0.ui.running = [self.call { $0.fallback = .networkError }] }),
            ("grenze", "Monatsgrenze", { $0.ui.running = [self.call { $0.fallback = .limit }] }),
            ("schluessel", "Schlüssel abgelehnt", { $0.ui.post = .paused(count: 1) }),
            ("nachlauf-wartet", "Genauere Fassung wartet", { $0.ui.post = .waiting(count: 2) }),
            ("kein-textfeld", "Kein Textfeld", { $0.ui.notInserted = true }),
            ("ordner-fehlt", "Ablageordner fehlt", { $0.ui.folderOK = false }),
            ("gegenseite", "Gegenseite fehlt", { $0.ui.running = [self.call()]; $0.ui.down = [.desktop] }),
            ("fn-steht", "Fn reagiert nicht", { $0.ui.tapRunning = false }),
            ("start-gescheitert", "Start gescheitert", { $0.ui.problem = "Call nicht gestartet" }),
            ("platte-voll", "Platte voll", { $0.ui.problem = "Platte voll, Call gesichert und beendet" }),
            // Paket D (16.11.): what the pill said before it lost its text
            ("diktat-gescheitert", "Diktat nicht erkannt", { $0.ui.dictationFailed = true }),
            ("kopfhoerer-getrennt", "Kopfhörer getrennt", {
                $0.ui.running = [self.call { $0.device = "airpods" }]; $0.ui.micLost = "AirPods Pro" }),
            ("import-gescheitert", "Geräte-Import gescheitert", {
                ($0.ui.importing, $0.ui.importFailed) = (.failed(.copy), ["REC_0042.WAV"]) }),
            ("schlaf-pause", "Aufnahme war pausiert", {
                $0.ui.running = [self.room()]; $0.ui.pauses = [.room: "14:02 bis 15:10"] }),
        ]
        return [Step(id: "m-leerlauf", caption: "Menü im Leerlauf", side: menu(app())),
                Step(id: "m-call-laeuft", caption: "Menü während Call: Statuszeile mit Gerät, Quelle und Pegel",
                     side: menu(app { $0.ui.running = [self.call { $0.device = "airpods" }] })),
                Step(id: "m-raum-und-call", caption: "Menü bei Raum plus Call: beide Blöcke, kein Start mehr",
                     side: menu(app { $0.ui.running = [self.call(), self.room()] }))]
            + alerts.map { id, caption, edit in
                Step(id: "m-warnung-\(id)", caption: "Warnzeile: \(caption), mit nächstem Schritt",
                     side: menu(app(edit)))
            }
    }
    /// The pen list in every state, with a real importer behind it so the switch is live.
    var penList: [Step] {
        let rows: [(String, [DeviceImporter.FileRow])] = [
            ("aus", []), ("leer", []),
            ("alle-zustaende", [("REC_0045.WAV", "wartet", false), ("REC_0044.WAV", "kopiert", false),
                                ("REC_0043.WAV", "erkannt", false), ("REC_0042.WAV", "abgelegt", false),
                                ("2026_11_09_19_02_40.WAV", "fehlgeschlagen", true)].map {
                DeviceImporter.FileRow(name: $0.0, state: $0.1, retry: $0.2) }),
        ]
        return rows.map { id, files in
            Step(id: "e-liste-\(id)", caption: "Stift-Liste \(id): Zustand je Datei, Erneut versuchen bei Fehler") {
                let m = self.app()
                m.ui.tab = .devices
                let d = DevicesModel(self.importer())
                (d.enabled, d.files) = (id != "aus", files)
                m.parts.devices = d
                return self.page(m)
            }
        }
    }
    struct NoSpeech: DeviceTranscriber {
        func transcribe(_ audio: URL, language: RecordingLanguage) async throws -> [LiveSegment] { [] }
    }
    struct NoFiling: DeviceFiling { func file(_ r: DeviceRecording) async throws -> URL { r.audio } }
    func importer() -> DeviceImporter {
        let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-gallery-devices")
        let fs = SafeFS(confinedTo: dir), log = EventLog(directory: dir.appending(path: "log"), fs: fs)
        return DeviceImporter(profile: .development, folders: .init(data: dir, archive: dir), fs: fs, log: log,
                              transcriber: NoSpeech(), filing: NoFiling(), post: { false }, volumes: { [] })
    }
    func words(filled: Bool) -> WordsModel {
        let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-gallery-words")
        let fs = SafeFS(confinedTo: dir), log = EventLog(directory: dir.appending(path: "log"), fs: fs)
        let lexicon = LexiconStore(folder: dir, fs: fs, log: log)
        let w = WordsModel(lexicon: lexicon, ledger: CorrectionLedger(lexicon: lexicon, fs: fs, log: log))
        if filled {
            w.items = [("Kalmora", "Kalmora"), ("Brightloop", "Brightloop"), ("Wiebke", "Wiebke")].map { heard, s in
                .init(id: heard, heard: heard, spelling: s, main: "Übernehmen", run: { _ in }, more: [])
            }
        }
        return w
    }
    func devices() -> DevicesModel {
        let d = DevicesModel(nil)
        d.enabled = true
        d.files = [.init(name: "REC_0042.WAV", state: "abgelegt", retry: false),
                   .init(name: "REC_0043.WAV", state: "fehlgeschlagen", retry: true)]
        return d
    }

}
