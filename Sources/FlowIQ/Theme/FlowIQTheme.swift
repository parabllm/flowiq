import SwiftUI
// FlowIQTheme: the only place for colors, fonts, spacing, radii and sizes (R-004). House colors
// ([T] house theme, [D] its dark dashboard variant, [A] derived for FlowIQ).
// DM Sans as in the house theme, bundled (Resources/Fonts, OFL 1.1, ATSApplicationFontsPath). Dark mode: no shadows.

nonisolated enum FlowIQTheme {
    enum Color {
        static let background = dynamic(light: 0xFBF9FE, dark: 0x1A1726)                      // [T] grund · [D]
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x282533)                         // [T] karte · [D]
        static let surfaceQuiet = dynamic(light: 0xF6F5FD, dark: 0xFFFFFF, darkAlpha: 0.06)   // [T] muted · [D]
        static let surfaceStrong = dynamic(light: 0xE5E0EF, dark: 0x3E3B4F)                   // [T] flaeche-kühl
        static let text = dynamic(light: 0x1A1726, dark: 0xFBF9FE)                            // [T] tinte · [D]
        static let textSecondary = dynamic(light: 0x423E55, dark: 0xFBF9FE, darkAlpha: 0.78)  // [T] · [D] fg-soft
        static let textMuted = dynamic(light: 0x5E5A70, dark: 0xC5C2D4)                       // [T] · [D]
        static let accent = dynamic(light: 0x6648CB, dark: 0xC7B3FF)                          // [T] akzent, Links
        static let accentTint = dynamic(light: 0xE8DEFF, dark: 0x6648CB, darkAlpha: 0.20)     // [T] marker · [D]
        static let hairline = dynamic(light: 0x3F3965, lightAlpha: 0.08, dark: 0xFBF9FE, darkAlpha: 0.12)
        static let hairlineStrong = dynamic(light: 0x3F3965, lightAlpha: 0.10, dark: 0xFBF9FE, darkAlpha: 0.22)
        /// [A] `haarlinie-stark` laid opaque on the card: a translucent stroke doubles where a capsule path closes.
        static let rim = dynamic(light: 0xE7E5EE, dark: 0x58556A)
        static let input = dynamic(light: 0x7C7890, dark: 0xA9A7B1)          // [T] Rand, Schalter aus
        static let primary = dynamic(light: 0x1A1726, dark: 0xFBF9FE)                         // [T] Knopf Tinte · [D]
        static let onPrimary = dynamic(light: 0xFBF9FE, dark: 0x1A1726)
        static let primaryHover = dynamic(light: 0x4F379C, dark: 0xC7B3FF)                    // [T] akzent-hover
        static let success = dynamic(light: 0x29A36E, dark: 0x29A36E)                         // [T]
        static let successText = dynamic(light: 0x1E7951, dark: 0xE2EFED)
        static let warning = dynamic(light: 0xCF7C53, dark: 0xCF7C53)
        static let warningText = dynamic(light: 0x995C3D, dark: 0xF6EAE9)
        static let warningTint = dynamic(light: 0xF6EAE9, dark: 0xCF7C53, darkAlpha: 0.20)
        static let infoTint = dynamic(light: 0xE8DEFF, dark: 0x6648CB, darkAlpha: 0.20)
        static let infoText = dynamic(light: 0x4F379C, dark: 0xE8DEFF)
        // Pill (local/design/pille-neu.html, 16.11.): fills fixed in both modes; outline, rim, pen ring follow.
        static let recording = SwiftUI.Color(nsColor: fixed(0xE0556B))                      // Diktat, status.danger
        static let recordingCall = SwiftUI.Color(nsColor: fixed(0x6648CB))                   // Call, violet.700
        static let recordingRoom = SwiftUI.Color(nsColor: fixed(0x9DA1FF))                   // Raum, violet.400
        static let pillOutline = dynamic(light: 0x1A1726, lightAlpha: 0.5, dark: 0xFFFFFF, darkAlpha: 0.6)  // at rest
        static let pillRim = dynamic(light: 0x1A1726, lightAlpha: 0.3, dark: 0xFFFFFF, darkAlpha: 0.28)  // around fills
        static let pillNeutral = dynamic(light: 0x1A1726, lightAlpha: 0.65, dark: 0xFFFFFF, darkAlpha: 0.75)  // pen
        static let glyph = SwiftUI.Color(nsColor: fixed(0xFFFFFF))                           // "EN", the lock dot
        static let brandCenter = dynamic(light: 0x6648CB, dark: 0xC7B3FF)                    // Logo B: 700 / 200
        static let brandMid = dynamic(light: 0xAC88FF, dark: 0xAC88FF)                       // 500
        static let brandOuter = dynamic(light: 0xC7B3FF, dark: 0x9DA1FF)                     // 200 / 400
        static let transparent = NSColor.clear
        static let windowBackground = dynamicNS(light: 0xFBF9FE, dark: 0x1A1726)
        private static func fixed(_ hex: UInt32, _ alpha: Double = 1) -> NSColor { NSColor(hex: hex, alpha: alpha) }
        private static func dynamic(light: UInt32, lightAlpha: Double = 1, dark: UInt32,
                                    darkAlpha: Double = 1) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: dynamicNS(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
        }
        // The provider runs wherever AppKit resolves the color, so it must stay nonisolated.
        private static func dynamicNS(light: UInt32, lightAlpha: Double = 1, dark: UInt32,
                                      darkAlpha: Double = 1) -> NSColor {
            NSColor(name: nil) { @Sendable appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
            }
        }
    }
    /// DM Sans as the house theme; in the app only 11, 12, 14 pt (R-077), weights 400 and 500.
    enum Font {
        static let regular = "DMSans-Regular", medium = "DMSans-Medium"
        struct Style { let postScriptName: String, size: CGFloat, tracking: CGFloat, uppercase: Bool }
        static let micro = Style(postScriptName: regular, size: 11, tracking: 0, uppercase: false)
        static let microMedium = Style(postScriptName: medium, size: 11, tracking: 0, uppercase: false)
        static let caption = Style(postScriptName: regular, size: 12, tracking: 0, uppercase: false)
        static let badge = Style(postScriptName: medium, size: 12, tracking: 0, uppercase: false)
        static let label = Style(postScriptName: medium, size: 11, tracking: 0.18, uppercase: true)  // [A] 11 statt 12
        static let small = Style(postScriptName: regular, size: 14, tracking: 0, uppercase: false)
        static let smallMedium = Style(postScriptName: medium, size: 14, tracking: 0, uppercase: false)
        static func custom(_ style: Style) -> SwiftUI.Font { .custom(style.postScriptName, fixedSize: style.size) }
        static func ns(_ style: Style) -> NSFont { NSFont(name: style.postScriptName,
            size: style.size) ?? .menuFont(ofSize: 0) }
        static func symbol(_ size: CGFloat) -> SwiftUI.Font { .system(size: size, weight: .regular) }
        static var isBundled: Bool { NSFont(name: regular, size: caption.size) != nil }
    }
    enum Spacing {
        static let s2: CGFloat = 2, s4: CGFloat = 4, s6: CGFloat = 6, s8: CGFloat = 8, s10: CGFloat = 10
        static let s12: CGFloat = 12, s16: CGFloat = 16, s20: CGFloat = 20, s24: CGFloat = 24
    }
    enum Radius { static let sm: CGFloat = 12, md: CGFloat = 16 }
    /// The main window (16.11.: "viel zu viel freier Platz"): sidebar, content, the history's time column and
    /// its stats card; `top` is the first line below the 32 pt title bar (measured offscreen), sidebar and heading.
    enum Main {
        static let window = CGSize(width: 900, height: 640), minimum = CGSize(width: 800, height: 420)  // large again
        static let sidebar: CGFloat = 148, time: CGFloat = 36, stats: CGFloat = 156, page = 60, dialog: CGFloat = 320
        static let top: CGFloat = 36, inset: CGFloat = 16, row: CGFloat = 32  // settings row with its grey line
        static let folded = 3, long = 220  // lines of a folded dictation, characters from which it folds
        // settings grid: label column, live column, key field, narrowest form (it fills the window's width)
        static let label: CGFloat = 230, live: CGFloat = 196, keyField: CGFloat = 220, form: CGFloat = 651
    }
    enum Size {
        static let hairline: CGFloat = 1, focusRing: CGFloat = 2
        static let control: CGFloat = 24, row: CGFloat = 28, rowTall: CGFloat = 40   // [A] Mac-Maße
        static let switchWidth: CGFloat = 26, switchHeight: CGFloat = 16, switchKnob: CGFloat = 12
        static let symbol: CGFloat = 12, symbolLarge: CGFloat = 16, iconTile: CGFloat = 28, mark: CGFloat = 10
        static let settings = CGSize(width: 440, height: 560), setupWidth: CGFloat = 360   // A.12
        static let correctionWidth: CGFloat = 400, choicesWidth: CGFloat = 220, field: CGFloat = 200
        static let menuBarIcon: CGFloat = 18, appMark: CGFloat = 32, levelWidth: CGFloat = 5
    }
    /// The pill (local/design/pille-neu.html, constant O, approved 16.11.): three pills 6 wide in one column
    /// 10 from the edge; dictation 6 × 22 at rest, 6 × 44 while dictating; call and room 6 × 18, 3 beyond the 44 high
    /// dictation pill; "EN" 5 right of its pill; rings 12 wide, the pen's center 11 right of the dictation pill.
    enum Pill {
        static let width: CGFloat = 6, idle: CGFloat = 22, active: CGFloat = 44, recording: CGFloat = 18
        static let gap: CGFloat = 3, edgeInset: CGFloat = 10, outline: CGFloat = 1, rim: CGFloat = 1
        static let lockDot: CGFloat = 4, dotAlpha: CGFloat = 0.95
        static let tag: CGFloat = 16, tagWidth: CGFloat = 26, tagGap: CGFloat = 5, tagFont: CGFloat = 11  // "EN"
        static let ring: CGFloat = 12, ringLine: CGFloat = 1.6, ringTrack: Float = 0.25, penOffset: CGFloat = 11
        static let canvas = CGSize(width: 60, height: 120)
        static let englishHold: Double = 5   // "EN" after an English start, then gone (16.11.)
        static let bounce: Double = 0.15  // a second press within this is a bounce, later it stops (review V6)
        // The ring after a stop (no real share known): cap 95 % until saved, time constant 2 s plus 0.1 s per
        // recorded second (assumed, not measured), redrawn every 0.2 s; full for 0.4 s at the end.
        static let ringCap = 0.95, ringBase = 2.0, ringPerSecond = 0.1, ringStep = 0.2, ringDone = 0.4
    }
    /// One spring for size and for what comes or goes (16.11.: "wie Apple, mit Physik"): damping ratio 0.62,
    /// about 8 % overshoot, settled after about 0.6 s; colors 0.3 s, opacity 0.2 s, appearing from half size.
    enum PillMotion {
        static let stiffness: Double = 190, damping: Double = 17.1, fade: Double = 0.2, color: Double = 0.3
        static let start: CGFloat = 0.5, ringFill: Double = 0.2
        /// The spring's share of the way at `t` seconds (mass 1), as CASpringAnimation runs it; for the previews.
        static func progress(_ t: Double) -> Double {
            let w0 = stiffness.squareRoot(), zeta = damping / (2 * w0), wd = w0 * (1 - zeta * zeta).squareRoot()
            guard t > 0 else { return 0 }
            return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta / (1 - zeta * zeta).squareRoot() * sin(wd * t))
        }
    }
    /// Logo B "Stimme" on a 100 grid (local/design/marke/zeichen-b): bar centers, tops, bottoms; stroke 11.
    enum Brand {
        static let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [(14, 24, 44), (32, 12, 56), (50, 5.5, 94.5),
                                                                          (68, 12, 56), (86, 24, 44)]
        static let stroke: CGFloat = 11, grid: CGFloat = 100, inset: CGFloat = 8.5, aspect: CGFloat = 85 / 102
    }
    enum State { static let disabledOpacity: Double = 0.4 }
    enum Motion {
        static let fast: Double = 0.15
        static let restartWait: Double = 5, restartPoll: Double = 0.1  // "Neu starten" waits for the old instance
        static let restartGrace: Double = 1  // after the hard end: this long until the new one goes on anyway
        static let iconCheck: Double = 2  // after launch: is the menu bar icon on a screen?
        static let pressedScale: CGFloat = 0.97, tick: Double = 1, idleTick: Double = 10
        static let easeSoft = (x1: 0.4, y1: 0.0, x2: 0.2, y2: 1.0)
    }
}

private nonisolated extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}

extension View {
    func textStyle(_ style: FlowIQTheme.Font.Style, _ color: Color = FlowIQTheme.Color.text) -> some View {
        font(FlowIQTheme.Font.custom(style)).tracking(style.tracking * style.size)
            .textCase(style.uppercase ? .uppercase : nil).foregroundStyle(color)
    }
    /// Card: surface on a hairline, no shadow.
    func card() -> some View {
        let t = FlowIQTheme.self, shape = RoundedRectangle(cornerRadius: t.Radius.md, style: .continuous)
        return background(shape.fill(t.Color.hairline).overlay(shape.inset(by: t.Size.hairline).fill(t.Color.surface)))
    }
}

/// A capsule with a 1 pt rim as two fills: a stroked capsule leaves spikes at its sides in offscreen renders.
struct Rim: View {
    let fill: Color, rim: Color
    var body: some View {
        Capsule().fill(rim).overlay(Capsule().inset(by: FlowIQTheme.Size.hairline).fill(fill))
    }
}

/// Primary: ink with paper text, at most one per view (review S2); otherwise an outline on `hairlineStrong`.
struct FlowButton: ButtonStyle {
    var primary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let t = FlowIQTheme.self, c = t.Motion.easeSoft
        let fill = primary ? (hover ? t.Color.primaryHover : t.Color.primary) : t.Color.surface
        return configuration.label.textStyle(t.Font.caption, primary ? t.Color.onPrimary : t.Color.text)
            .padding(.horizontal, t.Spacing.s12).frame(minHeight: t.Size.control)
            .background(Rim(fill: fill, rim: primary ? fill : t.Color.rim))
            .contentShape(Capsule()).opacity(enabled ? 1 : t.State.disabledOpacity)
            .scaleEffect(configuration.isPressed && !reduceMotion ? t.Motion.pressedScale : 1)
            .animation(reduceMotion ? nil : .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: t.Motion.fast),
                       value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

/// Switch 26 × 16, on with a check mark (review S8); the whole row is the target (M11).
struct FlowSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let t = FlowIQTheme.self, on = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: t.Spacing.s8) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: on ? .trailing : .leading) {
                    Rim(fill: on ? t.Color.primary : t.Color.surface, rim: on ? t.Color.primary : t.Color.input)
                    Circle().fill(on ? t.Color.onPrimary : t.Color.input).frame(width: t.Size.switchKnob)
                        .overlay(Image(systemName: "checkmark").font(.system(size: t.Size.mark - 3, weight: .bold))
                            .foregroundStyle(t.Color.primary).opacity(on ? 1 : 0))
                        .padding(t.Spacing.s2)
                }
                .frame(width: t.Size.switchWidth, height: t.Size.switchHeight)
            }
            .frame(minHeight: t.Size.control).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "an" : "aus")
    }
}

/// Segments as a pill bar in `surfaceQuiet`, the active one a card with a rim (house-theme tabs).
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var enabled: (Value) -> Bool = { _ in true }
    var body: some View {
        let t = FlowIQTheme.self
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button(title) { selection = value }.buttonStyle(.plain)
                    .textStyle(on ? t.Font.badge : t.Font.caption, on ? t.Color.text : t.Color.textMuted)
                    .padding(.horizontal, t.Spacing.s10).frame(minHeight: t.Size.control - t.Spacing.s4)
                    .background(Rim(fill: on ? t.Color.surface : .clear, rim: on ? t.Color.rim : .clear))
                    .opacity(enabled(value) ? 1 : t.State.disabledOpacity)
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(t.Spacing.s2).background(t.Color.surfaceQuiet, in: Capsule())
    }
}

/// A collapsed explanation (R-078): chevron and link text, the text only after a click.
struct Explain: View {
    let title: String, text: String
    var link = true
    @State private var open = false
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s4) {
            Button { open.toggle() } label: {
                Label(title, systemImage: open ? "chevron.down" : "chevron.right").labelStyle(.titleAndIcon)
                    .textStyle(t.Font.caption, link ? t.Color.accent : t.Color.text).frame(minHeight: t.Size.control)
            }
            .buttonStyle(.plain)
            if open { Text(text).textStyle(t.Font.micro, t.Color.textMuted).fixedSize(horizontal: false,
                vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
