import SwiftUI
import GameController

/// Drives the app's own screens from a game controller (and the arrow keys).
///
/// iOS and macOS don't move focus with a controller, so the app keeps its own: every control that can be
/// reached registers its on-screen frame with `.padFocusable`, the D-pad / left stick moves to the nearest one
/// in that direction, A presses it, B goes back, LB / RB switch tabs. While a stream is up the controller
/// belongs to the game and the navigator only watches for the menu chord (both sticks clicked).
@MainActor
final class PadNavigator: ObservableObject {
    static let shared = PadNavigator()

    enum Event { case up, down, left, right, select, back, previousTab, nextTab }

    struct Item {
        var frame: CGRect
        var scope: String
        var priority: Int
        var action: () -> Void
        /// Left / right on this item changes its value instead of moving away (-1 / +1).
        var adjust: ((Int) -> Void)?
    }

    @Published private(set) var focus: String?
    /// True once the controller or the arrow keys were used: shows the focus ring. A touch or click hides it again.
    @Published private(set) var padActive = false
    @Published private(set) var padConnected = false

    private var items: [String: Item] = [:]
    private var scopes: [(id: String, onBack: (() -> Void)?, returnTo: String?)] = [("root", nil, nil)]
    private var refocusPending = false

    /// LB / RB (-1 / +1). Set by the home screen.
    var onTab: ((Int) -> Void)?
    /// Both sticks clicked together during a stream.
    var onMenuChord: (() -> Void)?
    /// The game has the controller: only the menu chord is watched.
    var suspended = false { didSet { if suspended != oldValue { held = Self.allHeld } } }

    private var timer: Timer?
    private static let allHeld: Set<String> = ["up", "down", "left", "right", "a", "b", "lb", "rb", "chord"]
    /// Inputs that were down at the last poll. Starts (and restarts after a stream) as "everything", so a button
    /// still held from before doesn't count as a new press.
    private var held = PadNavigator.allHeld
    private var repeatAt: [String: TimeInterval] = [:]

    private init() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Registry
    var topScope: String { scopes.last?.id ?? "root" }

    func register(_ id: String, _ item: Item) {
        items[id] = item
        if focus == nil, padActive, item.scope == topScope { scheduleRefocus() }
    }

    func unregister(_ id: String) {
        items[id] = nil
        if focus == id { focus = nil; if padActive { scheduleRefocus() } }
    }

    func pushScope(_ id: String, onBack: (() -> Void)?) {
        scopes.removeAll { $0.id == id }
        scopes.append((id, onBack, focus))
        focus = nil
        if padActive { scheduleRefocus() }
    }

    func popScope(_ id: String) {
        guard let i = scopes.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let back = scopes[i].returnTo
        scopes.remove(at: i)
        focus = back.flatMap { items[$0]?.scope == topScope ? $0 : nil }
        if focus == nil, padActive { scheduleRefocus() }
    }

    /// Drop the focus and pick the first control again once the new content has registered (tab change).
    func resetFocus() {
        focus = nil
        if padActive { scheduleRefocus() }
    }

    func isFocused(_ id: String) -> Bool { padActive && focus == id }

    /// A touch or a click: the ring goes away until the controller is used again.
    func pointerUsed() { if padActive { padActive = false } }

    private func scheduleRefocus() {
        guard !refocusPending else { return }
        refocusPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.refocusPending = false
            if self.focus == nil || self.items[self.focus!] == nil { self.focusFirst() }
        }
    }

    private func focusFirst() {
        let scope = topScope
        let best = items.filter { $0.value.scope == scope && !$0.value.frame.isEmpty }.min { a, b in
            if a.value.priority != b.value.priority { return a.value.priority > b.value.priority }
            if abs(a.value.frame.minY - b.value.frame.minY) > 12 { return a.value.frame.minY < b.value.frame.minY }
            return a.value.frame.minX < b.value.frame.minX
        }
        focus = best?.key
    }

    // MARK: Events
    @discardableResult
    func handle(_ event: Event) -> Bool {
        guard !suspended else { return false }
        let wasActive = padActive
        padActive = true
        switch event {
        case .back:
            guard let back = scopes.last?.onBack else { return false }
            back()
        case .previousTab: onTab?(-1)
        case .nextTab: onTab?(1)
        case .select:
            // Like the directions: the first press only shows the focus, it doesn't press something unseen.
            guard wasActive, let id = focus, let item = items[id], item.scope == topScope else {
                if focus == nil || items[focus!]?.scope != topScope { focusFirst() }
                return true
            }
            item.action()
        case .up, .down, .left, .right:
            // The first press only reveals where the focus is.
            guard wasActive, let id = focus, let cur = items[id], cur.scope == topScope else {
                if focus == nil || items[focus!]?.scope != topScope { focusFirst() }
                return true
            }
            let dx: CGFloat = event == .left ? -1 : event == .right ? 1 : 0
            let dy: CGFloat = event == .up ? -1 : event == .down ? 1 : 0
            if dx != 0, let adjust = cur.adjust { adjust(Int(dx)); return true }
            move(from: id, cur.frame, dx, dy)
        }
        return true
    }

    /// Nearest control in the direction: distance along the direction, plus a penalty for being off to the side
    /// (small when the two overlap on that side axis, so rows and columns are followed first).
    private func move(from id: String, _ cur: CGRect, _ dx: CGFloat, _ dy: CGFloat) {
        let scope = topScope
        var best: (String, CGFloat)?
        for (key, item) in items where key != id && item.scope == scope && !item.frame.isEmpty {
            let f = item.frame
            let along = dx != 0 ? (f.midX - cur.midX) * dx : (f.midY - cur.midY) * dy
            guard along > 4 else { continue }
            let side = dx != 0 ? abs(f.midY - cur.midY) : abs(f.midX - cur.midX)
            let overlaps = dx != 0 ? (f.minY < cur.maxY && f.maxY > cur.minY) : (f.minX < cur.maxX && f.maxX > cur.minX)
            let gap = dx != 0 ? max(0, dx > 0 ? f.minX - cur.maxX : cur.minX - f.maxX) : max(0, dy > 0 ? f.minY - cur.maxY : cur.minY - f.maxY)
            let score = gap + along * 0.25 + side * (overlaps ? 0.4 : 3)
            if score < (best?.1 ?? .infinity) { best = (key, score) }
        }
        if let best { focus = best.0 }
    }

    // MARK: Controller polling
    private func poll() {
        let pads = GCController.controllers().compactMap(\.extendedGamepad)
        if padConnected != !pads.isEmpty { padConnected = !pads.isEmpty }
        guard !pads.isEmpty else { held = Self.allHeld; return }

        var down = Set<String>()
        for g in pads {
            let x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value
            if g.dpad.up.isPressed || y > 0.6 { down.insert("up") }
            if g.dpad.down.isPressed || y < -0.6 { down.insert("down") }
            if g.dpad.left.isPressed || x < -0.6 { down.insert("left") }
            if g.dpad.right.isPressed || x > 0.6 { down.insert("right") }
            if g.buttonA.isPressed { down.insert("a") }
            if g.buttonB.isPressed { down.insert("b") }
            if g.leftShoulder.isPressed { down.insert("lb") }
            if g.rightShoulder.isPressed { down.insert("rb") }
            if g.leftThumbstickButton?.isPressed == true, g.rightThumbstickButton?.isPressed == true { down.insert("chord") }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let pressed = down.subtracting(held)
        // Held directions repeat: after 0.4 s, then every 0.11 s.
        var repeated = Set<String>()
        for d in ["up", "down", "left", "right"] {
            if pressed.contains(d) { repeatAt[d] = now + 0.4 }
            else if down.contains(d), held.contains(d), let t = repeatAt[d], now >= t { repeated.insert(d); repeatAt[d] = now + 0.11 }
            else if !down.contains(d) { repeatAt[d] = nil }
        }
        held = down

        if suspended {
            if pressed.contains("chord") { onMenuChord?() }
            return
        }
        if pressed.contains("chord"), onMenuChord != nil { onMenuChord?(); return }
        let fire = pressed.union(repeated)
        if fire.contains("up") { handle(.up) }
        if fire.contains("down") { handle(.down) }
        if fire.contains("left") { handle(.left) }
        if fire.contains("right") { handle(.right) }
        if pressed.contains("a") { handle(.select) }
        if pressed.contains("b") { handle(.back) }
        if pressed.contains("lb") { handle(.previousTab) }
        if pressed.contains("rb") { handle(.nextTab) }
    }
}

// MARK: SwiftUI

private struct PadScopeKey: EnvironmentKey { static let defaultValue = "root" }
extension EnvironmentValues {
    var padScope: String {
        get { self[PadScopeKey.self] }
        set { self[PadScopeKey.self] = newValue }
    }
}

/// Holds a control's current closures. The navigator registers a control once (and again when its frame moves),
/// but the closures capture view state that changes between renders; the registry calls through this box so it
/// always runs the ones from the latest render.
private final class PadActionBox {
    var action: () -> Void = {}
    var adjust: ((Int) -> Void)?
    func update(_ action: @escaping () -> Void, _ adjust: ((Int) -> Void)? = nil) {
        self.action = action
        self.adjust = adjust
    }
}

private struct PadFocusable: ViewModifier {
    let id: String
    let priority: Int
    let adjust: ((Int) -> Void)?
    let action: () -> Void
    @Environment(\.padScope) private var scope
    @State private var box = PadActionBox()

    func body(content: Content) -> some View {
        let _ = box.update(action, adjust)
        content
            .background(GeometryReader { g in
                let frame = g.frame(in: .global)
                Color.clear
                    .onAppear { register(frame) }
                    .onChange(of: frame) { _, new in register(new) }
            })
            .onDisappear { PadNavigator.shared.unregister(id) }
            .id(id)
    }

    private func register(_ frame: CGRect) {
        let box = box
        PadNavigator.shared.register(id, .init(frame: frame, scope: scope, priority: priority, action: { box.action() },
                                               adjust: adjust == nil ? nil : { box.adjust?($0) }))
    }
}

/// A modal layer (a panel, a pushed page): only its controls are reachable while it's up, and B runs `onBack`.
private struct PadScope: ViewModifier {
    let id: String
    let onBack: (() -> Void)?
    @State private var box = PadActionBox()
    func body(content: Content) -> some View {
        let _ = box.update(onBack ?? {})
        content
            .environment(\.padScope, id)
            .onAppear { let box = box; PadNavigator.shared.pushScope(id, onBack: onBack == nil ? nil : { box.action() }) }
            .onDisappear { PadNavigator.shared.popScope(id) }
    }
}

extension View {
    /// Makes the view reachable with the controller. `id` must be unique on screen; it's also the scroll target.
    func padFocusable(_ id: String, priority: Int = 0, adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(PadFocusable(id: id, priority: priority, adjust: adjust, action: action))
    }

    func padScope(_ id: String, onBack: (() -> Void)? = nil) -> some View { modifier(PadScope(id: id, onBack: onBack)) }

    /// Arrow keys, Return and Escape drive the same navigation as the controller.
    func padKeyboard() -> some View { modifier(PadKeyboard()) }
}

private struct PadKeyboard: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape], phases: [.down, .repeat]) { press in
                let event: PadNavigator.Event = switch press.key {
                case .upArrow: .up
                case .downArrow: .down
                case .leftArrow: .left
                case .rightArrow: .right
                case .return: .select
                default: .back
                }
                return PadNavigator.shared.handle(event) ? .handled : .ignored
            }
    }
}

/// A scroll view that follows the controller focus.
struct PadScrollView<Content: View>: View {
    var axes: Axis.Set = .vertical
    @ViewBuilder var content: () -> Content
    @ObservedObject private var nav = PadNavigator.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axes, showsIndicators: false) { content() }
                .onChange(of: nav.focus) { _, id in
                    guard let id, nav.padActive else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
        }
    }
}
