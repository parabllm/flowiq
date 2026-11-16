// Group 6: track guard in two stages (A.4 "Spurwächter", R-040) and timeline guard (A.4
// "Zeitachsen-Wächter", G.2). Both are pure: fed with synthetic chunks on a virtual clock, no real time passes.
import Foundation
import Testing
@testable import FlowIQAudio

private let dt = 0.1

/// Feeds `seconds` of one signal kind into the guard and returns (time, level) after every chunk.
private func run(_ guardian: inout TrackGuard, from t: Double, seconds: Double, amp: Float,
                 digitalSilence: Bool = false, peerHasTone: Bool = true) -> [(time: Double, level: WarningLevel)] {
    var out: [(Double, WarningLevel)] = []
    var position = t
    for i in 0..<Int((seconds / dt).rounded()) {
        let samples: [Float]
        if digitalSilence || amp == 0 {
            samples = [Float](repeating: 0, count: 4_800)
        } else if amp >= 0.1 {
            samples = Signal.sine(amp: amp, count: 4_800, startSample: i * 4_800)
        } else {
            samples = Signal.noise(amp: amp, count: 4_800, seed: UInt64(i + 1))
        }
        let level = guardian.ingest(chunk(samples, at: position), peerHasTone: peerHasTone)  // ASSUMPTION: TrackGuard.ingest(_:peerHasTone:) -> WarningLevel, time from the chunk timestamps
        position += dt
        out.append((position, level))
    }
    return out
}

private func firstWarning(_ run: [(time: Double, level: WarningLevel)], from origin: Double = 0) -> Double? {
    run.first { $0.level != .none }.map { $0.time - origin }
}

private func level(at time: Double, in run: [(time: Double, level: WarningLevel)]) -> WarningLevel {
    run.last { $0.time <= time + 1e-9 }?.level ?? .none
}

struct TrackGuardTests {
    static let loudNoise: Float = 0.01  // about -45 dBFS RMS: a living microphone hears room noise
    static let quietNoise: Float = 0.0005  // about -71 dBFS RMS: below the -60 dBFS threshold

    @Test(arguments: [Float(0), TrackGuardTests.quietNoise])
    func silentMicrophoneWarnsWithinFifteenSecondsInStageOne(amp: Float) {
        var guardian = TrackGuard(kind: .microphone)  // ASSUMPTION: TrackGuard(kind:) with .microphone or .desktop
        let r = run(&guardian, from: 0, seconds: 60, amp: amp)
        #expect(level(at: 5, in: r) == .none)  // no alarm in the first seconds of a start
        let first = firstWarning(r)
        #expect(first != nil)
        #expect((first ?? 99) <= 15)
        #expect(level(at: 15, in: r) == .stage1)
        #expect(level(at: 20, in: r) == .stage1)  // ASSUMPTION: stage two does not start before 20 s of silence
    }

    @Test func longerSilenceEscalatesToStageTwo() {
        var guardian = TrackGuard(kind: .microphone)  // ASSUMPTION: TrackGuard(kind:)
        let r = run(&guardian, from: 0, seconds: 200, amp: 0)
        #expect(level(at: 180, in: r) == .stage2)  // ASSUMPTION: stage two at the latest after 3 minutes
        #expect(level(at: 15, in: r) < level(at: 180, in: r))  // ASSUMPTION: WarningLevel is Comparable; warnings only ever get stronger while silence lasts
    }

    @Test func roomNoiseNeverWarns() {
        var guardian = TrackGuard(kind: .microphone)  // ASSUMPTION: TrackGuard(kind:)
        let r = run(&guardian, from: 0, seconds: 300, amp: TrackGuardTests.loudNoise)
        #expect(firstWarning(r) == nil)
    }

    @Test func toneEndsTheWarningAndSilenceCanWarnAgain() {
        var guardian = TrackGuard(kind: .microphone)  // ASSUMPTION: TrackGuard(kind:)
        let silent = run(&guardian, from: 0, seconds: 30, amp: 0)
        #expect(level(at: 30, in: silent) != .none)
        let spoken = run(&guardian, from: 30, seconds: 5, amp: 0.1)
        #expect(level(at: 31, in: spoken) == .none)  // ASSUMPTION: the warning ends within one second of sound
        #expect(level(at: 35, in: spoken) == .none)
        let again = run(&guardian, from: 35, seconds: 30, amp: 0)
        let relapse = firstWarning(again, from: 35)
        #expect((relapse ?? 99) <= 15)
    }

    @Test func desktopSilentFromTheStartWarnsWithinFifteenSeconds() {
        var guardian = TrackGuard(kind: .desktop)  // ASSUMPTION: TrackGuard(kind:)
        let r = run(&guardian, from: 0, seconds: 30, amp: 0, digitalSilence: true)
        #expect((firstWarning(r) ?? 99) <= 15)
    }

    @Test func desktopSilenceInTheMiddleOfACallWaitsThreeMinutesWhileTheMicHasSound() {
        var guardian = TrackGuard(kind: .desktop)  // ASSUMPTION: TrackGuard(kind:)
        let talk = run(&guardian, from: 0, seconds: 60, amp: 0.2)
        #expect(firstWarning(talk) == nil)
        let silent = run(&guardian, from: 60, seconds: 200, amp: 0, digitalSilence: true, peerHasTone: true)
        #expect(level(at: 60 + 170, in: silent) == .none)  // a mute other side is normal
        #expect((firstWarning(silent, from: 60) ?? 999) <= 185)
    }

    @Test func desktopSilenceWithSilentMicrophoneWarnsEarly() {
        var guardian = TrackGuard(kind: .desktop)  // ASSUMPTION: TrackGuard(kind:)
        _ = run(&guardian, from: 0, seconds: 60, amp: 0.2)
        let silent = run(&guardian, from: 60, seconds: 60, amp: 0, digitalSilence: true, peerHasTone: false)
        #expect((firstWarning(silent, from: 60) ?? 999) <= 30)  // ASSUMPTION: without sound on the microphone the long wait does not apply
    }
}

struct TimelineGuardTests {
    private func make() -> TimelineGuard { TimelineGuard(sampleRate: Signal.rate) }  // ASSUMPTION: TimelineGuard(sampleRate:)

    @Test func contiguousChunksPassUntouched() {
        var timeline = make()
        for c in expectedSine(from: 0, seconds: 5) {
            let out = timeline.process(c)  // ASSUMPTION: process(_:) -> TimelineOutput { chunks, filledSeconds }
            #expect(out.chunks.count == 1)  // ASSUMPTION: TimelineOutput.chunks, the input chunk after any fill
            #expect(out.filledSeconds == nil)  // ASSUMPTION: TimelineOutput.filledSeconds, nil when nothing was filled
        }
    }

    @Test func clockDriftBelowTheThresholdIsNeverFilled() {
        var timeline = make()
        var position = 0.0
        for _ in 0..<108_000 {  // 3 hours of 100 ms chunks whose stamps run 0.1 ms per chunk too slow
            let out = timeline.process(chunk([Float](repeating: 0.1, count: 4_800), at: position))  // ASSUMPTION: process(_:)
            #expect(out.filledSeconds == nil)  // ASSUMPTION: TimelineOutput.filledSeconds
            position += 0.1001
        }
    }

    @Test func jumpUnderTwoHundredMillisecondsIsNotFilled() {
        var timeline = make()
        _ = timeline.process(chunk([Float](repeating: 0.1, count: 4_800), at: 0))  // ASSUMPTION: process(_:)
        let out = timeline.process(chunk([Float](repeating: 0.1, count: 4_800), at: 0.1 + 0.15))  // ASSUMPTION: process(_:)
        #expect(out.filledSeconds == nil)  // ASSUMPTION: TimelineOutput.filledSeconds
    }

    @Test(arguments: [0.5, 5.0, 45.0, 600.0])
    func jumpOverTheThresholdIsFilledWithMarkedSilenceWithoutUpperLimit(gap: Double) {
        var timeline = make()
        _ = timeline.process(chunk([Float](repeating: 0.1, count: 4_800), at: 0))  // ASSUMPTION: process(_:)
        let out = timeline.process(chunk([Float](repeating: 0.1, count: 4_800), at: 0.1 + gap))  // ASSUMPTION: process(_:)
        let filled = out.chunks.dropLast()  // ASSUMPTION: fill chunks come first, the real chunk is last
        let samples = filled.reduce(0) { $0 + $1.samples.count }
        #expect(abs(Double(samples) / Signal.rate - gap) <= 0.01)
        #expect(filled.allSatisfy(isSilent))
        #expect(abs((out.filledSeconds ?? -1) - gap) <= 0.01)  // ASSUMPTION: TimelineOutput.filledSeconds
        #expect(largestGap(out.chunks) <= 1e-6)  // the output timeline has no hole left
    }
}
