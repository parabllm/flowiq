// A user without the predecessor app Panotti (optional, only where it is installed) never reads its name in the
// interface and gets no path that carries it. The frontmatter keys of the transcripts are the stated exception.
import FlowIQCore
import Foundation
import Testing
@testable import FlowIQ

@Suite struct WithoutPredecessorTests {
    static let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)

    @Test func theSettingsHintNamesItOnlyWhereItIsInstalled() {
        #expect(RecordingPane.alternateHint(panotti: false) == "wenn ⌘⌥ schon belegt ist; ab Neustart")
        #expect(RecordingPane.alternateHint(panotti: true)
                == "wenn ⌘⌥ schon belegt ist (z.B. von Panotti); ab Neustart")  // unchanged where it is installed
    }

    @Test func noWarningLineNamesItWhileItDoesNotRun() {
        var states = [AppModel.Shown()]
        for (tap, screen) in [(true, true), (true, false), (false, true), (false, false)] {
            var ui = AppModel.Shown()
            (ui.tapRunning, ui.screenGranted, ui.problem) = (tap, screen, tap ? nil : "Ablage nicht erreichbar")
            ui.running = [Running(kind: .call, language: .de, started: .now)]
            states.append(ui)
        }
        for ui in states {
            let alerts = AppModel.alerts(ui, silent: true, limit: 60)
            #expect(!alerts.contains(.panottiKeys))
            #expect(alerts.allSatisfy { !$0.text.localizedCaseInsensitiveContains("panotti") })
            #expect(alerts.allSatisfy { !$0.step.title.localizedCaseInsensitiveContains("panotti") })
        }
    }

    @Test func noPathOfAFreshInstallCarriesItsName() {
        for profile in [Profile.production, .development] {
            let paths = Paths(profile: profile), s = FlowIQCore.Settings.defaults(for: profile)
            #expect(!s.panottiLink)
            let l = s.locations(paths)
            let all = [l.transcripts, l.raw, l.archiveAudio, l.liveLink, l.dataFolder, paths.support, paths.log,
                       paths.laufend, paths.diktate, paths.settingsFile]
            #expect(all.allSatisfy { !$0.path.localizedCaseInsensitiveContains("panotti") }, "\(all.map(\.path))")
        }
    }

    /// Every code line of the app that holds the name in a text is one of the known places, each behind its
    /// condition: the data folder exists (two buttons, the file panel behind one of them, the settings hint) or
    /// an app of that name runs (the warning line). A new place turns this red until it is gated and listed.
    @Test func theNameStandsOnlyAtTheKnownGatedPlaces() throws {
        var found: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                var code = String(line.trimmingCharacters(in: .whitespaces))
                if let comment = code.range(of: "//") { code = String(code[..<comment.lowerBound]) }
                for identifier in ["PanottiRecord", "PanottiIgnored", "failedInPanotti"] {
                    code = code.replacingOccurrences(of: identifier, with: "")
                }
                if code.contains("Panotti") { found[url.lastPathComponent, default: 0] += 1 }
            }
        }
        #expect(found == ["AppModel.swift": 2, "Devices.swift": 2, "SettingsWindow.swift": 1, "StatusMenu.swift": 1,
                          "RecordingSettings.swift": 1])
    }
}
