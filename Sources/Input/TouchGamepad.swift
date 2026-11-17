#if os(iOS)
import SwiftUI
import UIKit

/// State of the on-screen gamepad. Written on the main thread by `TouchGamepadView`, read by `InputPump`
/// on the WebRTC queue and merged into pad 0 like the keyboard.
final class TouchGamepad: @unchecked Sendable {
    static let shared = TouchGamepad()
    private let lock = NSLock()
    private var state = GamepadFrame()
    private var active = false

    func frame() -> GamepadFrame? {
        lock.lock(); defer { lock.unlock() }
        return active ? state : nil
    }

    func set(_ f: GamepadFrame) {
        lock.lock(); state = f; active = true; lock.unlock()
    }

    /// Called when the overlay goes away, so nothing stays held.
    func reset() {
        lock.lock(); state = GamepadFrame(); active = false; lock.unlock()
    }
}

/// Settings → Input → "Try on-screen controls": the gamepad over a black screen with a live readout,
/// to get used to the layout without starting a stream. `--touch-test` opens it at launch.
struct TouchGamepadTestView: View {
    @Environment(\.dismiss) private var dismiss
    static var requested: Bool { CommandLine.arguments.contains("--touch-test") }
    /// Taller than wide: the gamepad is a band along the bottom, so the readout goes above it.
    @State private var tall = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TimelineView(.animation) { _ in
                let f = TouchGamepad.shared.frame() ?? GamepadFrame()
                let names: [(String, Bool)] = [("A", f.a), ("B", f.b), ("X", f.x), ("Y", f.y), ("LB", f.leftShoulder), ("RB", f.rightShoulder),
                    ("L3", f.leftThumb), ("R3", f.rightThumb), ("View", f.view), ("Menu", f.menu), ("Xbox", f.nexus),
                    ("Up", f.dpadUp), ("Down", f.dpadDown), ("Left", f.dpadLeft), ("Right", f.dpadRight)]
                VStack(spacing: 4) {
                    Text(names.filter(\.1).map(\.0).joined(separator: " + ").isEmpty ? "Press something" : names.filter(\.1).map(\.0).joined(separator: " + "))
                    Text(String(format: "L %+.2f %+.2f   R %+.2f %+.2f   LT %.0f  RT %.0f", f.leftX, f.leftY, f.rightX, f.rightY, f.leftTrigger, f.rightTrigger))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .offset(y: tall ? 0 : -30)
                .frame(maxHeight: .infinity, alignment: tall ? .top : .center)
                .padding(.top, tall ? 110 : 0)
            }
            TouchGamepadOverlay()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered).tint(.white)
                .padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onGeometryChange(for: Bool.self) { $0.size.height > $0.size.width } action: { tall = $0 }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { StreamScreen.enter() }
        .onDisappear { StreamScreen.leave() }
    }
}

/// SwiftUI host. Touches that miss every control fall through to whatever is underneath.
struct TouchGamepadOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchGamepadView { TouchGamepadView() }
    func updateUIView(_ view: TouchGamepadView, context: Context) {}
    static func dismantleUIView(_ view: TouchGamepadView, coordinator: ()) { TouchGamepad.shared.reset() }
}

/// Multi-touch Xbox layout for landscape: sticks, D-pad, ABXY, bumpers, triggers, stick clicks, View / Menu / Xbox.
final class TouchGamepadView: UIView {
    private enum Kind {
        case button(WritableKeyPath<GamepadFrame, Bool>)
        case trigger(WritableKeyPath<GamepadFrame, Float>)
        case stick(x: WritableKeyPath<GamepadFrame, Float>, y: WritableKeyPath<GamepadFrame, Float>)
        case dpad
    }

    private struct Control {
        let kind: Kind
        var label: String? = nil
        var symbol: String? = nil
        var tint: UIColor = .white
        var center = CGPoint.zero
        var radius: CGFloat = 0
        /// Sticks: knob offset, -1…1 (screen axes).
        var vector = CGPoint.zero
        var pressed = false

        var isButton: Bool { if case .button = kind { return true }; if case .trigger = kind { return true }; return false }
    }

    private var controls: [Control] = [
        Control(kind: .stick(x: \.leftX, y: \.leftY)),                      // 0
        Control(kind: .dpad),                                               // 1
        Control(kind: .stick(x: \.rightX, y: \.rightY)),                    // 2
        Control(kind: .button(\.a), label: "A", tint: UIColor(red: 0.42, green: 0.85, blue: 0.35, alpha: 1)),   // 3
        Control(kind: .button(\.b), label: "B", tint: UIColor(red: 0.95, green: 0.33, blue: 0.30, alpha: 1)),   // 4
        Control(kind: .button(\.x), label: "X", tint: UIColor(red: 0.30, green: 0.62, blue: 0.98, alpha: 1)),   // 5
        Control(kind: .button(\.y), label: "Y", tint: UIColor(red: 0.98, green: 0.82, blue: 0.25, alpha: 1)),   // 6
        Control(kind: .trigger(\.leftTrigger), label: "LT"),                // 7
        Control(kind: .button(\.leftShoulder), label: "LB"),                // 8
        Control(kind: .trigger(\.rightTrigger), label: "RT"),               // 9
        Control(kind: .button(\.rightShoulder), label: "RB"),               // 10
        Control(kind: .button(\.view), symbol: "rectangle.on.rectangle"),   // 11
        Control(kind: .button(\.nexus), symbol: "xbox.logo"),               // 12
        Control(kind: .button(\.menu), symbol: "line.3.horizontal"),        // 13
        Control(kind: .button(\.leftThumb), label: "L3"),                   // 14
        Control(kind: .button(\.rightThumb), label: "R3"),                  // 15
    ]
    private var owners: [ObjectIdentifier: Int] = [:]
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        TouchGamepad.shared.set(GamepadFrame())
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout
    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        // Sized for a ~400 pt tall landscape phone; grows a little on taller screens (iPad, unfolded).
        let u = min(1.35, max(0.75, min(h / 400, w / 540)))
        let edge = 24 * u
        func place(_ i: Int, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { controls[i].center = CGPoint(x: x, y: y); controls[i].radius = r * u }

        // A view taller than wide (iPhone Duo's inner display, an iPad window in Split View): the whole gamepad
        // keeps its landscape-phone shape in a band along the bottom, so the triggers stay near the thumbs
        // instead of going to the top of the screen. `band` is where that band starts; 0 in landscape.
        let band = h > w ? max(0, h - 420 * u) : 0
        let top = band + 34 * u
        place(7, edge + 34 * u, top, 26)                // LT
        place(8, edge + 104 * u, top, 26)               // LB
        place(9, w - edge - 34 * u, top, 26)            // RT
        place(10, w - edge - 104 * u, top, 26)          // RB

        place(0, edge + 62 * u, h - 150 * u, 52)        // left stick
        place(1, edge + 176 * u, h - 66 * u, 50)        // D-pad
        let face = CGPoint(x: w - edge - 78 * u, y: h - 142 * u), d = 46 * u
        place(3, face.x, face.y + d, 25)                // A
        place(4, face.x + d, face.y, 25)                // B
        place(5, face.x - d, face.y, 25)                // X
        place(6, face.x, face.y - d, 25)                // Y
        place(2, w - edge - 196 * u, h - 62 * u, 44)    // right stick

        // The small buttons sit between the sticks when there's room, otherwise in a row under the stream controls.
        let bottom = w >= 750 * u ? h - 22 * u : band + 76 * u
        place(11, w / 2 - 44 * u, bottom, 16)           // View
        place(12, w / 2, bottom, 16)                    // Xbox
        place(13, w / 2 + 44 * u, bottom, 16)           // Menu
        place(14, w / 2 - 96 * u, bottom, 16)           // L3
        place(15, w / 2 + 96 * u, bottom, 16)           // R3
        setNeedsDisplay()
    }

    private func hitRadius(_ c: Control) -> CGFloat {
        switch c.kind {
        case .stick: c.radius * 1.35
        case .dpad: c.radius * 1.15
        default: max(c.radius * 1.25, 22)
        }
    }

    private func control(at p: CGPoint, buttonsOnly: Bool = false) -> Int? {
        var best: (Int, CGFloat)?
        for (i, c) in controls.enumerated() where !buttonsOnly || c.isButton {
            let dist = hypot(p.x - c.center.x, p.y - c.center.y)
            if dist <= hitRadius(c), dist < (best?.1 ?? .infinity) { best = (i, dist) }
        }
        return best?.0
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { control(at: point) != nil }

    // MARK: Touches
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            guard let i = control(at: p) else { continue }
            owners[ObjectIdentifier(t)] = i
            update(i, p)
            if AppSettings.shared.touchHaptics { feedback.impactOccurred() }
        }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t), p = t.location(in: self)
            guard let i = owners[id] else { continue }
            // Rolling a thumb from one face button to the next moves the press with it.
            if controls[i].isButton, let j = control(at: p, buttonsOnly: true), j != i {
                owners[id] = j
                release(i)
                update(j, p)
                if AppSettings.shared.touchHaptics { feedback.impactOccurred() }
            } else { update(i, p) }
        }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }

    private func end(_ touches: Set<UITouch>) {
        for t in touches {
            if let i = owners.removeValue(forKey: ObjectIdentifier(t)) { release(i) }
        }
        publish()
    }

    private func release(_ i: Int) {
        // Still held by another finger?
        if owners.values.contains(i) { return }
        controls[i].pressed = false
        controls[i].vector = .zero
    }

    private func update(_ i: Int, _ p: CGPoint) {
        controls[i].pressed = true
        switch controls[i].kind {
        case .stick, .dpad:
            let c = controls[i]
            var v = CGPoint(x: (p.x - c.center.x) / c.radius, y: (p.y - c.center.y) / c.radius)
            let len = hypot(v.x, v.y)
            if len > 1 { v.x /= len; v.y /= len }
            controls[i].vector = v
        default: break
        }
    }

    private func publish() {
        var f = GamepadFrame()
        for c in controls where c.pressed {
            switch c.kind {
            case .button(let k): f[keyPath: k] = true
            case .trigger(let k): f[keyPath: k] = 1
            case .stick(let x, let y):
                // Screen Y grows downwards; the wire format has +Y up.
                f[keyPath: x] = Float(c.vector.x); f[keyPath: y] = Float(-c.vector.y)
            case .dpad:
                // Eight-way, with a dead centre.
                f.dpadLeft = c.vector.x < -0.33; f.dpadRight = c.vector.x > 0.33
                f.dpadUp = c.vector.y < -0.33; f.dpadDown = c.vector.y > 0.33
            }
        }
        TouchGamepad.shared.set(f)
        // `--touch-test` runs log every change, so the controls can be checked from the log.
        if TouchGamepadTestView.requested { log("Touch", "buttons \(f.buttonMask) L \(f.leftX),\(f.leftY) R \(f.rightX),\(f.rightY) LT \(f.leftTrigger) RT \(f.rightTrigger)") }
        setNeedsDisplay()
    }

    // MARK: Drawing
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for c in controls {
            let r = c.radius
            let box = CGRect(x: c.center.x - r, y: c.center.y - r, width: r * 2, height: r * 2)
            let fill = UIColor.black.withAlphaComponent(c.pressed ? 0.5 : 0.28)
            let stroke = UIColor.white.withAlphaComponent(c.pressed ? 0.95 : 0.55)
            ctx.setLineWidth(1.5)
            switch c.kind {
            case .stick:
                ctx.setFillColor(fill.cgColor); ctx.fillEllipse(in: box)
                ctx.setStrokeColor(stroke.cgColor); ctx.strokeEllipse(in: box.insetBy(dx: 1, dy: 1))
                let k = r * 0.48
                let knob = CGRect(x: c.center.x + c.vector.x * r * 0.55 - k, y: c.center.y + c.vector.y * r * 0.55 - k, width: k * 2, height: k * 2)
                ctx.setFillColor(UIColor.white.withAlphaComponent(c.pressed ? 0.75 : 0.4).cgColor)
                ctx.fillEllipse(in: knob)
            case .dpad:
                let arm = r * 0.62
                let cross = UIBezierPath(roundedRect: CGRect(x: c.center.x - arm / 2, y: c.center.y - r, width: arm, height: r * 2), cornerRadius: 6)
                cross.append(UIBezierPath(roundedRect: CGRect(x: c.center.x - r, y: c.center.y - arm / 2, width: r * 2, height: arm), cornerRadius: 6))
                cross.usesEvenOddFillRule = false
                fill.setFill(); cross.fill()
                stroke.setStroke(); cross.lineWidth = 1.5; cross.stroke()
                fill.withAlphaComponent(1).setFill()
                UIBezierPath(rect: CGRect(x: c.center.x - arm / 2 + 1, y: c.center.y - arm / 2 + 1, width: arm - 2, height: arm - 2)).fill(with: .copy, alpha: c.pressed ? 0.5 : 0.28)
                // Light up the arms that are held.
                UIColor.white.withAlphaComponent(0.7).setFill()
                func lit(_ on: Bool, _ dx: CGFloat, _ dy: CGFloat) {
                    guard on else { return }
                    let s = arm * 0.8
                    UIBezierPath(roundedRect: CGRect(x: c.center.x + dx * (r - arm / 2) - s / 2, y: c.center.y + dy * (r - arm / 2) - s / 2, width: s, height: s), cornerRadius: 5).fill()
                }
                lit(c.vector.x < -0.33, -1, 0); lit(c.vector.x > 0.33, 1, 0); lit(c.vector.y < -0.33, 0, -1); lit(c.vector.y > 0.33, 0, 1)
                let glyph = UIColor.white.withAlphaComponent(0.6)
                for (s, dx, dy) in [("▲", 0.0, -1.0), ("▼", 0.0, 1.0), ("◀", -1.0, 0.0), ("▶", 1.0, 0.0)] {
                    draw(s, at: CGPoint(x: c.center.x + dx * (r - arm / 2), y: c.center.y + dy * (r - arm / 2)), size: r * 0.26, color: glyph)
                }
            case .button, .trigger:
                let path: UIBezierPath
                if case .trigger = c.kind { path = UIBezierPath(roundedRect: box.insetBy(dx: -r * 0.2, dy: r * 0.15), cornerRadius: r * 0.5) }
                else if c.label == "LB" || c.label == "RB" { path = UIBezierPath(roundedRect: box.insetBy(dx: -r * 0.2, dy: r * 0.15), cornerRadius: r * 0.5) }
                else { path = UIBezierPath(ovalIn: box) }
                (c.pressed ? c.tint.withAlphaComponent(0.55) : fill).setFill(); path.fill()
                stroke.setStroke(); path.lineWidth = 1.5; path.stroke()
                let ink = c.pressed ? UIColor.white : c.tint.withAlphaComponent(0.9)
                if let s = c.label { draw(s, at: c.center, size: r * (s.count > 1 ? 0.62 : 0.85), color: ink) }
                if let name = c.symbol,
                   let img = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: r * 0.8, weight: .semibold))?
                    .withTintColor(ink, renderingMode: .alwaysOriginal) {
                    img.draw(at: CGPoint(x: c.center.x - img.size.width / 2, y: c.center.y - img.size.height / 2))
                }
            }
        }
    }

    private func draw(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor) {
        let text = NSAttributedString(string: s, attributes: [.font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
        let sz = text.size()
        text.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }
}
#endif
