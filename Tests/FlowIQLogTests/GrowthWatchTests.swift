// 16.11.: the periodic resources line carries threads and live counts; growth past a limit becomes an error line.
import Foundation
import Testing
@testable import FlowIQLog

struct GrowthWatchTests {
    /// The first idle look is the base: threads or a count over twice that and 12 more, memory 400 MB more; each
    /// name is said once, a count that comes up later starts from 0.
    @Test func growthIsNamedOnceAndOnlyPastItsLimit() {
        var watch = GrowthWatch()
        #expect(watch.check(["threads": 10, "footprint_mb": 70, "taps": 1]).isEmpty)
        #expect(watch.check(["threads": 22, "footprint_mb": 470, "taps": 13]).isEmpty)
        #expect(watch.check(["threads": 23, "footprint_mb": 471, "taps": 14]) == ["footprint_mb", "taps", "threads"])
        #expect(watch.check(["threads": 90, "footprint_mb": 900, "taps": 50]).isEmpty)
        #expect(watch.check(["threads": 90, "mount_observers": 13]) == ["mount_observers"])
    }

    @Test func theSampleCountsThreadsAndTheCensusCountsUpAndDown() async throws {
        #expect(try await ResourceProbe.sample().threads > 0)
        let name = "probe-\(UUID().uuidString)"
        Census.add(name, 2)
        Census.add(name, -1)
        #expect(Census.counts.withLock { $0[name] } == 1)
    }
}
