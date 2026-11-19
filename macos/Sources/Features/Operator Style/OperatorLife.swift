#if os(macOS)
import AppKit
import Combine
import SwiftUI

// Motion that follows what the agents are doing: the sigil's heartbeat, the agents' moods,
// and the aurora behind each terminal. None of it takes clicks, and all of it steps like
// pixel art rather than easing smoothly.

// MARK: - Activity across the app

/// How many agents are working or waiting across every open tab, and when one last
/// finished. Drives the sidebar's sigil.
final class AgentPulse: ObservableObject {
    static let shared = AgentPulse()

    @Published private(set) var working = 0
    @Published private(set) var waiting = 0
    /// When an agent last went from working to done.
    @Published private(set) var finishedAt: Date?

    private var last: [ObjectIdentifier: VerticalTabAgentActivity] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let surface = note.object as? Ghostty.SurfaceView { self?.changed(surface) }
                self?.recount()
            }
            .store(in: &cancellables)
        VerticalTabsTicker.shared.publisher
            .sink { [weak self] in self?.recount() }
            .store(in: &cancellables)
    }

    private func changed(_ surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        let now = VerticalTabsAgents.shared.info(for: surface)?.activity
        let before = last[key]
        last[key] = now
        if now == .done, before == .working || before == .needsPermission { finishedAt = Date() }
    }

    private func recount() {
        var working = 0, waiting = 0
        for controller in VerticalTabsProjects.openControllers {
            for surface in controller.surfaceTree {
                switch VerticalTabsAgents.shared.info(for: surface)?.activity {
                case .working: working += 1
                case .needsPermission, .needsInput: waiting += 1
                default: break
                }
            }
        }
        if working != self.working { self.working = working }
        if waiting != self.waiting { self.waiting = waiting }
    }
}

// MARK: - The living sigil

/// The sidebar's sigil, awake: its core beats faster the more agents work, one cyan pixel
/// orbits it for each working agent, it glows amber while one waits for you, and it flares
/// gold when one finishes.
struct LivingSigil: View {
    var size: CGFloat = 26
    @ObservedObject private var pulse = AgentPulse.shared
    @AppStorage(UserDefaults.animStyleKey) private var animStyleKey: String = AnimationStyle.original.rawValue

    @Environment(\.operatorMotion) private var motion
    private var animStyle: AnimationStyle { AnimationStyle(rawValue: animStyleKey) ?? .original }

    var body: some View {
        let animating = motion
        Group {
            if flaring(at: Date()) && motion {
                // The 1.6 s finish flare: brief, so SwiftUI draws it.
                TimelineView(OperatorClock.schedule(every: OperatorClock.beat)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    frame(glow: glowLevel(at: t), orbit: t * orbitSpeed / (2 * .pi), waiting: Int(t / 0.32) % 2 == 0, flareAt: context.date)
                }
            } else if animating {
                // Working or waiting: one loop rendered once and played by Core Animation.
                let frames = loopFrames
                FilmStrip(key: "sigil|\(animStyleKey)|\(min(pulse.working, 6))|\(pulse.waiting > 0)|\(size)", frames: frames,
                          frameDuration: OperatorClock.beat, size: CGSize(width: size, height: size * 31 / 32)) { index in
                    let phase = Double(index) / Double(frames)
                    frame(glow: level(phase * Double(glowCycles(frames))), orbit: phase, waiting: (index / 4) % 2 == 0, flareAt: nil)
                }
            } else {
                frame(glow: glowLevel(at: Date().timeIntervalSinceReferenceDate), orbit: 0, waiting: true, flareAt: nil)
            }
        }
        .frame(width: size, height: size * 31 / 32)
        .help(help)
    }

    /// One frame of the sigil: `glow` 0…1, `orbit` in turns, the amber ticks on or off.
    private func frame(glow: Double, orbit: Double, waiting: Bool, flareAt: Date?) -> some View {
        ZStack {
            glowView(glow)
            OperatorSigil(size: size, alive: false)
            Canvas { gc, canvas in
                orbiters(gc, canvas, turns: orbit)
                if waiting { waitingTicks(gc, canvas) }
                if let flareAt { flare(gc, canvas, flareAt) }
            }
            .frame(width: size * 1.6, height: size * 1.6)
            .allowsHitTesting(false)
        }
        .frame(width: size, height: size * 31 / 32)
    }

    private var glowPeriod: Double { pulse.working > 0 ? max(0.45, 1.5 / Double(1 + pulse.working)) : 2.8 }
    private var orbitSpeed: Double { 1.6 + Double(min(pulse.working, 6)) * 0.25 }

    /// The loop: one orbit while agents work (or one slow breath while one only waits),
    /// in whole beats and a multiple of the amber blink.
    private var loopFrames: Int {
        let seconds = pulse.working > 0 ? 2 * .pi / orbitSpeed : glowPeriod
        return max(8, Int((seconds / OperatorClock.beat / 8).rounded()) * 8)
    }

    /// Whole breaths per loop, so the glow joins up where the loop repeats.
    private func glowCycles(_ frames: Int) -> Int {
        max(1, Int((Double(frames) * OperatorClock.beat / glowPeriod).rounded()))
    }

    private func glowLevel(at t: TimeInterval) -> Double { level((t / glowPeriod).truncatingRemainder(dividingBy: 1)) }

    /// Stepped, like a sprite: eight levels per breath.
    private func level(_ cycles: Double) -> Double {
        let step = Double(Int(cycles.truncatingRemainder(dividingBy: 1) * 8))
        return step < 4 ? step / 3 : (7 - step) / 3
    }

    private var help: String {
        var parts: [String] = []
        if pulse.working > 0 { parts.append("\(pulse.working) working") }
        if pulse.waiting > 0 { parts.append("\(pulse.waiting) waiting for you") }
        return parts.isEmpty ? "Operator" : "Agents: " + parts.joined(separator: " · ")
    }

    /// The core's light: slow breathing at rest, faster with each working agent.
    private func glowView(_ level: Double) -> some View {
        let color = pulse.waiting > 0 ? Operator.warn : Operator.core
        let strength = pulse.working > 0 || pulse.waiting > 0 ? 0.5 : 0.24
        return Circle()
            .fill(color.opacity(0.1 + level * strength))
            .frame(width: size * 0.42, height: size * 0.42)
            .blur(radius: size * 0.1)
            .offset(y: size * 0.04)
    }

    /// One pixel per working agent, circling the seal, each with a short fading trail.
    /// When no agents are active, draws a single faint ghost orbiter so the animation
    /// style is visible even at idle.
    private func orbiters(_ gc: GraphicsContext, _ canvas: CGSize, turns: Double) {
        let count = min(pulse.working, 6)
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius = size * 0.6
        let pixel = max(2, size / 11)
        let currentStyle = AnimationStyle(rawValue: UserDefaults.standard.string(forKey: UserDefaults.animStyleKey) ?? "") ?? .original

        // Idle ghost: one faint orbiter so the selected animation style is visible at rest.
        if count == 0 {
            let angle = (turns * 2 * .pi / (2 * .pi / 32)).rounded(.down) * (2 * .pi / 32)
            switch currentStyle {
            case .original, .comet:
                for trail in 0..<3 {
                    let a = (((turns - Double(trail) * 0.2) * 2 * .pi) / (2 * .pi / 32)).rounded(.down) * (2 * .pi / 32)
                    let x = center.x + CGFloat(cos(a)) * radius
                    let y = center.y + CGFloat(sin(a)) * radius * 0.92
                    gc.fill(Path(CGRect(x: (x - pixel / 2).rounded(), y: (y - pixel / 2).rounded(), width: pixel, height: pixel)),
                            with: .color(Operator.core.opacity((0.22 - Double(trail) * 0.07))))
                }
            case .radar:
                let endX = center.x + CGFloat(sin(angle)) * radius
                let endY = center.y - CGFloat(cos(angle)) * radius
                var linePath = Path()
                linePath.move(to: center)
                linePath.addLine(to: CGPoint(x: endX, y: endY))
                gc.stroke(linePath, with: .color(Operator.core.opacity(0.2)), lineWidth: 1.5)
            case .waveform:
                let arcSpan = Double.pi * 1.2
                let arcStart = -arcSpan / 2 - .pi / 2
                for i in 0..<8 {
                    let t = Double(i) / 7
                    let baseAngle = arcStart + t * arcSpan
                    let ripple = CGFloat(sin(t * .pi * 2 + turns * 2 * .pi)) * size * 0.08
                    let x = center.x + CGFloat(cos(baseAngle)) * (radius * 0.85 + ripple)
                    let y = center.y + CGFloat(sin(baseAngle)) * (radius * 0.85 + ripple) * 0.92
                    gc.fill(Path(CGRect(x: (x - pixel / 2).rounded(), y: (y - pixel / 2).rounded(), width: pixel, height: pixel)),
                            with: .color(Operator.core.opacity(0.15 + 0.1 * abs(sin(t * .pi + turns * .pi)))))
                }
            case .geometric:
                let x = center.x + CGFloat(cos(angle)) * radius
                let y = center.y + CGFloat(sin(angle)) * radius * 0.92
                let d = pixel * 1.4
                gc.fill(Path(CGRect(x: (x - d / 2).rounded(), y: (y - d / 2).rounded(), width: d, height: d)),
                        with: .color(Operator.core.opacity(0.22)))
            }
            return
        }

        switch currentStyle {
        case .original:
            for i in 0..<count {
                for trail in 0..<4 {
                    let raw = turns * 2 * .pi + Double(i) * 2 * .pi / Double(count) - Double(trail) * 0.2
                    let angle = (raw / (2 * .pi / 32)).rounded(.down) * (2 * .pi / 32)
                    let x = center.x + CGFloat(cos(angle)) * radius
                    let y = center.y + CGFloat(sin(angle)) * radius * 0.92
                    gc.fill(Path(CGRect(x: (x - pixel / 2).rounded(), y: (y - pixel / 2).rounded(), width: pixel, height: pixel)),
                            with: .color(Operator.core.opacity(1 - Double(trail) * 0.28)))
                }
            }

        case .radar:
            // A single sweep line from center outward, with 3 phosphor trail dots.
            let angle = turns * 2 * .pi
            let endX = center.x + CGFloat(sin(angle)) * radius
            let endY = center.y - CGFloat(cos(angle)) * radius
            var linePath = Path()
            linePath.move(to: center)
            linePath.addLine(to: CGPoint(x: endX, y: endY))
            gc.stroke(linePath, with: .color(Operator.core), lineWidth: 1.5)
            for trail in 1...3 {
                let trailAngle = angle - Double(trail) * 0.3
                let tx = center.x + CGFloat(sin(trailAngle)) * radius
                let ty = center.y - CGFloat(cos(trailAngle)) * radius
                gc.fill(Path(CGRect(x: (tx - pixel / 2).rounded(), y: (ty - pixel / 2).rounded(), width: pixel, height: pixel)),
                        with: .color(Operator.core.opacity(0.6 / Double(trail))))
            }

        case .waveform:
            // 8 dots along a small arc, vertically rippling by a sine function.
            let arcRadius = radius * 0.85
            let arcSpan = Double.pi * 1.2
            let arcStart = -arcSpan / 2 - .pi / 2
            for i in 0..<8 {
                let t = Double(i) / 7
                let baseAngle = arcStart + t * arcSpan
                let ripple = CGFloat(sin(t * .pi * 2 + turns * 2 * .pi)) * size * 0.08
                let x = center.x + CGFloat(cos(baseAngle)) * (arcRadius + ripple)
                let y = center.y + CGFloat(sin(baseAngle)) * (arcRadius + ripple) * 0.92
                let alpha = 0.4 + 0.6 * abs(sin(t * .pi + turns * .pi))
                gc.fill(Path(CGRect(x: (x - pixel / 2).rounded(), y: (y - pixel / 2).rounded(), width: pixel, height: pixel)),
                        with: .color(Operator.core.opacity(alpha)))
            }

        case .comet:
            // Single bright comet head + 3 fading tail pixels, orbiting fast.
            for trail in 0..<4 {
                let raw = turns * 2 * .pi - Double(trail) * 0.22
                let angle = (raw / (2 * .pi / 32)).rounded(.down) * (2 * .pi / 32)
                let x = center.x + CGFloat(cos(angle)) * radius
                let y = center.y + CGFloat(sin(angle)) * radius * 0.92
                let p = trail == 0 ? pixel * 1.3 : pixel
                gc.fill(Path(CGRect(x: (x - p / 2).rounded(), y: (y - p / 2).rounded(), width: p, height: p)),
                        with: .color(Operator.core.opacity(trail == 0 ? 1.0 : 1 - Double(trail) * 0.3)))
            }

        case .geometric:
            // Triangle of 3 dots rotating in discrete 60° steps.
            let stepAngle = floor(turns * 6) / 6 * 2 * .pi
            for i in 0..<3 {
                let angle = stepAngle + Double(i) * 2 * .pi / 3
                let x = center.x + CGFloat(cos(angle)) * radius
                let y = center.y + CGFloat(sin(angle)) * radius * 0.92
                gc.fill(Path(CGRect(x: (x - pixel / 2).rounded(), y: (y - pixel / 2).rounded(), width: pixel, height: pixel)),
                        with: .color(Operator.core.opacity(0.9)))
            }
        }
    }

    /// Amber ticks at the four points while an agent needs you.
    private func waitingTicks(_ gc: GraphicsContext, _ canvas: CGSize) {
        guard pulse.waiting > 0 else { return }
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let r = size * 0.66, p = max(2, size / 12)
        for (dx, dy) in [(0.0, -1.0), (1, 0), (0, 1), (-1, 0)] {
            gc.fill(Path(CGRect(x: c.x + CGFloat(dx) * r - p / 2, y: c.y + CGFloat(dy) * r - p / 2, width: p, height: p)),
                    with: .color(Operator.warn))
        }
    }

    private func flaring(at date: Date) -> Bool {
        pulse.finishedAt.map { date.timeIntervalSince($0) < 1.6 } ?? false
    }

    /// A gold ring and sparks bursting out when an agent finishes.
    private func flare(_ gc: GraphicsContext, _ canvas: CGSize, _ date: Date) {
        guard let start = pulse.finishedAt else { return }
        let age = date.timeIntervalSince(start)
        guard age >= 0, age < 1.6 else { return }
        let progress = CGFloat(age / 1.6)
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius = size * (0.25 + progress * 0.55)
        let alpha = Double(1 - progress)
        gc.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                  with: .color(Operator.gold.opacity(alpha)), lineWidth: 2)
        let p = max(2, size / 12)
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 + .pi / 8
            let d = size * (0.3 + progress * 0.5)
            let x = c.x + CGFloat(cos(angle)) * d, y = c.y + CGFloat(sin(angle)) * d
            gc.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: p, height: p)), with: .color(Operator.gold.opacity(alpha)))
        }
    }
}

// MARK: - Agent moods

/// What an agent looks like it's doing, from its state and the last tool it used.
enum AgentMood: Equatable {
    case idle, thinking, reading, editing, running, waiting, celebrating, failed

    init(_ info: VerticalTabAgentInfo?, now: Date = Date()) {
        guard let info else { self = .idle; return }
        switch info.activity {
        case .needsPermission, .needsInput: self = .waiting
        case .failed: self = .failed
        case .done: self = now.timeIntervalSince(info.since) < 6 ? .celebrating : .idle
        case .ready: self = .idle
        case .working:
            let tool = (info.lastAction ?? "").split(separator: ":").first.map(String.init) ?? ""
            switch tool {
            case "Read", "Grep", "Glob", "LS", "NotebookRead", "WebFetch", "WebSearch", "ToolSearch", "web_search":
                self = .reading
            case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch":
                self = .editing
            case "Bash", "BashOutput", "exec_command", "shell", "local_shell":
                self = .running
            default:
                self = .thinking
            }
        }
    }
}

/// An agent's sprite, acting out its mood: eyes that read, keys that type, a prompt that
/// blinks, a thought bubble, a hop and a "!" when it needs you, sparkles when it's done.
struct MoodSprite: View {
    let kind: VerticalTabAgentKind?
    let mood: AgentMood
    var pixel: CGFloat = 2

    @Environment(\.operatorMotion) private var motion

    var body: some View {
        if kind == nil || mood == .idle && !blinks || !motion {
            AgentSprite(kind: kind, pixel: pixel)
        } else {
            // The mood's loop, rendered once and played by Core Animation: no per-frame work.
            GeometryReader { geometry in
                FilmStrip(key: "mood|\(kind.map { "\($0)" } ?? "")|\(mood)|\(pixel)", frames: loopFrames,
                          frameDuration: 0.16, size: geometry.size) { frame in
                    ZStack {
                        AgentSprite(kind: kind, pixel: pixel, eyes: eyes(frame))
                            .offset(x: jitter(frame), y: bob(frame))
                        Canvas { gc, size in decorate(gc, size, frame) }
                            .frame(width: 34, height: 34)
                    }
                }
            }
        }
    }

    /// Frames in the mood's loop: a whole number of every cycle it shows.
    private var loopFrames: Int {
        switch mood {
        case .reading: return 24
        case .thinking: return 48
        case .editing: return 10
        case .running: return 6
        case .waiting: return 12
        case .celebrating: return 40 // it lasts six seconds
        case .failed: return 120
        case .idle: return 34
        }
    }

    /// Idle agents still blink now and then.
    private var blinks: Bool { kind == .claude }

    private func eyes(_ frame: Int) -> AgentSprite.Eyes {
        switch mood {
        case .reading:
            // Eyes sweep left to right across a line, then jump back.
            return [.left, .left, .center, .right, .right, .center][(frame / 2) % 6]
        case .celebrating: return frame % 10 < 5 ? .closed : .center
        case .thinking: return frame % 16 < 8 ? .right : .center
        default:
            // A blink every few seconds.
            return frame % 34 == 0 ? .closed : .center
        }
    }

    private func bob(_ frame: Int) -> CGFloat {
        switch mood {
        case .waiting: return frame % 6 < 3 ? -2 : 0
        case .celebrating: return frame % 4 < 2 ? -2 : 0
        case .editing: return frame % 2 == 0 ? 0 : -1
        default: return 0
        }
    }

    private func jitter(_ frame: Int) -> CGFloat {
        mood == .failed && frame % 30 < 6 ? (frame % 2 == 0 ? -1 : 1) : 0
    }

    private func decorate(_ gc: GraphicsContext, _ size: CGSize, _ frame: Int) {
        let p: CGFloat = 2
        let cx = size.width / 2, cy = size.height / 2
        func dot(_ x: CGFloat, _ y: CGFloat, _ color: Color, _ s: CGFloat = p) {
            gc.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: s, height: s)), with: .color(color))
        }
        switch mood {
        case .thinking:
            // Three rising dots, lighting in turn.
            for i in 0..<3 {
                let on = (frame / 3) % 4 > i
                dot(cx + 7 + CGFloat(i) * 3, cy - 9 - CGFloat(i) * 3, Operator.text.opacity(on ? 0.95 : 0.2), 2.5)
            }
        case .reading:
            // A scan line sweeping down the sprite.
            let y = cy - 7 + CGFloat(frame % 8) * 2
            gc.fill(Path(CGRect(x: cx - 12, y: y, width: 24, height: 1.5)), with: .color(Operator.core.opacity(0.9)))
        case .editing:
            // Keystrokes under the sprite.
            for i in 0..<4 where (frame + i * 3) % 5 < 2 {
                dot(cx - 8 + CGFloat(i) * 5, cy + 10, Operator.gold, 2.5)
            }
        case .running:
            // A tiny prompt that blinks beside it.
            let color = Operator.core.opacity(frame % 6 < 3 ? 1 : 0.3)
            dot(cx + 12, cy - 3, color); dot(cx + 13.5, cy - 1.5, color); dot(cx + 12, cy, color)
            dot(cx + 15, cy + 1, color, 2)
        case .waiting:
            guard frame % 4 < 2 else { return }
            gc.fill(Path(CGRect(x: cx - 1.5, y: cy - 17, width: 3, height: 6)), with: .color(Operator.warn))
            gc.fill(Path(CGRect(x: cx - 1.5, y: cy - 10, width: 3, height: 2.5)), with: .color(Operator.warn))
        case .celebrating:
            // Sparkles popping at fixed spots around it.
            let spots: [(CGFloat, CGFloat)] = [(-12, -9), (11, -10), (-13, 5), (12, 6), (0, -14), (-6, 11), (7, 12)]
            for (i, spot) in spots.enumerated() where (frame + i * 2) % 7 < 3 {
                let x = cx + spot.0, y = cy + spot.1
                dot(x, y, Operator.gold, 2.5)
                if (frame + i) % 3 == 0 {
                    dot(x - 2, y + 0.5, Operator.gold.opacity(0.6)); dot(x + 2.5, y + 0.5, Operator.gold.opacity(0.6))
                }
            }
        case .failed:
            let color = Operator.danger.opacity(frame % 8 < 4 ? 1 : 0.4)
            for d in stride(from: CGFloat(-2), through: 2, by: 1) {
                dot(cx + 11 + d, cy - 11 + d, color); dot(cx + 11 + d, cy - 11 - d, color)
            }
        case .idle:
            break
        }
    }
}

// MARK: - Aurora

/// Soft bands of light behind a tab's terminal that follow its agents: deep blue at rest,
/// cyan waves while an agent works, amber while one waits for you, and a gold sweep when
/// one finishes. Drawn faintly, so the text always stays readable.
struct AgentAurora: View {
    static let enabledKey = "ExtremeAurora"
    let controller: BaseTerminalController

    private enum Mode: Equatable { case idle, working, waiting }
    @State private var mode: Mode = .idle
    @State private var finishedAt: Date?
    @State private var previous: Mode = .idle
    @AppStorage(UserDefaults.animStyleKey) private var animStyleKey: String = AnimationStyle.original.rawValue

    @Environment(\.operatorMotion) private var motion
    private var animStyle: AnimationStyle { AnimationStyle(rawValue: animStyleKey) ?? .original }

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        TimelineView(.animation(minimumInterval: mode == .idle && !sweeping ? 1.0 / 4 : 1.0 / 15,
                                paused: reduceMotion || !motion)) { context in
            Canvas { gc, size in draw(gc, size, context.date) }
        }
        .blur(radius: 22)
        .opacity(mode == .idle ? 0.7 : 1)
        .drawingGroup()
        .blendMode(.screen)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.2), value: mode)
        .onReceive(VerticalTabsTicker.shared.publisher) { update() }
        .onReceive(NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)) { _ in update() }
        .onAppear(perform: update)
    }

    private var sweeping: Bool { finishedAt.map { Date().timeIntervalSince($0) < 2.6 } ?? false }

    private func update() {
        let infos = controller.surfaceTree.compactMap { VerticalTabsAgents.shared.info(for: $0) }
        let next: Mode = infos.contains { $0.activity == .needsPermission || $0.activity == .needsInput } ? .waiting
            : infos.contains { $0.activity == .working } ? .working : .idle
        if next == .idle, previous == .working, infos.contains(where: { $0.activity == .done }) { finishedAt = Date() }
        previous = next
        if next != mode { mode = next }
    }

    private var palette: [Color] {
        switch mode {
        case .idle: return [Color(rgb: 0x1B2C7A), Color(rgb: 0x2B1F66), Color(rgb: 0x123A5C)]
        case .working: return [Operator.core, Color(rgb: 0x3A7BFF), Color(rgb: 0x8A63FF)]
        case .waiting: return [Operator.warn, Color(rgb: 0xFF7A3D), Color(rgb: 0xD9A55B)]
        }
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize, _ date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        let w = size.width, h = size.height
        guard w > 10, h > 10 else { return }
        let strength: Double = mode == .idle ? 0.2 : mode == .working ? 0.42 : 0.45
        let speed = mode == .idle ? 0.12 : 0.35
        let currentStyle = AnimationStyle(rawValue: UserDefaults.standard.string(forKey: UserDefaults.animStyleKey) ?? "") ?? .original

        switch currentStyle {
        case .original:
            for (i, color) in palette.enumerated() {
                let base = h * (0.08 + Double(i) * 0.07)
                let amplitude = h * (0.05 + Double(i) * 0.015)
                let thickness = h * (0.22 + Double(i) * 0.05)
                var top = Path()
                let steps = 24
                for s in 0...steps {
                    let x = w * CGFloat(s) / CGFloat(steps)
                    let y = base + amplitude * sin(Double(s) * 0.45 + t * speed * (1 + Double(i) * 0.3) + Double(i) * 1.7)
                    if s == 0 { top.move(to: CGPoint(x: x, y: y)) } else { top.addLine(to: CGPoint(x: x, y: y)) }
                }
                var band = top
                band.addLine(to: CGPoint(x: w, y: base + thickness))
                band.addLine(to: CGPoint(x: 0, y: base + thickness))
                band.closeSubpath()
                gc.fill(band, with: .linearGradient(
                    Gradient(colors: [color.opacity(strength), color.opacity(strength * 0.4), color.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: base - amplitude), endPoint: CGPoint(x: 0, y: base + thickness)))
            }
            gc.fill(Path(CGRect(x: 0, y: h * 0.82, width: w, height: h * 0.18)), with: .linearGradient(
                Gradient(colors: [palette[1].opacity(0), palette[1].opacity(strength * 0.5)]),
                startPoint: CGPoint(x: 0, y: h * 0.82), endPoint: CGPoint(x: 0, y: h)))

        case .radar:
            // Flat horizontal grid + vertical scan bar sweeping left to right.
            let gridColor = palette[0]
            for i in 1...5 {
                let y = h * Double(i) / 6 * 0.45
                gc.fill(Path(CGRect(x: 0, y: y, width: w, height: 1)),
                        with: .color(gridColor.opacity(strength * 0.5)))
            }
            let scanX = (t * speed * 80).truncatingRemainder(dividingBy: Double(w))
            let scanW = w * 0.04
            gc.fill(Path(CGRect(x: CGFloat(scanX) - scanW / 2, y: 0, width: scanW, height: h * 0.5)),
                    with: .linearGradient(
                        Gradient(colors: [gridColor.opacity(0), gridColor.opacity(strength * 0.8), gridColor.opacity(0)]),
                        startPoint: CGPoint(x: CGFloat(scanX) - scanW / 2, y: 0),
                        endPoint: CGPoint(x: CGFloat(scanX) + scanW / 2, y: 0)))

        case .waveform:
            // Vertical EQ bars driven by sine functions of time.
            let barCount = 16
            let barW = w / CGFloat(barCount)
            for i in 0..<barCount {
                let barHeight = h * 0.4 * abs(sin(Double(i) * 0.6 + t * speed * 3))
                let x = CGFloat(i) * barW
                let y = h * 0.4 - barHeight
                let color = palette[i % palette.count]
                gc.fill(Path(CGRect(x: x + 1, y: y, width: barW - 2, height: barHeight)),
                        with: .linearGradient(
                            Gradient(colors: [color.opacity(strength), color.opacity(0)]),
                            startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: 0, y: y + barHeight)))
            }

        case .comet:
            // Sparse falling streams of pixels down from the top.
            let streamCount = 12
            let streamSpeed = h * 0.4
            for i in 0..<streamCount {
                let x = w * CGFloat(i) / CGFloat(streamCount) + w / CGFloat(streamCount * 2)
                let phase = Double(i * 7) * 0.37
                let y = CGFloat((t * streamSpeed * 0.5 + phase * Double(h)).truncatingRemainder(dividingBy: Double(h)))
                let dotH: CGFloat = 3
                for trail in 0..<4 {
                    let ty = y - CGFloat(trail) * (dotH + 2)
                    if ty < 0 || ty > h { continue }
                    gc.fill(Path(CGRect(x: x - 1, y: ty, width: 2, height: dotH)),
                            with: .color(palette[0].opacity(strength * (1 - Double(trail) * 0.28))))
                }
            }

        case .geometric:
            // Two solid horizontal bands, no motion (opacity shifts when mode changes).
            gc.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.18)),
                    with: .linearGradient(
                        Gradient(colors: [palette[0].opacity(strength * 0.8), palette[0].opacity(0)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h * 0.18)))
            gc.fill(Path(CGRect(x: 0, y: h * 0.18, width: w, height: h * 0.17)),
                    with: .linearGradient(
                        Gradient(colors: [palette[2].opacity(strength * 0.5), palette[2].opacity(0)]),
                        startPoint: CGPoint(x: 0, y: h * 0.18), endPoint: CGPoint(x: 0, y: h * 0.35)))
        }

        // The gold sweep when an agent finishes (all styles).
        if let finishedAt {
            let age = date.timeIntervalSince(finishedAt)
            if age >= 0, age < 2.6 {
                let x = w * CGFloat(age / 2.2) * 1.3 - w * 0.2
                let fade = age < 2.0 ? 1 : (2.6 - age) / 0.6
                gc.fill(Path(CGRect(x: x - w * 0.18, y: 0, width: w * 0.36, height: h)), with: .linearGradient(
                    Gradient(colors: [Operator.gold.opacity(0), Operator.gold.opacity(0.4 * fade), Operator.gold.opacity(0)]),
                    startPoint: CGPoint(x: x - w * 0.18, y: 0), endPoint: CGPoint(x: x + w * 0.18, y: 0)))
            }
        }
    }
}
#endif
