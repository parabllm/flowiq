// Paket G (16.11.): the key check at the settings field, "Mit ElevenLabs neu erkennen" in the history with its
// question before a large batch, and "Neu mit ElevenLabs" for a finished recording. Invented text, an artificial
// service (a closure), a scratch folder per test; nothing is sent anywhere.
import AppKit
import FlowIQCloud
import FlowIQCore
import FlowIQLog
import FlowIQStore
import Foundation
import Synchronization
import Testing
@testable import FlowIQ

@MainActor struct RenewHistoryTests {
    final class Keychain: KeychainPort, Sendable {
        let items = Mutex<[String: String]>([:])
        var secrets: [String] { items.withLock { $0.values.sorted() } }
        func read(service: String, account: String) throws -> String? { items.withLock { $0[service + account] } }
        func write(_ secret: String, service: String, account: String) throws {
            items.withLock { $0[service + account] = secret }
        }
        func delete(service: String, account: String) throws {
            _ = items.withLock { $0.removeValue(forKey: service + account) }
        }
    }
    /// What the artificial service was asked, and what it answers.
    final class Service: Sendable {
        let asked = Mutex<[DictationJob]>([]), failure = Mutex<PostFailure?>(nil)
        var ids: [String] { asked.withLock { $0.map(\.id) } }
        func answer(_ job: DictationJob) throws -> String {
            asked.withLock { $0.append(job) }
            if let f = failure.withLock({ $0 }) { throw f }
            return "Neu: " + job.insertedText
        }
    }
    final class Sent: Sendable {
        let rows = Mutex<[String]>([])
        var all: [String] { rows.withLock { $0 } }
    }
    struct Bench {
        let root: URL, journal: DictationJournal, model: HistoryModel, service: Service
        func remove() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
    }
    /// A journal with `count` dictations of `seconds` each (audio kept unless `audio` is false), loaded into a model.
    func bench(_ count: Int, seconds: Double = 4, audio: Bool = true) async throws -> Bench {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-renew-\(UUID().uuidString)")
        let paths = Paths(profile: .development, applicationSupport: root), fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        let journal = DictationJournal(paths: paths, fs: fs, log: EventLog(directory: paths.log, fs: fs))
        for n in 1...count {
            let id = String(format: "d%02d", n)
            try await journal.append(JournalEntry("audio", id: id, ["seconds": .number(seconds)]))
            try await journal.append(.recognized(id: id, recognizerText: "satz \(n) mit zorbal",
                                                 finalText: "Satz \(n) mit zorbal", interventions: [String]()))
            try await journal.append(.inserted(id: id, result: "landed"))
            if audio { try Data(repeating: 1, count: 16).write(to: try await journal.audioURL(for: id)) }
        }
        let model = HistoryModel(journal: journal) { _ in }, service = Service()
        model.redo = { try service.answer($0) }
        await model.load()
        return Bench(root: root, journal: journal, model: model, service: service)
    }

    // MARK: 1, the key check

    @Test func aKeyIDIsNotSavedAndTheFieldSaysSo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") } }
        let fs = SafeFS(confinedTo: root), chain = Keychain()
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: PillView(show: false))
        let keys = CloudKeys(keychain: chain, profile: .production)
        m.parts.cloud = CloudParts(keys: keys, usage: MonthUsage(meter: UsageMeter(folder: root, fs: fs),
                                                                 limitMinutes: nil),
                                   badge: CloudBadge(), live: false, post: nil, profile: .production,
                                   log: EventLog(directory: root.appending(path: "log"), fs: fs),
                                   policy: { CloudPolicy(settings: .defaults(for: .production), hasKey: false) })
        m.parts.orKeys = CloudKeys(keychain: chain, profile: .production, provider: .openRouter)
        m.ui.keyDraft = "  0a1b2c3d4e5f6a7b  "  // the key id as the service lists it
        m.storeKey()
        #expect(chain.secrets.isEmpty && !m.ui.hasKey && m.ui.keyDraft.isEmpty)
        #expect(m.ui.keyWrong == [.elevenLabs])
        #expect(AppModel.keyHint(.elevenLabs) == "Das ist die Schlüssel-ID. Der Schlüssel beginnt mit sk_.")
        m.ui.keyDraft = " sk_probe\n"
        m.storeKey()
        #expect(chain.secrets == ["sk_probe"], "saved without the white space around it")
        #expect(m.ui.keyWrong.isEmpty && m.ui.hasKey)
        m.ui.keyDraft = "probe"
        m.storeKey()
        #expect(chain.secrets == ["sk_probe"] && m.ui.keyWrong == [.elevenLabs], "the saved key stays")
        m.ui.orDraft = "sk_probe"  // an ElevenLabs key in the OpenRouter field
        m.storeKey(openRouter: true)
        #expect(chain.secrets == ["sk_probe"] && m.ui.keyWrong == [.elevenLabs, .openRouter] && !m.ui.openRouterKey)
        #expect(AppModel.keyHint(.openRouter).hasSuffix("Der Schlüssel beginnt mit sk-or-."))
        m.ui.orDraft = "\tsk-or-probe "
        m.storeKey(openRouter: true)
        #expect(chain.secrets == ["sk-or-probe", "sk_probe"] && m.ui.keyWrong == [.elevenLabs] && m.ui.openRouterKey)
        m.storeKey()  // an empty field still removes the key
        #expect(chain.secrets == ["sk-or-probe"] && m.ui.keyWrong.isEmpty && !m.ui.hasKey)
    }

    // MARK: 2, dictations once more

    @Test func theNewVersionReplacesTheShownTextAndKeepsTheRawOne() async throws {
        let b = try await bench(2)
        defer { b.remove() }
        let row = try #require(b.model.items.first { $0.id == "d01" })
        await b.model.renew(b.model.targets(row.id))
        #expect(b.service.ids == ["d01"])
        let job = try #require(b.service.asked.withLock { $0.first })
        #expect(job.language == "de" && job.insertedText == "Satz 1 mit zorbal" && job.seconds == 4)
        #expect(job.audio == (await b.journal.audio(of: row)))
        let shown = try #require(b.model.items.first { $0.id == "d01" })
        #expect(shown.text == "Neu: Satz 1 mit zorbal" && shown.rawText == "satz 1 mit zorbal" && shown.renewed)
        #expect(shown.result == "landed" && b.model.items.count == 2, "one row per dictation, nothing inserted anew")
        #expect(b.model.note == "Neu erkannt." && b.model.busy.isEmpty)
        #expect(HistoryModel.joined([shown]) == "Neu: Satz 1 mit zorbal", "what the copy button takes")
        let again = HistoryModel(journal: b.journal) { _ in }  // after a restart the journal says the same
        await again.load()
        #expect(again.items.first { $0.id == "d01" }?.text == "Neu: Satz 1 mit zorbal")
    }

    @Test func aSelectionRunsOneAfterTheOtherAndStopsAtTheLimit() async throws {
        let b = try await bench(3)
        defer { b.remove() }
        b.model.selection = ["d01", "d03"]
        await b.model.renew(b.model.targets("d03"))
        #expect(b.service.ids == ["d03", "d01"], "the chosen ones, in the list's order")
        #expect(b.model.note == "2 Diktate neu erkannt." && b.model.items.filter(\.renewed).count == 2)
        b.service.failure.withLock { $0 = .notAllowed }
        await b.model.renew(b.model.items)
        #expect(b.service.ids.count == 3, "the month's limit stops the batch at the first one")
        #expect(b.model.note == "Monatsgrenze erreicht." && b.model.busy.isEmpty)
        b.service.failure.withLock { $0 = .server(status: 500) }
        await b.model.renew(b.model.items)
        #expect(b.service.ids.count == 6 && b.model.note == "0 von 3 neu erkannt.", "any other failure: the next one")
    }

    @Test func withoutAudioOrWithoutAServiceNothingIsSent() async throws {
        let b = try await bench(1, audio: false)
        defer { b.remove() }
        await b.model.renew(b.model.items)
        #expect(b.service.ids.isEmpty && b.model.note == "0 von 1 neu erkannt.")
        b.model.redo = nil
        await b.model.renew(b.model.items)
        #expect(b.service.ids.isEmpty && b.model.items.first?.renewed == false)
    }

    // MARK: 5, the question before a large batch

    @Test func theQuestionComesFromElevenDictationsOrMoreThanThirtyMinutes() {
        #expect(HistoryModel.renewQuestion(count: 10, seconds: 1800) == nil)
        let many = HistoryModel.renewQuestion(count: 11, seconds: 90)
        #expect(many?.title == "11 Diktate mit ElevenLabs neu erkennen?")
        #expect(many?.text == "2 Min. Audio gehen an ElevenLabs.")
        let long = HistoryModel.renewQuestion(count: 2, seconds: 1801)
        #expect(long?.title == "2 Diktate mit ElevenLabs neu erkennen?" && long?.text.hasPrefix("30 Min.") == true)
        #expect(HistoryModel.renewQuestion(count: 1, seconds: 3601, recording: true)?.title
                == "Aufnahme mit ElevenLabs neu erkennen?")
    }

    @Test func aLargeBatchAsksFirstAndNeverRunsMoreThanFifty() async throws {
        let b = try await bench(52)
        defer { b.remove() }
        await b.model.renew(Array(b.model.items.prefix(11)))
        #expect(b.service.ids.isEmpty && b.model.renewing?.list.count == 11)
        #expect(b.model.renewing?.ask.title == "11 Diktate mit ElevenLabs neu erkennen?")
        b.model.renewing = nil  // "Abbrechen"
        #expect(b.service.ids.isEmpty)
        await b.model.load(more: true)
        await b.model.renew(b.model.items)
        #expect(b.model.renewing?.list.count == 50 && b.model.renewing?.ask.text == "3 Min. Audio gehen an ElevenLabs.")
        await b.model.renew(b.model.renewing?.list ?? [], confirmed: true)
        #expect(b.service.ids.count == 50 && b.model.renewing == nil && b.model.note == "50 Diktate neu erkannt.")
        #expect(b.model.items.count == 52 && b.model.items.filter(\.renewed).count == 50, "all rows stay loaded")
        let long = try await bench(2, seconds: 1000)
        defer { long.remove() }
        await long.model.renew(long.model.items)
        #expect(long.service.ids.isEmpty && long.model.renewing?.ask.text == "33 Min. Audio gehen an ElevenLabs.")
    }

    // MARK: 3, recordings

    @Test func aRecordingKnowsWhetherItsAudioIsThereAndALongOneAsksFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("cleanup: \(error)") } }
        let audio = dir.appending(path: "ton.wav")
        try Data(repeating: 1, count: 8).write(to: audio)
        func file(_ name: String, _ head: String) throws {
            try Data(("---\n" + head + "\n---\n").utf8).write(to: dir.appending(path: name))
        }
        try file("2026-11-16-1200-raum-dvt1600-rec-001-aa.md", "panotti_phase: final-lokal\nnachlauf: aus\n"
                 + "dauer: 01:00:01\nquelle: \(audio.path)")
        try file("2026-11-16-1100-raum.md", "panotti_phase: final-elevenlabs\ndauer: 07:56\nquelle: \(audio.path)")
        try file("2026-11-16-1000-raum.md", "panotti_phase: final-lokal\ndauer: 03:00\nquelle: \(dir.path)/weg.m4a")
        let rows = RecordingsModel.scan(dir)
        #expect(rows.map(\.kind) == ["Rekorder", "Raum", "Raum"] && rows.map(\.post) == [.local, .done, .local])
        #expect(rows.map(\.hasAudio) == [true, true, false] && rows.map(\.seconds) == [3601, 476, 180])
        let m = RecordingsModel(), sent = Sent()
        m.postNow = { row, choice, _ in
            sent.rows.withLock { $0.append(row.kind + (choice == .elevenLabs ? " über ElevenLabs" : "")) }
        }
        await m.renew(rows[1])
        #expect(sent.all == ["Raum über ElevenLabs"] && m.asking == nil, "under 30 minutes: at once")
        await m.renew(rows[0])
        #expect(m.asking == rows[0] && sent.all.count == 1, "an hour asks first")
        await m.renew(rows[0], confirmed: true)
        #expect(sent.all == ["Raum über ElevenLabs", "Rekorder über ElevenLabs"] && m.asking == nil)
    }
}
