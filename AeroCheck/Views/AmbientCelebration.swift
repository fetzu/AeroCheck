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
        revision &+= 1
        reveal &+= 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Palette

/// The alternate accent set (primary + plum surfaces) and the soft secondary hues used by the reveal.
/// Plain sRGB components; nothing here is wired up unless `AmbientController.engage()` installs it.
enum AmbientTheme {
    static let accent     = Color(red: 230 / 255, green: 46 / 255,  blue: 139 / 255)
    static let background = Color(red: 28 / 255,  green: 14 / 255,  blue: 28 / 255)
    static let panel      = Color(red: 42 / 255,  green: 20 / 255,  blue: 38 / 255)

    static let rose       = Color(red: 244 / 255, green: 114 / 255, blue: 182 / 255)
    static let cotton     = Color(red: 251 / 255, green: 207 / 255, blue: 232 / 255)
    static let lavender   = Color(red: 196 / 255, green: 181 / 255, blue: 253 / 255)
    static let sky        = Color(red: 147 / 255, green: 197 / 255, blue: 253 / 255)

    // Reveal-only detailing.
    static let crestSun   = Color(red: 253 / 255, green: 230 / 255, blue: 138 / 255)
    static let cheek      = Color(red: 251 / 255, green: 113 / 255, blue: 133 / 255)
    static let beak       = Color(red: 243 / 255, green: 217 / 255, blue: 192 / 255)
    static let plum       = Color(red: 131 / 255, green: 24 / 255,  blue: 67 / 255)
    static let pupil      = Color(red: 42 / 255,  green: 14 / 255,  blue: 30 / 255)

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
            panelStroke: accent.opacity(0.28),
            action: accent,
            actionText: .white,
            onTarget: .aviationGreen,
            warning: Color(red: 0.91, green: 0.56, blue: 0.18),
            danger: .aviationRed,
            info: .altimeterBlue,
            textPrimary: .primaryText,
            textSecondary: .secondaryText,
            textDim: .dimText,
            glassFill: Color.white.opacity(0.06),
            glassStroke: accent.opacity(0.35)
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

// MARK: - Mascot

/// A cartoon rainbow cockatiel perched on a cloud, drawn in a 190×250 design space.
private struct CockatielMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 190
            context.scaleBy(x: scale, y: scale)

            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            }
            func quadArc(_ x0: CGFloat, _ x1: CGFloat, _ apexY: CGFloat, baseY: CGFloat = 206) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: x0, y: baseY))
                path.addQuadCurve(to: CGPoint(x: x1, y: baseY),
                                  control: CGPoint(x: (x0 + x1) / 2, y: apexY))
                return path
            }

            // Rainbow arcs behind the mascot (mostly hidden by the cloud).
            let arcStyle = StrokeStyle(lineWidth: 9, lineCap: .round)
            context.stroke(quadArc(20, 170, 120), with: .color(AmbientTheme.rose.opacity(0.5)), style: arcStyle)
            context.stroke(quadArc(32, 158, 134), with: .color(AmbientTheme.lavender.opacity(0.5)), style: arcStyle)
            context.stroke(quadArc(44, 146, 148), with: .color(AmbientTheme.sky.opacity(0.5)), style: arcStyle)

            // Cloud.
            let white = GraphicsContext.Shading.color(.white)
            context.fill(Path(roundedRect: CGRect(x: 58, y: 200, width: 104, height: 28), cornerRadius: 14), with: white)
            context.fill(circle(60, 206, 30), with: white)
            context.fill(circle(95, 196, 36), with: white)
            context.fill(circle(132, 198, 34), with: white)
            context.fill(circle(160, 206, 26), with: white)

            // Tail feathers (in front of the cloud).
            func poly(_ pts: [CGPoint]) -> Path {
                var path = Path()
                path.move(to: pts[0])
                for point in pts.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                return path
            }
            context.fill(poly([CGPoint(x: 86, y: 150), CGPoint(x: 74, y: 202), CGPoint(x: 86, y: 205), CGPoint(x: 98, y: 152)]), with: .color(AmbientTheme.accent))
            context.fill(poly([CGPoint(x: 98, y: 151), CGPoint(x: 96, y: 206), CGPoint(x: 108, y: 206), CGPoint(x: 110, y: 154)]), with: .color(AmbientTheme.rose))
            context.fill(poly([CGPoint(x: 110, y: 150), CGPoint(x: 124, y: 202), CGPoint(x: 134, y: 197), CGPoint(x: 120, y: 152)]), with: .color(AmbientTheme.sky))

            // Crest (drawn before the head so the head covers the bases).
            func leaf(_ a: CGPoint, _ c1: CGPoint, _ tip: CGPoint, _ c2: CGPoint, _ b: CGPoint) -> Path {
                var path = Path()
                path.move(to: a)
                path.addQuadCurve(to: tip, control: c1)
                path.addQuadCurve(to: b, control: c2)
                path.closeSubpath()
                return path
            }
            context.fill(leaf(CGPoint(x: 84, y: 52), CGPoint(x: 82, y: 14), CGPoint(x: 96, y: 8), CGPoint(x: 99, y: 30), CGPoint(x: 101, y: 52)), with: .color(AmbientTheme.crestSun))
            context.fill(leaf(CGPoint(x: 98, y: 50), CGPoint(x: 103, y: 12), CGPoint(x: 117, y: 9), CGPoint(x: 112, y: 32), CGPoint(x: 112, y: 50)), with: .color(AmbientTheme.rose))
            context.fill(leaf(CGPoint(x: 110, y: 52), CGPoint(x: 120, y: 18), CGPoint(x: 132, y: 21), CGPoint(x: 124, y: 38), CGPoint(x: 120, y: 54)), with: .color(AmbientTheme.sky))

            // Body, belly, head.
            context.fill(ellipse(98, 118, 38, 46), with: .color(AmbientTheme.accent))
            context.fill(ellipse(95, 131, 22, 31), with: .color(AmbientTheme.cotton))
            context.fill(circle(98, 70, 32), with: .color(AmbientTheme.accent))

            // Wing.
            var wing = Path()
            wing.move(to: CGPoint(x: 104, y: 90))
            wing.addQuadCurve(to: CGPoint(x: 118, y: 158), control: CGPoint(x: 142, y: 116))
            wing.addQuadCurve(to: CGPoint(x: 98, y: 106), control: CGPoint(x: 101, y: 150))
            wing.closeSubpath()
            context.fill(wing, with: .color(AmbientTheme.rose))

            var wingTip = Path()
            wingTip.move(to: CGPoint(x: 110, y: 142))
            wingTip.addQuadCurve(to: CGPoint(x: 116, y: 160), control: CGPoint(x: 122, y: 152))
            wingTip.addQuadCurve(to: CGPoint(x: 106, y: 146), control: CGPoint(x: 107, y: 156))
            wingTip.closeSubpath()
            context.fill(wingTip, with: .color(AmbientTheme.sky))

            let featherLine = StrokeStyle(lineWidth: 1.6, lineCap: .round)
            var fl1 = Path(); fl1.move(to: CGPoint(x: 106, y: 104)); fl1.addQuadCurve(to: CGPoint(x: 116, y: 144), control: CGPoint(x: 124, y: 118))
            var fl2 = Path(); fl2.move(to: CGPoint(x: 102, y: 120)); fl2.addQuadCurve(to: CGPoint(x: 112, y: 152), control: CGPoint(x: 118, y: 132))
            context.stroke(fl1, with: .color(AmbientTheme.cotton.opacity(0.8)), style: featherLine)
            context.stroke(fl2, with: .color(AmbientTheme.cotton.opacity(0.8)), style: featherLine)

            // Face.
            context.fill(circle(80, 82, 10), with: .color(AmbientTheme.cheek.opacity(0.9)))
            context.fill(circle(102, 66, 11), with: white)
            context.fill(circle(104, 68, 6), with: .color(AmbientTheme.pupil))
            context.fill(circle(100, 63, 2.3), with: white)

            var beak = Path()
            beak.move(to: CGPoint(x: 84, y: 77))
            beak.addQuadCurve(to: CGPoint(x: 82, y: 95), control: CGPoint(x: 72, y: 86))
            beak.addQuadCurve(to: CGPoint(x: 91, y: 78), control: CGPoint(x: 89, y: 88))
            beak.closeSubpath()
            context.fill(beak, with: .color(AmbientTheme.beak))
        }
        .aspectRatio(190.0 / 250.0, contentMode: .fit)
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
    var body: some View {
        ZStack {
            CockatielMark()
                .frame(width: 150, height: 197)
            CurvedText(text: AmbientCopy.title, radius: 118, size: 21, uiWeight: .heavy,
                       color: .white, side: .top, tracking: 1, shadow: AmbientTheme.accent)
            CurvedText(text: AmbientCopy.subtitle, radius: 120, size: 11, uiWeight: .bold,
                       color: AmbientTheme.cotton, side: .bottom, tracking: 3)
        }
        .frame(width: 300, height: 300)
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
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .transition(.opacity)
                ConfettiLayer(start: start)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if showLogo {
                    AmbientLogoCard()
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
