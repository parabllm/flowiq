/// The text stage as the coordinator sees it: the real stage with the word oracle, a stub in tests.
nonisolated protocol TextProcessing: Sendable {
    func process(_ recognition: Recognition) async -> ProcessedText
}

/// `interventions` are rule names, one per applied intervention; `trace` carries the rest for the journal.
nonisolated struct ProcessedText: Sendable {
    let text: String, interventions: [String], trace: [String: JSONValue]
    let detail: [Intervention]  // for the correction window (N.2); empty where only rule names are known
    init(text: String, interventions: [String], trace: [String: JSONValue] = [:], detail: [Intervention] = []) {
        (self.text, self.interventions, self.trace, self.detail) = (text, interventions, trace, detail)
    }
}

/// What a running call or room and the after-run learn of a dictation (R-102, R-108); `host` on the chunk clock.
nonisolated protocol DictationObserver: Sendable {
    func window(started: Bool, host: UInt64) async
    func inserted(_ job: DictationJob) async
}

public nonisolated enum RawRefusal: Sendable, Equatable { case nothingToReplace, keyTyped, appChanged }

/// Raw version (R-034): inserted, refused before anything was posted, or failed after Cmd-Z.
public nonisolated enum RawResult: Sendable, Equatable { case inserted, refused(RawRefusal), failed(InsertResult) }

/// What the pump learned about one dictation's audio (B.1 step 4 to 6).
nonisolated struct PumpResult: Sendable {
    var report: CloseReport?, firstTicks: UInt64?, firstHost: UInt64?, closedTicks: UInt64 = 0, overflowed = false
    var peak: Float = 0, energy = 0.0, frames = 0
    /// Level in dBFS for the journal (peak and RMS), -160 for silence.
    var level: [String: JSONValue] {
        let db = { (v: Double) in JSONValue.number(v > 0 ? 20 * log10(v) : -160) }
        return ["peak_db": db(Double(peak)), "rms_db": db(frames > 0 ? (energy / Double(frames)).squareRoot() : 0)]
    }
}
