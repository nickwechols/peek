// Peek: the screenshot app your Mac deserves.
//
// Model of the whole app in one sentence: a blue ring means "this is on your clipboard".
// Every capture is copied and slides into a small tray. Click a screenshot to copy it,
// Command-click to copy several in order, double-click to mark it up. The tray hides
// itself when you are done. The Library works exactly the same way.
import AppKit
import AVFoundation
import SwiftUI
import Carbon.HIToolbox
import CoreImage
import ServiceManagement
import CoreServices
import UniformTypeIdentifiers

// MARK: - Entry

@main
struct PeekMain {
    static var delegate: AppDelegate?
    @MainActor static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }
}

// MARK: - Design tokens

let palette: [Color] = [
    Color(red: 1.0, green: 0.27, blue: 0.23),
    Color(red: 1.0, green: 0.78, blue: 0.0),
    Color(red: 0.2, green: 0.8, blue: 0.4),
    Color(red: 0.04, green: 0.52, blue: 1.0),
    Color(white: 0.98),
    Color(white: 0.1),
]

/// The website's type, bundled with the app (Geist, SIL Open Font License). Used for the setup wizard and
/// Library headings; small working UI stays on the system font. Falls back to the system font when run unbundled.
enum Brand {
    static func registerFonts() {
        for n in ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold"] {
            if let u = Bundle.main.url(forResource: n, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
        }
    }
    static func font(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        let name = w == .bold || w == .heavy || w == .black ? "Geist-Bold"
            : (w == .semibold ? "Geist-SemiBold" : (w == .medium ? "Geist-Medium" : "Geist-Regular"))
        return .custom(name, size: size)
    }
}
let snappy = Animation.spring(response: 0.3, dampingFraction: 0.8)
let soft = Animation.spring(response: 0.5, dampingFraction: 0.86)
let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
let sizeSteps: [CGFloat] = [0.65, 1.0, 1.6]

struct Pop: ViewModifier {
    var s: CGFloat, b: CGFloat, o: Double, y: CGFloat = 0, a: UnitPoint = .center
    func body(content: Content) -> some View {
        content.scaleEffect(s, anchor: a).blur(radius: b).opacity(o).offset(y: y)
    }
    static let rest = Pop(s: 1, b: 0, o: 1)
}

extension AnyTransition {
    static var pop: AnyTransition { .modifier(active: Pop(s: 0.5, b: 6, o: 0), identity: .rest) }
}

struct Squish: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let style = TrayLook.style
        return content
            .background(shape.fill(editorPanel.opacity(style == "solid" ? 1 : (style == "clear" ? 0.22 : 0.5))))
            .background(style == "solid" ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial), in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            .background(ShapeShadow(shape: shape, color: .black.opacity(0.32), radius: 20, y: 10))
    }
}

/// A shadow cast by a shape, not by the view's contents. SwiftUI's .shadow re-rasterizes the alpha of
/// everything inside it whenever any child animates; this one only redraws when the shape's size changes.
/// The interior is punched out so translucent glass above it stays clear.
struct ShapeShadow<S: Shape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    var y: CGFloat = 0
    var body: some View {
        shape.fill(Color.black)
            .shadow(color: color, radius: radius, y: y)
            .mask(Rectangle().padding(-radius * 3)
                .overlay(shape.padding(radius * 3).blendMode(.destinationOut))
                .compositingGroup())
            .allowsHitTesting(false)
    }
}

extension View {
    func glass(_ r: CGFloat) -> some View { modifier(Glass(radius: r)) }
}

/// A round glass icon button with a generous hit target.
struct RoundButton: View {
    let symbol: String
    var help = ""
    var size: CGFloat = 26
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(Squish())
        .help(help)
    }
}

struct OrderBadge: View {
    let n: Int?
    var body: some View {
        ZStack {
            Circle().fill(accent)
            if let n {
                Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(onAccent)
            } else {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(onAccent)
            }
        }
        .frame(width: 21, height: 21)
        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var value: T
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let light = scheme == .light
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let v = options[i].0
                Button { withAnimation(snappy) { value = v } } label: {
                    Text(options[i].1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(value == v ? onAccent : ink.opacity(0.62))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if value == v {
                                Capsule().fill(accent).shadow(color: .black.opacity(light ? 0.12 : 0.3), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(Squish())
            }
        }
        .padding(3)
        .background(Capsule().fill(ink.opacity(light ? 0.06 : 0.09)))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Preferences

enum TrayPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    var isTop: Bool { rawValue.hasPrefix("top") }
    var col: Int { rawValue.hasSuffix("Left") ? 0 : (rawValue.hasSuffix("Center") ? 1 : 2) }
    var alignment: Alignment {
        let h: [HorizontalAlignment] = [.leading, .center, .trailing]
        return Alignment(horizontal: h[col], vertical: isTop ? .top : .bottom)
    }
    var unit: UnitPoint {
        let xs: [CGFloat] = [0, 0.5, 1]
        return UnitPoint(x: xs[col], y: isTop ? 0 : 1)
    }
    static var current: TrayPosition {
        TrayPosition(rawValue: UserDefaults.standard.string(forKey: "position") ?? "") ?? .bottomCenter
    }
}

enum Prefs {
    static var shutterSound: Bool { UserDefaults.standard.object(forKey: "shutterSound") as? Bool ?? true }
    static var dismissAfter: Int { UserDefaults.standard.object(forKey: "dismissAfter") as? Int ?? 30 }
    static var watchNative: Bool { UserDefaults.standard.object(forKey: "watchNative") as? Bool ?? true }
}

/// Peek captures through screencapture -x, which is silent, so it plays its own shutter.
/// Loaded once at launch (a 0.26s PCM file) so the first click is as fast as the rest.
@MainActor enum Shutter {
    private static let sound: NSSound? = Bundle.main.url(forResource: "shutter", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: false) }
    static func prepare() { _ = sound }
    static func play(force: Bool = false) {
        guard force || Prefs.shutterSound, let sound else { return }
        sound.stop()
        sound.play()
    }
}

func setNativeThumbnail(hidden: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "defaults write com.apple.screencapture show-thumbnail -bool \(hidden ? "false" : "true"); killall SystemUIServer"]
    try? p.run()
}

// MARK: - Model

enum Tool: String, CaseIterable {
    case arrow, rect, pen, highlight, text, step, redact
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .redact: return "eye.slash"
        }
    }
    var key: String {
        switch self {
        case .arrow: return "a"
        case .rect: return "r"
        case .pen: return "p"
        case .highlight: return "h"
        case .text: return "t"
        case .step: return "n"
        case .redact: return "b"
        }
    }
    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .rect: return "Box"
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .step: return "Number"
        case .redact: return "Blur"
        }
    }
}

struct Mark: Identifiable, Equatable {
    var id = UUID()
    var tool: Tool
    var color: Int
    var pts: [CGPoint]
    var text = ""
    var n = 0
    var scale: CGFloat = 1
}

/// Thumbnails are decoded once at this size: sharp on the tray (168pt @2x) and library tiles, a few hundred KB each.
let thumbOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 520,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
let imageWork = DispatchQueue(label: "peek.image", qos: .userInitiated, attributes: .concurrent)

/// A screenshot holds encoded bytes plus a small thumbnail. The full-resolution bitmap only exists while
/// the editor is open, so a session of thirty captures costs a few MB of PNG data, not gigabytes of pixels.
final class Shot: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    /// The capture as taken, before any markup. The editor always starts from this, so marks stay editable.
    let source: Data
    /// What goes on the clipboard: PNG bytes of the current image. Copying hands these over as-is, never re-encoding.
    var png: Data
    let pixelSize: CGSize
    @Published var thumb: NSImage
    var marks: [Mark] = []

    /// Decodes on the calling thread, so call it off the main thread (see `load`).
    init?(data: Data, url: URL) {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let t = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions) else { return nil }
        let isPNG = (CGImageSourceGetType(src) as String?) == "public.png"
        guard let png = isPNG ? data : CGImageSourceCreateImageAtIndex(src, 0, nil).flatMap({ Clip.png($0) }) else { return nil }
        self.url = url
        source = png
        self.png = png
        pixelSize = CGSize(width: w, height: h)
        thumb = NSImage(cgImage: t, size: NSSize(width: t.width, height: t.height))
    }

    /// Decode and thumbnail off the main thread; `done` runs on the main thread the moment the shot is ready.
    /// With `save`, the PNG is written to disk afterwards and `saved` fires once it is there.
    static func load(_ read: @escaping () -> Data?, url: URL, save: Bool = false,
                     done: @escaping @MainActor (Shot?) -> Void, saved: (@MainActor () -> Void)? = nil) {
        imageWork.async {
            let shot = read().flatMap { Shot(data: $0, url: url) }
            Task { @MainActor in done(shot) }
            guard save, let shot else { return }
            try? shot.png.write(to: url, options: .atomic)
            ThumbCache.shared.put(url, thumb: shot.thumb)
            if let saved { Task { @MainActor in saved() } }
        }
    }

    /// Full-resolution decode, forced now rather than lazily at first draw. Call off the main thread.
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func thumbnail(_ cg: CGImage) -> NSImage {
        let k = min(1, 520 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * k), h = Int(CGFloat(cg.height) * k)
        // Keep the capture's own color space (usually Display P3) so thumbnails match the real thing.
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }
}

/// Library thumbnails, decoded off the main thread on demand and kept within a fixed memory budget.
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.totalCostLimit = 96 << 20 }

    private func key(_ u: URL, _ d: Date) -> NSString { "\(u.path)|\(d.timeIntervalSinceReferenceDate)" as NSString }
    private func cost(_ i: NSImage) -> Int { Int(i.size.width * i.size.height * 4) }
    private func modified(_ u: URL) -> Date? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    func cached(_ u: URL, _ d: Date) -> NSImage? { cache.object(forKey: key(u, d)) }
    /// Seed with a thumbnail we already have (fresh captures, markup renders), so the Library never decodes them again.
    func put(_ u: URL, thumb: NSImage) {
        guard let d = modified(u) else { return }
        cache.setObject(thumb, forKey: key(u, d), cost: cost(thumb))
    }
    func load(_ u: URL, _ d: Date) async -> NSImage? {
        if let t = cached(u, d) { return t }
        if isVideoFile(u) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 520, height: 520)
            guard let r = try? await gen.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)) else { return nil }
            let img = NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
            cache.setObject(img, forKey: key(u, d), cost: cost(img))
            return img
        }
        return await withCheckedContinuation { c in
            imageWork.async {
                guard let src = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions) else { c.resume(returning: nil); return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.cache.setObject(img, forKey: self.key(u, d), cost: self.cost(img))
                c.resume(returning: img)
            }
        }
    }
}

// MARK: - Clipboard

/// Clipboard data produced on demand. The pasteboard advertises the type immediately and asks for the bytes
/// only when an app actually pastes. Whoever needs them first (a paste, or warm-up work) runs `make` once.
final class Promise: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let url: URL?
    private let make: () -> Data?
    private var cached: Data?
    private var done = false
    private let lock = NSLock()
    init(url: URL?, _ make: @escaping () -> Data?) { self.url = url; self.make = make }
    func data() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if !done { cached = make(); done = true }
        return cached
    }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let d = data() { item.setData(d, forType: type) }
    }
}

enum Clip {
    /// ImageIO encode: faster than NSBitmapImageRep and keeps the color profile.
    static func png(_ cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, cg, nil)
        return CGImageDestinationFinalize(d) ? out as Data : nil
    }
    /// PNG files are handed over byte for byte; anything else is converted once.
    static func fileData(_ u: URL) -> Data? {
        if u.pathExtension.lowercased() == "png" { return try? Data(contentsOf: u, options: .mappedIfSafe) }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return png(cg)
    }

    /// Promises we still owe the pasteboard. Held strongly here, and settled for real if Peek quits.
    private static var owed: [Promise] = []
    private static var owedChange = -1

    static func copy(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        owed = []
    }
    /// One image goes on the clipboard as image data. Several go as files, in order,
    /// which is what chat apps, Figma and Finder accept for a multi-image paste.
    static func copy(files: [(URL, Data)]) {
        guard files.count > 1 else { if let f = files.first { copy(f.1) }; return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = files.map { f in
            let it = NSPasteboardItem()
            it.setData(f.1, forType: .png)
            it.setString(f.0.absoluteString, forType: .fileURL)
            return it
        }
        pb.writeObjects(items)
        owed = []
    }
    /// Instant copy: nothing is read or encoded until someone pastes.
    @discardableResult static func copy(promises: [Promise]) -> [Promise] {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = promises.map { p in
            let it = NSPasteboardItem()
            if let u = p.url, promises.count > 1 { it.setString(u.absoluteString, forType: .fileURL) }
            it.setDataProvider(p, forTypes: [.png])
            return it
        }
        pb.writeObjects(items)
        owed = promises
        owedChange = pb.changeCount
        return promises
    }
    /// Called at quit: a promise cannot be kept by an app that is gone, so hand over real bytes.
    static func settle() {
        guard !owed.isEmpty, NSPasteboard.general.changeCount == owedChange else { return }
        let list = owed
        if list.count == 1 { if let d = list[0].data() { copy(d) }; return }
        copy(files: list.compactMap { p in p.url.flatMap { u in p.data().map { (u, $0) } } })
    }
}

// MARK: - Geometry and drawing

@MainActor func fitSize(_ s: CGSize, in b: CGSize) -> CGSize {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let k = min(max(b.width, 1) / s.width, max(b.height, 1) / s.height, 1 / scale)
    return CGSize(width: max(1, s.width * k), height: max(1, s.height * k))
}

func unit(_ s: CGSize) -> CGFloat { max(s.width, s.height) / 260 }

func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

func segDist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let l2 = dx * dx + dy * dy
    var t: CGFloat = l2 == 0 ? 0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2
    t = max(0, min(1, t))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Creating a CIContext costs tens of milliseconds, so the app keeps one.
let ciContext = CIContext(options: [.cacheIntermediates: false])

func pixelate(_ cg: CGImage) -> NSImage {
    let size = NSSize(width: cg.width, height: cg.height)
    let ci = CIImage(cgImage: cg)
    guard let f = CIFilter(name: "CIPixellate") else { return NSImage(cgImage: cg, size: size) }
    f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
    f.setValue(max(size.width, size.height) / 70, forKey: kCIInputScaleKey)
    guard let out = f.outputImage?.cropped(to: ci.extent),
          let r = ciContext.createCGImage(out, from: ci.extent) else { return NSImage(cgImage: cg, size: size) }
    return NSImage(cgImage: r, size: size)
}

func smooth(_ p: [CGPoint]) -> Path {
    var path = Path()
    guard let f = p.first else { return path }
    path.move(to: f)
    if p.count < 3 { p.dropFirst().forEach { path.addLine(to: $0) }; return path }
    for i in 1..<(p.count - 1) {
        let mid = CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
        path.addQuadCurve(to: mid, control: p[i])
    }
    path.addLine(to: p[p.count - 1])
    return path
}

func arrowPath(_ a: CGPoint, _ b: CGPoint, w: CGFloat) -> Path {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(hypot(dx, dy), 0.001)
    let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
    let hl = min(w * 4.2, len * 0.6), hw = w * 2.0
    let base = CGPoint(x: b.x - ux * hl, y: b.y - uy * hl)
    func pt(_ o: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: o.x + nx * k, y: o.y + ny * k) }
    var p = Path()
    p.move(to: pt(a, w * 0.22))
    p.addLine(to: pt(base, w * 0.5))
    p.addLine(to: pt(base, hw))
    p.addLine(to: b)
    p.addLine(to: pt(base, -hw))
    p.addLine(to: pt(base, -w * 0.5))
    p.addLine(to: pt(a, -w * 0.22))
    p.closeSubpath()
    return p
}

func drawMarks(_ ctx: GraphicsContext, size: CGSize, marks: [Mark], pixelated: Image?) {
    let u0 = unit(size)
    for m in marks {
        var g = ctx
        let u = u0 * m.scale
        let c = palette[m.color]
        let P = m.pts.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let shadow = GraphicsContext.Filter.shadow(color: .black.opacity(0.3), radius: u0 * 0.8, x: 0, y: u0 * 0.25)
        switch m.tool {
        case .redact:
            guard P.count == 2 else { continue }
            let r = Path(roundedRect: box(P[0], P[1]), cornerRadius: u0 * 0.8)
            if let pixelated {
                g.clip(to: r)
                g.draw(pixelated, in: CGRect(origin: .zero, size: size))
            } else {
                g.fill(r, with: .color(Color(white: 0.55)))   // for the first few frames, before the pixelated copy is ready
            }
        case .highlight:
            g.blendMode = .multiply
            g.stroke(smooth(P), with: .color(c.opacity(0.45)),
                     style: StrokeStyle(lineWidth: u * 4.5, lineCap: .round, lineJoin: .round))
        case .pen:
            g.addFilter(shadow)
            g.stroke(smooth(P), with: .color(c), style: StrokeStyle(lineWidth: u * 1.1, lineCap: .round, lineJoin: .round))
        case .rect:
            guard P.count == 2 else { continue }
            g.addFilter(shadow)
            g.stroke(Path(roundedRect: box(P[0], P[1]), cornerRadius: u0 * 1.2, style: .continuous),
                     with: .color(c), lineWidth: u * 1.1)
        case .arrow:
            guard P.count == 2 else { continue }
            g.addFilter(shadow)
            let a = arrowPath(P[0], P[1], w: u * 1.15)
            g.fill(a, with: .color(c))
            g.stroke(a, with: .color(c), style: StrokeStyle(lineWidth: u * 0.5, lineJoin: .round))
        case .step:
            guard let p = P.first else { continue }
            let r = u * 3.4
            g.addFilter(shadow)
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(c))
            g.draw(Text("\(m.n)").font(.system(size: r * 1.1, weight: .bold, design: .rounded))
                    .foregroundColor(m.color == 4 || m.color == 1 ? .black : .white), at: p)
        case .text:
            guard let p = P.first, !m.text.isEmpty else { continue }
            g.addFilter(.shadow(color: .black.opacity(0.45), radius: u0 * 0.6, x: 0, y: u0 * 0.2))
            g.draw(Text(m.text).font(.system(size: u * 5, weight: .semibold)).foregroundColor(c), at: p, anchor: .leading)
        }
    }
}

// MARK: - Hotkeys

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var hk = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    let id = hk.id
    Task { @MainActor in HotKeys.handlers[id]?() }
    return noErr
}

@MainActor enum HotKeys {
    static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
    /// False when macOS or another app already owns the combination.
    @discardableResult static func register(_ id: UInt32, _ k: Hotkey, _ h: @escaping () -> Void) -> Bool {
        unregister(id)
        handlers[id] = h
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(k.keyCode, k.mods, EventHotKeyID(signature: OSType(0x5045_454B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }
    static func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
    }
}

// MARK: - Custom shortcuts

/// A global shortcut: Carbon key code and modifier mask, plus the label its keycap shows.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32
    var key: String

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }
    /// In the order macOS menus print them.
    static func symbols(_ mods: UInt32) -> [String] {
        var s: [String] = []
        if mods & UInt32(controlKey) != 0 { s.append("⌃") }
        if mods & UInt32(optionKey) != 0 { s.append("⌥") }
        if mods & UInt32(shiftKey) != 0 { s.append("⇧") }
        if mods & UInt32(cmdKey) != 0 { s.append("⌘") }
        return s
    }
    var symbols: [String] { Hotkey.symbols(mods) + [key] }
    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { f.insert(.control) }
        if mods & UInt32(optionKey) != 0 { f.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    static let functionKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                                 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
                                                 106: "F16", 64: "F17", 79: "F18", 80: "F19"]
    private static let named: [UInt16: String] = [49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→",
                                                  125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
    /// The keycap label for a key press, independent of the modifiers held (Shift-2 shows "2", not "@").
    static func label(_ e: NSEvent) -> String {
        if let n = functionKeys[e.keyCode] ?? named[e.keyCode] { return n }
        let c = e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? "?"
        return c.uppercased()
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case area, screen, record, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area: return "Capture an area"
        case .screen: return "Capture the screen"
        case .record: return "Record the screen"
        case .library: return "Open Library"
        }
    }
    var carbonID: UInt32 {
        switch self {
        case .area: return 1
        case .screen: return 2
        case .library: return 3
        case .record: return 4
        }
    }
    var standard: Hotkey {
        let m = UInt32(cmdKey | shiftKey)
        switch self {
        case .area: return Hotkey(keyCode: UInt32(kVK_ANSI_2), mods: m, key: "2")
        case .screen: return Hotkey(keyCode: UInt32(kVK_ANSI_1), mods: m, key: "1")
        case .library: return Hotkey(keyCode: UInt32(kVK_ANSI_L), mods: m, key: "L")
        case .record: return Hotkey(keyCode: UInt32(kVK_ANSI_0), mods: m, key: "0")   // free system-wide and in Slack, Docs, Notion and browsers
        }
    }
}

/// Owns Peek's global shortcuts and the record-a-new-one flow. While recording, every Peek shortcut is
/// switched off, so pressing the current combination is captured instead of taking a screenshot.
@MainActor final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()
    @Published private(set) var keys: [HotkeyAction: Hotkey] = [:]
    @Published private(set) var recording: HotkeyAction?
    @Published private(set) var live: [String] = []          // modifiers held right now, shown as you press them
    @Published private(set) var problem: (HotkeyAction, String)?
    @Published private(set) var shakes: [HotkeyAction: Int] = [:]
    var onChange: () -> Void = {}
    private var actions: [HotkeyAction: () -> Void] = [:]
    private var monitor: Any?
    private var resign: NSObjectProtocol?
    private var clearTask: Task<Void, Never>?

    init() {
        for a in HotkeyAction.allCases {
            keys[a] = UserDefaults.standard.data(forKey: "hotkey.\(a.rawValue)")
                .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? a.standard
        }
    }

    func key(_ a: HotkeyAction) -> Hotkey { keys[a] ?? a.standard }

    func start(_ handlers: [HotkeyAction: () -> Void]) {
        actions = handlers
        registerAll()
    }
    /// A shortcut macOS or another app already owns fails quietly, so say so in Shortcuts instead.
    private func registerAll() {
        for a in HotkeyAction.allCases {
            if let h = actions[a], !HotKeys.register(a.carbonID, key(a), h), problem == nil {
                problem = (a, "macOS or another app already uses this. Click to pick another.")
            }
        }
    }

    /// Returns a short reason when the combination cannot be used.
    @discardableResult func set(_ k: Hotkey, for a: HotkeyAction) -> String? {
        if let other = HotkeyAction.allCases.first(where: { $0 != a && key($0) == k }) { return "Already used for \(other.title)" }
        if let h = actions[a], !HotKeys.register(a.carbonID, k, h) {
            HotKeys.unregister(a.carbonID)
            return "macOS or another app already uses this"
        }
        keys[a] = k
        if let d = try? JSONEncoder().encode(k) { UserDefaults.standard.set(d, forKey: "hotkey.\(a.rawValue)") }
        onChange()
        return nil
    }
    func reset(_ a: HotkeyAction) {
        withAnimation(bouncy) { _ = set(a.standard, for: a) }
    }

    func record(_ a: HotkeyAction) {
        stop()
        for x in HotkeyAction.allCases { HotKeys.unregister(x.carbonID) }
        withAnimation(snappy) { recording = a; live = []; problem = nil }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] e in
            self?.handle(e) ?? e
        }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resign { NotificationCenter.default.removeObserver(resign) }
        monitor = nil; resign = nil
        guard recording != nil else { return }
        withAnimation(snappy) { recording = nil; live = [] }
        registerAll()
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let a = recording else { return e }
        switch e.type {
        case .leftMouseDown:
            stop()                       // clicking anywhere else cancels
            return e
        case .flagsChanged:
            let syms = Hotkey.symbols(Hotkey.carbon(e.modifierFlags))
            if syms != live { withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { live = syms } }
            return nil
        case .keyDown:
            let mods = Hotkey.carbon(e.modifierFlags.intersection(.deviceIndependentFlagsMask))
            if e.keyCode == UInt16(kVK_Escape) && mods == 0 { stop(); return nil }
            let fn = Hotkey.functionKeys[e.keyCode] != nil
            guard fn || mods & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                fail(a, "Add ⌘, ⌥ or ⌃ so it doesn't clash with typing"); return nil
            }
            let k = Hotkey(keyCode: UInt32(e.keyCode), mods: mods, key: Hotkey.label(e))
            var reason: String?
            withAnimation(bouncy) { reason = set(k, for: a) }
            if let reason { fail(a, reason); return nil }
            stop()
            return nil
        default:
            return e
        }
    }

    /// Keeps recording so the next try is one keystroke away; the field shakes and says why.
    private func fail(_ a: HotkeyAction, _ reason: String) {
        withAnimation(snappy) { problem = (a, reason); live = [] }
        withAnimation(.linear(duration: 0.42)) { shakes[a, default: 0] += 1 }
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(soft) { self.problem = nil }
        }
    }
}

/// Side-to-side shake for a rejected shortcut.
struct Shake: GeometryEffect {
    var t: CGFloat
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(t * .pi * 6), y: 0))
    }
}

/// Click to record. While recording the field shows a caret and "Press a shortcut", the modifiers you hold
/// appear as keycaps, and the first full combination is saved. Esc or a click elsewhere cancels.
struct ShortcutField: View {
    let action: HotkeyAction
    @ObservedObject var sc: Shortcuts
    @State private var hover = false
    @State private var caret = false

    var body: some View {
        let rec = sc.recording == action
        let k = sc.key(action)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 6) {
            if hover && !rec && k != action.standard {
                Button { sc.reset(action) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.45)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(Squish())
                .help("Reset to " + action.standard.symbols.joined(separator: " "))
                .transition(.opacity)
            }
            Button { rec ? sc.stop() : sc.record(action) } label: {
                Group {
                    if rec {
                        HStack(spacing: 5) {
                            ForEach(Array(sc.live.enumerated()), id: \.offset) { Keycap(k: $0.element).transition(.pop) }
                            Capsule().fill(accent).frame(width: 2, height: 16).opacity(caret ? 1 : 0.15)
                            if sc.live.isEmpty {
                                Text("Press a shortcut").font(Brand.font(13, .medium)).foregroundStyle(ink.opacity(0.42))
                            }
                        }
                        .padding(.horizontal, 12).frame(minWidth: 158, minHeight: 36, alignment: .leading)
                        .background(shape.fill(.white))
                        .overlay(shape.strokeBorder(accent, lineWidth: 2))
                        .shadow(color: accent.opacity(0.22), radius: 10)
                        .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { caret = true } }
                        .onDisappear { caret = false }
                    } else {
                        HStack(spacing: 5) {
                            ForEach(Array(k.symbols.enumerated()), id: \.offset) { Keycap(k: $0.element) }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 2).frame(minHeight: 36)
                        .background(shape.fill(Color.black.opacity(hover ? 0.045 : 0)))
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .modifier(Shake(t: CGFloat(sc.shakes[action, default: 0])))
            .help(rec ? "Press Esc to cancel" : "Click to change")
        }
        .onHover { h in withAnimation(snappy) { hover = h } }
        .animation(snappy, value: rec)
    }
}

// MARK: - Capture

@MainActor enum Capture {
    static let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Peek")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// screencapture hands the image straight to the pasteboard (-c), so the tray can show it the
    /// instant the selection ends. The file is written afterwards, off the main thread.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
    /// `done` gets the image bytes and whether they are already on the clipboard as PNG (so nothing re-copies them).
    static func run(_ args: [String], done: @escaping (Data?, URL, Bool) -> Void) {
        let url = dir.appendingPathComponent("Peek \(stamp.string(from: Date())).png")
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args + ["-c"]
        p.terminationHandler = { _ in
            Task { @MainActor in
                guard pb.changeCount != before else { done(nil, url, false); return }   // cancelled with Esc
                if pb.availableType(from: [.png]) != nil, let png = pb.data(forType: .png) { done(png, url, true); return }
                done(pb.data(forType: .tiff), url, false)   // converted to PNG off the main thread by Shot.load
            }
        }
        do { try p.run() } catch { done(nil, url, false) }
    }
}

/// Catches screenshots taken with the built-in macOS shortcuts so they get copied too.
/// FSEvents on the screenshot folder fires within a few milliseconds of macOS finishing the file,
/// where a Spotlight query can lag by seconds.
@MainActor final class SystemWatcher: NSObject {
    var onNew: (URL) -> Void = { _ in }
    private var stream: FSEventStreamRef?
    private var seen = Set<String>()
    private let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    static var folder: URL {
        let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = raw.map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func start() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<SystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) {
                let p = list[i], f = flags[i]
                Task { @MainActor in me.consider(p, f) }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [Self.folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.01, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func consider(_ p: String, _ f: FSEventStreamEventFlags) {
        let name = (p as NSString).lastPathComponent
        let made = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
        guard !name.hasPrefix("."), f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0, f & made != 0,
              exts.contains((p as NSString).pathExtension.lowercased()), !seen.contains(p),
              let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let born = attrs[.creationDate] as? Date, Date().timeIntervalSince(born) < 15,
              Self.isScreenshot(p) else { return }
        seen.insert(p)
        onNew(URL(fileURLWithPath: p))
    }

    /// macOS tags its own screenshots with this attribute; the name check covers older systems.
    private static func isScreenshot(_ p: String) -> Bool {
        if getxattr(p, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let n = (p as NSString).lastPathComponent
        return n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot")
    }
}

// MARK: - Tray (the floating preview)

let maxThumbs = 5
let trayMargin: CGFloat = 24
let headerH: CGFloat = 38

@MainActor final class Tray: ObservableObject {
    @Published var shots: [Shot] = []          // oldest first, newest on the end
    @Published var visible = false
    @Published var hovering = false
    @Published var resting = false
    @Published var copied: [UUID] = []        // what is on the clipboard, in paste order
    @Published var flash: UUID?
    @Published var position: TrayPosition = .bottomCenter
    var shown: [Shot] { Array(shots.suffix(maxThumbs)) }
    var overflow: Int { max(0, shots.count - maxThumbs) }
}

struct TrayActions {
    var markup: (Shot) -> Void
    var openLibrary: () -> Void
}

/// Hosting view that reports hover even though the panel never becomes key.
final class TrayHost<C: View>: NSHostingView<C> {
    var onHover: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.userInfo?["peek"] != nil { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["peek": true]))
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
}

@MainActor final class TrayController: NSObject {
    let tray = Tray()
    let actions: TrayActions
    let panel: NSPanel
    private var screen: NSScreen?
    private var restTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init(actions: TrayActions) {
        self.actions = actions
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let host = TrayHost(rootView: TrayView(t: tray, c: self))
        host.onHover = { [weak self] h in self?.hover(h) }
        panel.contentView = host
    }

    // Layout: the panel hugs the tray, so nothing invisible ever blocks clicks.
    private func size(for count: Int) -> CGSize {
        let n = min(count, maxThumbs)
        let extra: CGFloat = count > maxThumbs ? 52 : 0
        let plateW = 16 + CGFloat(n) * thumbW + CGFloat(max(n - 1, 0)) * 8 + extra
        return CGSize(width: max(plateW, 290) + trayMargin * 2, height: thumbH + 16 + headerH + 8 + trayMargin * 2)
    }

    private func place(count: Int) {
        let s = size(for: count)
        let scr = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = scr.visibleFrame
        let p = tray.position
        let inset: CGFloat = 10 - trayMargin
        let x: CGFloat = p.col == 0 ? vf.minX + inset : (p.col == 1 ? vf.midX - s.width / 2 : vf.maxX - s.width - inset)
        let y: CGFloat = p.isTop ? vf.maxY - s.height - inset : vf.minY + inset
        panel.setFrame(NSRect(x: x, y: y, width: s.width, height: s.height), display: true)
    }

    func add(_ shot: Shot) {
        let fresh = !tray.visible
        if fresh {
            tray.shots = []
            tray.position = .current
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        }
        place(count: tray.shots.count + 1)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        Task { @MainActor [weak self] in
            guard let self else { return }
            withAnimation(bouncy) {
                self.tray.shots.append(shot)
                self.tray.visible = true
                self.tray.resting = false
                self.tray.copied = [shot.id]
            }
            self.flash(shot.id)
        }
        scheduleIdle()
    }

    func hover(_ h: Bool) {
        withAnimation(soft) {
            tray.hovering = h
            if h { tray.resting = false }
        }
        if h { restTask?.cancel(); dismissTask?.cancel() } else { scheduleIdle() }
    }

    /// After a few quiet seconds the tray settles down a little; after the user's
    /// chosen delay it leaves. Hovering pauses both.
    private func scheduleIdle() {
        restTask?.cancel(); dismissTask?.cancel()
        restTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled, !self.tray.hovering else { return }
            withAnimation(soft) { self.tray.resting = true }
        }
        let secs = Prefs.dismissAfter
        guard secs > 0 else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.tray.hovering else { return }
            self.hide()
        }
    }

    func hide() {
        restTask?.cancel(); dismissTask?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            tray.visible = false
            tray.hovering = false
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !self.tray.visible else { return }
            self.panel.orderOut(nil)
            self.tray.shots = []
            self.tray.copied = []
        }
    }

    func remove(_ s: Shot) {
        if tray.shots.count <= 1 { hide(); return }
        withAnimation(snappy) {
            tray.shots.removeAll { $0.id == s.id }
            tray.copied.removeAll { $0 == s.id }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let self else { return }
            self.place(count: self.tray.shots.count)
        }
    }

    func setCapturing(_ c: Bool) { panel.alphaValue = c ? 0 : 1 }

    // Copying. Plain click copies one. Command- or Shift-click builds an ordered set.
    func click(_ s: Shot) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) || mods.contains(.shift) {
            var c = tray.copied
            if let i = c.firstIndex(of: s.id) { c.remove(at: i) } else { c.append(s.id) }
            copy(ids: c.isEmpty ? [s.id] : c)
        } else {
            copy(ids: [s.id])
        }
        flash(s.id)
    }

    /// What the tray header is talking about: the picked screenshots in paste order, otherwise the whole tray.
    /// Files are written lazily, so make sure each one exists before handing it to the share menu.
    func shareURLs() -> [URL] {
        let ids = tray.copied.count > 1 ? tray.copied : tray.shots.map(\.id)
        let list = ids.compactMap { id in tray.shots.first { $0.id == id } }
        for s in list where !FileManager.default.fileExists(atPath: s.url.path) { try? s.png.write(to: s.url, options: .atomic) }
        return list.map(\.url)
    }

    func copyAll() {
        copy(ids: tray.shots.map(\.id))
        if let last = tray.shots.last { flash(last.id) }
    }

    func markCopied(_ s: Shot) {
        guard tray.shots.contains(where: { $0.id == s.id }) else { return }
        withAnimation(snappy) { tray.copied = [s.id] }
    }

    private func copy(ids: [UUID]) {
        let list = ids.compactMap { id in tray.shots.first { $0.id == id } }
        Clip.copy(files: list.map { ($0.url, $0.png) })
        withAnimation(bouncy) { tray.copied = ids }
    }

    private func flash(_ id: UUID) {
        withAnimation(bouncy) { tray.flash = id }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard let self, self.tray.flash == id else { return }
            withAnimation(soft) { self.tray.flash = nil }
        }
    }
}

struct TrayView: View {
    @ObservedObject var t: Tray
    let c: TrayController

    var body: some View {
        let top = t.position.isTop
        VStack(spacing: 8) {
            if !top { header }
            plate
            if top { header }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: t.position.alignment)
        .padding(trayMargin)
    }

    @ViewBuilder var plate: some View {
        if t.visible {
            HStack(spacing: 8) {
                if t.overflow > 0 {
                    Text("+\(t.overflow)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 44, height: thumbH)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
                        .help("Older screenshots from this session are in your Library")
                        .onTapGesture { c.actions.openLibrary() }
                }
                ForEach(t.shown) { s in
                    ThumbView(shot: s, t: t, c: c)
                        .transition(.asymmetric(
                            insertion: .modifier(active: Pop(s: 0.6, b: 14, o: 0), identity: .rest),
                            removal: .modifier(active: Pop(s: 0.75, b: 10, o: 0), identity: .rest)))
                }
            }
            .padding(8)
            .glass(20)
            .scaleEffect(t.resting ? 0.9 : 1, anchor: t.position.unit)
            .opacity(t.resting ? 0.88 : 1)
            .transition(.modifier(active: Pop(s: 0.82, b: 18, o: 0, y: t.position.isTop ? -40 : 40), identity: .rest))
        }
    }

    /// Built only while hovering. A hidden-but-present header would keep a blur filter alive on every frame.
    var header: some View {
        ZStack {
            if t.hovering && t.visible {
                headerBar.transition(.modifier(active: Pop(s: 0.9, b: 6, o: 0, a: t.position.unit), identity: .rest))
            }
        }
        .frame(height: headerH)
    }

    var headerBar: some View {
        HStack(spacing: 2) {
            Text(t.shots.count == 1 ? "Copied" : (t.copied.count > 1 ? "\(t.copied.count) copied" : "\(t.shots.count) screenshots"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
            if t.shots.count > 1 {
                Button { c.copyAll() } label: {
                    Label("Copy all", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(onAccent)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(Squish())
                .help("Copy every screenshot in the tray, oldest first")
            }
            ShareIcon(tint: .white, size: CGSize(width: 30, height: 26),
                      help: t.copied.count > 1 ? "Share \(t.copied.count) or AirDrop" : (t.shots.count > 1 ? "Share all or AirDrop" : "Share or AirDrop")) { r in
                Export.share(c.shareURLs(), from: r)
            }
            Button { c.actions.openLibrary() } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(Squish()).help("Open Library")
            Button { c.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(Squish()).help("Clear the tray. Screenshots stay in your Library.")
        }
        .padding(4)
        .glass(999)
        .environment(\.colorScheme, .dark)
    }
}

struct ThumbView: View {
    @ObservedObject var shot: Shot
    @ObservedObject var t: Tray
    let c: TrayController

    var body: some View {
        let order = t.copied.firstIndex(of: shot.id)
        let on = order != nil
        Color.clear
            .frame(width: thumbW, height: thumbH)
            .overlay(Image(nsImage: shot.thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fill))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? accent : Color.white.opacity(0.14), lineWidth: on ? 2.5 : 0.5))
            .overlay(alignment: .topLeading) {
                if let order, t.copied.count > 1 { OrderBadge(n: order + 1).padding(6).transition(.pop) }
            }
            .overlay {
                if t.flash == shot.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(onAccent)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(accent))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .transition(.modifier(active: Pop(s: 0.3, b: 4, o: 0), identity: .rest))
                }
            }
            .overlay(alignment: .topTrailing) {
                if t.hovering { RoundButton(symbol: "xmark", help: "Remove from tray") { c.remove(shot) }.padding(2).transition(.pop) }
            }
            .overlay(alignment: .bottomTrailing) {
                if t.hovering { RoundButton(symbol: "pencil.tip", help: "Mark up") { c.actions.markup(shot) }.padding(2).transition(.pop) }
            }
            .scaleEffect(on && t.copied.count > 1 ? 0.97 : 1)
            .contentShape(Rectangle())
            .onTapGesture { c.click(shot) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { c.actions.markup(shot) })
            .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
            .help("Click to copy. Command-click to copy several. Double-click to mark up. Drag into any app.")
    }
}

// MARK: - Editor

enum DragMode {
    case none, idle, draw
    case move(UUID, CGPoint)
    case handle(UUID, Int)
    case scale(UUID, CGFloat, CGFloat)
}

@MainActor final class EditorModel: ObservableObject {
    let shot: Shot
    /// Opens on the tray thumbnail (already decoded), then swaps to full resolution a moment later,
    /// so the window never waits on a 5K decode.
    @Published var base: NSImage
    /// Only the Blur tool needs this; it is prepared in the background after the window opens.
    @Published var pixelated: NSImage?
    private var full: CGImage?
    @Published var marks: [Mark] { didSet { scheduleRender() } }
    @Published var tool: Tool = .arrow
    @Published var color = 0
    @Published var scale: CGFloat = 1
    @Published var draft: Mark?
    @Published var selectedID: UUID?
    @Published var editingID: UUID?
    @Published var savedPulse = 0
    @Published var paletteOpen = false
    var onCopied: (Shot) -> Void = { _ in }
    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    private var mode: DragMode = .none
    private var wasSelected: UUID?
    private var renderTask: Task<Void, Never>?
    private var dirty = false
    private var dragging: Bool { if case .none = mode { return false }; return true }

    init(shot: Shot) {
        self.shot = shot
        base = shot.thumb
        marks = shot.marks
        let src = shot.source
        imageWork.async { [weak self] in
            guard let cg = Shot.decode(src) else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            Task { @MainActor in self?.full = cg; self?.base = image }
            let px = pixelate(cg)
            Task { @MainActor in self?.pixelated = px }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var selected: Mark? { selectedID.flatMap { id in marks.first { $0.id == id } } }

    private func index(_ id: UUID?) -> Int? { id.flatMap { id in marks.firstIndex { $0.id == id } } }
    private func norm(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / s.width, 0), 1), y: min(max(p.y / s.height, 0), 1))
    }
    private func px(_ p: CGPoint, _ s: CGSize) -> CGPoint { CGPoint(x: p.x * s.width, y: p.y * s.height) }

    // Geometry used for selection, hit-testing and handles.
    func bounds(_ m: Mark, _ s: CGSize) -> CGRect {
        let u = unit(s) * m.scale
        let P = m.pts.map { px($0, s) }
        guard let p0 = P.first else { return .zero }
        switch m.tool {
        case .text:
            let f = u * 5
            let w = max(CGFloat(max(m.text.count, 1)) * f * 0.55, f)
            return CGRect(x: p0.x, y: p0.y - f * 0.65, width: w, height: f * 1.3)
        case .step:
            let r = u * 3.4
            return CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2)
        default:
            let xs = P.map(\.x), ys = P.map(\.y)
            let minX = xs.min() ?? 0, minY = ys.min() ?? 0
            return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
        }
    }

    func handles(_ m: Mark, _ s: CGSize) -> [CGPoint] {
        switch m.tool {
        case .arrow, .rect, .redact: return m.pts.prefix(2).map { px($0, s) }
        case .text, .step:
            let b = bounds(m, s)
            return [CGPoint(x: b.maxX, y: b.maxY)]
        default: return []
        }
    }

    private func hits(_ m: Mark, _ p: CGPoint, _ s: CGSize) -> Bool {
        let u = unit(s) * m.scale
        let tol = max(8, u * 2.2)
        let P = m.pts.map { px($0, s) }
        switch m.tool {
        case .arrow: return P.count == 2 && segDist(p, P[0], P[1]) < tol
        case .pen, .highlight:
            let extra = m.tool == .highlight ? u * 2 : 0
            return zip(P, P.dropFirst()).contains { segDist(p, $0.0, $0.1) < tol + extra }
        case .rect:
            let r = bounds(m, s)
            return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
        default: return bounds(m, s).insetBy(dx: -6, dy: -6).contains(p)
        }
    }

    // History
    private func snapshot() {
        undoStack.append(marks)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func undo() {
        commitText()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(marks)
        selectedID = nil
        marks = last
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        marks = next
    }

    // Pointer
    func drag(_ start: CGPoint, _ cur: CGPoint, _ s: CGSize) {
        if case .none = mode { begin(start, s) }
        switch mode {
        case .draw:
            let nc = norm(cur, s)
            switch tool {
            case .pen, .highlight: draft?.pts.append(nc)
            case .step, .text: draft?.pts = [nc]
            default: if let first = draft?.pts.first { draft?.pts = [first, nc] }
            }
        case .move(let id, let last):
            guard let i = index(id) else { return }
            let d = CGPoint(x: (cur.x - last.x) / s.width, y: (cur.y - last.y) / s.height)
            marks[i].pts = marks[i].pts.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
            mode = .move(id, cur)
        case .handle(let id, let k):
            guard let i = index(id), k < marks[i].pts.count else { return }
            marks[i].pts[k] = norm(cur, s)
        case .scale(let id, let s0, let d0):
            guard let i = index(id), let p0 = marks[i].pts.first else { return }
            let a = px(p0, s)
            let d = max(hypot(cur.x - a.x, cur.y - a.y), 1)
            marks[i].scale = min(max(s0 * d / d0, 0.35), 5)
            scale = marks[i].scale
        default: break
        }
    }

    private func begin(_ p: CGPoint, _ s: CGSize) {
        wasSelected = selectedID
        if paletteOpen { withAnimation(bouncy) { paletteOpen = false } }
        if editingID != nil { commitText(); mode = .idle; return }
        if let sid = selectedID, let i = index(sid) {
            for (k, h) in handles(marks[i], s).enumerated() where hypot(h.x - p.x, h.y - p.y) < 12 {
                snapshot()
                if marks[i].tool == .text || marks[i].tool == .step {
                    let a = px(marks[i].pts[0], s)
                    mode = .scale(sid, marks[i].scale, max(hypot(h.x - a.x, h.y - a.y), 1))
                } else {
                    mode = .handle(sid, k)
                }
                return
            }
        }
        if let hit = marks.last(where: { hits($0, p, s) }) {
            snapshot()
            withAnimation(snappy) { selectedID = hit.id }
            color = hit.color
            scale = hit.scale
            mode = .move(hit.id, p)
            return
        }
        if selectedID != nil { withAnimation(snappy) { selectedID = nil } }
        draft = Mark(tool: tool, color: color, pts: [norm(p, s)], scale: scale)
        mode = .draw
    }

    func end(_ start: CGPoint, _ cur: CGPoint, _ s: CGSize) {
        defer { mode = .none; if dirty { scheduleRender() } }
        let moved = hypot(start.x - cur.x, start.y - cur.y) > 3
        switch mode {
        case .draw:
            guard var d = draft else { return }
            draft = nil
            switch d.tool {
            case .step:
                d.n = (marks.filter { $0.tool == .step }.map(\.n).max() ?? 0) + 1
                push(d)
            case .text:
                push(d)
                editingID = d.id
            case .pen, .highlight:
                if d.pts.count > 1 { push(d) }
            default:
                if moved { push(d) }
            }
        case .move(let id, _):
            if !moved, let last = undoStack.last, last == marks { undoStack.removeLast() }
            if !moved, wasSelected == id, let i = index(id), marks[i].tool == .text {
                snapshot()
                selectedID = nil
                editingID = id
            }
        default: break
        }
    }

    private func push(_ m: Mark) { snapshot(); marks.append(m) }

    // Styling applies to the selection if there is one, and becomes the default.
    func setColor(_ c: Int) {
        color = c
        if let i = index(selectedID) { snapshot(); marks[i].color = c }
    }
    func setScale(_ v: CGFloat) {
        scale = v
        if let i = index(selectedID) { snapshot(); marks[i].scale = v }
    }
    func bump(_ up: Bool) { setScale(min(max(scale * (up ? 1.2 : 1 / 1.2), 0.35), 5)) }
    func setTool(_ t: Tool) {
        withAnimation(snappy) { tool = t; selectedID = nil }
    }
    func deleteSelected() {
        guard let i = index(selectedID) else { return }
        snapshot()
        withAnimation(snappy) { selectedID = nil }
        marks.remove(at: i)
    }
    func editSelectedText() {
        guard let i = index(selectedID), marks[i].tool == .text else { return }
        snapshot()
        editingID = marks[i].id
        selectedID = nil
    }
    func setText(_ id: UUID, _ t: String) { if let i = index(id) { marks[i].text = t } }
    func commitText() {
        guard let id = editingID else { return }
        editingID = nil
        if let i = index(id), marks[i].text.trimmingCharacters(in: .whitespaces).isEmpty { marks.remove(at: i) }
    }

    // Output
    /// Re-rendering waits until the pointer is up and the edits pause, so a full-resolution render never
    /// lands in the middle of a stroke or a drag.
    private func scheduleRender() {
        dirty = true
        renderTask?.cancel()
        guard !dragging else { return }
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled else { return }
            self.renderNow()
        }
    }
    func flush() { if dirty { renderTask?.cancel(); renderNow() } }

    /// The file on disk with every mark baked in, for sharing or saving.
    func exportURL() -> URL {
        commitText()
        renderTask?.cancel()
        renderNow()
        imageWork.sync(flags: .barrier) {}
        if !FileManager.default.fileExists(atPath: shot.url.path) { try? shot.png.write(to: shot.url, options: .atomic) }
        return shot.url
    }

    /// Bakes the markup into the image and copies it. The main thread only composites; the clipboard gets a
    /// promise right away, and PNG encoding, the file write and the thumbnail happen in the background.
    func renderNow() {
        dirty = false
        guard let cg0 = full ?? Shot.decode(shot.source) else { return }
        full = cg0
        let size = shot.pixelSize
        let list = marks.filter { !($0.tool == .text && $0.text.isEmpty) }
        if pixelated == nil, list.contains(where: { $0.tool == .redact }) { pixelated = pixelate(cg0) }
        let px = pixelated.map { Image(nsImage: $0) }
        let content = ZStack {
            Image(nsImage: NSImage(cgImage: cg0, size: size)).resizable()
            Canvas { ctx, s in drawMarks(ctx, size: s, marks: list, pixelated: px) }
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: content)
        r.scale = 1
        guard let cg = r.cgImage else { return }
        let s = shot
        let promise = Promise(url: s.url) { Clip.png(cg) }
        Clip.copy(promises: [promise])
        s.marks = marks
        savedPulse += 1
        onCopied(s)
        imageWork.async {
            guard let data = promise.data() else { return }
            try? data.write(to: s.url, options: .atomic)
            let t = Shot.thumbnail(cg)
            ThumbCache.shared.put(s.url, thumb: t)
            DispatchQueue.main.async { s.png = data; s.thumb = t }
        }
    }
}

struct EditorView: View {
    @ObservedObject var m: EditorModel
    let done: () -> Void
    @Namespace private var ns
    @FocusState private var textFocus: Bool
    @State private var appeared = false
    @State private var showSaved = false
    @State private var savedTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            editorBG.ignoresSafeArea()
            GeometryReader { geo in
                let avail = CGSize(width: geo.size.width - 64, height: geo.size.height - 160)
                let fit = fitSize(m.shot.pixelSize, in: avail)
                canvas(fit)
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                    .scaleEffect(appeared ? 1 : 0.95)
                    .opacity(appeared ? 1 : 0)
                    .position(x: geo.size.width / 2, y: 44 + avail.height / 2)
            }
            VStack(spacing: 10) {
                Spacer()
                hint
                EditorToolbar(m: m, tool: m.tool, color: m.color, scale: m.scale, canUndo: m.canUndo,
                              paletteOpen: m.paletteOpen, ns: ns, done: done,
                              share: { r in Export.share([m.exportURL()], from: r) },
                              save: { Export.save([m.exportURL()], in: NSApp.keyWindow) })
                    .equatable()
                    .offset(y: appeared ? 0 : 50)
                    .opacity(appeared ? 1 : 0)
            }
            .padding(.bottom, 22)
            VStack {
                HStack {
                    Spacer()
                    if showSaved {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glass(999)
                            .transition(.pop)
                    }
                }
                .padding(.top, 10).padding(.trailing, 16)
                Spacer()
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(soft.delay(0.04)) { appeared = true } }
        .onChange(of: m.savedPulse) { _ in
            savedTask?.cancel()
            withAnimation(bouncy) { showSaved = true }
            savedTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(soft) { showSaved = false }
            }
        }
    }

    @ViewBuilder var hint: some View {
        let text: String? = m.editingID != nil ? "Type, then press Return."
            : (m.selected != nil ? "Drag to move. Drag the white dot to resize. Delete removes it." : nil)
        if let text {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .transition(.opacity)
        }
    }

    @ViewBuilder func canvas(_ fit: CGSize) -> some View {
        let u = unit(fit)
        let list = m.marks.filter { $0.id != m.editingID } + (m.draft.map { [$0] } ?? [])
        let px = m.pixelated.map { Image(nsImage: $0) }
        let sel = m.selected
        ZStack(alignment: .topLeading) {
            Image(nsImage: m.base).resizable().interpolation(.high)
            Canvas { ctx, s in drawMarks(ctx, size: s, marks: list, pixelated: px) }
            if let sel { SelectionOverlay(mark: sel, size: fit, m: m) }
            if let id = m.editingID, let mk = m.marks.first(where: { $0.id == id }), let p = mk.pts.first {
                let f = u * 5 * mk.scale
                TextField("Type", text: Binding(get: { m.marks.first(where: { $0.id == id })?.text ?? "" },
                                                set: { m.setText(id, $0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: f, weight: .semibold))
                    .foregroundColor(palette[mk.color])
                    .frame(minWidth: 120, alignment: .leading)
                    .fixedSize()
                    .focused($textFocus)
                    .onSubmit { m.commitText() }
                    .offset(x: p.x * fit.width, y: p.y * fit.height - f * 0.65)
                    .onAppear { DispatchQueue.main.async { textFocus = true } }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in m.drag(v.startLocation, v.location, fit) }
            .onEnded { v in m.end(v.startLocation, v.location, fit) })
        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }
}

/// Dashed outline, resize handles and a small floating action bar for the selected mark.
struct SelectionOverlay: View {
    let mark: Mark
    let size: CGSize
    let m: EditorModel

    var body: some View {
        let b = m.bounds(mark, size).insetBy(dx: -7, dy: -7)
        let hs = m.handles(mark, size)
        let barY = b.minY - 44 > 0 ? b.minY - 44 : b.maxY + 8
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(accent, style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                .frame(width: max(b.width, 14), height: max(b.height, 14))
                .offset(x: b.minX, y: b.minY)
                .allowsHitTesting(false)
            ForEach(hs.indices, id: \.self) { k in
                Circle().fill(.white)
                    .overlay(Circle().stroke(accent, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: hs[k].x - 6, y: hs[k].y - 6)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 0) {
                if mark.tool == .text {
                    Button { m.editSelectedText() } label: {
                        Image(systemName: "character.cursor.ibeam").frame(width: 32, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(Squish()).help("Edit text")
                }
                Button { m.bump(false) } label: {
                    Image(systemName: "minus").frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).help("Smaller  -")
                Button { m.bump(true) } label: {
                    Image(systemName: "plus").frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).help("Bigger  =")
                Button { m.deleteSelected() } label: {
                    Image(systemName: "trash").foregroundStyle(palette[0]).frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).help("Delete")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(3)
            .glass(999)
            .fixedSize()
            .offset(x: max(0, b.midX - 66), y: barY)
            .transition(.pop)
        }
    }
}

/// Takes plain values instead of observing the model. Every pointer move while drawing publishes a change;
/// with `.equatable()` the toolbar only re-renders when something it shows actually changed.
struct EditorToolbar: View, Equatable {
    let m: EditorModel
    let tool: Tool
    let color: Int
    let scale: CGFloat
    let canUndo: Bool
    let paletteOpen: Bool
    let ns: Namespace.ID
    let done: () -> Void
    var share: (ViewRef) -> Void = { _ in }
    var save: () -> Void = {}
    @Namespace private var sizeNS

    static func == (a: Self, b: Self) -> Bool {
        a.tool == b.tool && a.color == b.color && a.scale == b.scale && a.canUndo == b.canUndo && a.paletteOpen == b.paletteOpen
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases, id: \.self) { t in
                Button { m.setTool(t) } label: {
                    ZStack {
                        if tool == t { Capsule().fill(accent).matchedGeometryEffect(id: "tool", in: ns) }
                        Image(systemName: t.symbol).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tool == t ? onAccent : Color.white.opacity(0.82))
                    }
                    .frame(width: 38, height: 32).contentShape(Capsule())
                }
                .buttonStyle(Squish()).help("\(t.label)  \(t.key.uppercased())")
            }
            sep
            colorControl
            sizeControl
            sep
            Button { m.undo() } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(canUndo ? 0.85 : 0.3))
                    .frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(Squish()).disabled(!canUndo).help("Undo  ⌘Z")
            sep
            ShareIcon(tint: .white.opacity(0.85), action: share)
            Button(action: save) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(Squish()).help("Save As  ⌘S")
            Button(action: done) {
                Text("Done").font(.system(size: 13, weight: .semibold)).foregroundStyle(onAccent)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(Squish()).padding(.leading, 4).help("Done. Already copied.  Return")
        }
        .padding(5)
        .glass(999)
    }

    var sep: some View { Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 6) }

    @ViewBuilder var colorControl: some View {
        HStack(spacing: 3) {
            if paletteOpen {
                ForEach(palette.indices, id: \.self) { i in
                    Button {
                        m.setColor(i)
                        withAnimation(bouncy) { m.paletteOpen = false }
                    } label: {
                        Circle().fill(palette[i])
                            .overlay(Circle().strokeBorder(.white.opacity(color == i ? 0.95 : 0.3), lineWidth: color == i ? 2 : 0.5))
                            .frame(width: 20, height: 20)
                            .frame(width: 28, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(Squish())
                    .help("Color  \(i + 1)")
                    .transition(AnyTransition.modifier(active: Pop(s: 0.2, b: 4, o: 0), identity: .rest)
                        .animation(bouncy.delay(Double(i) * 0.025)))
                }
            } else {
                Button { withAnimation(bouncy) { m.paletteOpen = true } } label: {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 24, height: 24)
                        Circle().fill(palette[color]).frame(width: 15, height: 15)
                    }
                    .frame(width: 36, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(Squish())
                .help("Color  1-6")
                .transition(.pop)
            }
        }
    }

    var sizeControl: some View {
        HStack(spacing: 0) {
            ForEach(sizeSteps.indices, id: \.self) { i in
                let v = sizeSteps[i]
                let on = abs(scale - v) < 0.12
                let dot: CGFloat = [5, 8, 12][i]
                Button { withAnimation(snappy) { m.setScale(v) } } label: {
                    ZStack {
                        if on { Capsule().fill(.white.opacity(0.18)).matchedGeometryEffect(id: "size", in: sizeNS) }
                        Circle().fill(.white).frame(width: dot, height: dot)
                    }
                    .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(Squish())
                .help(["Small", "Medium", "Large"][i] + ". Press - or = to fine-tune.")
            }
        }
    }
}

@MainActor final class EditorController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var model: EditorModel?
    var monitor: Any?
    var onCopied: (Shot) -> Void = { _ in }
    var onClose: () -> Void = {}

    func open(_ shot: Shot) {
        if window != nil { close(hideApp: false) }
        let m = EditorModel(shot: shot)
        m.onCopied = { [weak self] s in self?.onCopied(s) }
        model = m
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let fit = fitSize(shot.pixelSize, in: CGSize(width: vf.width * 0.8 - 64, height: vf.height * 0.85 - 160))
        let size = CGSize(width: max(fit.width + 64, 760), height: max(fit.height + 160, 440))
        let w = NSWindow(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = NSColor(editorBG)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 440)
        w.delegate = self
        w.contentView = NSHostingView(rootView: EditorView(m: m, done: { [weak self] in self?.close(hideApp: true) }))
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handle(e)
        }
    }

    func handle(_ e: NSEvent) -> NSEvent? {
        guard let m = model, e.window === window else { return e }
        if m.editingID != nil {
            if e.keyCode == 53 { m.commitText(); return nil }
            return e
        }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if f.contains(.command) {
            switch ch {
            case "z": if f.contains(.shift) { m.redo() } else { m.undo() }; return nil
            case "c": m.renderNow(); return nil
            case "w": close(hideApp: true); return nil
            case "s": Export.save([m.exportURL()], in: window); return nil
            default: return e
            }
        }
        switch e.keyCode {
        case 53:
            if m.selectedID != nil { withAnimation(snappy) { m.selectedID = nil } }
            else if m.paletteOpen { withAnimation(bouncy) { m.paletteOpen = false } }
            else { close(hideApp: true) }
            return nil
        case 36, 76: close(hideApp: true); return nil
        case 51, 117: m.deleteSelected(); return nil
        default: break
        }
        if ch == "-" { m.bump(false); return nil }
        if ch == "=" || ch == "+" { m.bump(true); return nil }
        if let t = Tool.allCases.first(where: { $0.key == ch }) { m.setTool(t); return nil }
        if let d = Int(ch), d >= 1, d <= palette.count { withAnimation(snappy) { m.setColor(d - 1) }; return nil }
        return e
    }

    func close(hideApp: Bool) {
        let w = window
        w?.orderOut(nil)                 // the window leaves first; the final render happens behind it
        model?.commitText()
        model?.flush()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
        model = nil
        w?.delegate = nil
        onClose()
        if hideApp && !(PeekMain.delegate?.library.window?.isVisible ?? false) { NSApp.hide(nil) }
    }

    func windowWillClose(_ notification: Notification) { close(hideApp: false) }
}


// MARK: - Share and save

/// Holds the AppKit view behind a SwiftUI control so the share menu can open right under it.
final class ViewRef { weak var view: NSView? }
struct Anchor: NSViewRepresentable {
    let ref: ViewRef
    func makeNSView(context: Context) -> NSView { let v = NSView(); ref.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { ref.view = v }
}

/// AirDrop, Messages, Mail and the rest of the system share menu, plus Save As, for one screenshot or several.
@MainActor enum Export {
    static func share(_ urls: [URL], from ref: ViewRef) {
        guard !urls.isEmpty, let v = ref.view else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: v.bounds, of: v, preferredEdge: .maxY)
    }

    static func save(_ urls: [URL], in window: NSWindow?) {
        guard let first = urls.first else { return }
        let fm = FileManager.default
        if urls.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = first.lastPathComponent
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            run(panel, window) {
                guard let dest = panel.url else { return }
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: first, to: dest)
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save \(urls.count) Screenshots"
            run(panel, window) {
                guard let dir = panel.url else { return }
                for u in urls {
                    var dest = dir.appendingPathComponent(u.lastPathComponent)
                    var n = 2
                    while fm.fileExists(atPath: dest.path) {
                        dest = dir.appendingPathComponent("\(u.deletingPathExtension().lastPathComponent) \(n).png"); n += 1
                    }
                    try? fm.copyItem(at: u, to: dest)
                }
            }
        }
    }

    private static func run(_ panel: NSSavePanel, _ window: NSWindow?, _ ok: @escaping () -> Void) {
        if let window { panel.beginSheetModal(for: window) { if $0 == .OK { ok() } } }
        else { NSApp.activate(ignoringOtherApps: true); if panel.runModal() == .OK { ok() } }
    }
}

/// A quiet icon button that remembers where it sits on screen, for anchoring the share menu.
struct ShareIcon: View {
    let tint: Color
    var size = CGSize(width: 34, height: 32)
    var help = "Share or AirDrop"
    let action: (ViewRef) -> Void
    @State private var ref = ViewRef()
    var body: some View {
        Button { action(ref) } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: size.height < 30 ? 12 : 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: size.width, height: size.height).contentShape(Rectangle())
                .background(Anchor(ref: ref))
        }
        .buttonStyle(Squish()).help(help)
    }
}

// MARK: - Library

/// Just a file and its date. Thumbnails load per tile, so only what is on screen is ever decoded.
struct LibItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
}

struct DaySection: Identifiable {
    let title: String
    let items: [LibItem]
    var id: String { title }
}

@MainActor final class LibraryModel: ObservableObject {
    @Published var sections: [DaySection] = []
    @Published var selection: [URL] = []      // ordered, and always equal to the clipboard
    @Published var tab = 0
    var recent: [URL] = []
    var markup: (URL) -> Void = { _ in }
    private var anchor: URL?

    var flat: [URL] { sections.flatMap { $0.items.map(\.url) } }

    /// False until the first listing arrives, so the empty state never flashes on open.
    @Published var loaded = false
    private var generation = 0

    /// Lists files off the main thread (a directory read and a stat per file, no image decoding).
    func reload(animated: Bool = false) {
        generation += 1
        let g = generation, recent = self.recent, dir = Capture.dir, vdir = Recordings.dir
        imageWork.async { [weak self] in
            let out = LibraryModel.listing(recent, dir: dir, videos: vdir)
            Task { @MainActor in
                guard let self, self.generation == g else { return }
                if animated { withAnimation(snappy) { self.apply(out) } } else { self.apply(out) }
            }
        }
    }

    private func apply(_ out: [DaySection]) {
        if out.map(\.items) != sections.map(\.items) || out.map(\.title) != sections.map(\.title) { sections = out }
        let urls = Set(out.flatMap { $0.items.map(\.url) })
        selection = selection.filter { urls.contains($0) }
        loaded = true
    }

    nonisolated static func listing(_ recent: [URL], dir: URL, videos: URL) -> [DaySection] {
        let fm = FileManager.default
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "EEEE, MMMM d"
        let own = [dir, videos].flatMap { d in
            (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        }
        var seen = Set<String>()
        let dated: [(URL, Date)] = (recent + own).compactMap { u in
            guard ["png", "jpg", "jpeg", "heic", "mp4", "mov", "m4v"].contains(u.pathExtension.lowercased()), seen.insert(u.path).inserted,
                  let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (u, d)
        }.sorted { $0.1 > $1.1 }
        let cal = Calendar.current
        var out: [DaySection] = []
        for (u, d) in dated.prefix(240) {
            let it = LibItem(url: u, date: d)
            let t = cal.isDateInToday(d) ? "Today" : (cal.isDateInYesterday(d) ? "Yesterday" : dayFormat.string(from: d))
            if let last = out.last, last.title == t {
                out[out.count - 1] = DaySection(title: t, items: last.items + [it])
            } else {
                out.append(DaySection(title: t, items: [it]))
            }
        }
        return out
    }

    /// Removes tiles at once; the files go to the Trash in the background.
    private func drop(_ urls: Set<URL>) {
        withAnimation(snappy) {
            sections = sections.compactMap { s in
                let items = s.items.filter { !urls.contains($0.url) }
                return items.isEmpty ? nil : DaySection(title: s.title, items: items)
            }
            selection.removeAll { urls.contains($0) }
        }
        recent.removeAll { urls.contains($0) }
        imageWork.async { for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) } }
    }

    func click(_ u: URL) {
        let mods = NSEvent.modifierFlags
        var s = selection
        if mods.contains(.command) {
            if let i = s.firstIndex(of: u) { s.remove(at: i) } else { s.append(u) }
            anchor = u
        } else if mods.contains(.shift), let a = anchor, let i = flat.firstIndex(of: a), let j = flat.firstIndex(of: u) {
            for r in flat[min(i, j)...max(i, j)] where !s.contains(r) { s.append(r) }
        } else {
            s = [u]
            anchor = u
        }
        withAnimation(bouncy) { selection = s }
        copySelection()
    }

    func selectAll() { withAnimation(bouncy) { selection = flat }; copySelection() }
    func clear() { withAnimation(snappy) { selection = [] } }
    /// One file is read now (a few ms). Several are promised, so Command-A on hundreds of shots copies instantly
    /// and only the app you paste into pulls the bytes.
    func copySelection() {
        guard !selection.isEmpty else { return }
        if selection.contains(where: isVideoFile) {       // videos travel as files
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(selection.map { $0 as NSURL })
            return
        }
        if selection.count == 1 {
            if let d = Clip.fileData(selection[0]) { Clip.copy(d) }
        } else {
            Clip.copy(promises: selection.map { u in Promise(url: u) { Clip.fileData(u) } })
        }
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(selection) }
    func trashSelection() { drop(Set(selection)) }
    func trash(_ u: URL) { drop([u]) }
}

// Calm, warm surfaces for the windows you spend time in (Library, Setup).
// The floating tray and the editor stay dark glass: they sit on top of your work.

/// The Peek mark: screenshot crop corners with two tall eyes.
struct PeekMark: Shape {
    var eyes = true
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 100
        let ox = r.midX - 50 * s, oy = r.midY - 50 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var c = Path()
        c.move(to: p(15, 35)); c.addLine(to: p(15, 25)); c.addQuadCurve(to: p(25, 15), control: p(15, 15)); c.addLine(to: p(35, 15))
        c.move(to: p(65, 15)); c.addLine(to: p(75, 15)); c.addQuadCurve(to: p(85, 25), control: p(85, 15)); c.addLine(to: p(85, 35))
        c.move(to: p(85, 65)); c.addLine(to: p(85, 75)); c.addQuadCurve(to: p(75, 85), control: p(85, 85)); c.addLine(to: p(65, 85))
        c.move(to: p(35, 85)); c.addLine(to: p(25, 85)); c.addQuadCurve(to: p(15, 75), control: p(15, 85)); c.addLine(to: p(15, 65))
        var out = c.strokedPath(StrokeStyle(lineWidth: 8.5 * s, lineCap: .round, lineJoin: .round))
        if eyes {
            out.addRoundedRect(in: CGRect(x: ox + 40.5 * s, y: oy + 31 * s, width: 9.5 * s, height: 31 * s), cornerSize: CGSize(width: 4.75 * s, height: 4.75 * s))
            out.addRoundedRect(in: CGRect(x: ox + 56.5 * s, y: oy + 31 * s, width: 9.5 * s, height: 31 * s), cornerSize: CGSize(width: 4.75 * s, height: 4.75 * s))
        }
        return out
    }
}

/// The app icon, drawn: ink tile, white mark. With `lively`, the eyes now and then glance left and right
/// (anticipation, a stretched dart, an impact squash, an elastic settle, a blink), same as on the website.
struct PeekTile: View {
    var size: CGFloat = 76
    var lively = false
    var symbol: String? = nil          // a system symbol in place of the mark, for setup steps
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ex: CGFloat = 0
    @State private var sx: CGFloat = 1
    @State private var sy: CGFloat = 1
    @State private var busy = false

    var body: some View {
        let inner = size * 0.66, u = inner / 100
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.165, green: 0.169, blue: 0.192), ink], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white)
                } else {
                    ZStack {
                        PeekMark(eyes: false).fill(.white)
                        ForEach([45.25, 61.25], id: \.self) { cx in
                            RoundedRectangle(cornerRadius: 4.75 * u, style: .continuous).fill(.white)
                                .frame(width: 9.5 * u, height: 31 * u)
                                .scaleEffect(x: sx, y: sy)
                                .position(x: (cx + ex) * u, y: 46.5 * u)
                        }
                    }
                    .frame(width: inner, height: inner)
                }
            }
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(Color(hex: 0x15161B))
                .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.4).opacity(0.3), radius: size * 0.24, y: size * 0.12))
            .onHover { h in if h && lively && symbol == nil { Task { await glance() } } }
            .task {
                guard lively, symbol == nil, !reduceMotion else { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
                while !Task.isCancelled {
                    await glance()
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 9_000_000_000...15_000_000_000))
                }
            }
    }

    private func step(_ a: Animation, _ secs: Double, _ change: () -> Void) async {
        withAnimation(a) { change() }
        if secs > 0 { try? await Task.sleep(nanoseconds: UInt64(secs * 1e9)) }
    }
    private func dart(_ x: CGFloat, _ travel: Double) async {
        await step(.easeOut(duration: 0.08), 0.08) { sx = 1.1; sy = 0.86 }
        await step(.easeIn(duration: travel), travel) { ex = x; sx = 1.32; sy = 0.84 }
        await step(.easeOut(duration: 0.07), 0.07) { sx = 0.9; sy = 1.1 }
        await step(.spring(response: 0.42, dampingFraction: 0.42), 0) { sx = 1; sy = 1 }
    }
    private func glance() async {
        guard !busy, !reduceMotion else { return }
        busy = true
        let first: CGFloat = Bool.random() ? -1 : 1
        await dart(first * 7, 0.15)
        try? await Task.sleep(nanoseconds: 560_000_000)
        await dart(-first * 7, 0.19)
        try? await Task.sleep(nanoseconds: 450_000_000)
        await dart(0, 0.13)
        try? await Task.sleep(nanoseconds: 220_000_000)
        await step(.easeIn(duration: 0.07), 0.07) { sy = 0.1; sx = 1.12 }
        await step(.spring(response: 0.3, dampingFraction: 0.5), 0.4) { sy = 1; sx = 1 }
        busy = false
    }
}

/// A white keycap with a 2pt key edge, matching the website's shortcut keys.
struct Keycap: View {
    let k: String
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Text(k)
            .font(Brand.font(12.5, .semibold)).foregroundStyle(Color(hex: 0x15161B))
            .frame(minWidth: 14).padding(.horizontal, 7).frame(height: 26)
            .background(shape.fill(LinearGradient(colors: [.white, Color(red: 0.953, green: 0.957, blue: 0.969)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
            .background(shape.fill(Color(red: 0.835, green: 0.847, blue: 0.886)).offset(y: 2)
                .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.35).opacity(0.2), radius: 5, y: 3))
    }
}

struct LibraryView: View {
    @ObservedObject var m: LibraryModel
    @ObservedObject private var store = ThemeStore.shared
    @Namespace private var ns
    private let pages: [(String, String)] = [("Library", "photo.on.rectangle.angled"), ("Shortcuts", "command"), ("Settings", "gearshape")]

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(pages[m.tab].0)
                        .font(Brand.font(27, .semibold)).tracking(-0.9).foregroundStyle(ink)
                        .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 14)
                        .id(m.tab).transition(.opacity)
                    ZStack {
                        if m.tab == 0 { library.transition(.opacity) }
                        if m.tab == 1 { ShortcutsView().transition(.opacity) }
                        if m.tab == 2 { SettingsView().transition(.opacity) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack {
                    Spacer()
                    if m.tab == 0 && !m.selection.isEmpty {
                        SelectionBar(m: m)
                            .padding(.bottom, 20)
                            .transition(.modifier(active: Pop(s: 0.85, b: 10, o: 0, y: 34), identity: .rest))
                    }
                }
                .animation(bouncy, value: m.selection.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 16, y: 4)
            .padding(.vertical, 10).padding(.trailing, 10)
        }
        .background(canvasBG)
        .environment(\.colorScheme, theme.dark ? .dark : .light)
        .id(store.key)                      // a theme switch re-colors every tile at once
        .animation(.easeInOut(duration: 0.25), value: store.key)
        .onChange(of: store.key) { _ in NSApp.windows.forEach { w in if w.title == "Peek Library" || w.identifier?.rawValue == "library" { w.backgroundColor = NSColor(canvasBG) } } }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                LivelyMark(color: ink).frame(width: 30, height: 30)
                Text("Peek").font(Brand.font(23, .semibold)).tracking(-0.7).foregroundStyle(ink)
            }
            .padding(.leading, 12).padding(.top, 54).padding(.bottom, 24)
            ForEach(pages.indices, id: \.self) { i in
                Button { withAnimation(snappy) { m.tab = i } } label: {
                    HStack(spacing: 11) {
                        Image(systemName: pages[i].1).font(.system(size: 15)).frame(width: 20)
                            .foregroundStyle(m.tab == i ? accent : ink.opacity(0.68))
                        Text(pages[i].0).font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ink.opacity(m.tab == i ? 1 : 0.68))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background {
                        if m.tab == i {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ink.opacity(0.07))
                                .matchedGeometryEffect(id: "nav", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Squish())
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder var library: some View {
        if !m.loaded {
            Color.clear
        } else if m.sections.isEmpty {
            VStack(spacing: 12) {
                PeekMark().fill(ink.opacity(0.18)).frame(width: 46, height: 46)
                Text("No screenshots yet").font(Brand.font(16, .semibold)).foregroundStyle(ink)
                Text("Press Shift ⌘ 2 to capture an area").font(.system(size: 12.5)).foregroundStyle(ink.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 60)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach(m.sections) { sec in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(sec.title.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(1.1).foregroundStyle(ink.opacity(0.45))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 186), spacing: 14)], spacing: 14) {
                                ForEach(sec.items) { LibTile(item: $0, m: m) }
                            }
                        }
                    }
                    Text("Click to copy. Command-click or Shift-click to copy several. Double-click to mark up or edit.")
                        .font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 36).padding(.top, 6).padding(.bottom, 100)
            }
        }
    }
}

struct LibTile: View {
    let item: LibItem
    @ObservedObject var m: LibraryModel
    @State private var hover = false
    @State private var thumb: NSImage?

    init(item: LibItem, m: LibraryModel) {
        self.item = item
        self.m = m
        _thumb = State(initialValue: ThumbCache.shared.cached(item.url, item.date))   // no fade for anything already decoded
    }

    var body: some View {
        let order = m.selection.firstIndex(of: item.url)
        let on = order != nil
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let video = isVideoFile(item.url)
        ink.opacity(0.05)
            .frame(height: 128)
            .overlay {
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill).transition(.opacity) }
            }
            .overlay(alignment: .bottomLeading) {
                if video { VideoBadge(url: item.url).padding(8) }
            }
            .clipShape(shape)
            .background(shape.fill(ink.opacity(0.05))
                .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 16 : 4, y: hover ? 8 : 2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? accent : ink.opacity(hover ? 0.16 : 0.08), lineWidth: on ? 3 : 1))
            .overlay(alignment: .topLeading) {
                if let order { OrderBadge(n: m.selection.count > 1 ? order + 1 : nil).padding(8).transition(.pop) }
            }
            .overlay(alignment: .topTrailing) {
                if hover { RoundButton(symbol: video ? "scissors" : "pencil.tip", help: video ? "Edit" : "Mark up") { m.markup(item.url) }.padding(4).transition(.pop) }
            }
            .scaleEffect(on ? 0.965 : (hover ? 1.015 : 1))
            .animation(snappy, value: hover)
            .animation(bouncy, value: on)
            .onHover { hover = $0 }
            .contentShape(Rectangle())
            .onTapGesture { m.click(item.url) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { m.markup(item.url) })
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .task(id: item.date) {
                if let c = ThumbCache.shared.cached(item.url, item.date) { if thumb !== c { thumb = c }; return }
                let t = await ThumbCache.shared.load(item.url, item.date)
                withAnimation(.easeOut(duration: 0.18)) { thumb = t }
            }
            .contextMenu {
                Button("Copy") { m.click(item.url) }
                Button(video ? "Edit" : "Mark Up") { m.markup(item.url) }
                Menu("Share") {
                    ForEach(NSSharingService.sharingServices(forItems: [item.url]), id: \.title) { svc in
                        Button { svc.perform(withItems: [item.url]) } label: { Label { Text(svc.title) } icon: { Image(nsImage: svc.image) } }
                    }
                }
                Button("Save As…") { Export.save([item.url], in: NSApp.keyWindow) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Divider()
                Button("Move to Trash") { m.trash(item.url) }
            }
    }
}

struct SelectionBar: View {
    @ObservedObject var m: LibraryModel

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                Text(m.selection.count == 1 ? "Copied" : "\(m.selection.count) copied")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 4)
            if m.selection.count == 1 {
                Button { m.markup(m.selection[0]) } label: {
                    Label(m.selection.first.map(isVideoFile) == true ? "Edit" : "Mark up",
                          systemImage: m.selection.first.map(isVideoFile) == true ? "scissors" : "pencil.tip")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(onAccent)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(Squish()).help("Mark up  Return")
                .transition(.pop)
            }
            ShareIcon(tint: .white) { r in Export.share(m.selection, from: r) }
            bar("arrow.down.to.line", "Save As") { Export.save(m.selection, in: NSApp.keyWindow) }
            bar("folder", "Show in Finder") { m.reveal() }
            bar("trash", "Move to Trash  Delete") { m.trashSelection() }
            bar("xmark", "Deselect  Esc") { m.clear() }
        }
        .padding(5)
        .background(Capsule().fill(editorPanel))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .animation(bouncy, value: m.selection.count)
    }

    func bar(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(Squish()).help(help)
    }
}

/// A quiet card for settings and shortcut groups, with a small uppercase label above it.
struct Group2<C: View>: View {
    let title: String
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(1.1).foregroundStyle(ink.opacity(0.45))
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hairline, lineWidth: 1))
        }
    }
}

struct ShortcutsView: View {
    @ObservedObject private var sc = Shortcuts.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Group2(title: "Capture") {
                        ForEach(HotkeyAction.allCases) { a in
                            VStack(alignment: .trailing, spacing: 6) {
                                HStack {
                                    Text(a.title).font(.system(size: 13.5)).foregroundStyle(ink.opacity(0.85))
                                    Spacer()
                                    ShortcutField(action: a, sc: sc)
                                }
                                if let p = sc.problem, p.0 == a {
                                    Text(p.1).font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Color(red: 0.84, green: 0.27, blue: 0.2))
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            if a != HotkeyAction.allCases.last { Rectangle().fill(hairline).frame(height: 1).padding(.leading, 16) }
                        }
                    }
                    Text("Click a shortcut, then press the keys you want. Esc cancels.")
                        .font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.4)).padding(.leading, 2)
                }
                group("Preview and Library", [("Copy one", "Click"), ("Copy several, in order", "⌘ Click"),
                                               ("Copy a range", "⇧ Click"), ("Mark up", "Double-click"), ("Copy everything", "⌘ A")])
                group("Recording", [("Record an area", "Drag"), ("Record a whole screen", "Click  or  Return"),
                                    ("Start now, skip the countdown", "Space"), ("Cancel", "Esc")])
                group("Video editor", [("Play / Pause", "Space"), ("Split at the playhead", "S"), ("Split anywhere (click the timeline)", "B"),
                                       ("Delete the selected clip or annotation", "Delete"), ("Mute / unmute", "M"), ("Step a frame / a second", "←  →  /  ⇧ ←  →"),
                                       ("Previous / next cut", "↑  ↓"), ("Crop", "C"), ("Annotate", "A  R  T  N"),
                                       ("Back out one step", "Esc"), ("Save and copy", "Return")])
                group("Markup", [("Tools", "A  R  P  H  T  N  B"), ("Colors", "1 - 6"), ("Smaller / bigger", "-  ="),
                                 ("Undo / Redo", "⌘ Z  /  ⇧ ⌘ Z"), ("Delete selection", "Delete"), ("Done, copied", "Return")])
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 36).padding(.top, 6).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { sc.stop() }
    }

    func group(_ title: String, _ rows: [(String, String)]) -> some View {
        Group2(title: title) {
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    Text(rows[i].0).font(.system(size: 13.5)).foregroundStyle(ink.opacity(0.85))
                    Spacer()
                    Keycap(k: rows[i].1).padding(.bottom, 2)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if i < rows.count - 1 { Rectangle().fill(hairline).frame(height: 1).padding(.leading, 16) }
            }
        }
    }
}

/// A tiny desktop. Click a spot, or drag the preview and let go near one: it springs into place.
struct PositionPicker: View {
    @Binding var pos: String
    @State private var drag: CGPoint?
    private let size = CGSize(width: 300, height: 186)
    private let chip = CGSize(width: 58, height: 34)

    func center(_ p: TrayPosition) -> CGPoint {
        let xs: [CGFloat] = [12 + chip.width / 2, size.width / 2, size.width - 12 - chip.width / 2]
        return CGPoint(x: xs[p.col], y: p.isTop ? 17 + chip.height / 2 : size.height - 14 - chip.height / 2)
    }
    func nearest(_ q: CGPoint) -> TrayPosition {
        TrayPosition.allCases.min { hypot(center($0).x - q.x, center($0).y - q.y) < hypot(center($1).x - q.x, center($1).y - q.y) }!
    }

    var body: some View {
        let current = TrayPosition(rawValue: pos) ?? .bottomCenter
        let target = drag.map(nearest)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.56, green: 0.65, blue: 0.96), Color(red: 0.85, green: 0.77, blue: 0.94), Color(red: 1.0, green: 0.88, blue: 0.77)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.white.opacity(0.35)).frame(width: size.width, height: 9)
            ForEach(TrayPosition.allCases) { p in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(target == p ? 1 : 0.7), style: StrokeStyle(lineWidth: target == p ? 1.5 : 1, dash: [3, 3]))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(target == p ? 0.22 : 0)))
                    .frame(width: chip.width, height: chip.height)
                    .contentShape(Rectangle())
                    .position(center(p))
                    .onTapGesture { withAnimation(bouncy) { pos = p.rawValue } }
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: 0x15161B).opacity(0.85))
                .overlay(HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.95))
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.55))
                }.padding(4))
                .frame(width: chip.width, height: chip.height)
                .scaleEffect(drag == nil ? 1 : 1.08)
                .shadow(color: .black.opacity(drag == nil ? 0.25 : 0.35), radius: drag == nil ? 5 : 10, y: drag == nil ? 2 : 6)
                .position(drag ?? center(current))
                .onContinuousHover { _ in (drag == nil ? NSCursor.openHand : NSCursor.closedHand).set() }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("picker"))
                    .onChanged { v in
                        let x = min(max(chip.width / 2, v.location.x), size.width - chip.width / 2)
                        let y = min(max(chip.height / 2, v.location.y), size.height - chip.height / 2)
                        if drag == nil { withAnimation(snappy) { drag = CGPoint(x: x, y: y) } } else { drag = CGPoint(x: x, y: y) }
                    }
                    .onEnded { v in
                        let p = nearest(v.location)
                        withAnimation(bouncy) { pos = p.rawValue; drag = nil }
                    })
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "picker")
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hairline, lineWidth: 1))
        .animation(snappy, value: target)
    }
}

struct SettingsView: View {
    @AppStorage("position") private var position = TrayPosition.bottomCenter.rawValue
    @AppStorage("dismissAfter") private var dismissAfter = 30
    @AppStorage("watchNative") private var watchNative = true
    @AppStorage("shutterSound") private var shutterSound = true
    @AppStorage("hideThumb") private var hideThumb = false
    @AppStorage("traySize") private var traySize = 1
    @AppStorage("trayStyle") private var trayStyle = "glass"
    @AppStorage("rec.clicks") private var recClicks = true
    @AppStorage("rec.cursor") private var recCursor = true
    @AppStorage("rec.countdown") private var recCountdown = true
    @AppStorage("rec.mic") private var recMic = false
    @AppStorage("rec.audio") private var recAudio = false
    @AppStorage("rec.fps") private var recFPS = 60
    @AppStorage("rec.codec") private var recCodec = "h264"
    @AppStorage("rec.quality") private var recQuality = 1
    @AppStorage("rec.keepOriginal") private var recKeep = true
    @AppStorage("rec.dir") private var recDir = ""
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Group2(title: "Appearance") {
                    ThemePicker().padding(16)
                }
                Group2(title: "Preview") {
                    VStack(alignment: .leading, spacing: 12) {
                        label("Where the preview appears", "Pick a corner or an edge")
                        PositionPicker(pos: $position)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    divider
                    HStack {
                        label("Hide it after", "Hovering keeps it open")
                        Spacer()
                        Segmented(options: [(5, "5s"), (10, "10s"), (30, "30s"), (60, "1 min"), (0, "Never")], value: $dismissAfter)
                    }
                    .padding(16)
                    divider
                    HStack {
                        label("Size", "How big the floating preview is")
                        Spacer()
                        Segmented(options: [(0, "Small"), (1, "Medium"), (2, "Large")], value: $traySize)
                    }
                    .padding(16)
                    divider
                    HStack {
                        label("Style", ["Frosted glass over your work", "Barely there", "Solid, in your theme's color"][["glass", "clear", "solid"].firstIndex(of: trayStyle) ?? 0])
                        Spacer()
                        Segmented(options: [("glass", "Glass"), ("clear", "Clear"), ("solid", "Solid")], value: $trayStyle)
                    }
                    .padding(16)
                }
                Group2(title: "Capture") {
                    Toggle(isOn: $shutterSound) { label("Shutter sound", "Plays when Peek takes a screenshot") }
                        .onChange(of: shutterSound) { on in if on { Shutter.play(force: true) } }.padding(16)
                    divider
                    Toggle(isOn: $watchNative) { label("Copy macOS screenshots too", "Shift ⌘ 3, 4 and 5 also land on your clipboard") }.padding(16)
                    divider
                    Toggle(isOn: $hideThumb) { label("Hide the macOS thumbnail", "Makes macOS screenshots show up in Peek instantly") }
                        .onChange(of: hideThumb) { v in setNativeThumbnail(hidden: v) }.padding(16)
                    divider
                    Toggle(isOn: $atLogin) { label("Open Peek at login", "Always ready in the background") }
                        .onChange(of: atLogin) { v in
                            if v { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        }
                        .padding(16)
                }
                Group2(title: "Recording") {
                    Toggle(isOn: $recClicks) { label("Show clicks", "A soft ring wherever you click") }.padding(16)
                    divider
                    Toggle(isOn: $recCursor) { label("Show the pointer", "Turn off for clean product shots") }.padding(16)
                    divider
                    Toggle(isOn: $recCountdown) { label("Countdown", "Three seconds to get ready. Space skips it.") }.padding(16)
                    divider
                    Toggle(isOn: $recMic) { label("Microphone", "Narrate as you go") }.padding(16)
                    divider
                    Toggle(isOn: $recAudio) { label("Mac sound", "Record what your Mac plays") }.padding(16)
                    divider
                    HStack {
                        label("Frame rate", "60 for smooth motion, 30 for smaller files")
                        Spacer()
                        Segmented(options: [(30, "30"), (60, "60")], value: $recFPS)
                    }
                    .padding(16)
                    divider
                    HStack {
                        label("Format", recCodec == "hevc" ? "HEVC. About half the size, plays on recent devices." : "H.264. Plays everywhere.")
                        Spacer()
                        Segmented(options: [("h264", "H.264"), ("hevc", "HEVC")], value: $recCodec)
                    }
                    .padding(16)
                    divider
                    HStack {
                        label("Quality", ["Smaller files, saved edits up to 1080p", "Sharp text, sensible size", "Highest bitrate"][min(max(recQuality, 0), 2)])
                        Spacer()
                        Segmented(options: [(0, "Smaller"), (1, "Balanced"), (2, "Best")], value: $recQuality)
                    }
                    .padding(16)
                    divider
                    Toggle(isOn: $recKeep) { label("Keep the original when saving edits", recKeep ? "Edits save as a new file next to it" : "Edits replace the recording") }.padding(16)
                }
                Group2(title: "Storage") {
                    HStack {
                        label("Screenshots folder", Capture.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Spacer()
                        Button { NSWorkspace.shared.open(Capture.dir) } label: {
                            Text("Open").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                                .padding(.horizontal, 14).frame(height: 28)
                                .background(Capsule().fill(surface))
                                .overlay(Capsule().strokeBorder(hairline, lineWidth: 1))
                        }
                        .buttonStyle(Squish())
                    }
                    .padding(16)
                    divider
                    HStack {
                        label("Recordings folder", (recDir.isEmpty ? Recordings.defaultDir.path : recDir).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Spacer()
                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.prompt = "Use This Folder"
                            panel.directoryURL = Recordings.dir
                            NSApp.activate(ignoringOtherApps: true)
                            if panel.runModal() == .OK, let u = panel.url { recDir = u.path }
                        } label: {
                            Text("Change").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                                .padding(.horizontal, 14).frame(height: 28)
                                .background(Capsule().fill(surface))
                                .overlay(Capsule().strokeBorder(hairline, lineWidth: 1))
                        }
                        .buttonStyle(Squish())
                        Button { NSWorkspace.shared.open(Recordings.dir) } label: {
                            Text("Open").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                                .padding(.horizontal, 14).frame(height: 28)
                                .background(Capsule().fill(surface))
                                .overlay(Capsule().strokeBorder(hairline, lineWidth: 1))
                        }
                        .buttonStyle(Squish())
                    }
                    .padding(16)
                }
            }
            .toggleStyle(RowToggle())
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 36).padding(.top, 6).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var divider: some View { Rectangle().fill(hairline).frame(height: 1).padding(.leading, 16) }

    func label(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13.5, weight: .medium)).foregroundStyle(ink)
            Text(sub).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.5))
        }
    }
}

@MainActor final class LibraryController: NSObject {
    var window: NSWindow?
    let model = LibraryModel()
    private var monitor: Any?

    func show(tab: Int = 0) {
        model.tab = tab
        model.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = true
            w.backgroundColor = NSColor(canvasBG)
            w.identifier = NSUserInterfaceItemIdentifier("library")
            w.appearance = NSAppearance(named: .aqua)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 720, height: 460)
            w.contentView = NSHostingView(rootView: LibraryView(m: model))
            w.center()
            window = w
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                return self.handle(e)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshIfVisible() { if window?.isVisible == true { model.reload() } }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard e.window === window, model.tab == 0 else { return e }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if f.contains(.command) {
            if ch == "a" { model.selectAll(); return nil }
            if ch == "c" { model.copySelection(); return nil }
            return e
        }
        switch e.keyCode {
        case 53: model.clear(); return nil
        case 51, 117:
            if !model.selection.isEmpty { model.trashSelection() }
            return nil
        case 36, 76:
            if model.selection.count == 1 { model.markup(model.selection[0]) }
            return nil
        default: return e
        }
    }
}

// MARK: - Screen recording across updates

/// macOS ties the Screen Recording grant to the app's code signature. When an update arrives with a different
/// signature, Settings still shows Peek switched on, but the switch belongs to the old build and the new one is
/// refused. Peek remembers that it was allowed before; if that is no longer true, it removes the stale entry and asks
/// again straight away, so the user sees one ordinary system prompt instead of a switch that is on but does nothing.
enum ScreenAccess {
    private static let key = "screenAccessGranted"

    static func note() { if CGPreflightScreenCaptureAccess() { UserDefaults.standard.set(true, forKey: key) } }

    static func healIfStale() {
        if CGPreflightScreenCaptureAccess() { UserDefaults.standard.set(true, forKey: key); return }
        guard UserDefaults.standard.bool(forKey: key), let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.set(false, forKey: key)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]     // only Peek's own entry
        p.terminationHandler = { _ in DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() } }
        try? p.run()
    }
}

// MARK: - Setup wizard

@MainActor final class SetupModel: ObservableObject {
    @Published var step = 0
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var hideThumb = true
    @Published var atLogin = true
    var finish: () -> Void = {}
    var poll: Timer?

    func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(timeInterval: 0.8, target: self, selector: #selector(check), userInfo: nil, repeats: true)
    }
    @objc func check() {
        let p = CGPreflightScreenCaptureAccess()
        if p { ScreenAccess.note() }
        if p != hasPermission { withAnimation(snappy) { hasPermission = p } }
    }
    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path is passed as an argument, never spliced into the script, so no path can inject a command.
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// One of the website's sky paintings, bundled for the setup wizard.
struct Sky: View {
    let name: String
    var body: some View {
        if let u = Bundle.main.url(forResource: name, withExtension: "jpg"), let img = NSImage(contentsOf: u) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(red: 0.53, green: 0.65, blue: 0.96), Color(red: 0.85, green: 0.77, blue: 0.94),
                                    Color(red: 1.0, green: 0.88, blue: 0.77)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Setup reads like the website: a painted sky with the app icon floating in it, big Geist type on white,
/// shortcut keycaps, and an ink pill button.
struct SetupView: View {
    @ObservedObject var s: SetupModel
    private let skies = ["setup-welcome", "setup-permission", "setup-choices"]
    private let ink = Color(hex: 0x15161B)
    private let canvasBG = Color(hex: 0xF6F5F2)
    private let ink2 = Color(red: 0.149, green: 0.157, blue: 0.196)

    var body: some View {
        VStack(spacing: 0) {
            hero
            ZStack {
                if s.step == 0 { welcome.transition(slide) }
                if s.step == 1 { permission.transition(slide) }
                if s.step == 2 { prefs.transition(slide) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 600, height: 620)
        .background(Color.white)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
    }

    // A painted sky that fades into the page, the icon floating in it, then the title on white.
    var hero: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(skies.indices, id: \.self) { i in
                    if i == s.step { Sky(name: skies[i]).transition(.opacity) }
                }
                LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.45), .init(color: .white, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                ZStack {
                    if s.step == 0 { PeekTile(size: 84, lively: true).transition(.pop) }
                    if s.step == 1 {
                        PeekTile(size: 84, symbol: s.hasPermission ? "checkmark" : "lock.fill").id(s.hasPermission).transition(.pop)
                    }
                    if s.step == 2 { PeekTile(size: 84, symbol: "slider.horizontal.3").transition(.pop) }
                }
                .offset(y: 14)
            }
            .frame(width: 600, height: 236)
            .clipped()
            VStack(spacing: 10) {
                Text(heading.0).font(Brand.font(32, .semibold)).tracking(-1.2).foregroundStyle(ink)
                Text(heading.1).font(Brand.font(15)).foregroundStyle(ink2.opacity(0.75))
                    .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 420)
            }
            .id("\(s.step)-\(s.hasPermission)")
            .transition(.opacity)
            .padding(.top, 6)
        }
    }

    var heading: (String, String) {
        switch s.step {
        case 0: return ("Welcome to Peek", "Every screenshot is copied the moment you take it, ready to paste into any chat or doc.")
        case 1: return s.hasPermission ? ("You're all set", "Peek can capture your screen. Nothing ever leaves your Mac.")
                                       : ("Allow screen capture", "macOS asks once. Turn on Peek in the list, then come back here.")
        default: return ("A few quick choices", "You can change these anytime in Settings.")
        }
    }

    var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(ink.opacity(i == s.step ? 0.9 : 0.14)).frame(width: i == s.step ? 18 : 6, height: 6)
                }
            }
            Spacer()
            if s.step > 0 {
                Button { withAnimation(soft) { s.step -= 1 } } label: {
                    Text("Back").font(Brand.font(14, .medium)).foregroundStyle(ink.opacity(0.55))
                        .padding(.horizontal, 10).frame(height: 38).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).padding(.trailing, 4)
            }
            primary
        }
        .padding(.horizontal, 28).padding(.bottom, 26)
    }

    var slide: AnyTransition {
        .asymmetric(insertion: .modifier(active: Pop(s: 0.96, b: 8, o: 0, y: 18), identity: .rest),
                    removal: .modifier(active: Pop(s: 1.02, b: 8, o: 0, y: -10), identity: .rest))
    }

    var primary: some View {
        let label = s.step == 0 ? "Get Started" : (s.step == 1 ? (s.hasPermission ? "Continue" : "Skip for now") : "Start Using Peek")
        return Button {
            if s.step < 2 { withAnimation(soft) { s.step += 1 } } else { s.finish() }
        } label: {
            Text(label).font(Brand.font(14, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 22).frame(height: 40)
                .background(Capsule().fill(Color(red: 0.067, green: 0.071, blue: 0.094)))
                .shadow(color: Color(red: 0.08, green: 0.1, blue: 0.3).opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(Squish())
        .keyboardShortcut(.defaultAction)
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(Shortcuts.shared.key(.area).symbols, "Capture an area")
            row(Shortcuts.shared.key(.screen).symbols, "Capture the whole screen")
            row(["⌘", "Click"], "Copy several previews, in order")
        }
        .padding(.top, 26)
    }

    func row(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) { ForEach(keys, id: \.self) { Keycap(k: $0) } }
                .frame(width: 118, alignment: .trailing)
            Text(text).font(Brand.font(14.5, .medium)).foregroundStyle(ink.opacity(0.82))
                .frame(width: 230, alignment: .leading)
        }
    }

    var permission: some View {
        VStack(spacing: 14) {
            if s.hasPermission {
                Label("Screen capture is on", systemImage: "checkmark.circle.fill")
                    .font(Brand.font(14, .medium)).foregroundStyle(ink.opacity(0.7))
                    .symbolRenderingMode(.multicolor)
            } else {
                Button { s.requestPermission() } label: {
                    Label("Open System Settings", systemImage: "arrow.up.forward.app")
                        .font(Brand.font(14, .semibold)).foregroundStyle(ink)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(Capsule().fill(.white))
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
                        .shadow(color: Color(red: 0.08, green: 0.1, blue: 0.3).opacity(0.1), radius: 8, y: 3)
                }
                .buttonStyle(Squish())
                Button { s.restart() } label: {
                    Text("Already turned it on? Restart Peek")
                        .font(Brand.font(12.5, .medium)).foregroundStyle(ink.opacity(0.45)).underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 28)
        .onAppear { s.startPolling() }
    }

    var prefs: some View {
        VStack(spacing: 0) {
            toggle("Hide the macOS screenshot thumbnail", "Makes Shift ⌘ 3 and 4 show up in Peek right away", $s.hideThumb)
            Rectangle().fill(hairline).frame(height: 1).padding(.leading, 16)
            toggle("Open Peek at login", "So it's always ready", $s.atLogin)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hairline, lineWidth: 1))
        .frame(width: 440)
        .padding(.top, 22)
    }

    func toggle(_ t: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(Brand.font(14, .medium)).foregroundStyle(ink)
                Text(sub).font(Brand.font(12)).foregroundStyle(ink.opacity(0.5))
            }
        }
        .toggleStyle(.switch).tint(ink).padding(.horizontal, 16).padding(.vertical, 12)
    }
}

@MainActor final class SetupController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    let model = SetupModel()
    var onFinish: (SetupModel) -> Void = { _ in }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        model.step = model.hasPermission ? 2 : 0
        model.finish = { [weak self] in self?.complete() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isOpaque = true
        w.backgroundColor = .white
        w.appearance = NSAppearance(named: .aqua)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SetupView(s: model))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        model.poll?.invalidate()
        onFinish(model)
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        model.poll?.invalidate()
        window = nil
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var trayC: TrayController!
    let editor = EditorController()
    let watcher = SystemWatcher()
    let setup = SetupController()
    let library = LibraryController()
    let recorder = RecordController()
    let clips = ClipCardController()
    let clipEditor = ClipEditorController()
    private var session: [Shot] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        TrayLook.refresh()
        Brand.registerFonts()
        trayC = TrayController(actions: TrayActions(
            markup: { [weak self] s in self?.editor.open(s) },
            openLibrary: { [weak self] in self?.library.show() }
        ))
        editor.onCopied = { [weak self] s in self?.trayC.markCopied(s) }
        editor.onClose = { [weak self] in self?.library.refreshIfVisible() }
        library.model.markup = { [weak self] url in
            guard let self else { return }
            if isVideoFile(url) { self.clipEditor.open(url); return }
            if let s = self.session.first(where: { $0.url == url }) { self.editor.open(s); return }
            Shot.load({ try? Data(contentsOf: url) }, url: url, done: { [weak self] s in if let s { self?.editor.open(s) } })
        }
        buildMenu()
        Shutter.prepare()
        HotKeys.install()
        Shortcuts.shared.onChange = { [weak self] in self?.buildMenu() }
        Shortcuts.shared.start([
            .area: { [weak self] in self?.captureArea() },
            .screen: { [weak self] in self?.captureScreen() },
            .library: { [weak self] in self?.library.show() },
            .record: { [weak self] in self?.recorder.toggle() },
        ])
        recorder.onPhase = { [weak self] in self?.buildMenu() }
        recorder.onFinished = { [weak self] url in
            Clip.copyFile(url)
            self?.remember(url)
            self?.clips.show(url)
        }
        clips.onEdit = { [weak self] url in self?.clipEditor.open(url) }
        clipEditor.onSaved = { [weak self] url in
            Clip.copyFile(url)
            self?.remember(url)
            self?.clips.show(url, status: "Saved and copied")
        }
        clipEditor.onCancel = { [weak self] url in
            Clip.copyFile(url)
            self?.clips.show(url)
        }
        watcher.onNew = { [weak self] url in
            guard let self, Prefs.watchNative else { return }
            self.ingest(url)
        }
        watcher.start()
        setup.onFinish = { [weak self] m in
            UserDefaults.standard.set(m.hideThumb, forKey: "hideThumb")
            if m.hideThumb { setNativeThumbnail(hidden: true) }
            if m.atLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
            self?.captureArea()
        }
        if !UserDefaults.standard.bool(forKey: "onboarded") { setup.show() } else { ScreenAccess.healIfStale() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        library.show()
        return true
    }

    @objc func captureArea() { capture(["-i", "-x"]) }
    @objc func captureScreen() { capture(["-x", "-m"]) }
    @objc func showLibrary() { library.show() }
    @objc func toggleRecording() { recorder.toggle() }
    @objc func pauseRecording() { recorder.togglePause() }
    @objc func showRecordings() { NSWorkspace.shared.open(Recordings.dir) }
    @objc func showSettings() { library.show(tab: 2) }
    @objc func showSetup() { setup.show() }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Free and open source.\ngithub.com/nickwechols/peek",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        ])
    }
    @objc func quit() { NSApp.terminate(nil) }

    /// The capture path, in order: screencapture puts the PNG on the clipboard itself, the thumbnail is
    /// decoded off the main thread, the tray animates in, and only then is the file written.
    func capture(_ args: [String]) {
        trayC.setCapturing(true)
        Capture.run(args) { [weak self] data, url, onClipboard in
            guard let self else { return }
            self.trayC.setCapturing(false)
            guard let data else { return }
            Shutter.play()
            Shot.load({ data }, url: url, save: true,
                      done: { [weak self] shot in if let shot { self?.present(shot, copy: !onClipboard) } },
                      saved: { [weak self] in self?.remember(url) })
        }
    }

    /// Screenshots taken with the macOS shortcuts. Read and decoded off the main thread too.
    func ingest(_ url: URL) {
        Shot.load({ try? Data(contentsOf: url) }, url: url, done: { [weak self] shot in
            guard let self, let shot else { return }
            self.present(shot, copy: true)
            ThumbCache.shared.put(url, thumb: shot.thumb)
            self.remember(url)
        })
    }

    private func present(_ shot: Shot, copy: Bool) {
        if copy { Clip.copy(shot.png) }
        session.append(shot)
        if session.count > 30 { session.removeFirst() }
        trayC.add(shot)
    }

    func applicationWillTerminate(_ notification: Notification) { Clip.settle() }

    private func remember(_ url: URL) {
        library.model.recent.insert(url, at: 0)
        library.refreshIfVisible()
    }

    func buildMenu() {
        if status == nil { status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        let mark = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(PeekMark().path(in: r.insetBy(dx: 0.5, dy: 0.5)).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        mark.isTemplate = true
        mark.accessibilityDescription = "Peek"
        let recording = recorder.phase == .recording
        if recording, let dot = NSImage(systemSymbolName: recorder.paused ? "pause.circle" : "record.circle", accessibilityDescription: "Recording") {
            dot.isTemplate = true
            status.button?.image = dot
        } else {
            status.button?.image = mark
        }
        let menu = NSMenu()
        if recording {
            menu.addItem(hotkeyItem("Stop Recording", #selector(toggleRecording), .record))
            menu.addItem(item(recorder.paused ? "Resume Recording" : "Pause Recording", #selector(pauseRecording)))
            menu.addItem(.separator())
        }
        menu.addItem(hotkeyItem("Capture Area", #selector(captureArea), .area))
        menu.addItem(hotkeyItem("Capture Screen", #selector(captureScreen), .screen))
        if !recording { menu.addItem(hotkeyItem("Record Screen", #selector(toggleRecording), .record)) }
        menu.addItem(.separator())
        menu.addItem(hotkeyItem("Library", #selector(showLibrary), .library))
        menu.addItem(item("Recordings Folder", #selector(showRecordings)))
        menu.addItem(item("Settings…", #selector(showSettings), ",", [.command]))
        menu.addItem(item("Setup…", #selector(showSetup)))
        menu.addItem(item("About Peek", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Peek", #selector(quit), "q", [.command]))
        status.menu = menu
    }

    /// Menu items mirror whatever shortcut the user picked.
    func hotkeyItem(_ t: String, _ s: Selector, _ a: HotkeyAction) -> NSMenuItem {
        let k = Shortcuts.shared.key(a)
        return item(t, s, k.key.count == 1 ? k.key.lowercased() : "", k.flags)
    }

    func item(_ t: String, _ s: Selector, _ k: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: s, keyEquivalent: k)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }
}


func isVideoFile(_ u: URL) -> Bool { ["mp4", "mov", "m4v"].contains(u.pathExtension.lowercased()) }

/// Marks a Library tile as a video: a play glyph and the length, on a dark chip so it reads on any frame.
struct VideoBadge: View {
    @MainActor static var known: [URL: Double] = [:]
    let url: URL
    @State private var duration: Double?
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill").font(.system(size: 8.5, weight: .bold))
            if let duration { Text(Recordings.time(duration)).monospacedDigit().transition(.opacity) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .task(id: url) {
            if let d = VideoBadge.known[url] { duration = d; return }     // scrolling back costs nothing
            let d = try? await AVURLAsset(url: url).load(.duration).seconds
            if let d { VideoBadge.known[url] = d }
            withAnimation(.easeOut(duration: 0.2)) { duration = d }
        }
    }
}


/// The mark with eyes that live a little: every so often a slow blink, or a look to one side and back.
/// Ambient on purpose. You notice it only if you happen to be looking. Still under Reduce Motion.
struct LivelyMark: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ex: CGFloat = 0
    @State private var sy: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            let u = min(g.size.width, g.size.height) / 100
            ZStack(alignment: .topLeading) {
                PeekMark(eyes: false).fill(color)
                ForEach([45.25, 61.25], id: \.self) { cx in
                    RoundedRectangle(cornerRadius: 4.75 * u, style: .continuous).fill(color)
                        .frame(width: 9.5 * u, height: 31 * u)
                        .scaleEffect(x: 1, y: sy)
                        .position(x: (cx + ex) * u, y: 46.5 * u)
                }
            }
        }
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            while !Task.isCancelled {
                if Int.random(in: 0..<3) == 0 { await look() } else { await blink() }
                try? await Task.sleep(nanoseconds: UInt64.random(in: 5_000_000_000...11_000_000_000))
            }
        }
    }

    private func blink() async {
        withAnimation(.easeIn(duration: 0.08)) { sy = 0.12 }
        try? await Task.sleep(nanoseconds: 90_000_000)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { sy = 1 }
    }

    private func look() async {
        let dir: CGFloat = Bool.random() ? -1 : 1
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { ex = dir * 5 }
        try? await Task.sleep(nanoseconds: UInt64.random(in: 900_000_000...1_500_000_000))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { ex = 0 }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Bool.random() { await blink() }
    }
}
