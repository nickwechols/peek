// Themes: one set of colors for the Library, the screenshot editor, the video editor and the floating
// preview. Every surface reads the tokens below, so switching is instant and nothing is hard-coded twice.

import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let dark: Bool
    let canvas: Color      // Library window background
    let surface: Color     // Library content panel
    let ink: Color         // text
    let accent: Color
    let editor: Color      // editor backgrounds
    let panel: Color       // toolbars, the floating preview, cards on dark

    static let all: [Theme] = [
        Theme(id: "peek", name: "Peek", dark: false, canvas: Color(hex: 0xF6F5F2), surface: .white, ink: Color(hex: 0x15161B),
              accent: Color(hex: 0x4087FF), editor: Color(hex: 0x131417), panel: Color(hex: 0x1D1F23)),
        Theme(id: "paper", name: "Paper", dark: false, canvas: Color(hex: 0xEEF0F3), surface: Color(hex: 0xFBFCFD), ink: Color(hex: 0x1B1E24),
              accent: Color(hex: 0x1F9D6B), editor: Color(hex: 0x16191E), panel: Color(hex: 0x22262D)),
        Theme(id: "graphite", name: "Graphite", dark: true, canvas: Color(hex: 0x1B1B1D), surface: Color(hex: 0x242427), ink: Color(hex: 0xE8E8EA),
              accent: Color(hex: 0x4C9AFF), editor: Color(hex: 0x141416), panel: Color(hex: 0x26262A)),
        Theme(id: "onyx", name: "Onyx", dark: true, canvas: Color(hex: 0x0A0A0B), surface: Color(hex: 0x131315), ink: Color(hex: 0xEDEDEF),
              accent: Color(hex: 0xF2F2F3), editor: Color(hex: 0x070708), panel: Color(hex: 0x18181B)),
        Theme(id: "arctic", name: "Arctic", dark: true, canvas: Color(hex: 0x2B303B), surface: Color(hex: 0x343A46), ink: Color(hex: 0xECEFF4),
              accent: Color(hex: 0x88C0D0), editor: Color(hex: 0x232731), panel: Color(hex: 0x3B4252)),
        Theme(id: "dusk", name: "Dusk", dark: true, canvas: Color(hex: 0x1E1F29), surface: Color(hex: 0x282A36), ink: Color(hex: 0xF4F4EF),
              accent: Color(hex: 0xBD93F9), editor: Color(hex: 0x191A22), panel: Color(hex: 0x30323F)),
        Theme(id: "solar", name: "Solar", dark: false, canvas: Color(hex: 0xEEE8D5), surface: Color(hex: 0xFDF6E3), ink: Color(hex: 0x073642),
              accent: Color(hex: 0x268BD2), editor: Color(hex: 0x002B36), panel: Color(hex: 0x0B3A46)),
    ]

    /// Accent overrides. Index 0 means "the theme's own".
    static let accents: [Color] = [Color(hex: 0x4087FF), Color(hex: 0x1FB57A), Color(hex: 0xFF8A3D), Color(hex: 0xFF5C93),
                                   Color(hex: 0x8E6CFF), Color(hex: 0x8A8F98)]
}

final class ThemeStore: ObservableObject, @unchecked Sendable {
    static let shared = ThemeStore()
    @Published var themeID: String { didSet { UserDefaults.standard.set(themeID, forKey: "theme"); resolve() } }
    /// -1 uses the theme's accent, otherwise an index into Theme.accents.
    @Published var accentIndex: Int { didSet { UserDefaults.standard.set(accentIndex, forKey: "accent"); resolve() } }

    // Resolved once per change. Views read these on every frame of every animation, so they are plain stored values.
    private(set) var current: Theme = Theme.all[0]
    private(set) var accent: Color = Theme.all[0].accent
    private(set) var onAccent: Color = .white

    init() {
        themeID = UserDefaults.standard.string(forKey: "theme") ?? "peek"
        accentIndex = UserDefaults.standard.object(forKey: "accent") as? Int ?? -1
        resolve()
    }

    private func resolve() {
        current = Theme.all.first { $0.id == themeID } ?? Theme.all[0]
        accent = Theme.accents.indices.contains(accentIndex) ? Theme.accents[accentIndex] : current.accent
        let c = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        onAccent = l > 0.62 ? Color(hex: 0x111214) : .white
    }

    var key: String { "\(themeID).\(accentIndex)" }
}

// Tokens. Read at render time, so a theme switch re-colors every window.
var theme: Theme { ThemeStore.shared.current }
var accent: Color { ThemeStore.shared.accent }
var canvasBG: Color { theme.canvas }
var surface: Color { theme.surface }
var ink: Color { theme.ink }
var hairline: Color { theme.ink.opacity(theme.dark ? 0.1 : 0.07) }
var editorBG: Color { theme.editor }
var editorPanel: Color { theme.panel }

// MARK: - Floating preview look

/// Read during layout and on every animation frame of the preview, so cached and refreshed only when
/// Settings actually change.
enum TrayLook {
    private(set) static var style = "glass"          // "glass", "clear" or "solid"
    private(set) static var scale: CGFloat = 1
    private(set) static var w: CGFloat = 168
    private(set) static var h: CGFloat = 106
    private static var observer: NSObjectProtocol? = {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in TrayLook.refresh() }
    }()

    static func refresh() {
        _ = observer
        let d = UserDefaults.standard
        style = d.string(forKey: "trayStyle") ?? "glass"
        scale = [0.82, 1, 1.22][min(max(d.object(forKey: "traySize") as? Int ?? 1, 0), 2)]
        w = (168 * scale).rounded()
        h = (106 * scale).rounded()
    }
}

var thumbW: CGFloat { TrayLook.w }
var thumbH: CGFloat { TrayLook.h }

// MARK: - Settings views

struct ThemePicker: View {
    @ObservedObject var store = ThemeStore.shared
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 12) {
                ForEach(Theme.all) { t in
                    Button { withAnimation(.easeInOut(duration: 0.25)) { store.themeID = t.id } } label: {
                        VStack(spacing: 7) {
                            swatch(t)
                                .overlay {
                                    if store.themeID == t.id {
                                        RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(accent, lineWidth: 2.5).padding(-4)
                                            .matchedGeometryEffect(id: "ring", in: ns)
                                    }
                                }
                            Text(t.name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.opacity(store.themeID == t.id ? 1 : 0.6))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Squish())
                }
            }
            HStack(spacing: 10) {
                Text("Accent").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ink)
                Spacer()
                dot(theme.accent, on: store.accentIndex < 0, help: "The theme's own") { store.accentIndex = -1 }
                ForEach(Theme.accents.indices, id: \.self) { i in
                    dot(Theme.accents[i], on: store.accentIndex == i, help: "") { store.accentIndex = i }
                }
            }
        }
        .animation(bouncy, value: store.themeID)
        .animation(bouncy, value: store.accentIndex)
    }

    /// A tiny Library: canvas, a panel, a heading line, a few tiles, an accent mark, plus the editor color.
    func swatch(_ t: Theme) -> some View {
        ZStack(alignment: .topLeading) {
            t.canvas
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(t.surface)
                .padding(.leading, 24).padding([.top, .trailing, .bottom], 6)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(t.ink.opacity(0.85)).frame(width: 28, height: 4)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(t.ink.opacity(0.12)).frame(width: 18, height: 13)
                    RoundedRectangle(cornerRadius: 2).strokeBorder(t.accent, lineWidth: 1.5).frame(width: 18, height: 13)
                    RoundedRectangle(cornerRadius: 2).fill(t.editor).frame(width: 18, height: 13)
                }
            }
            .padding(.leading, 31).padding(.top, 13)
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in Capsule().fill(t.ink.opacity(i == 0 ? 0.5 : 0.2)).frame(width: 12, height: 3) }
            }
            .padding(.leading, 6).padding(.top, 14)
        }
        .frame(height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hairline, lineWidth: 1))
    }

    func dot(_ c: Color, on: Bool, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Circle().fill(c).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(ink.opacity(0.85), lineWidth: on ? 2 : 0).padding(-4))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(Squish()).help(help)
    }
}

/// Text and icons that sit on the accent: dark on light accents (Onyx, Arctic, Dusk), white on the rest.
var onAccent: Color { ThemeStore.shared.onAccent }

/// A settings row: label on the left, switch on the right, full width. (The stock switch style hugs its
/// label, which centered every toggle row.)
struct RowToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).tint(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The standard loading ring, in whatever color sits on its button.
struct Spinner: View {
    var color: Color
    var size: CGFloat = 13
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.75).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
