#if os(macOS)
import AppKit
import Combine
import SwiftUI

// Keeping the chrome's motion cheap.
//
// Two rules, because SwiftUI re-lays-out the whole sidebar on every animation frame:
// 1. Endless motion (pulsing dots, spinners, activity bars) runs as Core Animation on
//    layers, which the system compositor animates without waking the app.
// 2. Motion that has to be SwiftUI (pixel-art sprites, the living sigil, the wordmark
//    glint) only runs while its window is on screen: `operatorMotion` turns false for
//    background tabs, hidden and minimized windows, so they cost nothing.

// MARK: - Is this window on screen?

private struct OperatorMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the view's window isn't visible (a background tab, minimized, covered).
    var operatorMotion: Bool {
        get { self[OperatorMotionKey.self] }
        set { self[OperatorMotionKey.self] = newValue }
    }
}

/// Tracks whether a window is actually on screen.
final class WindowMotion: ObservableObject {
    @Published private(set) var active = true
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification]
        observers = names.map { center.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in self?.update() } }
        update()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func update() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized && window.isVisible
        if visible != active { active = visible }
    }
}

/// Test hook: `OPERATOR_TEST_NOANIM=comet,spinner,bar,dot,film,bracket` turns those off, to
/// measure what each costs the window server. Empty in release builds (see `TestHooks`).
enum MotionTest {
    static let off = TestHooks.motionOff
}

/// Frame rate for the chrome's smooth motion. At the display's full 120 Hz, a sweeping bar
/// makes the window server re-composite the whole window 120 times a second (and re-render
/// the clipped sprite avatars each time); at 30 it looks the same and costs a quarter.
enum Motion {
    static let chromeRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}

// MARK: - Core Animation primitives

/// A layer-hosting view that doesn't clip its glow.
class MotionLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Animations are dropped when a layer leaves its window; put them back on return.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartAnimations() }
    }

    func restartAnimations() {}
}

private extension Color {
    var cg: CGColor { NSColor(self).cgColor }
}

/// A dot with a ring that radiates outward (scale 1 → `spread`, fading out) when `active`.
struct RadiateDotLayer: NSViewRepresentable {
    let color: Color
    let active: Bool
    let size: CGFloat
    var spread: CGFloat = 2.6
    var period: Double = 1.6

    final class View: MotionLayerView {
        let ring = CALayer()
        let dot = CALayer()
        var size: CGFloat = 8
        var active = false
        var spread: CGFloat = 2.6
        var period = 1.6

        override init(frame: NSRect) {
            super.init(frame: frame)
            dot.shadowOffset = .zero
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let rect = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            for shape in [ring, dot] {
                shape.frame = rect
                shape.cornerRadius = size / 2
            }
            dot.shadowRadius = 3
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
        }

        override func restartAnimations() {
            ring.removeAnimation(forKey: "radiate")
            ring.isHidden = !active
            dot.shadowOpacity = active ? 0.8 : 0
            guard active, !MotionTest.off.contains("radiate") else { return }
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = spread
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = period
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.preferredFrameRateRange = Motion.chromeRate
            ring.add(group, forKey: "radiate")
        }
    }

    func makeNSView(context: Context) -> View {
        let side = size * spread
        return View(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.dot.backgroundColor = color.cg
        view.dot.shadowColor = color.cg
        view.ring.backgroundColor = NSColor(color).withAlphaComponent(0.55).cgColor
        CATransaction.commit()
        if view.size != size { view.size = size; view.needsLayout = true }
        if view.active != active || view.spread != spread || view.period != period {
            view.active = active
            view.spread = spread
            view.period = period
            view.restartAnimations()
        }
    }
}

/// A glowing dot that pulses (opacity 1 → 0.25) when `blinking`.
struct PulseDotLayer: NSViewRepresentable {
    let color: Color
    let blinking: Bool
    let size: CGFloat
    let interval: Double

    final class View: MotionLayerView {
        let dot = CALayer()
        var blinking = false
        var interval = 0.5

        override init(frame: NSRect) {
            super.init(frame: frame)
            dot.shadowOpacity = 0.85
            dot.shadowOffset = .zero
            layer?.addSublayer(dot)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
            dot.shadowRadius = bounds.width * 0.6
            // Glows drawn from a known shape skip an offscreen render pass every frame.
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
        }

        override func restartAnimations() {
            dot.removeAnimation(forKey: "pulse")
            guard blinking, !MotionTest.off.contains("dot") else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = interval
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.preferredFrameRateRange = Motion.chromeRate
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }

    func makeNSView(context: Context) -> View { View(frame: NSRect(x: 0, y: 0, width: size, height: size)) }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.dot.backgroundColor = color.cg
        view.dot.shadowColor = color.cg
        CATransaction.commit()
        if view.blinking != blinking || view.interval != interval {
            view.blinking = blinking
            view.interval = interval
            view.restartAnimations()
        }
    }
}

/// A glowing arc turning: "working". Five motion styles via AnimationStyle.
struct SpinnerLayer: NSViewRepresentable {
    let color: Color
    let diameter: CGFloat
    @AppStorage(UserDefaults.animStyleKey) private var styleKey: String = AnimationStyle.original.rawValue

    final class View: MotionLayerView {
        let spin = CALayer()
        // Rebuilt per style in setupStyleLayers()
        private var builtStyle: AnimationStyle?
        private var builtSize: CGSize = .zero
        var style: AnimationStyle = .original
        var color: CGColor = NSColor.cyan.cgColor

        override init(frame: NSRect) {
            super.init(frame: frame)
            spin.shadowOpacity = 0.6
            spin.shadowRadius = 2
            spin.shadowOffset = .zero
            layer?.addSublayer(spin)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spin.frame = bounds
            setupStyleLayers()
            CATransaction.commit()
            if spin.animation(forKey: "spin") == nil { restartAnimations() }
        }

        func update(style: AnimationStyle, color: CGColor) {
            let changed = style != self.style
            self.style = style
            self.color = color
            if changed {
                builtStyle = nil
                needsLayout = true
            } else {
                applyColor()
            }
        }

        private func applyColor() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spin.shadowColor = color
            if let first = spin.sublayers?.first {
                if let g = first as? CAGradientLayer {
                    g.colors = [NSColor(cgColor: color)?.withAlphaComponent(0).cgColor ?? color, color]
                } else if let s = first as? CAShapeLayer {
                    s.strokeColor = color
                }
            }
            CATransaction.commit()
        }

        func setupStyleLayers() {
            guard style != builtStyle || bounds.size != builtSize else { return }
            builtStyle = style
            builtSize = bounds.size
            spin.sublayers?.forEach { $0.removeFromSuperlayer() }
            spin.removeAllAnimations()

            let line = max(1.4, bounds.width * 0.17)
            let r = bounds.width / 2 - line / 2
            let cx = bounds.midX, cy = bounds.midY

            switch style {
            case .original:
                let gradient = CAGradientLayer()
                let ring = CAShapeLayer()
                gradient.type = .conic
                gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                ring.fillColor = nil
                ring.strokeColor = NSColor.white.cgColor
                ring.lineCap = .round
                ring.strokeStart = 0.12
                ring.lineWidth = line
                ring.frame = spin.bounds
                ring.path = CGPath(ellipseIn: bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
                gradient.frame = spin.bounds
                gradient.mask = ring
                gradient.colors = [NSColor(cgColor: color)?.withAlphaComponent(0).cgColor ?? color, color]
                spin.addSublayer(gradient)
                spin.shadowColor = color
                spin.shadowPath = ring.path?.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 1)

            case .radar:
                // A single clock-hand line that rotates, with 3 fading trails behind it.
                let handPath = CGMutablePath()
                handPath.move(to: CGPoint(x: cx, y: cy))
                handPath.addLine(to: CGPoint(x: cx, y: cy - r))
                let hand = CAShapeLayer()
                hand.frame = spin.bounds
                hand.path = handPath
                hand.strokeColor = color
                hand.lineWidth = 1.5
                hand.lineCap = .round
                // Trails at decreasing opacity, fixed angular offsets behind the hand.
                for i in 1...3 {
                    let trail = CAShapeLayer()
                    trail.frame = spin.bounds
                    trail.path = handPath
                    trail.strokeColor = NSColor(cgColor: color)?.withAlphaComponent(CGFloat(4 - i) * 0.2).cgColor
                    trail.lineWidth = 1.5
                    trail.lineCap = .round
                    trail.transform = CATransform3DMakeRotation(CGFloat(i) * -0.28, 0, 0, 1)
                    spin.addSublayer(trail)
                }
                spin.addSublayer(hand)
                spin.shadowColor = color
                spin.shadowPath = nil

            case .waveform:
                // Sine wave that scrolls horizontally inside a circular mask.
                let container = CALayer()
                container.frame = spin.bounds
                container.masksToBounds = true
                container.cornerRadius = bounds.width / 2
                let waveW = bounds.width * 2.5
                let waveH = bounds.height
                let wavelength = bounds.width * 0.6
                let wave = CAShapeLayer()
                wave.frame = CGRect(x: -(waveW / 2 - bounds.width / 2), y: 0, width: waveW, height: waveH)
                wave.strokeColor = color
                wave.fillColor = nil
                wave.lineWidth = max(1.2, bounds.width * 0.1)
                wave.lineCap = .round
                let path = CGMutablePath()
                let amp = waveH * 0.3
                path.move(to: CGPoint(x: 0, y: waveH / 2))
                stride(from: CGFloat(2), through: waveW, by: 2).forEach { px in
                    path.addLine(to: CGPoint(x: px, y: waveH / 2 + amp * sin(2 * .pi * px / wavelength)))
                }
                wave.path = path
                container.addSublayer(wave)
                spin.addSublayer(container)
                spin.shadowColor = color
                spin.shadowPath = nil

            case .comet:
                // Short bright arc (18%) rotating fast around the ring.
                let track = CAShapeLayer()
                track.frame = spin.bounds
                let ellipsePath = CGPath(ellipseIn: bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
                track.path = ellipsePath
                track.fillColor = nil
                track.strokeColor = NSColor(cgColor: color)?.withAlphaComponent(0.12).cgColor
                track.lineWidth = max(1, line * 0.5)
                let comet = CAShapeLayer()
                comet.frame = spin.bounds
                comet.path = ellipsePath
                comet.fillColor = nil
                comet.strokeColor = color
                comet.lineWidth = line
                comet.lineCap = .round
                comet.strokeStart = 0.82
                comet.strokeEnd = 1.0
                spin.addSublayer(track)
                spin.addSublayer(comet)
                spin.shadowColor = color
                spin.shadowPath = ellipsePath.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 1)

            case .geometric:
                // Diamond outline that steps 45° per beat — no continuous spin.
                let side = r * 0.88
                let dPath = CGMutablePath()
                dPath.move(to: CGPoint(x: cx, y: cy - side))
                dPath.addLine(to: CGPoint(x: cx + side, y: cy))
                dPath.addLine(to: CGPoint(x: cx, y: cy + side))
                dPath.addLine(to: CGPoint(x: cx - side, y: cy))
                dPath.closeSubpath()
                let diamond = CAShapeLayer()
                diamond.frame = spin.bounds
                diamond.path = dPath
                diamond.fillColor = nil
                diamond.strokeColor = color
                diamond.lineWidth = max(1.2, bounds.width * 0.12)
                spin.addSublayer(diamond)
                spin.shadowColor = color
                spin.shadowPath = nil
            }
        }

        override func restartAnimations() {
            spin.removeAllAnimations()
            spin.sublayers?.forEach { $0.removeAllAnimations() }
            guard !MotionTest.off.contains("spinner") else { return }

            switch style {
            case .original:
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0; turn.toValue = Double.pi * 2
                turn.duration = 0.85; turn.repeatCount = .infinity
                turn.preferredFrameRateRange = Motion.chromeRate
                spin.add(turn, forKey: "spin")

            case .radar:
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0; turn.toValue = Double.pi * 2
                turn.duration = 2.5; turn.repeatCount = .infinity
                turn.preferredFrameRateRange = Motion.chromeRate
                spin.add(turn, forKey: "spin")

            case .waveform:
                // Scroll the wave layer by one wavelength for a seamless loop.
                guard let container = spin.sublayers?.first,
                      let wave = container.sublayers?.first else { return }
                let wavelength = bounds.width * 0.6
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = wave.position.x
                move.toValue = wave.position.x - wavelength
                move.duration = 1.4; move.repeatCount = .infinity
                move.timingFunction = CAMediaTimingFunction(name: .linear)
                move.preferredFrameRateRange = Motion.chromeRate
                wave.add(move, forKey: "spin")

            case .comet:
                // Rotate the comet arc around the ring.
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0; turn.toValue = Double.pi * 2
                turn.duration = 1.0; turn.repeatCount = .infinity
                turn.timingFunction = CAMediaTimingFunction(name: .linear)
                turn.preferredFrameRateRange = Motion.chromeRate
                spin.add(turn, forKey: "spin")

            case .geometric:
                // Discrete 45° steps — 8 steps per revolution.
                guard let diamond = spin.sublayers?.first else { return }
                let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                anim.values = (0..<8).map { Double($0) * .pi / 4 }
                anim.calculationMode = .discrete
                anim.duration = 1.6; anim.repeatCount = .infinity
                anim.preferredFrameRateRange = Motion.chromeRate
                diamond.add(anim, forKey: "spin")
            }
        }
    }

    func makeNSView(context: Context) -> View { View(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter)) }

    func updateNSView(_ view: View, context: Context) {
        let animStyle = AnimationStyle(rawValue: styleKey) ?? .original
        view.update(style: animStyle, color: color.cg)
    }
}

/// A thin track with a light sweeping along it: an agent at work. Five styles.
struct ActivityBarLayer: NSViewRepresentable {
    let color: Color
    @AppStorage(UserDefaults.animStyleKey) private var styleKey: String = AnimationStyle.original.rawValue

    final class View: MotionLayerView {
        let track = CALayer()
        let sweep = CAGradientLayer()       // original / comet / geometric
        let scanLine = CALayer()            // radar: sliding vertical line
        let waveShape = CAShapeLayer()      // waveform: sine wave
        var style: AnimationStyle = .original
        private var builtStyle: AnimationStyle?
        private var width: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.masksToBounds = true
            sweep.startPoint = CGPoint(x: 0, y: 0.5)
            sweep.endPoint = CGPoint(x: 1, y: 0.5)
            scanLine.isHidden = true
            waveShape.fillColor = nil
            waveShape.isHidden = true
            layer?.addSublayer(track)
            layer?.addSublayer(sweep)
            layer?.addSublayer(scanLine)
            layer?.addSublayer(waveShape)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = bounds.height / 2
            track.frame = bounds
            layoutStyleLayers()
            CATransaction.commit()
            if bounds.width != width || style != builtStyle {
                width = bounds.width
                builtStyle = style
                restartAnimations()
            }
        }

        private func layoutStyleLayers() {
            switch style {
            case .original, .comet:
                let pct: CGFloat = style == .comet ? 0.20 : 0.35
                sweep.isHidden = false
                sweep.bounds = CGRect(x: 0, y: 0, width: bounds.width * pct, height: bounds.height)
                sweep.position = CGPoint(x: -bounds.width, y: bounds.midY)
                scanLine.isHidden = true
                waveShape.isHidden = true
            case .radar:
                sweep.isHidden = true
                waveShape.isHidden = true
                scanLine.isHidden = false
                scanLine.frame = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
            case .waveform:
                sweep.isHidden = true
                scanLine.isHidden = true
                waveShape.isHidden = false
                waveShape.frame = bounds
                let path = CGMutablePath()
                let amp = bounds.height * 0.38
                let wl = max(10, bounds.width / 5)
                path.move(to: CGPoint(x: 0, y: bounds.midY))
                stride(from: CGFloat(1), through: bounds.width, by: 1).forEach { x in
                    path.addLine(to: CGPoint(x: x, y: bounds.midY + amp * sin(2 * .pi * x / wl)))
                }
                waveShape.path = path
                waveShape.lineWidth = max(1, bounds.height * 0.4)
                waveShape.lineCap = .round
            case .geometric:
                sweep.isHidden = false
                sweep.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
                sweep.position = CGPoint(x: bounds.midX, y: bounds.midY)
                scanLine.isHidden = true
                waveShape.isHidden = true
            }
        }

        override func restartAnimations() {
            sweep.removeAnimation(forKey: "sweep")
            scanLine.removeAnimation(forKey: "sweep")
            waveShape.removeAnimation(forKey: "sweep")
            guard bounds.width > 0, !MotionTest.off.contains("bar") else { return }

            switch style {
            case .original:
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = -bounds.width * 0.175
                move.toValue = bounds.width * 1.175
                move.duration = 1.3; move.repeatCount = .infinity
                move.preferredFrameRateRange = Motion.chromeRate
                move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sweep.add(move, forKey: "sweep")

            case .comet:
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = -bounds.width * 0.10
                move.toValue = bounds.width * 1.10
                move.duration = 0.7; move.repeatCount = .infinity
                move.preferredFrameRateRange = Motion.chromeRate
                move.timingFunction = CAMediaTimingFunction(name: .easeIn)
                sweep.add(move, forKey: "sweep")

            case .radar:
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = CGFloat(0)
                move.toValue = bounds.width
                move.duration = 1.5; move.repeatCount = .infinity
                move.preferredFrameRateRange = Motion.chromeRate
                move.timingFunction = CAMediaTimingFunction(name: .linear)
                scanLine.add(move, forKey: "sweep")

            case .waveform:
                // Animate strokeEnd from 0 to 1 so the wave draws in, then loops.
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0; draw.toValue = 1
                draw.duration = 1.2; draw.repeatCount = .infinity
                draw.preferredFrameRateRange = Motion.chromeRate
                draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                draw.autoreverses = true
                waveShape.strokeStart = 0
                waveShape.strokeEnd = 1
                waveShape.add(draw, forKey: "sweep")

            case .geometric:
                // Crossfade between purple→gold and gold→purple.
                let purple = NSColor(red: 0.44, green: 0, blue: 0.74, alpha: 0.75).cgColor
                let gold   = NSColor(red: 0.79, green: 0.66, blue: 0.30, alpha: 0.75).cgColor
                let anim = CAKeyframeAnimation(keyPath: "colors")
                anim.values = [[purple, gold], [gold, purple]]
                anim.calculationMode = .discrete
                anim.duration = 4.0; anim.repeatCount = .infinity
                anim.preferredFrameRateRange = Motion.chromeRate
                sweep.add(anim, forKey: "sweep")
            }
        }

        func updateColors(_ color: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch style {
            case .original, .comet:
                track.backgroundColor = color.withAlphaComponent(0.12).cgColor
                sweep.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
            case .radar:
                track.backgroundColor = color.withAlphaComponent(0.08).cgColor
                scanLine.backgroundColor = color.cgColor
            case .waveform:
                track.backgroundColor = color.withAlphaComponent(0.08).cgColor
                waveShape.strokeColor = color.cgColor
            case .geometric:
                track.backgroundColor = color.withAlphaComponent(0.05).cgColor
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        let animStyle = AnimationStyle(rawValue: styleKey) ?? .original
        if animStyle != view.style {
            view.style = animStyle
            view.needsLayout = true
        }
        view.updateColors(NSColor(color))
    }
}

// MARK: - One clock for every animation

/// The sidebar's animations all tick on this one clock. Each tick of any SwiftUI timeline
/// lays out the whole sidebar; timelines that start at different moments tick at different
/// moments, so six agent sprites, the sigil, the bracket and the frame light used to cost
/// ~80 layouts a second. On a shared epoch and a common beat, their ticks coincide and
/// SwiftUI handles them in one pass: ~12 a second however many agents are working.
enum OperatorClock {
    /// Seconds per beat (12.5 a second). Slower animations use whole multiples of it.
    static let beat: TimeInterval = 0.08
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// A schedule on the shared beat; `every` is rounded to a whole number of beats.
    static func schedule(every seconds: TimeInterval) -> PeriodicTimelineSchedule {
        .periodic(from: epoch, by: max(1, (seconds / beat).rounded()) * beat)
    }
}

// MARK: - Sparse timelines

/// Ticks only for a short burst (`steps` frames across `burst` seconds) once every
/// `every` seconds, instead of continuously: for effects that move briefly then rest.
struct BurstSchedule: TimelineSchedule {
    let every: TimeInterval
    let burst: TimeInterval
    let steps: Int

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let start = startDate.timeIntervalSinceReferenceDate
        var cycle = (start / every).rounded(.down)
        var step = 0
        return AnyIterator {
            while true {
                if step > steps { step = 0; cycle += 1 }
                let date = cycle * every + burst * Double(step) / Double(steps)
                step += 1
                if date >= start - 0.001 { return Date(timeIntervalSinceReferenceDate: date) }
            }
        }
    }
}
#endif
