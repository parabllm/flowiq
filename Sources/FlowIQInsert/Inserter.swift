/// Insertion off the main thread (A.8, R-019, R-020): probe within 50 ms, old clipboard saved whole (unreadable:
/// nothing written), promise data, Cmd-V, old clipboard back 100 ms after the fetch or after 2 s, only while the
/// change count is the own one. One insertion at a time; field content is only compared; waits use the clock.
public actor Inserter {
    static let probeLimit = Duration.milliseconds(50), restoreDelay = Duration.milliseconds(100)
    static let fetchLimit = Duration.seconds(2), sameAppSpace = Duration.seconds(45)
    private let focus: any FocusProbing, pasteboard: any PasteboardPort, keys: any KeyPosting
    private let front: any FrontAppProbing, field: (any FieldEditing)?, clock: any Clock<Duration>, log: EventLog
    private var restoring: Task<Void, Never>?, keepText: Bool  // R-117: the text stays for Cmd-V, no give-back
    private var lastLanded: (app: String, endsWithSpace: Bool, at: ContinuousClock.Instant)?
    /// The last landed insertion: text, payload with its leading space, character offset in the field, app.
    private var last: (text: String, payload: String, offset: Int?, app: String?)?
    public init(focus: any FocusProbing, pasteboard: any PasteboardPort, keys: any KeyPosting,
                front: any FrontAppProbing, field: (any FieldEditing)? = nil, clock: any Clock<Duration>,
                log: EventLog, keepText: Bool = false) {
        self.keepText = keepText
        (self.focus, self.pasteboard, self.keys, self.front, self.field, self.clock, self.log) =
            (focus, pasteboard, keys, front, field, clock, log)
    }
    public func insert(_ text: String) async -> InsertResult { await insertTimed(text).result }
    public func insertTimed(_ text: String, lead: String? = nil) async -> InsertOutcome {
        await restoring?.value
        let outcome = await run(text, lead: lead)
        log.record(LogEvent("insert_result", level: outcome.result == .failed ? .error : .info,
                            ["result": .string(outcome.result.rawValue)]))
        return outcome
    }
    /// Raw version (R-034): Cmd-Z on the last insertion, then `text` with the same leading space as before.
    public func undoAndInsert(_ text: String) async -> InsertOutcome {
        await restoring?.value
        do { try keys.undo() } catch {
            log.record(LogEvent("insert_result", level: .error, ["result": "failed", "step": "undo"]))
            return InsertOutcome(result: .failed, frontApp: front.frontmost(), pastedTicks: nil, fetchedTicks: nil)
        }
        return await insertTimed(text, lead: last.map { String($0.payload.dropLast($0.text.count)) })
    }
    /// Correction (K-35, N.2 point 3), `range` in characters of the insertion: in the unchanged field, else Cmd-Z
    /// and the whole corrected text (no key since, app in front), else on the clipboard. The field is never kept.
    public func replaceInLastInsertion(range: Range<Int>, with text: String, keySinceInsert: Bool) async
        -> ReplaceResult {
        await restoring?.value
        guard let last, range.lowerBound >= 0, range.upperBound <= last.text.count else { return .nothingToReplace }
        var chars = Array(last.text)
        chars.replaceSubrange(range, with: Array(text))
        let corrected = String(chars), lead = last.payload.count - last.text.count
        let inFront = front.frontmost() == last.app && !front.secureInputActive
        let end = (last.offset ?? 0) + last.payload.count
        if inFront, let field, let offset = last.offset, let value = await field.value().map(Array.init),
           end <= value.count, String(value[offset..<end]) == last.payload {
            do {
                try await field.replace((offset + lead + range.lowerBound)..<(offset + lead + range.upperBound),
                                        with: text)
                self.last = (corrected, String(last.payload.prefix(lead)) + corrected, offset, last.app)
                return replaced(.fieldReplaced)
            } catch { log.record(LogEvent("field_replace_failed", level: .error)) }
        }
        // Cmd-Z only with certainty: no key since the insertion, same app in front, focus still in a text field
        if inFront, !keySinceInsert, await focus.probe() != .notTextField,
           await undoAndInsert(corrected).result == .landed {
            return replaced(.undoReinserted)
        }
        log.attempt("clipboard_hint_failed") { _ = try pasteboard.writePlain(corrected) }
        return replaced(.clipboardHint)
    }
    private func replaced(_ result: ReplaceResult) -> ReplaceResult {
        log.record(LogEvent("replace_result", ["result": .string(result.rawValue)]))
        return result
    }
    public nonisolated func frontmost() -> String? { front.frontmost() }
    /// Returns once the old clipboard of the last insertion is back (or kept because the user copied).
    public func settled() async { await restoring?.value }
    private func run(_ text: String, lead: String?) async -> InsertOutcome {
        let probed = await within(Self.probeLimit, clock: clock) { [focus] in await focus.probe() } ?? .unreadable
        let app = front.frontmost(), name = front.frontmostName()  // the paste goes to the app in front now
        func done(_ result: InsertResult, _ pasted: UInt64? = nil, _ fetched: UInt64? = nil) -> InsertOutcome {
            InsertOutcome(result: result, frontApp: app, pastedTicks: pasted, fetchedTicks: fetched, appName: name)
        }
        func unplaced(_ result: InsertResult) -> InsertOutcome {  // R-117: kept text goes on the clipboard anyway
            if keepText { log.attempt("clipboard_keep_failed") { _ = try pasteboard.writePlain(text) } }
            return done(result)
        }
        if front.secureInputActive { return unplaced(.secureInput) }
        if probed == .notTextField { return unplaced(.noTextFocus) }
        let payload = lead.map { $0 + text } ?? spaced(text, probed, app)
        let offset = probed == .notTextField ? nil : await field?.value()?.count  // a count, never the content
        let saved: PasteboardSnapshot
        do { saved = try pasteboard.snapshot() } catch { return unplaced(.failed) }
        let before = pasteboard.changeCount
        let fetch = Latch<UInt64>(), own: Int
        do { own = try pasteboard.writePromise(payload) { fetch.fire(MachTime.now()) } } catch {
            if keepText { return unplaced(.failed) }
            if pasteboard.changeCount != before { putBack(saved, ifStill: pasteboard.changeCount) }
            return done(.failed)
        }
        let pasted = MachTime.now()
        do { try keys.paste() } catch {
            release(saved, text, ifStill: own)
            return done(.failed, pasted)
        }
        guard let fetched = await within(Self.fetchLimit, clock: clock, { await fetch.wait() }) ?? nil else {
            release(saved, text, ifStill: own)
            return done(.notFetched, pasted)
        }
        restoring = Task {
            _ = await clock.pause(Self.restoreDelay)
            release(saved, text, ifStill: own)
        }
        if let app { lastLanded = (app, payload.last?.isWhitespace ?? true, .now) }
        last = (text, payload, offset, app)
        return done(.landed, pasted, fetched)
    }
    /// A space first after a non-space before the caret; unreadable: same app within 45 s, last one ended non-space.
    private func spaced(_ text: String, _ probed: FocusState, _ app: String?) -> String {
        guard let first = text.first, !first.isWhitespace, !",.;:!?)".contains(first) else { return text }
        switch probed {
        case .textField(let before?) where !before.isWhitespace: return " " + text
        case .unreadable:
            guard let last = lastLanded, last.app == app, !last.endsWithSpace,
                  ContinuousClock.now - last.at < Self.sameAppSpace else { return text }
            return " " + text
        default: return text
        }
    }
    private func release(_ saved: PasteboardSnapshot, _ text: String, ifStill own: Int) {
        guard keepText else { return putBack(saved, ifStill: own) }
        guard pasteboard.changeCount == own else { return }
        log.attempt("clipboard_keep_failed") { _ = try pasteboard.writePlain(text) }
    }
    private func putBack(_ saved: PasteboardSnapshot, ifStill own: Int) {
        guard pasteboard.changeCount == own else {
            return log.record(LogEvent("clipboard_kept", ["reason": "changed_meanwhile"]))
        }
        log.attempt("clipboard_restore_failed") { try pasteboard.restore(saved) }
    }
}
