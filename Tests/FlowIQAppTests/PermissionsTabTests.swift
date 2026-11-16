// Einstellungen, Reiter "Berechtigungen" (16.11.): the state is read again when the tab appears and when a
// window comes to the front or the app becomes active; the tab is the third one and holds the four rights only.
import AppKit
import Foundation
import os
import SwiftUI
import Testing
@testable import FlowIQ

@MainActor struct PermissionsTabTests {
    /// A reader that counts and hands out the states in order, the last one again and again.
    final class Reader: Sendable {
        let states: OSAllocatedUnfairLock<(left: [PermissionState], reads: Int)>
        init(_ states: [PermissionState]) { self.states = .init(initialState: (states, 0)) }
        var reads: Int { states.withLock { $0.reads } }
        func next() -> PermissionState {
            states.withLock { s in
                s.reads += 1
                return s.left.count > 1 ? s.left.removeFirst() : s.left[0]
            }
        }
    }
    func model(_ reader: Reader) -> PermissionModel {
        let m = PermissionModel()
        m.read = { reader.next() }
        return m
    }
    func wait(_ what: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<200 where !what() { try await Task.sleep(for: .milliseconds(10)) }
        return what()
    }

    @Test func everyRefreshReadsTheStateAgain() async {
        let three: Set<Permission> = [.microphone, .accessibility, .inputMonitoring]
        let reader = Reader([PermissionState(granted: three), PermissionState(granted: Set(Permission.allCases))])
        let m = model(reader)
        await m.refresh()
        #expect(m.state.granted == three && reader.reads == 1)
        await m.refresh()
        #expect(m.state.granted.contains(.screenRecording) && reader.reads == 2)
    }

    @Test func tabReadsWhenItAppearsAndWhenAWindowComesToTheFront() async throws {
        let reader = Reader([PermissionState(), PermissionState(granted: [.microphone])])
        let m = model(reader)
        _ = NSApplication.shared  // offscreen, never shown
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let followed = OSAllocatedUnfairLock(initialState: 0)  // the app's own refresh after each read
        let host = NSHostingView(rootView: PermissionsPane(model: m, tapRunning: true) {
            followed.withLock { $0 += 1 }
        })
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(try await wait { reader.reads >= 1 })
        let appeared = reader.reads
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(try await wait { reader.reads > appeared && m.state.granted == [.microphone] })
        let key = reader.reads
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(try await wait { reader.reads > key && followed.withLock { $0 } >= 3 })
        window.contentView = nil
    }

    @Test func refreshAloneNeverAsksForARestart() async {
        let m = model(Reader([PermissionState(granted: [.microphone])]))
        #expect(!m.needsRestart(.screenRecording))
        m.read = { PermissionState(granted: [.microphone]) }
        await m.refresh()
        #expect(!m.needsRestart(.screenRecording) && !m.needsRestart(.microphone))
    }

    @Test func rightsAreTheFourOfEinrichtenWithTheSameTexts() {
        #expect(Permission.allCases.map(\.title)
                == ["Mikrofon", "Bedienungshilfen", "Eingabeüberwachung", "Bildschirmaufnahme"])
        #expect(Permission.allCases.allSatisfy { !$0.row.purpose.isEmpty && $0.settingsURL != nil })
    }
}
