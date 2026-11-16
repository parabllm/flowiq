import SwiftUI
/// The pill (16.11., local/design/pille-neu.html): three narrow pills without signs in one fixed column at the
/// left edge, call on top, dictation in the middle and always there, room below. Nothing ever moves; what comes or
/// goes grows or shrinks at its own place. Dictation: a thin outline at rest, red at one fixed height while
/// dictating, a white dot when locked. "EN" beside a call or room for 5 s after an English start; a problem turns its
/// pill orange (the reason is in the menu); after the stop a ring fills at the pill's place until it is saved; the
/// pen import fills a ring beside the dictation pill. A click on the column opens the menu.
nonisolated struct PillScene: Equatable, Sendable {
    struct Recording: Equatable, Sendable { var english = false, problem = false }
    var dictation = PillState.hidden, locked = false
    var call: Recording?, room: Recording?
    var pending: Set<String> = []  // "call", "room": the start runs, the pill shows at once
    var english: Set<String> = []  // "EN" beside these pills, for 5 s after an English start
    var saving: [String: Double] = [:]  // after the stop: the ring's share at the pill's place
    var importing: Double?  // the pen import's share, a ring beside the dictation pill
    struct Element: Equatable, Sendable {
        enum Look: Equatable, Sendable { case outline, fill(Fill), dot, english(Fill), ring(Fill, Double) }
        enum Fill: Equatable, Sendable { case dictation, call, room, warning, neutral }
        let id: String, frame: CGRect, look: Look
    }

    static var column: CGFloat { FlowIQTheme.Pill.edgeInset + FlowIQTheme.Pill.width / 2 }
    static var middle: CGFloat { FlowIQTheme.Pill.canvas.height / 2 }
    /// The fixed places: call above, room below the 44 pt dictation pill, also while it rests small.
    static func slot(_ tile: String) -> CGRect {
        let p = FlowIQTheme.Pill.self, reach = p.active / 2 + p.gap
        return CGRect(x: p.edgeInset, y: tile == "call" ? middle + reach : middle - reach - p.recording,
                      width: p.width, height: p.recording)
    }
    /// Where a click opens the menu: the column from above the call to below the room.
    static var reach: CGRect {
        let p = FlowIQTheme.Pill.self, low = slot("room").minY - p.gap
        return CGRect(x: 0, y: low, width: p.edgeInset + p.width + p.gap, height: slot("call").maxY + p.gap - low)
    }
    private static func around(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
    }
    /// What is drawn: the dictation pill always, each running thing at its place, nothing else.
    var elements: [Element] {
        let p = FlowIQTheme.Pill.self, on = dictation == .dictating
        let x = Self.column, y = Self.middle
        var out = [Element(id: "dictation", frame: Self.around(x, y, p.width, on ? p.active : p.idle),
                           look: on ? .fill(.dictation) : .outline)]
        if on && locked { out.append(Element(id: "lock", frame: Self.around(x, y, p.lockDot, p.lockDot), look: .dot)) }
        for (tag, rec, fill) in [("call", call, Element.Fill.call), ("room", room, .room)] {
            let slot = Self.slot(tag)
            if rec != nil || pending.contains(tag) {
                out.append(Element(id: tag, frame: slot, look: .fill(rec?.problem == true ? .warning : fill)))
                if rec != nil && english.contains(tag) {
                    out.append(Element(id: tag + "-en", frame: CGRect(x: slot.maxX + p.tagGap, y: slot.midY - p.tag / 2,
                        width: p.tagWidth, height: p.tag), look: .english(fill)))
                }
            } else if let share = saving[tag] {
                out.append(Element(id: tag + "-ring", frame: Self.around(Self.column, slot.midY, p.ring, p.ring),
                                   look: .ring(fill, share)))
            }
        }
        if let importing {
            out.append(Element(id: "pen", frame: Self.around(x + p.width / 2 + p.penOffset, y, p.ring, p.ring),
                               look: .ring(.neutral, importing)))
        }
        return out
    }
    /// The pen import's real share (R-072), never full before the end: copying fills up to the cap, recognizing
    /// holds, the end fills it; a failure takes it away (the reason is in the devices list).
    static func ring(_ p: ImportProgress, now: Double?) -> Double? {
        switch p {
        case .copying(let share):  // a ring still full from the import before starts again
            max(now.flatMap { $0 < 1 ? $0 : nil } ?? 0, min(max(share, 0), 1) * FlowIQTheme.Pill.ringCap)
        case .transcribing: now ?? 0
        case .hidden: now == nil ? nil : 1
        case .failed: nil
        }
    }
    /// After the stop there is no real share: an estimate from the recording's length, rising and never above the
    /// cap; 100 % only when it is saved (16.11.).
    static func estimate(after t: Double, recorded seconds: Double) -> Double {
        let p = FlowIQTheme.Pill.self, tau = p.ringBase + p.ringPerSecond * max(0, seconds)
        return p.ringCap * (1 - exp(-max(0, t) / tau))
    }
    static func clock(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The pill panel (A.12): non-activating, never key, every space, created once; layers only, no text input (R-021).
final class PillView {
    let panel: NSPanel
    private let host = PillHost()
    private var layers: [String: CALayer] = [:], timers: [String: Int] = [:]
    private var due: [String: (inout PillScene) -> Void] = [:]
    private var stops: [String: (at: Date, seconds: Double)] = [:], ticker: Timer?
    private(set) var scene = PillScene()
    var onClick: (NSView) -> Void = { _ in }  // the menu
    func layer(_ id: String) -> CALayer? { layers[id] }
    init(show: Bool = true) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: FlowIQTheme.Pill.canvas),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        (panel.isOpaque, panel.hasShadow, panel.animationBehavior) = (false, false, .none)
        panel.backgroundColor = FlowIQTheme.Color.transparent
        host.wantsLayer = true
        host.onClick = { [weak self] point in
            if let self, PillScene.reach.contains(point) { self.onClick(self.host) }
        }
        host.onLook = { [weak self] in self?.draw(animated: false) }  // light and dark resolve again
        panel.contentView = host
        place()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        draw(animated: false)
        if show { panel.orderFrontRegardless() }
    }
    /// Left edge of the visible frame (Dock left, Stage Manager), vertically centered (review S10).
    func place() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.minX, y: screen.midY - FlowIQTheme.Pill.canvas.height / 2))
    }
    /// A recording that starts in English shows "EN" for 5 s; one that ends takes it along.
    func update(animated: Bool = true, _ change: (inout PillScene) -> Void) {
        var next = scene
        change(&next)
        for (tag, was, now) in [("call", scene.call, next.call), ("room", scene.room, next.room)] {
            if now?.english == true && was?.english != true {
                next.english.insert(tag)
                later("en-" + tag, FlowIQTheme.Pill.englishHold) { $0.english.remove(tag) }
            }
            if now == nil { next.english.remove(tag) }
        }
        guard next != scene else { return }
        scene = next
        draw(animated: animated)
    }
    /// The stop: a ring at the pill's place fills from the recording's length until `saved`; a second stop
    /// meanwhile never sets it back.
    func saving(_ kind: SessionKind, recorded seconds: Double, now: Date = .now) {
        let tag = kind.pillID
        guard stops[tag] == nil else { return }
        cancel("ring-" + tag)
        stops[tag] = (now, seconds)
        update { $0.saving[tag] = 0 }
        tick(now)
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: FlowIQTheme.Pill.ringStep, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(.now) }
        }
    }
    /// Saved: the ring is full for a moment, then gone.
    func saved(_ kind: SessionKind) {
        let tag = kind.pillID
        guard stops.removeValue(forKey: tag) != nil else { return }
        if stops.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
        update { $0.saving[tag] = 1 }
        later("ring-" + tag, FlowIQTheme.Pill.ringDone) { $0.saving[tag] = nil }
    }
    func tick(_ now: Date) {
        update { s in
            for (tag, stop) in stops {
                s.saving[tag] = max(s.saving[tag] ?? 0, PillScene.estimate(after: now.timeIntervalSince(stop.at),
                                                                           recorded: stop.seconds))
            }
        }
    }
    /// The pen import: real share, full at the end for a moment, then gone.
    func importing(_ p: ImportProgress) {
        cancel("pen")
        update { $0.importing = PillScene.ring(p, now: $0.importing) }
        if scene.importing == 1 { later("pen", FlowIQTheme.Pill.ringDone) { $0.importing = nil } }
    }
    /// After `hold` seconds, unless the same timer was set again or cancelled meanwhile.
    private func later(_ key: String, _ hold: Double, _ change: @escaping (inout PillScene) -> Void) {
        let mark = (timers[key] ?? 0) + 1
        (timers[key], due[key]) = (mark, change)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            MainActor.assumeIsolated { if let self, self.timers[key] == mark { self.fire(key) } }
        }
    }
    private func cancel(_ key: String) { (timers[key], due[key]) = ((timers[key] ?? 0) + 1, nil) }
    /// Runs a waiting timer now (also what the tests use instead of waiting 5 s).
    func fire(_ key: String) {
        guard let change = due.removeValue(forKey: key) else { return }
        timers[key] = (timers[key] ?? 0) + 1
        update(change)
    }

    // MARK: drawing

    /// One layer per element, kept while it is drawn: size springs from its center, colors cross-fade, what comes or
    /// goes scales from its own center; never a position animation. Reduced motion: only opacity.
    private func draw(animated: Bool) {
        let motion = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let drawn = scene.elements, wanted = Set(drawn.map(\.id)), look = host.effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in layers where !wanted.contains(id) {
            layers[id] = nil
            Self.leave(layer, fade: animated, motion: motion)
        }
        for e in drawn {
            let fresh = layers[e.id] == nil, layer = layers[e.id] ?? Self.make(e.look)
            if fresh { host.layer?.addSublayer(layer); layers[e.id] = layer }
            let parts = [layer] + Array(layer.sublayers?.prefix(1) ?? []), arc = Self.arc(layer)?.strokeEnd  // and rim
            let before = parts.map { part in (Self.springs + Self.colors).map { part.value(forKey: $0) } }
            look.performAsCurrentDrawingAppearance { Self.style(layer, e) }
            if fresh { Self.enter(layer, fade: animated, motion: motion) } else if animated {
                for (part, old) in zip(parts, before) { Self.change(part, from: old, motion: motion) }
                Self.fill(layer, from: arc)
            }
        }
        CATransaction.commit()
    }
    private static let springs = ["bounds", "cornerRadius"], colors = ["backgroundColor", "borderColor"]
    private static func spring(_ key: String, from: Any?, to: Any? = nil) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: key), m = FlowIQTheme.PillMotion.self
        (a.mass, a.stiffness, a.damping, a.fromValue, a.toValue) = (1, m.stiffness, m.damping, from, to)
        a.duration = a.settlingDuration
        return a
    }
    private static func fade(_ key: String, from: Any?, to: Any? = nil, _ seconds: Double,
                             _ curve: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        (a.fromValue, a.toValue, a.duration, a.timingFunction) = (from, to, seconds, CAMediaTimingFunction(name: curve))
        return a
    }
    /// From where it is now (also mid-spring) to the new size and color.
    private static func change(_ layer: CALayer, from: [Any?], motion: Bool) {
        let m = FlowIQTheme.PillMotion.self
        for (key, old) in zip(springs + colors, from)
        where !((layer.value(forKey: key) as AnyObject?)?.isEqual(old) ?? (old == nil)) {
            let now = layer.presentation()?.value(forKey: key) ?? old
            if colors.contains(key) { layer.add(fade(key, from: now, m.color), forKey: key) } else if motion {
                layer.add(spring(key, from: now), forKey: key)
            }
        }
    }
    /// The ring's arc runs on evenly to its new share.
    private static func fill(_ layer: CALayer, from arc: CGFloat?) {
        guard let arc, let fill = Self.arc(layer), fill.strokeEnd != arc else { return }
        let from = fill.presentation()?.strokeEnd ?? arc
        fill.add(fade("strokeEnd", from: from, FlowIQTheme.PillMotion.ringFill, .linear), forKey: "fill")
    }
    private static func enter(_ layer: CALayer, fade on: Bool, motion: Bool) {
        guard on else { return }
        let m = FlowIQTheme.PillMotion.self
        layer.add(fade("opacity", from: 0, m.fade), forKey: "enter")
        if motion { layer.add(spring("transform.scale", from: m.start, to: 1), forKey: "enter-scale") }
    }
    private static func leave(_ layer: CALayer, fade on: Bool, motion: Bool) {
        layer.removeAllAnimations()
        guard on else { return layer.removeFromSuperlayer() }
        let m = FlowIQTheme.PillMotion.self
        layer.opacity = 0
        layer.add(fade("opacity", from: 1, m.fade), forKey: "leave")
        if motion {
            layer.transform = CATransform3DMakeScale(m.start, m.start, 1)
            layer.add(spring("transform.scale", from: 1, to: m.start), forKey: "leave-scale")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + m.fade) {
            MainActor.assumeIsolated { layer.removeFromSuperlayer() }
        }
    }
    /// Every layer carries its rim first, a ring 1 pt outside it (a shadow is not drawn offscreen); a ring adds its
    /// pale track and its arc, "EN" its text.
    private static func make(_ look: PillScene.Element.Look) -> CALayer {
        let layer = CALayer()
        layer.sublayers = [CALayer()]
        switch look {
        case .ring: layer.sublayers? += [CAShapeLayer(), CAShapeLayer()]
        case .english: layer.sublayers?.append(CATextLayer())
        default: break
        }
        return layer
    }
    private static func arc(_ layer: CALayer) -> CAShapeLayer? { layer.sublayers?.last as? CAShapeLayer }
    static func color(_ fill: PillScene.Element.Fill) -> CGColor {
        let c = FlowIQTheme.Color.self
        let color = switch fill {
        case .dictation: c.recording
        case .call: c.recordingCall
        case .room: c.recordingRoom
        case .warning: c.warning
        case .neutral: c.pillNeutral
        }
        return NSColor(color).cgColor
    }
    /// The bounds lie around their own center, so the rim inside stays put while the size springs.
    private static func style(_ layer: CALayer, _ e: PillScene.Element) {
        let p = FlowIQTheme.Pill.self, c = FlowIQTheme.Color.self, clear = c.transparent.cgColor
        let size = e.frame.size, r = min(size.width, size.height) / 2, edge = NSColor(c.pillRim).cgColor
        var left = false
        if case .english = e.look { left = true }  // "EN" grows out of its pill (Vorlage)
        layer.anchorPoint = CGPoint(x: left ? 0 : 0.5, y: 0.5)
        layer.bounds = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        layer.position = CGPoint(x: left ? e.frame.minX : e.frame.midX, y: e.frame.midY)
        (layer.cornerRadius, layer.borderWidth, layer.borderColor, layer.backgroundColor) = (r, p.outline, clear, clear)
        guard let rim = layer.sublayers?.first else { return }
        (rim.bounds, rim.position) = (layer.bounds.insetBy(dx: -p.rim, dy: -p.rim), .zero)
        (rim.cornerRadius, rim.borderWidth, rim.borderColor) = (r + p.rim, p.rim, clear)
        switch e.look {
        case .outline: layer.borderColor = NSColor(c.pillOutline).cgColor
        case .fill(let f): (layer.backgroundColor, rim.borderColor) = (color(f), edge)
        case .dot: layer.backgroundColor = NSColor(c.glyph).withAlphaComponent(p.dotAlpha).cgColor
        case .english(let f):
            (layer.backgroundColor, rim.borderColor) = (color(f), edge)
            guard let text = layer.sublayers?.last as? CATextLayer else { return }
            let font = NSFont.boldSystemFont(ofSize: p.tagFont)
            (text.string, text.font, text.fontSize, text.alignmentMode) = ("EN", font, p.tagFont, .center)
            text.foregroundColor = NSColor(c.glyph).cgColor
            text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            let h = ceil(font.ascender - font.descender)
            text.frame = CGRect(x: -size.width / 2, y: -h / 2, width: size.width, height: h)
        case .ring(let f, let share):
            let box = CGRect(origin: .zero, size: size), path = CGMutablePath()  // from the top, clockwise
            path.addArc(center: CGPoint(x: box.midX, y: box.midY), radius: (p.ring - p.ringLine) / 2,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            for (n, shape) in (layer.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
                (shape.frame, shape.path, shape.fillColor, shape.strokeColor) = (layer.bounds, path, clear, color(f))
                (shape.lineWidth, shape.lineCap) = (p.ringLine, .round)
                (shape.opacity, shape.strokeEnd) = n == 0 ? (p.ringTrack, 1) : (1, CGFloat(min(max(share, 0), 1)))
            }
        }
    }
}

extension SessionKind { nonisolated var pillID: String { self == .call ? "call" : "room" } }

/// Only the column takes clicks; transparent pixels pass through to the window below.
private final class PillHost: NSView {
    var onClick: (CGPoint) -> Void = { _ in }, onLook: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick(convert(event.locationInWindow, from: nil)) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onLook()
    }
}

/// The input side calls this from the tap thread: exactly one hop to the main thread (appendix C, t1 to t2).
nonisolated final class PillRelay: PillSink {
    private let view: PillView, onState: @Sendable (PillState) -> Void
    init(_ view: PillView, onState: @escaping @Sendable (PillState) -> Void) {
        (self.view, self.onState) = (view, onState)
    }
    func set(_ state: PillState) {
        DispatchQueue.main.async { [view] in
            MainActor.assumeIsolated {
                view.update { s in
                    s.dictation = state
                    if state == .dictating { s.locked = false }
                }
            }
        }
        onState(state)
    }
}
