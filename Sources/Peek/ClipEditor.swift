// What happens after a recording: a small card with the clip (already on the clipboard), one-click GIF
// and stills for AI chats, and a light editor to trim, split and cut, crop, and mark up over time.

import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Clip tools

enum ClipTools {
    static func info(_ url: URL) async -> (NSImage?, Double, CGSize) {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 16, height: 10)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let t = CMTime(seconds: min(0.4, dur / 2), preferredTimescale: 600)
        let img = (try? await gen.image(at: t)).map { NSImage(cgImage: $0.image, size: .zero) }
        return (img, dur, size)
    }

    /// A looping GIF, sized for GitHub, Linear and Slack: up to 900px wide, 12 frames a second.
    static func gif(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return nil }
        let fps = dur > 30 ? max(4, 360 / dur) : 12
        let n = max(1, Int(dur * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 900, height: 900)
        let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let out = Recordings.sibling(url, "GIF", ext: "gif")
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, n, nil) else { return nil }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<n {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let r = try? await gen.image(at: t) { CGImageDestinationAddImage(dst, r.image, frameProps) }
        }
        return CGImageDestinationFinalize(dst) ? out : nil
    }

    /// Evenly spaced stills, copied in order as images. Claude and ChatGPT read a handful of frames far better
    /// than they read a video file, so this is the fastest way to show an AI what happened.
    static func frames(_ url: URL, count: Int = 8) async -> [(URL, Data)] {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return [] }
        let n = max(1, min(count, Int(dur * 2)))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Peek Frames \(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [(URL, Data)] = []
        for i in 0..<n {
            let s = n == 1 ? 0 : dur * (Double(i) + 0.5) / Double(n)
            guard let r = try? await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)), let png = Clip.png(r.image) else { continue }
            let name = String(format: "Frame %d at %d.%02ds.png", i + 1, Int(s), Int((s - Double(Int(s))) * 100))
            let u = dir.appendingPathComponent(name)
            try? png.write(to: u)
            out.append((u, png))
        }
        return out
    }
}

// MARK: - Clip card

@MainActor final class ClipCard: ObservableObject {
    @Published var url: URL
    @Published var poster: NSImage?
    @Published var duration: Double = 0
    @Published var status = "Copied"
    @Published var busy = false
    @Published var pulse = 0
    init(url: URL) { self.url = url }
}

@MainActor final class ClipCardController {
    private var panel: NSPanel?
    private var card: ClipCard?
    private var hideTask: Task<Void, Never>?
    private var hovering = false
    var onEdit: (URL) -> Void = { _ in }

    func show(_ url: URL, status: String = "Copied") {
        let c = card ?? ClipCard(url: url)
        c.url = url
        c.status = status
        c.busy = false
        card = c
        Task {
            let (img, dur, _) = await ClipTools.info(url)
            c.poster = img
            c.duration = dur
        }
        if panel == nil {
            let host = NSHostingView(rootView: ClipCardView(c: c, ctl: self))
            let size = CGSize(width: 330, height: 290)
            let p = overlayPanel(NSRect(origin: .zero, size: size), level: .statusBar, mouse: true)
            p.contentView = host
            panel = p
        }
        place()
        panel?.orderFrontRegardless()
        withAnimation(snappy) { c.pulse += 1 }
        scheduleHide()
    }

    private func place() {
        guard let p = panel else { return }
        let s = NSScreen.underMouse.visibleFrame
        let size = p.frame.size
        let pos = TrayPosition.current
        let m = trayMargin - 14
        let x: CGFloat = [s.minX + m, s.midX - size.width / 2, s.maxX - size.width - m][pos.col]
        let y: CGFloat = pos.isTop ? s.maxY - size.height - m : s.minY + m
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hover(_ h: Bool) {
        hovering = h
        if h { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let after = Prefs.dismissAfter
        guard after > 0 else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(after) * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.hovering, !(self.card?.busy ?? false) else { return }
            self.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    func copy() {
        guard let c = card else { return }
        Clip.copyFile(c.url)
        say("Copied")
    }

    func edit() {
        guard let c = card else { return }
        hide()
        onEdit(c.url)
    }

    func gif() {
        guard let c = card, !c.busy else { return }
        withAnimation(snappy) { c.busy = true; c.status = "Making GIF" }
        Task {
            let out = await ClipTools.gif(c.url)
            withAnimation(snappy) { c.busy = false }
            if let out { Clip.copyFile(out); say("GIF copied") } else { say("Could not make a GIF") }
        }
    }

    func frames() {
        guard let c = card, !c.busy else { return }
        withAnimation(snappy) { c.busy = true; c.status = "Picking frames" }
        Task {
            let files = await ClipTools.frames(c.url)
            withAnimation(snappy) { c.busy = false }
            if files.isEmpty { say("Could not read the clip"); return }
            Clip.copy(files: files)
            say("\(files.count) frames copied")
        }
    }

    func reveal() {
        guard let c = card else { return }
        NSWorkspace.shared.activateFileViewerSelecting([c.url])
    }

    func say(_ s: String) {
        guard let c = card else { return }
        withAnimation(snappy) { c.status = s; c.pulse += 1 }
        scheduleHide()
    }
}

struct ClipCardView: View {
    @ObservedObject var c: ClipCard
    let ctl: ClipCardController
    @State private var hover = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                if c.busy {
                    Spinner(color: .white, size: 12).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
                Text(c.status).foregroundStyle(.white).id(c.status).transition(.opacity)
                Spacer()
                Button { ctl.hide() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).help("Close. The clip stays in Movies/Peek.")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.leading, 4)

            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.3)
                if let p = c.poster { Image(nsImage: p).resizable().aspectRatio(contentMode: .fill) }
                Text(Recordings.time(c.duration)).monospacedDigit()
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(8)
            }
            .frame(width: 290, height: 164)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .scaleEffect(hover ? 1.015 : 1)
            .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 10, y: 4)
            .animation(snappy, value: hover)
            .onHover { hover = $0 }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { ctl.edit() }
            .onTapGesture { ctl.copy() }
            .onDrag { NSItemProvider(contentsOf: c.url) ?? NSItemProvider() }

            HStack(spacing: 2) {
                action("scissors", "Edit", "Trim, cut, crop and mark up") { ctl.edit() }
                action("photo.stack", "Frames", "Copy 8 stills, in order, for Claude or ChatGPT") { ctl.frames() }
                action("sparkles.tv", "GIF", "Copy as a looping GIF for GitHub, Linear or Slack") { ctl.gif() }
                ShareIcon(tint: .white, size: CGSize(width: 34, height: 30)) { r in Export.share([c.url], from: r) }
                Button { ctl.reveal() } label: {
                    Image(systemName: "folder").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).help("Show in Finder")
            }
            .disabled(c.busy)
            .opacity(c.busy ? 0.5 : 1)
        }
        .padding(10)
        .glass(20)
        .environment(\.colorScheme, .dark)
        .onHover { ctl.hover($0) }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    func action(_ symbol: String, _ title: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 30)
            .background(Capsule().fill(.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(Squish()).help(help)
    }
}

