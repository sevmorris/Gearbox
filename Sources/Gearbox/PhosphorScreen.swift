// Shared verbatim across the sibling app repos (Gearbox, Dipstick). Keep the
// copies byte-identical: scripts/check-shared.sh compares them and a release
// preflight fails when they drift. Anything one app needs on its own belongs
// in that app's files, not here.

import AppKit
import SwiftUI

// The console's tube: Magic Backup Machine's phosphor screen, copied rather
// than shared with MBM, as MBM's is a copy of KeyVault's. MBM draws a log
// that only grows; the console draws a terminal, with a cursor and the keys
// typed at it, so the text view is the console's own (ConsoleScreenView.swift)
// and only the glass is copied: the style, the type, the face of the tube, the
// screen's decoration, the clip that keeps the text on the glass, and the
// scroller.

/// The colour of the tube.
enum PhosphorStyle: String, CaseIterable, Identifiable {
    case green
    case amber
    case plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green: return "Phosphor Green"
        case .amber: return "Phosphor Amber"
        case .plain: return "Plain"
        }
    }

    /// P1 green and P3 amber, near enough. Bright, and brighter than a text
    /// colour has any business being, because a phosphor dot emits light
    /// rather than reflecting it.
    var tint: Color {
        switch self {
        case .green: return Color(red: 0.44, green: 1.00, blue: 0.56)
        case .amber: return Color(red: 1.00, green: 0.72, blue: 0.24)
        case .plain: return .primary
        }
    }

    /// Not black. An unlit tube still has a colour, and a pure black ground
    /// makes the glow look pasted on rather than emitted.
    var ground: Color {
        switch self {
        case .green: return Color(red: 0.02, green: 0.055, blue: 0.03)
        case .amber: return Color(red: 0.055, green: 0.032, blue: 0.012)
        case .plain: return Color(nsColor: .textBackgroundColor)
        }
    }
}

/// The type the tube is set in.
///
/// A couple of points above the system size, because the glow is the reason: a
/// bloom softens the edge of every glyph, so monospaced 13 under one reads
/// smaller and fuzzier than the same face set plain. The extra points buy back
/// what the phosphor costs. MBM's and KeyVault's screens carry the same scale.
enum PhosphorType {
    static let bodySize: CGFloat = 15
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
    /// What a program's bold is set in: semibold, since bold at this size
    /// under a bloom fills in the counters.
    static let boldFont = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .semibold)
}

/// The face of the tube: a rounded rectangle whose edges bow outward, the way
/// glass does over a deflection yoke.
///
/// The shape insets itself by the bow and then curves back out by the same
/// amount, so the widest point of each edge lands exactly on the rectangle it
/// was handed and the screen still fills its slot.
struct TubeFace: InsettableShape {
    /// Curvature as a fraction of the shorter side rather than a fixed number
    /// of points. A tube bows in proportion to its size: six points of bend
    /// reads as a curve on a small pane and as a straight edge on a window
    /// thirteen hundred points wide, which is how MBM's first shipped.
    /// Clamped at both ends so it stays sane either way.
    var bowFraction: CGFloat = 0.022
    var cornerFraction: CGFloat = 0.055
    var insetAmount: CGFloat = 0

    func bow(for size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * bowFraction, 5), 24)
    }

    func corner(for size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * cornerFraction, 16), 70)
    }

    /// How far a rectangular box has to sit from the edge to look like it
    /// belongs on the glass.
    ///
    /// Derived from the same bow and corner the path uses rather than picked
    /// by eye, because both scale with the screen: a fixed inset that looked
    /// generous on a small screen let the corner arc bite the first character
    /// on a large one. The same on every side, since margins that differ read
    /// as a mistake rather than a bezel.
    func boxInset(for size: CGSize) -> CGFloat {
        // 0.29 ≈ 1 − 1/√2: how far a corner of that radius cuts into the
        // rectangle it is rounding, measured along the diagonal.
        bow(for: size) + corner(for: size) * 0.29 + 8
    }

    func path(in rect: CGRect) -> Path {
        let bow = bow(for: rect.size)
        let r = rect.insetBy(dx: bow + insetAmount, dy: bow + insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let c = min(corner(for: rect.size), min(r.width, r.height) / 2)
        // A quadratic's midpoint sits half way to its control point, so the
        // control goes twice the bow out to deviate by exactly the bow.
        let reach = bow * 2

        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.minY),
                       control: CGPoint(x: r.midX, y: r.minY - reach))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - c),
                       control: CGPoint(x: r.maxX + reach, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.maxY + reach))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c),
                       control: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + c),
                       control: CGPoint(x: r.minX - reach, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Dresses a block of monospaced output as a phosphor screen: a dark tube,
/// scanlines, a slow refresh sweep, and a bezel.
///
/// Everything here is decoration over unmodified content. The text inside is
/// what the command printed, still selectable and still copyable.
struct PhosphorScreen<Content: View>: View {
    let style: PhosphorStyle
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this app is frontmost. The sweep only runs while it is.
    @State private var appIsActive = true

    private let face = TubeFace()

    var body: some View {
        if style == .plain {
            content
                .background(style.ground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                )
        } else {
            content
                .foregroundStyle(style.tint)
                .background { tube }
                .overlay { scanlines }
                .overlay { if !reduceMotion && appIsActive { RefreshSweep(tint: style.tint) } }
                .overlay { glass }
                .clipShape(face)
                .overlay { bezel }
                .onAppear { appIsActive = NSApplication.shared.isActive }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    appIsActive = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didResignActiveNotification
                )) { _ in
                    appIsActive = false
                }
        }
    }

    private var tube: some View {
        style.ground.overlay {
            // Brightest in the middle, falling away at the corners, the way a
            // deflection tube does. Fractional radii, not absolute ones: a
            // fixed falloff put the black end of the gradient over almost the
            // whole of MBM's pane and buried the scanlines.
            EllipticalGradient(
                colors: [style.tint.opacity(0.07), .clear, .black.opacity(0.42)],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.78
            )
        }
    }

    /// Drawn rather than tiled: a Canvas costs one pass and needs no image
    /// asset, and the spacing stays honest at any size.
    private var scanlines: some View {
        Canvas { context, size in
            guard size.height > 0 else { return }
            for y in stride(from: 0, to: size.height, by: 3) {
                // Flat at the middle of the screen, bowing further as it
                // approaches either edge. Straight scanlines over curved glass
                // give the whole trick away.
                let fromCentre = (y / size.height) * 2 - 1
                let bow = min(max(size.width * 0.02, 6), 40)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addQuadCurve(
                    to: CGPoint(x: size.width, y: y),
                    control: CGPoint(x: size.width / 2, y: y + fromCentre * bow)
                )
                context.stroke(line, with: .color(.black.opacity(0.30)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    /// A soft highlight up and to the left, the way a room light sits on the
    /// curve of a real tube. Faint enough to read as a sheen rather than a
    /// smear over the output.
    private var glass: some View {
        EllipticalGradient(
            colors: [.white.opacity(0.055), .clear],
            center: UnitPoint(x: 0.3, y: 0.1),
            startRadiusFraction: 0,
            endRadiusFraction: 0.62
        )
        .allowsHitTesting(false)
    }

    private var bezel: some View {
        face
            .strokeBorder(style.tint.opacity(0.22), lineWidth: 1)
            .shadow(color: .black.opacity(0.6), radius: 6)
            .allowsHitTesting(false)
    }
}

/// The slow bright band of a tube refreshing.
///
/// SwiftUI does not hand a repeating animation to Core Animation: it steps it
/// from the main thread, frame by frame, for as long as the view is on
/// screen. So the screen takes this out whenever the app is in the
/// background, rather than spending the main thread and the GPU on a window
/// nobody is looking at.
///
/// A view of its own so that its state goes with it: put back in, it starts a
/// fresh pass from the top.
private struct RefreshSweep: View {
    let tint: Color

    @State private var down = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, tint.opacity(0.05), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)
            .offset(y: down ? geo.size.height : -120)
            .onAppear {
                withAnimation(.linear(duration: 7.5).repeatForever(autoreverses: false)) {
                    down = true
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Clips its content to the face of the tube.
///
/// SwiftUI's `.clipShape` does not clip a hosted AppKit view: it masks
/// SwiftUI's own drawing, and the scroll view is a real subview composited
/// above that. Without this mask a line scrolling upward stays visible past
/// the curve, out in the corners where the glass has already ended.
///
/// The face is symmetric about both axes, so it does not matter whether the
/// layer's geometry is flipped; the same path serves either way.
final class TubeClipView: NSView {
    private var scrollObserver: NSObjectProtocol?

    /// Watch the scroll position, because the fade depends on it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard scrollObserver == nil, let scrollView = subviews.first as? NSScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshEdgeFade()
        }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Called when the text grows as well as when it scrolls: a new line
    /// changes whether the view is still sitting at the bottom.
    func refreshEdgeFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyEdgeFade()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        // No implicit animation: a mask that eases into place on every resize
        // makes the glass look like it is breathing.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = TubeFace().path(in: bounds).cgPath
        layer?.mask = mask

        // Sit the whole text box inside the curve rather than letting it run
        // to the edges and relying on the mask to cut it. The mask stays as a
        // backstop, but nothing should be reaching it.
        if let scrollView = subviews.first as? NSScrollView {
            let inset = TubeFace().boxInset(for: bounds.size)
            scrollView.frame = bounds.insetBy(dx: inset, dy: inset)
        }
        applyEdgeFade()
        CATransaction.commit()
    }

    /// Dissolve the top and bottom of the text rather than slicing it.
    ///
    /// The gradient rides on the scroll view's own layer, not the clip view's:
    /// a clip view's bounds origin moves as it scrolls, so a mask positioned
    /// there would slide up the page with the content.
    private func applyEdgeFade() {
        guard let scrollView = subviews.first as? NSScrollView,
              let document = scrollView.documentView else { return }
        scrollView.wantsLayer = true
        let height = scrollView.bounds.height
        guard height > 0 else { return }

        // Fade only what is really running off an edge. A fixed band at both
        // ends dimmed the first line of a short run that had not scrolled.
        let visible = scrollView.contentView.bounds
        let hiddenAbove = max(0, visible.origin.y)
        let hiddenBelow = max(0, document.frame.height - visible.maxY)
        let maxBand = min(max(height * 0.07, 26), 70)
        let topBand = min(maxBand, hiddenAbove) / height
        let bottomBand = min(maxBand, hiddenBelow) / height

        let fade = (scrollView.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        fade.frame = scrollView.bounds
        fade.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor,
        ]
        // The first ramp is the TOP edge. A layer's y axis normally runs
        // bottom-up, but everything under SwiftUI's hosting view inherits
        // flipped layer geometry, so it runs top-down here. MBM verified it
        // by capture: scrolled to the end, the fade has to be at the top.
        fade.locations = [0, NSNumber(value: topBand), NSNumber(value: 1 - bottomBand), 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        scrollView.layer?.mask = fade
    }
}

/// A scroller that belongs on a phosphor tube: a dark slot and a glowing
/// knob. Falls back to the stock drawing when the screen is set to Plain, so
/// the ordinary look stays ordinary.
final class PhosphorScroller: NSScroller {
    /// nil means "draw as macOS would".
    var tint: NSColor?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard tint != nil else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }
        NSColor.black.withAlphaComponent(0.22).setFill()
        slotRect.fill()
    }

    override func drawKnob() {
        guard let tint else {
            super.drawKnob()
            return
        }
        let knob = rect(for: .knob).insetBy(dx: 3, dy: 2)
        guard knob.width > 0, knob.height > 0 else { return }
        let radius = knob.width / 2
        let path = NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius)
        tint.withAlphaComponent(0.55).setFill()
        path.fill()
    }
}
