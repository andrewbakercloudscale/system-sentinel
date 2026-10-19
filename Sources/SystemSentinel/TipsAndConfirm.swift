import AppKit
import SwiftUI

// MARK: Tooltips that always show

/// macOS's own tooltips (`.help`) do not appear in a menu bar panel, which never becomes the
/// active window. These are drawn by the page itself: hover over a control for half a second
/// and a bubble says what it does. The bubble ignores the mouse, so clicks go straight through.
@MainActor
final class TipCenter: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var anchor: CGRect = .zero
    private var pending: DispatchWorkItem?
    private var owner: UUID?

    func hover(_ id: UUID, _ text: String, at frame: CGRect, inside: Bool) {
        pending?.cancel()
        guard inside else {
            if owner == id { self.text = nil; owner = nil }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.owner = id
            self?.anchor = frame
            self?.text = text
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (self.text == nil ? 0.25 : 0.05), execute: work)
    }

    func hide() { pending?.cancel(); text = nil; owner = nil }
}

private struct TipCenterKey: EnvironmentKey {
    static let defaultValue: TipCenter? = nil
}

extension EnvironmentValues {
    var tipCenter: TipCenter? {
        get { self[TipCenterKey.self] }
        set { self[TipCenterKey.self] = newValue }
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @Environment(\.tipCenter) private var center
    @State private var id = UUID()
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        if let center {
            content
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { frame = g.frame(in: .named(TipLayer.space)) }
                        .onChange(of: g.frame(in: .named(TipLayer.space))) { _, f in frame = f }
                })
                .onHover { inside in center.hover(id, text, at: frame, inside: inside) }
                .onDisappear { center.hover(id, text, at: frame, inside: false) }
                .simultaneousGesture(TapGesture().onEnded { center.hide() })
        } else {
            content.help(text)
        }
    }
}

extension View {
    /// A tooltip that shows wherever the control is, the menu bar panel included.
    func tip(_ text: String) -> some View { modifier(TipModifier(text: text)) }

    /// Makes `.tip` and `.confirmations` work inside this view: once, at the root of a window.
    func tipsAndConfirmations(_ center: TipCenter, surface: String) -> some View {
        self
            .coordinateSpace(name: TipLayer.space)
            .environment(\.tipCenter, center)
            .overlay { TipLayer(center: center) }
            .overlay { ConfirmLayer(confirm: .shared, surface: surface) }
            .environment(\.confirmSurface, surface)
    }
}

/// Draws the bubble under (or above, near the bottom) whatever is hovered.
struct TipLayer: View {
    static let space = "tipRoot"
    @ObservedObject var center: TipCenter

    var body: some View {
        GeometryReader { g in
            if let text = center.text {
                let a = center.anchor
                let width = min(300, g.size.width - 16)
                let below = a.maxY + 70 < g.size.height
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: width, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in 0 }
                    .position(x: min(max(a.midX, width / 2 + 8), g.size.width - width / 2 - 8),
                              y: below ? a.maxY + 8 : a.minY - 8)
                    .offset(y: below ? 18 : -18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: center.text)
    }
}

// MARK: Confirmations

/// One question before an action: what it is, what will happen, how to undo it, and the
/// buttons. Shown over the page it was asked from, never as a system alert that would close
/// the menu bar panel.
struct ConfirmRequest: Identifiable {
    struct Choice {
        let title: String
        var destructive = false
        let action: () -> Void
    }

    let id = UUID()
    var surface = "main"
    var symbol: String
    var tint: Color
    var title: String
    var message: String
    /// What happens, one line each.
    var points: [String] = []
    /// How to put it back, when it can be.
    var undo: String?
    /// A command to show (and copy) as it is.
    var command: String?
    var confirm: Choice
    var others: [Choice] = []
}

@MainActor
final class Confirm: ObservableObject {
    static let shared = Confirm()
    @Published var request: ConfirmRequest?

    /// Asks over the page `surface` names ("main" is the menu bar panel and its window).
    static func ask(_ r: ConfirmRequest) { shared.request = r }

    /// The common shape: a yes-or-cancel question.
    static func ask(_ title: String, _ message: String, symbol: String = "questionmark.circle.fill", tint: Color = Theme.accent,
                    points: [String] = [], undo: String? = nil, button: String, destructive: Bool = false,
                    surface: String = "main", then action: @escaping () -> Void) {
        ask(ConfirmRequest(surface: surface, symbol: symbol, tint: destructive ? Theme.heat(100) : tint, title: title, message: message,
                           points: points, undo: undo, confirm: .init(title: button, destructive: destructive, action: action)))
    }
}

private struct ConfirmSurfaceKey: EnvironmentKey { static let defaultValue = "main" }

extension EnvironmentValues {
    /// Which window a confirmation asked from here appears over.
    var confirmSurface: String {
        get { self[ConfirmSurfaceKey.self] }
        set { self[ConfirmSurfaceKey.self] = newValue }
    }
}

struct ConfirmLayer: View {
    @ObservedObject var confirm: Confirm
    let surface: String

    var body: some View {
        if let r = confirm.request, r.surface == surface {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { confirm.request = nil }
                ConfirmCard(request: r) { confirm.request = nil }
                    .padding(24)
            }
            .transition(.opacity)
        }
    }
}

private struct ConfirmCard: View {
    let request: ConfirmRequest
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(request.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(request.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !request.points.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(request.points.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(request.tint).frame(width: 5, height: 5).offset(y: -2)
                            Text(p).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 46)
            }
            if let c = request.command {
                HStack(alignment: .top) {
                    Text(c).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.link).font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .padding(.leading, 46)
            }
            if let u = request.undo {
                Label(u, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 46)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                ForEach(Array(request.others.enumerated()), id: \.offset) { _, o in
                    Button(o.title) { close(); o.action() }
                }
                Button(request.confirm.title) { close(); request.confirm.action() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(request.confirm.destructive ? Theme.heat(100) : request.tint)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}
