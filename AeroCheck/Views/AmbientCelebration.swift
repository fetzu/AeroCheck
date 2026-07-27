import SwiftUI
import UIKit

// Optional runtime accent treatment for the app shell.
//
// This file owns an alternate accent palette that can be installed at runtime (e.g. for a seasonal
// or promotional look) on top of the standard cockpit tokens, plus the short reveal animation that
// plays when it is switched on. Everything specific to the treatment lives here; the rest of the app
// only ever sees the generic `AmbientPalette` tokens and the `cockpitTheme` environment value, both
// of which fall back to the normal cockpit appearance when nothing is installed.

// MARK: - Controller

/// Owns the lifecycle of the optional accent treatment and drives the one-shot reveal.
@MainActor
final class AmbientController: ObservableObject {
    static let shared = AmbientController()
    nonisolated private init() {}

    /// Bumped whenever the installed palette changes. The shared design tokens are plain computed
    /// properties, so the view tree needs an explicit nudge (a fresh identity at the root) to re-read
    /// them — this counter provides it.
    @Published private(set) var revision: Int = 0

    /// Bumped to play the reveal overlay exactly once.
    @Published private(set) var reveal: Int = 0

    /// `true` while the alternate accent palette is installed.
    var isEngaged: Bool { AmbientPalette.isActive }

    /// Installs the alternate accent palette (idempotent) and replays the reveal. Never persisted —
    /// a fresh launch always starts on the standard cockpit palette.
    func engage() {
        AmbientPalette.accent = AmbientTheme.accent
        AmbientPalette.background = AmbientTheme.background
        AmbientPalette.panel = AmbientTheme.panel
        AmbientPalette.card = AmbientTheme.panel
        AmbientPalette.chrome = AmbientTheme.chrome
        AmbientPalette.hairline = AmbientTheme.hairline
        AmbientPalette.textPrimary = AmbientTheme.textPrimary
        AmbientPalette.textSecondary = AmbientTheme.textSecondary
        AmbientPalette.textDim = AmbientTheme.textDim
        revision &+= 1
        reveal &+= 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Palette

/// The alternate accent set (a pink accent over light blush surfaces with dark text) and the soft
/// secondary hues used by the reveal. Plain sRGB components; nothing here is wired up unless
/// `AmbientController.engage()` installs it.
enum AmbientTheme {
    static let accent       = Color(red: 230 / 255, green: 46 / 255,  blue: 139 / 255)
    static let background   = Color(red: 253 / 255, green: 242 / 255, blue: 248 / 255) // blush
    static let panel        = Color(red: 1.0,       green: 1.0,       blue: 1.0)       // white cards
    static let chrome       = Color(red: 252 / 255, green: 231 / 255, blue: 243 / 255) // cotton bar
    static let hairline     = Color(red: 240 / 255, green: 217 / 255, blue: 230 / 255)
    static let textPrimary  = Color(red: 59 / 255,  green: 10 / 255,  blue: 36 / 255)  // deep plum
    static let textSecondary = Color(red: 157 / 255, green: 91 / 255, blue: 121 / 255)
    static let textDim      = Color(red: 201 / 255, green: 155 / 255, blue: 180 / 255)

    static let rose       = Color(red: 244 / 255, green: 114 / 255, blue: 182 / 255)
    static let cotton     = Color(red: 251 / 255, green: 207 / 255, blue: 232 / 255)
    static let lavender   = Color(red: 196 / 255, green: 181 / 255, blue: 253 / 255)
    static let sky        = Color(red: 147 / 255, green: 197 / 255, blue: 253 / 255)

    // Reveal-only detailing (the uni-tiel mark).
    static let crestSun   = Color(red: 253 / 255, green: 230 / 255, blue: 138 / 255)
    static let cheek      = Color(red: 251 / 255, green: 146 / 255, blue: 60 / 255)   // orange cheek patch
    static let beak       = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)  // grey beak
    static let belly      = Color(red: 251 / 255, green: 207 / 255, blue: 232 / 255)
    static let pupil      = Color(red: 42 / 255,  green: 14 / 255,  blue: 30 / 255)
    static let horn       = Color(red: 252 / 255, green: 211 / 255, blue: 77 / 255)
    static let hornHi     = Color(red: 254 / 255, green: 243 / 255, blue: 199 / 255)
    static let hornLine   = Color(red: 217 / 255, green: 154 / 255, blue: 46 / 255)

    /// Reveal confetti draws from the focused pink→sky set.
    static let confetti: [Color] = [accent, rose, cotton, lavender, sky]
}

extension CockpitTheme {
    /// The cockpit palette to inject while the alternate accent is engaged, or `nil` to use the
    /// normally-resolved theme. Mirrors `.day` but swaps the action colour and the surfaces so the
    /// revamped screens follow the same accent as the static tokens.
    static var ambientOverride: CockpitTheme? {
        guard AmbientPalette.isActive else { return nil }
        let accent = AmbientPalette.accent ?? .aviationGold
        return CockpitTheme(
            mode: .day,
            background: AmbientPalette.background ?? .cockpitBackground,
            panel: AmbientPalette.panel ?? .panelBackground,
            card: AmbientPalette.card ?? .cardBackground,
            panelStroke: AmbientPalette.hairline ?? accent.opacity(0.28),
            action: accent,
            actionText: .white,
            onTarget: .aviationGreen,
            warning: Color(red: 0.91, green: 0.56, blue: 0.18),
            danger: .aviationRed,
            info: .altimeterBlue,
            textPrimary: AmbientPalette.textPrimary ?? .primaryText,
            textSecondary: AmbientPalette.textSecondary ?? .secondaryText,
            textDim: AmbientPalette.textDim ?? .dimText,
            glassFill: Color.black.opacity(0.05),
            glassStroke: accent.opacity(0.30)
        )
    }
}

// MARK: - Copy

/// Reveal copy, assembled from bytes at runtime so the source carries no plaintext.
private enum AmbientCopy {
    static var title: String {
        String(decoding: [0x46, 0x75, 0x6E, 0x6B, 0x73, 0x20, 0x61, 0x6E, 0x64, 0x20,
                          0x53, 0x70, 0x6F, 0x6F, 0x6B, 0x73, 0x21], as: UTF8.self)
    }
    static var subtitle: String {
        String(decoding: [0x41, 0x20, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x20, 0x63,
                          0x6F, 0x63, 0x6B, 0x70, 0x69, 0x74, 0x20, 0x74, 0x68, 0x65,
                          0x6D, 0x65], as: UTF8.self).uppercased()
    }
}

// MARK: - Curved text

/// Lays a string along the top or bottom of a circle, each glyph rotated tangent to the arc.
private struct CurvedText: View {
    enum Side { case top, bottom }

    let text: String
    let radius: CGFloat
    let size: CGFloat
    let uiWeight: UIFont.Weight
    let color: Color
    let side: Side
    var tracking: CGFloat = 0
    var shadow: Color? = nil

    private var uiFont: UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private var swiftWeight: Font.Weight {
        switch uiWeight {
        case .black: return .black
        case .heavy: return .heavy
        case .bold: return .bold
        case .semibold: return .semibold
        default: return .regular
        }
    }

    private func glyphWidth(_ character: Character) -> CGFloat {
        (String(character) as NSString).size(withAttributes: [.font: uiFont]).width + tracking
    }

    var body: some View {
        let characters = Array(text)
        let widths = characters.map(glyphWidth)
        let total = widths.reduce(0, +)
        let dim = radius * 2 + uiFont.lineHeight * 2
        let center = CGPoint(x: dim / 2, y: dim / 2)
        let font = Font.system(size: size, weight: swiftWeight, design: .rounded)

        return ZStack {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                let before = widths[0..<index].reduce(0, +)
                let mid = before + widths[index] / 2
                let offsetAngle = (mid - total / 2) / radius
                let alpha = placementAngle(offset: offsetAngle)
                let position = CGPoint(x: center.x + radius * cos(alpha),
                                       y: center.y + radius * sin(alpha))
                Text(String(character))
                    .font(font)
                    .foregroundColor(color)
                    .shadow(color: shadow ?? .clear, radius: shadow == nil ? 0 : 2, x: 0, y: 1)
                    .rotationEffect(.radians(Double(glyphRotation(alpha: alpha))))
                    .position(position)
            }
        }
        .frame(width: dim, height: dim)
    }

    // Angle measured from +x axis in a y-down space. Top centre = -π/2, bottom centre = +π/2.
    private func placementAngle(offset: CGFloat) -> CGFloat {
        switch side {
        case .top: return -(.pi / 2) + offset
        case .bottom: return (.pi / 2) - offset
        }
    }

    private func glyphRotation(alpha: CGFloat) -> CGFloat {
        switch side {
        case .top: return alpha + .pi / 2
        case .bottom: return alpha - .pi / 2
        }
    }
}

// MARK: - Mark

/// The uni-tiel: a left-facing rainbow cockatiel head with a spiral unicorn horn, rainbow crest,
/// orange cheek and a little neck, drawn in a 180×230 design space.
private struct UnitielMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 180
            context.scaleBy(x: scale, y: scale)

            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            func quad(_ a: CGPoint, _ c1: CGPoint, _ tip: CGPoint, _ c2: CGPoint, _ b: CGPoint) -> Path {
                var path = Path()
                path.move(to: a)
                path.addQuadCurve(to: tip, control: c1)
                path.addQuadCurve(to: b, control: c2)
                path.closeSubpath()
                return path
            }
            func line(_ a: CGPoint, _ b: CGPoint) -> Path {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                return path
            }
            func starPath(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: cx, y: cy - s))
                p.addLine(to: CGPoint(x: cx + 0.28 * s, y: cy - 0.28 * s))
                p.addLine(to: CGPoint(x: cx + s, y: cy))
                p.addLine(to: CGPoint(x: cx + 0.28 * s, y: cy + 0.28 * s))
                p.addLine(to: CGPoint(x: cx, y: cy + s))
                p.addLine(to: CGPoint(x: cx - 0.28 * s, y: cy + 0.28 * s))
                p.addLine(to: CGPoint(x: cx - s, y: cy))
                p.addLine(to: CGPoint(x: cx - 0.28 * s, y: cy - 0.28 * s))
                p.closeSubpath()
                return p
            }

            // Neck / upper chest (a little of the body below the head).
            var chest = Path()
            chest.move(to: CGPoint(x: 70, y: 150))
            chest.addQuadCurve(to: CGPoint(x: 90, y: 222), control: CGPoint(x: 66, y: 196))
            chest.addQuadCurve(to: CGPoint(x: 130, y: 192), control: CGPoint(x: 120, y: 226))
            chest.addQuadCurve(to: CGPoint(x: 116, y: 148), control: CGPoint(x: 134, y: 160))
            chest.closeSubpath()
            context.fill(chest, with: .color(AmbientTheme.accent))
            var belly = Path()
            belly.move(to: CGPoint(x: 78, y: 162))
            belly.addQuadCurve(to: CGPoint(x: 94, y: 218), control: CGPoint(x: 74, y: 196))
            belly.addQuadCurve(to: CGPoint(x: 122, y: 192), control: CGPoint(x: 114, y: 220))
            belly.addQuadCurve(to: CGPoint(x: 108, y: 158), control: CGPoint(x: 124, y: 168))
            belly.closeSubpath()
            context.fill(belly, with: .color(AmbientTheme.belly))

            // Head.
            context.fill(circle(92, 108, 50), with: .color(AmbientTheme.accent))

            // Rainbow crest, swept up and back (to the right, for a left-facing head).
            context.fill(quad(CGPoint(x: 98, y: 60), CGPoint(x: 98, y: 24), CGPoint(x: 108, y: 8), CGPoint(x: 118, y: 26), CGPoint(x: 112, y: 62)), with: .color(AmbientTheme.crestSun))
            context.fill(quad(CGPoint(x: 106, y: 60), CGPoint(x: 112, y: 22), CGPoint(x: 124, y: 10), CGPoint(x: 122, y: 34), CGPoint(x: 118, y: 64)), with: .color(AmbientTheme.rose))
            context.fill(quad(CGPoint(x: 114, y: 64), CGPoint(x: 124, y: 34), CGPoint(x: 136, y: 24), CGPoint(x: 130, y: 48), CGPoint(x: 122, y: 68)), with: .color(AmbientTheme.lavender))
            context.fill(quad(CGPoint(x: 122, y: 68), CGPoint(x: 136, y: 48), CGPoint(x: 148, y: 42), CGPoint(x: 138, y: 58), CGPoint(x: 128, y: 72)), with: .color(AmbientTheme.sky))

            // Spiral unicorn horn on the forehead, pointing up-left.
            let hornT = CGAffineTransform(translationX: 76, y: 74)
                .rotated(by: -0.52)
                .scaledBy(x: 1, y: 66.0 / 46.0)
            var cone = Path()
            cone.move(to: CGPoint(x: -6, y: 0))
            cone.addLine(to: CGPoint(x: 6, y: 0))
            cone.addLine(to: CGPoint(x: 0, y: -46))
            cone.closeSubpath()
            context.fill(cone.applying(hornT), with: .color(AmbientTheme.horn))
            context.stroke(line(CGPoint(x: -1, y: -3), CGPoint(x: 0, y: -43)).applying(hornT), with: .color(AmbientTheme.hornHi), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            context.stroke(line(CGPoint(x: -5, y: -7), CGPoint(x: 5, y: -11)).applying(hornT), with: .color(AmbientTheme.hornLine), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.stroke(line(CGPoint(x: -4, y: -17), CGPoint(x: 4, y: -21)).applying(hornT), with: .color(AmbientTheme.hornLine), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.stroke(line(CGPoint(x: -3, y: -27), CGPoint(x: 3, y: -30)).applying(hornT), with: .color(AmbientTheme.hornLine), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            context.stroke(line(CGPoint(x: -2, y: -36), CGPoint(x: 2, y: -38)).applying(hornT), with: .color(AmbientTheme.hornLine), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))

            // Beak (downcurved, on the left).
            var beak = Path()
            beak.move(to: CGPoint(x: 48, y: 104))
            beak.addQuadCurve(to: CGPoint(x: 40, y: 132), control: CGPoint(x: 26, y: 112))
            beak.addQuadCurve(to: CGPoint(x: 52, y: 110), control: CGPoint(x: 50, y: 126))
            beak.closeSubpath()
            context.fill(beak, with: .color(AmbientTheme.beak))

            // Cheek + eye.
            context.fill(circle(66, 128, 14), with: .color(AmbientTheme.cheek))
            context.fill(circle(74, 100, 12), with: .color(AmbientTheme.pupil))
            context.fill(circle(69, 95, 3), with: .color(.white))

            // A few sparkles.
            context.fill(starPath(40, 30, 6), with: .color(AmbientTheme.crestSun))
            context.fill(starPath(152, 70, 5), with: .color(AmbientTheme.lavender))
            context.fill(starPath(150, 150, 4), with: .color(AmbientTheme.sky))
        }
        .aspectRatio(180.0 / 230.0, contentMode: .fit)
    }
}

// MARK: - Confetti

private struct ConfettiPiece {
    let fromLeft: Bool
    let y0: CGFloat
    let speedX: CGFloat
    let speedY: CGFloat
    let delay: Double
    let life: Double
    let size: CGFloat
    let isCircle: Bool
    let colorIndex: Int
    let rotation: CGFloat
    let spin: CGFloat
}

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}

/// Edge-launched confetti, evaluated as deterministic projectile motion from a fixed start date.
private struct ConfettiLayer: View {
    let start: Date

    private static let pieces: [ConfettiPiece] = {
        var rng = SplitMix64(state: 0x1234_5678_9ABC_DEF0)
        return (0..<320).map { index in
            ConfettiPiece(
                fromLeft: index % 2 == 0,
                y0: CGFloat(0.12 + 0.46 * rng.unit()),
                speedX: CGFloat(220 + 360 * rng.unit()),
                speedY: CGFloat(-540 + 260 * rng.unit()),
                delay: 0.5 * rng.unit(),
                life: 3.0 + 1.2 * rng.unit(),
                size: CGFloat(6 + 6 * rng.unit()),
                isCircle: rng.unit() < 0.4,
                colorIndex: min(4, Int(rng.unit() * 5)),
                rotation: CGFloat(rng.unit() * 6.283185),
                spin: CGFloat(-6 + 12 * rng.unit())
            )
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                let gravity: CGFloat = 1100
                for piece in Self.pieces {
                    let lt = t - piece.delay
                    if lt < 0 || lt > piece.life { continue }
                    let originX: CGFloat = piece.fromLeft ? -12 : size.width + 12
                    let velocityX = piece.fromLeft ? piece.speedX : -piece.speedX
                    let x = originX + velocityX * CGFloat(lt)
                    let y = size.height * piece.y0 + piece.speedY * CGFloat(lt) + 0.5 * gravity * CGFloat(lt * lt)
                    if y > size.height + 24 { continue }
                    let fade = lt > piece.life - 0.8 ? max(0, (piece.life - lt) / 0.8) : 1
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2,
                                      width: piece.size, height: piece.size * 0.62)
                    let transform = CGAffineTransform(translationX: x, y: y)
                        .rotated(by: piece.rotation + piece.spin * CGFloat(lt))
                    let shape = piece.isCircle
                        ? Path(ellipseIn: rect).applying(transform)
                        : Path(roundedRect: rect, cornerRadius: 1).applying(transform)
                    context.fill(shape, with: .color(AmbientTheme.confetti[piece.colorIndex].opacity(fade)))
                }
            }
        }
    }
}

// MARK: - Logo + overlay

private struct AmbientLogoCard: View {
    /// Overall side length of the square logo; everything scales from it so the mark grows to fit
    /// the available screen (much bigger on iPad; capped so it never clips on iPhone).
    let side: CGFloat

    var body: some View {
        ZStack {
            UnitielMark()
                .frame(width: side * 0.50, height: side * 0.64)
            CurvedText(text: AmbientCopy.title, radius: side * 0.41, size: side * 0.068, uiWeight: .heavy,
                       color: .white, side: .top, tracking: 1, shadow: AmbientTheme.accent)
            CurvedText(text: AmbientCopy.subtitle, radius: side * 0.415, size: side * 0.0355, uiWeight: .bold,
                       color: AmbientTheme.cotton, side: .bottom, tracking: 3)
        }
        .frame(width: side, height: side)
    }
}

/// Full-screen reveal: a dimming scrim, edge confetti and the logo, shown once when `reveal` changes.
struct AmbientCelebrationOverlay: View {
    let reveal: Int

    @State private var activeReveal = 0
    @State private var start = Date()
    @State private var showLogo = false

    var body: some View {
        ZStack {
            if activeReveal != 0 {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .transition(.opacity)
                ConfettiLayer(start: start)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if showLogo {
                    GeometryReader { geo in
                        AmbientLogoCard(side: min(540, min(geo.size.width, geo.size.height) * 0.92))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .ignoresSafeArea()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        // Blocks stray taps while playing (so a 6th tap can't cut the animation short) but offers no
        // tap-to-dismiss — the reveal always runs its full course, then clears itself.
        .allowsHitTesting(activeReveal != 0)
        .onChange(of: reveal) { _, newValue in
            guard newValue != 0 else { return }
            start = Date()
            withAnimation(.easeOut(duration: 0.35)) { activeReveal = newValue }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { showLogo = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation(.easeOut(duration: 0.5)) { showLogo = false }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeOut(duration: 0.4)) { activeReveal = 0 }
            }
        }
    }
}

private struct AmbientCelebrationModifier: ViewModifier {
    @ObservedObject private var controller = AmbientController.shared

    func body(content: Content) -> some View {
        content.overlay(AmbientCelebrationOverlay(reveal: controller.reveal))
    }
}

extension View {
    /// Layers the one-shot accent reveal above the app shell. Inert until the treatment is engaged.
    func ambientCelebrationOverlay() -> some View {
        modifier(AmbientCelebrationModifier())
    }
}
