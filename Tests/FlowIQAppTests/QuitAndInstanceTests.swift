// Quit, restart and single instance (16.11.): the first real day found a restart that never ended.
import AppKit
import Foundation
import Testing
@testable import FlowIQ

@Suite(.serialized) struct QuitAndInstanceTests {
    @MainActor final class Box { var ran = false }
    /// What AppKit does after `.terminateLater`: a nested loop that waits until a MainActor task has replied.
    @MainActor private static func repliedInNestedLoop() -> Bool {
        let box = Box(), end = Date.now.addingTimeInterval(0.3)
        Task { @MainActor in box.ran = true }
        while !box.ran, Date.now < end { RunLoop.current.run(mode: .default, before: .now.addingTimeInterval(0.02)) }
        return box.ran
    }

    /// The fault as sampled: inside a block of the main dispatch queue the reply task never runs.
    @Test @MainActor func insideAMainQueueBlockTheReplyNeverComes() async {
        let replied = await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume(returning: MainActor.assumeIsolated { Self.repliedInNestedLoop() }) }
        }
        #expect(!replied)
    }

    /// The fix: `outsideMainQueue` leaves the queue first, even when it is called from one of its blocks.
    @Test @MainActor func outsideTheMainQueueTheReplyComes() async {
        let replied = await withCheckedContinuation { done in
            DispatchQueue.main.async {
                AppDelegate.outsideMainQueue { done.resume(returning: Self.repliedInNestedLoop()) }
            }
        }
        #expect(replied)
    }

    @Test func theNewInstanceWaitsThenEndsTheOldOneHard() {
        #expect(AppDelegate.takeover(waited: 0, limit: 5) == .wait)
        #expect(AppDelegate.takeover(waited: 4.9, limit: 5) == .wait)
        #expect(AppDelegate.takeover(waited: 5, limit: 5) == .force)
        #expect(FlowIQTheme.Motion.restartWait == 5 && FlowIQTheme.Motion.restartGrace > 0)
    }

    @Test func aSecondStartGivesWayToTheRunningInstance() {
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        #expect(AppDelegate.elder([(42, late)], own: (42, late)) == nil)  // alone: only itself in the list
        #expect(AppDelegate.elder([(42, late), (7, early)], own: (42, late)) == 7)  // second start: gives way
        #expect(AppDelegate.elder([(7, early), (42, late)], own: (7, early)) == nil)  // the running one stays
    }

    @Test func twoStartsAtOnceNeverBothQuit() {
        let t = Date(timeIntervalSince1970: 100)
        #expect(AppDelegate.elder([(8, t)], own: (9, t)) == 8 && AppDelegate.elder([(9, t)], own: (8, t)) == nil)
        #expect(AppDelegate.elder([(8, nil)], own: (9, t)) == 8 && AppDelegate.elder([(9, t)], own: (8, nil)) == nil)
    }

    @Test func theOldInstanceOfARestartNeverCounts() {
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        #expect(AppDelegate.elder([(7, early)], own: (42, late), ended: 7) == nil)  // ended hard, still listed
        #expect(AppDelegate.elder([(7, early), (8, early)], own: (42, late), ended: 7) == 8)
    }

    /// A closed window hands the focus on only when FlowIQ holds it and no other window of its own is open.
    @Test func closingTheLastWindowHandsTheFocusOn() {
        #expect(Front.handsOn(active: true, openWindows: 0))
        #expect(!Front.handsOn(active: true, openWindows: 1) && !Front.handsOn(active: false, openWindows: 0))
    }

    /// No call of terminate besides the one way out and the invisible second instance.
    @Test func terminateIsCalledOnlyWhereItIsSafe() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/FlowIQ")
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let count = try String(contentsOf: file, encoding: .utf8).components(separatedBy: ".terminate(").count - 1
            if count > 0 { hits.append("\(file.lastPathComponent):\(count)") }
        }
        #expect(hits == ["FlowIQApp.swift:2"])
    }
}
