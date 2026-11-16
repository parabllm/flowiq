// 16.11.: the idle app showed 90 % CPU in the log for hours; sampled, the main thread drew the history list again
// and again. The busy tick refreshes once a second and wrote `ui` every time (a counter, unchanged lists), and
// every write of `ui` draws the open window anew. A refresh that finds nothing new must not touch `ui`.
import Foundation
import Synchronization
import Testing
@testable import FlowIQ

@MainActor struct RefreshQuietTests {
    @Test func aRefreshThatFindsNothingNewDrawsNothing() async {
        let model = AppModel(profile: .development, settings: .defaults(for: .development), pill: PillView(show: false))
        await model.refresh(full: false)
        let drawn = Mutex(0)
        withObservationTracking { _ = model.ui } onChange: { drawn.withLock { $0 += 1 } }
        for _ in 0..<5 { await model.refresh(full: false) }
        #expect(drawn.withLock { $0 } == 0)
        model.ui.problem = "neu"  // the counter check: a real change is still seen
        #expect(drawn.withLock { $0 } == 1)
    }
}
