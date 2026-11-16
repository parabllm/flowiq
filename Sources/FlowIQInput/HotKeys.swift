import Carbon.HIToolbox

/// The registered keys (A.3, D, 16.11.): Command-Option with U call, R room, E for English, K correct;
/// Control in development. E is registered so that it never reaches the app in front; alone it does nothing.
public enum HotKey: String, Sendable, CaseIterable {
    case call, room, english, correct
    public func combination(for profile: Profile) -> (keyCode: UInt32, modifiers: UInt32) {
        let code = switch self {
        case .call: kVK_ANSI_U
        case .room: kVK_ANSI_R
        case .english: kVK_ANSI_E
        case .correct: kVK_ANSI_K
        }
        return (UInt32(code), UInt32(cmdKey | optionKey | (profile == .development ? controlKey : 0)))
    }
}

/// Global shortcuts over Carbon (A.3): a taken combination is logged as `shortcut_taken`, never silent.
/// Presses and releases go through `LanguageChord`; only a lone U or R waits, and only while nothing runs.
@MainActor
public final class HotKeys {
    private let profile: Profile, log: EventLog, running: (HotKey) -> Bool, deliver: (Shortcut) -> Void
    private let eDown: () -> Bool
    private var refs: [EventHotKeyRef] = [], handler: EventHandlerRef? = nil
    private var chord = LanguageChord(), wait: Task<Void, Never>?
    public init(profile: Profile, log: EventLog, running: @escaping (HotKey) -> Bool,
                deliver: @escaping (Shortcut) -> Void,
                eDown: @escaping () -> Bool = { CGEventSource.keyState(.combinedSessionState, key: 14) }) {
        (self.profile, self.log, self.running, self.deliver, self.eDown) = (profile, log, running, deliver, eDown)
    }
    /// Returns the keys that could not be registered.
    @discardableResult
    public func register(_ keys: [HotKey]) -> [HotKey] {
        let specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let installed = handler != nil ? noErr : InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 2,
                                                                    specs, Unmanaged.passUnretained(self).toOpaque(),
                                                                    &handler)
        return keys.filter { key in
            let (code, modifiers) = key.combination(for: profile)
            let id = EventHotKeyID(signature: OSType(PostedEvents.tag),
                                   id: UInt32(HotKey.allCases.firstIndex(of: key) ?? 0))
            var ref: EventHotKeyRef?
            let status = installed != noErr ? installed
                : RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                log.record(LogEvent("shortcut_taken", level: .error,
                                    ["shortcut": .string(key.rawValue), "status": .int(Int64(status))]))
                return true
            }
            refs.append(ref)
            return false
        }
    }
    /// One edge from Carbon on the main thread; `eDown` reads the real E (key code 14) before a letter decides.
    func receive(_ key: HotKey, down: Bool) {
        if key != .english, down, !eDown() { chord.releaseE() }  // only clears a stale E, never invents one
        route(chord.handle(key, down: down, at: MachTime.nanos(ticks: MachTime.now()), running: running(key)))
    }
    private func route(_ shortcuts: [Shortcut]) {
        shortcuts.forEach(deliver)
        wait?.cancel()
        guard let until = chord.deadline else { return }
        let now = MachTime.nanos(ticks: MachTime.now())
        wait = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: until > now ? until - now : 0) } catch { return }
            guard let self else { return }
            route(chord.tick(now: max(until, MachTime.nanos(ticks: MachTime.now()))))
        }
    }
}

private func hotKeyCallback(_ call: EventHandlerCallRef?, _ event: EventRef?,
                            _ keys: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    guard let event, let keys, GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                                 EventParamType(typeEventHotKeyID), nil,
                                                 MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
          Int(id.id) < HotKey.allCases.count else { return OSStatus(eventNotHandledErr) }
    let (key, down) = (HotKey.allCases[Int(id.id)], GetEventKind(event) == UInt32(kEventHotKeyPressed))
    let address = UInt(bitPattern: keys)  // Carbon calls on the main thread; the address crosses as a plain number
    MainActor.assumeIsolated {
        guard let keys = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<HotKeys>.fromOpaque(keys).takeUnretainedValue().receive(key, down: down)
    }
    return noErr
}
