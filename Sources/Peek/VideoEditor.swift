// The video editor. One timeline of clips you can split, trim, reorder by deleting, and crop without
// losing anything, plus light annotations that sit on a layer above the video.
//
// Timeline model: the clip list *is* the output. Playback runs on an AVComposition built from it, so
// what you see, scrub and export are the same thing, and deleting a clip closes the gap for real.

import AppKit
import SwiftUI
import AVFoundation

// MARK: - Model

struct VClip: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var cam: CamMode = .bubble
    var len: Double { end - start }
}

struct VNote: Identifiable, Equatable {
    var id = UUID()
    var mark: Mark
    var start: Double     // output time, seconds
    var end: Double
}

enum MarkTool: String, CaseIterable {
    case arrow, rect, text, step
    var tool: Tool {
        switch self {
        case .arrow: return .arrow
        case .rect: return .rect
        case .text: return .text
        case .step: return .step
        }
    }
    var symbol: String { tool.symbol }
    var label: String { tool.label }
    var key: String {
        switch self {
        case .arrow: return "a"
        case .rect: return "r"
        case .text: return "t"
        case .step: return "n"
        }
    }
}

enum EditMode { case edit, blade, crop }

/// A stretch of the camera layer, in source time. Only used once the camera is unlinked from the video.
struct CamSeg: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var mode: CamMode = .bubble
}

struct EditState: Equatable {
    var clips: [VClip] = []
    var crop: CGRect?
    var notes: [VNote] = []
    var muted = false
    var cam: CamLayout?
    /// Linked (the default): the camera is part of each clip, so cuts, trims and deletes take it along.
    /// Unlinked: the camera layer has its own cuts, so it can hide or go full screen anywhere.
    var camLinked = true
    var camSegs: [CamSeg] = []
}

/// The playhead's time lives on its own, so playback redraws only the playhead, the time and the
/// annotations, not the whole editor.
final class PlayClock: ObservableObject {
    @Published var t: Double = 0
}
let gentle = Animation.spring(response: 0.38, dampingFraction: 0.86)

@MainActor final class VideoEditorModel: ObservableObject {
    let url: URL
    let asset: AVURLAsset
    let player = AVPlayer()
    /// A presentation: the raw screen recording, your camera beside it, and the edit that made the clip.
    let meta: PresentMeta?
    let screenURL: URL
    let cameraURL: URL?
    let camPlayer: AVPlayer?
    private let camAsset: AVURLAsset?
    private var lastResync = -10.0
    private var camRange = CMTimeRange.zero
    @Published var cameraOpen = false
    @Published var s = EditState()
    @Published var duration: Double = 0
    @Published var natural = CGSize(width: 16, height: 10)
    let clock = PlayClock()
    var time: Double {
        get { clock.t }
        set { clock.t = newValue }
    }
    @Published var playing = false
    @Published var mode: EditMode = .edit
    @Published var tool: MarkTool?
    @Published var markupOpen = false
    @Published var color = 0
    @Published var selectedClip: UUID?
    @Published var selectedNote: UUID?
    @Published var editingText: UUID?
    @Published var draft: Mark?
    @Published var strip: [NSImage] = []
    @Published var camStrip: [NSImage] = []
    @Published var selectedSeg: UUID?
    @Published var exporting = false
    @Published var hint: String?
    @Published var ready = false
    @Published var cropAspect: CGFloat?   // nil = free
    @Published var hasAudio = false
    private var base = EditState()
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var observer: Any?
    private var hintTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    var escArmed = false

    init(url: URL) {
        self.url = url
        if let (m, s, c) = Present.load(url) {
            meta = m; screenURL = s; cameraURL = c
        } else {
            meta = nil; screenURL = url; cameraURL = nil
        }
        asset = AVURLAsset(url: screenURL)
        camAsset = cameraURL.map { AVURLAsset(url: $0) }
        camPlayer = cameraURL.map { _ in AVPlayer() }
        camPlayer?.isMuted = true
        camPlayer?.actionAtItemEnd = .pause
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            let v = t.seconds
            Task { @MainActor in self?.tick(v) }
        }
        Task { await load() }
    }

    func teardown() {
        player.pause()
        camPlayer?.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        buildTask?.cancel()
    }

    private func load() async {
        // The three reads are independent, so they run together instead of one after another before the editor appears.
        let asset = self.asset
        async let durationLoad = asset.load(.duration)
        async let videoLoad = asset.loadTracks(withMediaType: .video)
        async let audioLoad = asset.loadTracks(withMediaType: .audio)
        var d = ((try? await durationLoad)?.seconds) ?? 0
        if let t = (try? await videoLoad)?.first {
            if let n = try? await t.load(.naturalSize) { natural = n }
            // Measured against the picture: sound can run a few frames past it, and those would play black.
            if let r = try? await t.load(.timeRange), r.end.isNumeric { d = max(0, min(d, r.end.seconds)) }
        }
        hasAudio = !((try? await audioLoad) ?? []).isEmpty
        duration = d
        s.clips = [VClip(start: 0, end: d)]
        if let camAsset, let t = try? await camAsset.loadTracks(withMediaType: .video).first {
            camRange = (try? await t.load(.timeRange)) ?? .zero
        }
        if let meta {
            if cameraURL != nil { s.cam = meta.layout }
            let clips = meta.clips.compactMap { c -> VClip? in
                guard c.count >= 2, c[1] > c[0] else { return nil }
                return VClip(start: max(0, c[0]), end: min(d, c[1]), cam: CamMode(rawValue: Int(c.count > 2 ? c[2] : 0)) ?? .bubble)
            }
            if !clips.isEmpty {
                // Everything you recorded is still here: undo brings the cut retakes back.
                if meta.removed > 0 || clips.count > 1 || clips.first.map({ $0.start > 0.05 || $0.end < d - 0.05 }) == true {
                    var whole = s
                    whole.clips = [VClip(start: 0, end: d)]
                    undoStack = [whole]
                }
                s.clips = clips
            }
            if let c = meta.crop, c.count == 4 { s.crop = CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) }
            if meta.muted == true { s.muted = true }
            if meta.linked == false, let segs = meta.segs {
                s.camLinked = false
                s.camSegs = segs.compactMap { g in
                    guard g.count >= 3, g[1] > g[0] else { return nil }
                    return CamSeg(start: g[0], end: min(d, g[1]), mode: CamMode(rawValue: Int(g[2])) ?? .bubble)
                }
                if s.camSegs.isEmpty { s.camLinked = true }
            }
        }
        base = s
        rebuild(keepTime: 0)
        if let meta, meta.removed > 0 {
            say(meta.removed == 1 ? "1 retake removed. ⌘Z brings it back." : "\(meta.removed) retakes removed. ⌘Z brings them back.")
        }
        withAnimation(gentle) { ready = true }
        // A dense strip of frames from the source; each clip shows the ones from its own range.
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 220, height: 220)
        let tol = CMTime(seconds: max(d / 80, 0.05), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let n = 40
        guard d > 0 else { return }
        // One batched request: the generator decodes forward through the file once, instead of 40 separate
        // seek-and-decode round trips.
        let times = (0..<n).map { CMTime(seconds: d * (Double($0) + 0.5) / Double(n), preferredTimescale: 600) }
        var got: [(Double, NSImage)] = []
        got.reserveCapacity(n)
        for await r in gen.images(for: times) {
            if case .success(let at, let cg, _) = r { got.append((at.seconds, NSImage(cgImage: cg, size: .zero))) }
        }
        let imgs = got.sorted { $0.0 < $1.0 }.map(\.1)
        withAnimation(.easeOut(duration: 0.3)) { strip = imgs }
        // Your camera gets its own small strip for the camera layer.
        if let camAsset {
            let cg = AVAssetImageGenerator(asset: camAsset)
            cg.maximumSize = CGSize(width: 96, height: 96)
            cg.requestedTimeToleranceBefore = tol
            cg.requestedTimeToleranceAfter = tol
            var cams: [NSImage] = []
            for i in 0..<24 {
                let t = CMTime(seconds: d * (Double(i) + 0.5) / 24, preferredTimescale: 600)
                if let r = try? await cg.image(at: t) { cams.append(NSImage(cgImage: r.image, size: .zero)) }
            }
            withAnimation(.easeOut(duration: 0.3)) { camStrip = cams }
        }
    }

    var dirty: Bool { ready && s != base }
    var total: Double { s.clips.reduce(0) { $0 + $1.len } }

    func outStart(_ i: Int) -> Double { s.clips.prefix(i).reduce(0) { $0 + $1.len } }
    var boundaries: [Double] {
        var out: [Double] = [0]
        var t = 0.0
        for c in s.clips { t += c.len; out.append(t) }
        return out
    }
    func locate(_ t: Double) -> (Int, Double)? {
        var a = 0.0
        for (i, c) in s.clips.enumerated() {
            if t < a + c.len || i == s.clips.count - 1 { return (i, min(max(0, t - a), c.len)) }
            a += c.len
        }
        return nil
    }

    // History
    func snapshot() {
        undoStack.append(s)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
        escArmed = false
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(s)
        apply(last)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(s)
        apply(next)
    }
    private func apply(_ st: EditState) {
        let clipsChanged = st.clips.map(\.start) != s.clips.map(\.start) || st.clips.map(\.end) != s.clips.map(\.end)
        withAnimation(gentle) {
            s = st
            if !st.clips.contains(where: { $0.id == selectedClip }) { selectedClip = nil }
            if !st.notes.contains(where: { $0.id == selectedNote }) { selectedNote = nil }
            if !st.camSegs.contains(where: { $0.id == selectedSeg }) { selectedSeg = nil }
        }
        player.isMuted = s.muted
        if clipsChanged { rebuild(keepTime: min(time, total)) }
    }

    func toggleMute() {
        snapshot()
        withAnimation(gentle) { s.muted.toggle() }
        player.isMuted = s.muted
        say(s.muted ? "Sound off. The saved video will be silent." : "Sound on")
    }

    /// While a trim handle moves, show the frame at the new edge (from the composition that is still playing).
    func preview(_ t: Double) {
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600),
                    toleranceBefore: CMTime(value: 1, timescale: 60), toleranceAfter: CMTime(value: 1, timescale: 60))
        camPlayer?.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600),
                        toleranceBefore: CMTime(value: 1, timescale: 30), toleranceAfter: CMTime(value: 1, timescale: 30))
    }

    // Camera
    var hasCamera: Bool { camPlayer != nil }
    /// The camera layer shows under the video once you click into it, open Camera, or unlink it.
    var layersShown: Bool { hasCamera && (selectedClip != nil || selectedSeg != nil || cameraOpen || !s.camLinked) }

    func camMode(atSource t: Double, clip i: Int) -> CamMode {
        if s.camLinked { return s.clips.indices.contains(i) ? s.clips[i].cam : .bubble }
        return s.camSegs.first { t >= $0.start - 0.0001 && t < $0.end }?.mode ?? .bubble
    }
    func camMode(at t: Double) -> CamMode {
        guard let (i, off) = locate(t), s.clips.indices.contains(i) else { return .bubble }
        return camMode(atSource: s.clips[i].start + off, clip: i)
    }
    /// The clip the camera controls act on: the selected one, or the one under the playhead.
    private var camClipIndex: Int? {
        if let id = selectedClip, let i = s.clips.firstIndex(where: { $0.id == id }) { return i }
        return locate(time)?.0
    }
    /// The camera piece the controls act on when unlinked: the selected one, or the one under the playhead.
    private var camSegIndex: Int? {
        if let id = selectedSeg, let i = s.camSegs.firstIndex(where: { $0.id == id }) { return i }
        guard let (i, off) = locate(time), s.clips.indices.contains(i) else { return nil }
        let src = s.clips[i].start + off
        return s.camSegs.firstIndex { src >= $0.start - 0.0001 && src < $0.end }
    }
    func camModeForControls(at t: Double) -> CamMode {
        if !s.camLinked { return camSegIndex.map { s.camSegs[$0].mode } ?? .bubble }
        if let i = camClipIndex, s.clips.indices.contains(i) { return s.clips[i].cam }
        return camMode(at: t)
    }
    func setCamMode(_ md: CamMode) {
        if !s.camLinked {
            guard let i = camSegIndex, s.camSegs[i].mode != md else { return }
            snapshot()
            withAnimation(settle) { s.camSegs[i].mode = md }
            say(md == .full ? "Only you, for this part" : md == .off ? "Camera hidden for this part" : "Camera back in its corner")
            return
        }
        guard let i = camClipIndex, s.clips.indices.contains(i), s.clips[i].cam != md else { return }
        snapshot()
        withAnimation(settle) { s.clips[i].cam = md }
        if s.clips.count > 1 {
            say(md == .full ? "This clip shows only you" : md == .off ? "Camera hidden for this clip" : "Camera back in its corner")
        }
    }

    /// Give the camera its own cuts. Its pieces start out exactly where the video's clips are.
    func unlinkCamera() {
        guard hasCamera, s.camLinked else { return }
        snapshot()
        var pts = Set([0, duration])
        for c in s.clips { pts.insert(c.start); pts.insert(c.end) }
        let p = pts.sorted()
        var segs: [CamSeg] = []
        for k in 0..<(p.count - 1) where p[k + 1] - p[k] > 0.01 {
            let mid = (p[k] + p[k + 1]) / 2
            let md = s.clips.first { mid >= $0.start && mid < $0.end }?.cam ?? .bubble
            if let last = segs.last, last.mode == md, abs(last.end - p[k]) < 0.0001 { segs[segs.count - 1].end = p[k + 1] }
            else { segs.append(CamSeg(start: p[k], end: p[k + 1], mode: md)) }
        }
        withAnimation(gentle) {
            s.camSegs = segs
            s.camLinked = false
            if let id = selectedClip, let c = s.clips.first(where: { $0.id == id }) {
                selectedSeg = segs.first { c.start + 0.001 >= $0.start && c.start < $0.end }?.id
            }
            selectedClip = nil
        }
        say("Camera unlinked. Split it to hide it or show only you for part of a clip.")
    }

    /// Back to one layer: each clip takes the camera setting from its middle.
    func linkCamera() {
        guard !s.camLinked else { return }
        snapshot()
        withAnimation(gentle) {
            for i in s.clips.indices {
                let mid = (s.clips[i].start + s.clips[i].end) / 2
                s.clips[i].cam = s.camSegs.first { mid >= $0.start && mid < $0.end }?.mode ?? .bubble
            }
            s.camLinked = true
            s.camSegs = []
            selectedSeg = nil
        }
        say("Camera linked. Cuts take it along with the video.")
    }

    /// Cut only the camera layer at a point on the timeline.
    func splitCamera(at t: Double) {
        guard hasCamera, let (i, off) = locate(t), s.clips.indices.contains(i) else { return }
        if s.camLinked { unlinkCamera() }
        let src = s.clips[i].start + off
        guard let k = s.camSegs.firstIndex(where: { src > $0.start && src < $0.end }) else { return }
        let g = s.camSegs[k]
        guard src - g.start > 0.08, g.end - src > 0.08 else { say("Too close to an edge to split"); return }
        snapshot()
        let b = CamSeg(start: src, end: g.end, mode: g.mode)
        withAnimation(gentle) {
            s.camSegs[k].end = src
            s.camSegs.insert(b, at: k + 1)
            selectedSeg = b.id
            selectedClip = nil
            selectedNote = nil
        }
    }

    struct CamPiece: Identifiable { let id: String; let x: Double; let len: Double; let src: Double; let mode: CamMode; let clip: UUID?; let seg: UUID? }
    /// The camera layer as drawn on the timeline, in output time.
    func camPieces() -> [CamPiece] {
        var out: [CamPiece] = []
        var x = 0.0
        for c in s.clips {
            if s.camLinked {
                out.append(CamPiece(id: c.id.uuidString, x: x, len: c.len, src: c.start, mode: c.cam, clip: c.id, seg: nil))
            } else {
                for g in s.camSegs where g.end > c.start && g.start < c.end {
                    let a = max(c.start, g.start), b = min(c.end, g.end)
                    out.append(CamPiece(id: g.id.uuidString + c.id.uuidString,
                                        x: x + a - c.start, len: b - a, src: a, mode: g.mode, clip: nil, seg: g.id))
                }
            }
            x += c.len
        }
        return out
    }

    /// What gets rendered: each clip, cut further wherever the unlinked camera changes.
    func renderClips() -> [Present.RenderClip] {
        if s.camLinked { return s.clips.map { .init(start: $0.start, end: $0.end, mode: $0.cam) } }
        var out: [Present.RenderClip] = []
        for c in s.clips {
            var a = c.start
            for g in s.camSegs where g.end > c.start && g.start < c.end {
                let b = min(c.end, g.end)
                if b - a > 0.001 { out.append(.init(start: a, end: b, mode: g.mode)) }
                a = b
            }
            if c.end - a > 0.001 { out.append(.init(start: a, end: c.end, mode: .bubble)) }
        }
        return out
    }
    func setCam(_ change: (inout CamLayout) -> Void) {
        var l = s.cam ?? CamLayout()
        change(&l)
        guard l != s.cam else { return }
        snapshot()
        withAnimation(settle) { s.cam = l }
        CamLayout.saved = l
    }
    func toggleCamera() {
        withAnimation(snappy) {
            cameraOpen.toggle()
            if cameraOpen {
                markupOpen = false; tool = nil; if mode == .crop { applyCrop() }
                // Open on the camera layer, with the part under the playhead picked.
                if selectedClip == nil && selectedSeg == nil {
                    if s.camLinked { selectedClip = camClipIndex.map { s.clips[$0].id } } else { selectedSeg = camSegIndex.map { s.camSegs[$0].id } }
                }
            }
        }
    }

    func say(_ text: String) {
        hintTask?.cancel()
        withAnimation(snappy) { hint = text }
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(snappy) { self?.hint = nil }
        }
    }

    // Playback runs on a composition of the clips, so cut parts are simply not there.
    func rebuild(keepTime: Double) {
        buildTask?.cancel()
        let clips = s.clips
        let asset = self.asset
        buildTask = Task { [weak self] in
            let comp = AVMutableComposition()
            var cur = CMTime.zero
            for c in clips {
                let r = CMTimeRange(start: CMTime(seconds: c.start, preferredTimescale: 6000), end: CMTime(seconds: c.end, preferredTimescale: 6000))
                try? await comp.insertTimeRange(r, of: asset, at: cur)
                cur = cur + r.duration
            }
            guard let self, !Task.isCancelled else { return }
            var camItem: AVPlayerItem?
            if let ca = self.camAsset, let ct = try? await ca.loadTracks(withMediaType: .video).first {
                let cc = AVMutableComposition()
                if let t = cc.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    var at = CMTime.zero
                    for c in clips {
                        let r = CMTimeRange(start: CMTime(seconds: c.start, preferredTimescale: 6000), end: CMTime(seconds: c.end, preferredTimescale: 6000))
                        Present.place(ct, range: r, available: self.camRange, into: t, at: at)
                        at = at + r.duration
                    }
                }
                camItem = AVPlayerItem(asset: cc)
            }
            guard !Task.isCancelled else { return }
            let wasPlaying = self.playing
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
            if let camItem { self.camPlayer?.replaceCurrentItem(with: camItem) }
            self.seek(min(keepTime, self.total))
            if wasPlaying { self.play() }
        }
    }

    private func tick(_ t: Double) {
        guard !t.isNaN else { return }
        // While paused and scrubbing, `seek` already set the time; the landing of an older queued seek must not
        // pull the playhead back. (Only paused ticks are skipped, so the camera sync below is untouched.)
        if !playing, seekInFlight { return }
        let v = min(t, total)
        if abs(v - time) > 0.0005 { time = v }
        if playing, player.rate == 0, time >= total - 0.05 { playing = false; camPlayer?.pause() }
        // Keep your camera on the same frame as the screen.
        // Re-sync on the host clock rather than with an exact seek, which stalls on the camera's keyframes.
        if playing, let cp = camPlayer, abs(cp.currentTime().seconds - v) > 0.15, abs(v - lastResync) > 1 {
            lastResync = v
            let lead = CMTime(value: 1, timescale: 15)
            cp.setRate(1, time: CMTime(seconds: v, preferredTimescale: 6000) + lead, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()) + lead)
        }
    }

    func togglePlay() { playing ? pause() : play() }
    func play() {
        guard ready else { return }
        if time >= total - 0.05 { seek(0) }
        if let cp = camPlayer {
            // Start both on the same host time so the camera does not drift from the slides.
            player.automaticallyWaitsToMinimizeStalling = false
            cp.automaticallyWaitsToMinimizeStalling = false
            let now = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 20)
            let at = CMTime(seconds: time, preferredTimescale: 6000)
            player.setRate(1, time: at, atHostTime: now)
            cp.setRate(1, time: at, atHostTime: now)
        } else {
            player.play()
        }
        playing = true
    }
    func pause() {
        player.pause()
        camPlayer?.pause()
        playing = false
    }
    func seek(_ t: Double) {
        let v = min(max(0, t), total)
        time = v
        chaseSeek(CMTime(seconds: v, preferredTimescale: 6000))
        camPlayer?.seek(to: CMTime(seconds: v, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Scrubbing fires a frame-exact seek per pointer event. AVPlayer cancels a seek when the next one arrives, so
    /// during a fast drag no seek ever finished and the picture froze until the pointer stopped. Here only one seek
    /// is in flight; newer targets replace the queued one and run when it lands, so the frame keeps up with the
    /// playhead and always ends on the exact last position (Apple's "chase seek", QA1820).
    private var seekTarget: CMTime?
    private var seekInFlight = false
    private func chaseSeek(_ t: CMTime) {
        guard player.currentItem != nil else {        // nothing to seek yet (the composition is still being built)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        seekTarget = t
        guard !seekInFlight else { return }
        nextSeek()
    }
    private func nextSeek() {
        guard let t = seekTarget else { seekInFlight = false; return }
        seekTarget = nil
        seekInFlight = true
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.nextSeek() }
        }
    }
    func step(_ d: Double) {
        pause()
        seek(time + d)
    }
    func jumpBoundary(_ forward: Bool) {
        pause()
        let b = boundaries
        if forward { seek(b.first { $0 > time + 0.01 } ?? total) } else { seek(b.last { $0 < time - 0.01 } ?? 0) }
    }

    // Splitting and deleting
    func split(at t: Double) {
        guard ready, let (i, off) = locate(t) else { return }
        let c = s.clips[i]
        guard off > 0.08, c.len - off > 0.08 else { say("Too close to an edge to split"); return }
        snapshot()
        var a = c
        a.end = c.start + off
        let b = VClip(start: c.start + off, end: c.end, cam: c.cam)
        withAnimation(gentle) {
            s.clips[i] = a
            s.clips.insert(b, at: i + 1)
            selectedClip = b.id
            selectedNote = nil
        }
    }

    func deleteClip(_ id: UUID) {
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return }
        guard s.clips.count > 1 else { say("This is the only clip. Split it first, then delete a part."); return }
        snapshot()
        let a = outStart(i), d = s.clips[i].len, b = a + d
        var notes: [VNote] = []
        for var n in s.notes {
            if n.end <= a { notes.append(n); continue }
            if n.start >= b { n.start -= d; n.end -= d; notes.append(n); continue }
            let ns = n.start < a ? n.start : a
            let ne = n.end > b ? n.end - d : a
            if ne - ns >= 0.15 { n.start = ns; n.end = ne; notes.append(n) }
        }
        let keep = time >= b ? time - d : min(time, a)
        withAnimation(gentle) {
            s.clips.remove(at: i)
            s.notes = notes
            selectedClip = nil
        }
        rebuild(keepTime: keep)
    }

    func setClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return }
        if let start { s.clips[i].start = min(max(0, start), s.clips[i].end - 0.15) }
        if let end { s.clips[i].end = max(min(duration, end), s.clips[i].start + 0.15) }
    }

    func deleteSelection() {
        if let id = selectedNote {
            snapshot()
            withAnimation(gentle) { s.notes.removeAll { $0.id == id }; selectedNote = nil }
        } else if let id = selectedClip {
            deleteClip(id)
        } else {
            say("Select a clip or an annotation first")
        }
    }

    // Crop. Never destructive: the full frame is always kept, so you can widen it again later.
    func enterCrop() {
        guard mode != .crop else { return }
        pause()
        snapshot()
        withAnimation(gentle) { mode = .crop; markupOpen = false; tool = nil; selectedNote = nil }
    }
    func applyCrop() {
        guard mode == .crop else { return }
        if let c = s.crop, c.width > 0.995, c.height > 0.995 { s.crop = nil }
        withAnimation(gentle) { mode = .edit }
    }
    func setAspect(_ r: CGFloat?) {
        cropAspect = r
        guard let r else { return }
        let A = natural.width / max(natural.height, 1)
        var w: CGFloat = 1, h: CGFloat = 1
        if r > A { h = A / r } else { w = r / A }
        withAnimation(gentle) { s.crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h) }
    }
    func resetCrop() {
        cropAspect = nil
        withAnimation(gentle) { s.crop = nil }
    }

    // Annotations live in output time, on a layer above the clips.
    func visibleNotes(at t: Double) -> [VNote] { s.notes.filter { $0.start <= t + 0.0001 && t < $0.end } }

    func addNote(_ m: Mark) {
        snapshot()
        let start = time
        var end = min(total, start + 3)
        if let cut = boundaries.first(where: { $0 > start + 0.5 && $0 < end }) { end = cut }   // stop at the next cut
        if end - start < 0.3 { end = min(total, start + 0.3) }
        let n = VNote(mark: m, start: start, end: end)
        withAnimation(gentle) { s.notes.append(n); selectedNote = n.id; selectedClip = nil }
    }

    func nextStep() -> Int { (s.notes.filter { $0.mark.tool == .step }.map(\.mark.n).max() ?? 0) + 1 }

    func noteBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { self.s.notes.first { $0.id == id }?.mark.text ?? "" },
                set: { v in if let i = self.s.notes.firstIndex(where: { $0.id == id }) { self.s.notes[i].mark.text = v } })
    }

    func commitText() {
        guard let id = editingText else { return }
        editingText = nil
        if let i = s.notes.firstIndex(where: { $0.id == id }), s.notes[i].mark.text.trimmingCharacters(in: .whitespaces).isEmpty {
            s.notes.remove(at: i)
            if selectedNote == id { selectedNote = nil }
        }
    }

    func hit(_ p: CGPoint) -> VNote? { visibleNotes(at: time).reversed().first { noteBox($0.mark).contains(p) } }

    func noteBox(_ m: Mark) -> CGRect {
        let pad: CGFloat = 0.02
        switch m.tool {
        case .text:
            guard let p = m.pts.first else { return .zero }
            let w = CGFloat(max(m.text.count, 3)) * 0.03 * natural.height / max(natural.width, 1)
            return CGRect(x: p.x - pad, y: p.y - 0.035, width: w + pad * 2, height: 0.07)
        case .step:
            guard let p = m.pts.first else { return .zero }
            return CGRect(x: p.x - 0.035, y: p.y - 0.035, width: 0.07, height: 0.07)
        default:
            guard m.pts.count >= 2 else { return .zero }
            return box(m.pts[0], m.pts[1]).insetBy(dx: -pad, dy: -pad)
        }
    }

    func moveNote(_ id: UUID, to pts: [CGPoint]) {
        if let i = s.notes.firstIndex(where: { $0.id == id }) { s.notes[i].mark.pts = pts }
    }

    func setNoteTime(_ id: UUID, start: Double, end: Double) {
        guard let i = s.notes.firstIndex(where: { $0.id == id }) else { return }
        let a = max(0, min(start, total - 0.15))
        s.notes[i].start = a
        s.notes[i].end = min(total, max(end, a + 0.15))
    }

    func setColor(_ c: Int) {
        color = c
        if let id = selectedNote, let i = s.notes.firstIndex(where: { $0.id == id }), s.notes[i].mark.color != c {
            snapshot()
            s.notes[i].mark.color = c
        }
    }

    func pick(_ t: MarkTool?) {
        withAnimation(snappy) {
            tool = t
            if t != nil { markupOpen = true; cameraOpen = false; if mode == .crop { applyCrop() }; mode = .edit }
        }
    }

    // Export: the clips in order, cropped, annotations burned in. Returns the new file.
    func export() async throws -> URL {
        guard !s.clips.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        if meta != nil { return try await exportPresentation() }
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        for c in s.clips {
            let range = CMTimeRange(start: CMTime(seconds: c.start, preferredTimescale: 6000), end: CMTime(seconds: c.end, preferredTimescale: 6000))
            try await comp.insertTimeRange(range, of: asset, at: cursor)
            cursor = cursor + range.duration
        }
        if s.muted { for t in comp.tracks(withMediaType: .audio) { comp.removeTrack(t) } }
        guard let vtrack = comp.tracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let total = cursor.seconds
        let W = natural.width, H = natural.height
        let c = s.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let cx = (c.minX * W).rounded(), cy = (c.minY * H).rounded()
        let rw = CGFloat(RecEngine.even(c.width * W)), rh = CGFloat(RecEngine.even(c.height * H))

        let vc = AVMutableVideoComposition()
        let fps = (try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 60
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(fps.rounded(), 24), 60)))
        vc.renderSize = CGSize(width: rw, height: rh)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: cursor)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vtrack)
        li.setTransform(CGAffineTransform(translationX: -cx, y: -cy), at: .zero)
        ins.layerInstructions = [li]
        vc.instructions = [ins]

        let notes = s.notes.filter { $0.start < total && $0.end > 0 }
        if !notes.isEmpty, total > 0 {
            let parent = CALayer()
            parent.frame = CGRect(x: 0, y: 0, width: rw, height: rh)
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            for n in notes {
                guard let img = render(n.mark) else { continue }
                let l = CALayer()
                l.frame = CGRect(x: -cx, y: -(H - cy - rh), width: W, height: H)   // Core Animation's origin is bottom left
                l.contents = img
                l.opacity = 0
                let a = max(0, n.start) / total, b = min(n.end, total) / total
                let anim = CAKeyframeAnimation(keyPath: "opacity")
                anim.calculationMode = .discrete
                anim.values = a > 0 ? [0, 1, 0] : [1, 0]
                anim.keyTimes = (a > 0 ? [0, a, b, 1] : [0, b, 1]).map { NSNumber(value: $0) }
                anim.duration = total
                anim.beginTime = AVCoreAnimationBeginTimeAtZero
                anim.isRemovedOnCompletion = false
                anim.fillMode = .both
                l.add(anim, forKey: "show")
                parent.addSublayer(l)
            }
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        }

        let out = Recordings.sibling(url, "edited")
        let preset: String
        switch (RecPrefs.hevc, RecPrefs.quality) {
        case (true, 0): preset = AVAssetExportPresetHEVC1920x1080
        case (true, _): preset = AVAssetExportPresetHEVCHighestQuality
        case (false, 0): preset = AVAssetExportPreset1920x1080
        default: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = vc
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        if !RecPrefs.keepOriginal, (try? FileManager.default.replaceItemAt(url, withItemAt: out)) != nil { return url }
        return out
    }

    /// A presentation saves through the same compositor that made it, so the camera can keep moving later.
    private func exportPresentation() async throws -> URL {
        let total = self.total
        let notes = s.notes.filter { $0.start < total && $0.end > 0 }.compactMap { n in render(n.mark).map { ($0, n.start, n.end) } }
        let out = Recordings.sibling(url, "edited")
        let layout = s.cam ?? meta?.layout ?? CamLayout()
        try await Present.render(screen: screenURL, camera: cameraURL, clips: renderClips(),
                                 layout: layout, notes: notes, crop: s.crop, muted: s.muted, to: out)
        var final = out
        if !RecPrefs.keepOriginal, (try? FileManager.default.replaceItemAt(url, withItemAt: out)) != nil { final = url }
        var m = meta ?? PresentMeta(screen: screenURL.lastPathComponent, camera: cameraURL?.lastPathComponent, layout: layout, clips: [])
        m.layout = layout
        m.clips = s.clips.map { [$0.start, $0.end, Double($0.cam.rawValue)] }
        m.removed = 0
        m.crop = s.crop.map { [$0.minX, $0.minY, $0.width, $0.height] }
        m.muted = s.muted
        m.linked = s.camLinked
        m.segs = s.camLinked ? nil : s.camSegs.map { [$0.start, $0.end, Double($0.mode.rawValue)] }
        Present.save(m, for: final)
        return final
    }

    private func render(_ m: Mark) -> CGImage? {
        let size = natural
        let r = ImageRenderer(content: Canvas { ctx, s in drawMarks(ctx, size: s, marks: [m], pixelated: nil) }
            .frame(width: size.width, height: size.height))
        r.scale = 1
        r.isOpaque = false
        return r.cgImage
    }
}

// MARK: - Views

final class PlayerNSView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resize
    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.wantsLayer = true
        (v.layer as? AVPlayerLayer)?.player = player
        (v.layer as? AVPlayerLayer)?.videoGravity = gravity
        return v
    }
    func updateNSView(_ v: PlayerNSView, context: Context) {}
}

struct VideoEditorView: View {
    @ObservedObject var m: VideoEditorModel
    let done: () -> Void

    var body: some View {
        ZStack {
            editorBG.ignoresSafeArea()
                .onTapGesture {
                    if m.mode == .crop { m.applyCrop(); return }
                    if m.editingText != nil { m.commitText() }
                    withAnimation(snappy) { m.selectedClip = nil; m.selectedNote = nil; m.selectedSeg = nil }
                }
            VStack(spacing: 0) {
                GeometryReader { geo in
                    StageView(m: m, avail: geo.size)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .padding(.horizontal, 32).padding(.top, 44)
                ContextBar(m: m).frame(height: 46)
                TimelineView2(m: m)
                    .frame(height: m.layersShown ? 154 : 118)
                    .animation(gentle, value: m.layersShown)
                    .padding(.horizontal, 24)
                VStack(spacing: 8) {
                    if m.markupOpen { MarkupTray(m: m).transition(.modifier(active: Pop(s: 0.94, b: 6, o: 0, y: 10), identity: .rest)) }
                    if m.cameraOpen { CameraTray(m: m, clock: m.clock).transition(.modifier(active: Pop(s: 0.94, b: 6, o: 0, y: 10), identity: .rest)) }
                    EditorBar(m: m, done: done)
                }
                .padding(.top, 10).padding(.bottom, 18)
            }
            VStack {
                if let h = m.hint {
                    Text(h).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .transition(.modifier(active: Pop(s: 0.94, b: 6, o: 0, y: -8), identity: .rest))
                }
                Spacer()
            }
            .padding(.top, 12)
            .allowsHitTesting(false)
            if m.exporting {
                Color.black.opacity(0.35).ignoresSafeArea().transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(gentle, value: m.markupOpen)
        .animation(gentle, value: m.cameraOpen)
    }
}

/// The video, shown cropped when not cropping, and as the full frame with a crop box while cropping.
struct StageView: View {
    @ObservedObject var m: VideoEditorModel
    let avail: CGSize
    @FocusState private var textFocus: Bool
    @State private var dragOrigin: [CGPoint]?
    @State private var dragNote: UUID?
    @State private var wasSelected: UUID?

    var body: some View {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let c = m.mode == .crop ? full : (m.s.crop ?? full)
        let shown = CGSize(width: max(m.natural.width * c.width, 1), height: max(m.natural.height * c.height, 1))
        let k = min(avail.width / shown.width, avail.height / shown.height)
        let fit = CGSize(width: shown.width * k, height: shown.height * k)
        let inner = CGSize(width: fit.width / c.width, height: fit.height / c.height)
        ZStack(alignment: .topLeading) {
            content(inner)
                .frame(width: inner.width, height: inner.height)
                .offset(x: -c.minX * inner.width, y: -c.minY * inner.height)
        }
        .frame(width: fit.width, height: fit.height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if m.hasCamera && m.mode != .crop {
                CamOverlay(m: m, clock: m.clock, area: CGRect(origin: .zero, size: fit))
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        // A shape shadow, not .shadow: the latter is computed from the rendered contents, so every video frame and
        // every 30 Hz annotation redraw paid for an offscreen 24pt blur of the whole stage during playback.
        .background(ShapeShadow(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), color: .black.opacity(0.5), radius: 24, y: 12))
        .opacity(m.ready ? 1 : 0)
        .scaleEffect(m.ready ? 1 : 0.97)
    }

    @ViewBuilder func content(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            PlayerSurface(player: m.player)
            NotesLayer(m: m, clock: m.clock)
            if m.mode != .crop {
                Color.clear.contentShape(Rectangle()).gesture(drawGesture(size))
                    .onContinuousHover { _ in if m.tool != nil { NSCursor.crosshair.set() } else { NSCursor.arrow.set() } }
            }
            if let id = m.editingText, let n = m.s.notes.first(where: { $0.id == id }), let p = n.mark.pts.first {
                TextField("Type, then Return", text: m.noteBinding(id))
                    .textFieldStyle(.plain)
                    .font(.system(size: unit(size) * 5, weight: .semibold))
                    .foregroundStyle(palette[n.mark.color])
                    .frame(width: max(200, size.width - p.x * size.width - 12), alignment: .leading)
                    .focused($textFocus)
                    .onSubmit { m.commitText() }
                    .offset(x: p.x * size.width, y: p.y * size.height - unit(size) * 3.2)
                    .onAppear { textFocus = true }
            }
            if m.mode == .crop { CropBox(m: m, size: size) }
        }
    }

    func drawGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let a = CGPoint(x: g.startLocation.x / size.width, y: g.startLocation.y / size.height)
                let b = CGPoint(x: g.location.x / size.width, y: g.location.y / size.height)
                if m.editingText != nil { m.commitText() }
                switch m.tool {
                case nil:
                    if dragOrigin == nil {
                        if let n = m.hit(a) {
                            wasSelected = m.selectedNote
                            m.snapshot()
                            dragNote = n.id
                            dragOrigin = n.mark.pts
                            withAnimation(snappy) { m.selectedNote = n.id; m.selectedClip = nil }
                        } else {
                            dragOrigin = []
                            dragNote = nil
                        }
                    }
                    if let id = dragNote, let o = dragOrigin {
                        m.moveNote(id, to: o.map { CGPoint(x: $0.x + b.x - a.x, y: $0.y + b.y - a.y) })
                    }
                case .arrow?, .rect?:
                    m.draft = Mark(tool: m.tool!.tool, color: m.color, pts: [a, b])
                default:
                    break
                }
            }
            .onEnded { g in
                let a = CGPoint(x: g.startLocation.x / size.width, y: g.startLocation.y / size.height)
                let b = CGPoint(x: g.location.x / size.width, y: g.location.y / size.height)
                let moved = hypot(g.translation.width, g.translation.height) > 4
                switch m.tool {
                case nil:
                    if !moved, let id = dragNote, wasSelected == id,
                       let n = m.s.notes.first(where: { $0.id == id }), n.mark.tool == .text {
                        m.editingText = id                 // a second click on text edits it
                    } else if dragNote == nil, !moved {
                        if m.selectedNote != nil || m.selectedClip != nil {
                            withAnimation(snappy) { m.selectedNote = nil; m.selectedClip = nil }
                        } else {
                            m.togglePlay()
                        }
                    }
                    dragOrigin = nil
                    dragNote = nil
                case .arrow?, .rect?:
                    m.draft = nil
                    if moved { m.addNote(Mark(tool: m.tool!.tool, color: m.color, pts: [a, b])) }
                case .step?:
                    m.addNote(Mark(tool: .step, color: m.color, pts: [b], n: m.nextStep()))
                case .text?:
                    m.addNote(Mark(tool: .text, color: m.color, pts: [b]))
                    m.editingText = m.selectedNote
                }
            }
    }
}

/// Crop box over the full frame. Drag inside to move, corners and edges to resize. Click outside applies.
struct NotesLayer: View {
    @ObservedObject var m: VideoEditorModel
    @ObservedObject var clock: PlayClock
    var body: some View {
        Canvas { ctx, s in
            let visible = m.visibleNotes(at: clock.t)
            var marks = visible.filter { $0.id != m.editingText }.map(\.mark)
            if let d = m.draft { marks.append(d) }
            drawMarks(ctx, size: s, marks: marks, pixelated: nil)
            if m.mode != .crop, let id = m.selectedNote, let n = visible.first(where: { $0.id == id }) {
                let b = m.noteBox(n.mark)
                let r = CGRect(x: b.minX * s.width, y: b.minY * s.height, width: b.width * s.width, height: b.height * s.height)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(accent),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
    }
}

struct PlayheadView: View {
    @ObservedObject var clock: PlayClock
    let pps: CGFloat
    let height: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.white).frame(width: 2, height: height)
            RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 14)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .frame(width: 12)
        .offset(x: CGFloat(clock.t) * pps - 6)
        .allowsHitTesting(false)
    }
}

struct TimeLabel: View {
    @ObservedObject var clock: PlayClock
    let total: Double
    var body: some View {
        Text("\(Recordings.precise(clock.t)) / \(Recordings.precise(total))")
            .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            .frame(width: 112)
    }
}

struct CropBox: View {
    @ObservedObject var m: VideoEditorModel
    let size: CGSize
    @State private var origin: CGRect?

    var body: some View {
        let r = m.s.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let R = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(R)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .contentShape(Rectangle())
            .onTapGesture { m.applyCrop() }
            ZStack {
                Path { p in
                    for i in 1...2 {
                        let x = R.width * CGFloat(i) / 3, y = R.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: R.height))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: R.width, y: y))
                    }
                }
                .stroke(.white.opacity(0.3), lineWidth: 0.7)
                Rectangle().strokeBorder(.white, lineWidth: 1.5)
            }
            .frame(width: R.width, height: R.height)
            .contentShape(Rectangle())
            .offset(x: R.minX, y: R.minY)
            .onContinuousHover { _ in NSCursor.openHand.set() }
            .gesture(DragGesture().onChanged { g in
                let o = begin(r)
                var n = o.offsetBy(dx: g.translation.width / size.width, dy: g.translation.height / size.height)
                n.origin.x = min(max(0, n.origin.x), 1 - n.width)
                n.origin.y = min(max(0, n.origin.y), 1 - n.height)
                m.s.crop = n
            }.onEnded { _ in origin = nil })
            ForEach(0..<4, id: \.self) { i in
                corner(i, R: R, r: r)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    func corner(_ i: Int, R: CGRect, r: CGRect) -> some View {
        let left = i % 2 == 0, top = i < 2
        let cx = left ? R.minX : R.maxX, cy = top ? R.minY : R.maxY
        return ZStack {
            Color.clear
            Path { p in
                let L: CGFloat = 16, o = CGPoint(x: 18, y: 18)
                let sx: CGFloat = left ? 1 : -1, sy: CGFloat = top ? 1 : -1
                p.move(to: CGPoint(x: o.x, y: o.y + sy * L)); p.addLine(to: o); p.addLine(to: CGPoint(x: o.x + sx * L, y: o.y))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .offset(x: cx - 18, y: cy - 18)
        .onContinuousHover { _ in NSCursor.crosshair.set() }
        .gesture(DragGesture().onChanged { g in
                let o = begin(r)
                let dx = g.translation.width / size.width, dy = g.translation.height / size.height
                var x0 = o.minX, y0 = o.minY, x1 = o.maxX, y1 = o.maxY
                if left { x0 = min(max(0, x0 + dx), x1 - 0.06) } else { x1 = max(min(1, x1 + dx), x0 + 0.06) }
                if top { y0 = min(max(0, y0 + dy), y1 - 0.06) } else { y1 = max(min(1, y1 + dy), y0 + 0.06) }
                if let a = m.cropAspect {
                    let A = m.natural.width / max(m.natural.height, 1)
                    let h = (x1 - x0) * A / a
                    if top { y0 = max(0, y1 - h) } else { y1 = min(1, y0 + h) }
                }
                m.s.crop = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }.onEnded { _ in origin = nil })
    }

    private func begin(_ r: CGRect) -> CGRect {
        if let origin { return origin }
        origin = r
        return r
    }
}

/// The strip between the video and the timeline: says what is selected and offers the one thing to do with it.
struct ContextBar: View {
    @ObservedObject var m: VideoEditorModel

    var body: some View {
        ZStack {
            if m.mode == .crop {
                cropControls.transition(.modifier(active: Pop(s: 0.95, b: 6, o: 0, y: 6), identity: .rest))
            } else if m.mode == .blade {
                pill {
                    SplitGlyph().foregroundStyle(.white)
                    Text("Click where to split").foregroundStyle(.white.opacity(0.85))
                    action("Cancel", "Esc") { withAnimation(gentle) { m.mode = .edit } }
                }
                .transition(.modifier(active: Pop(s: 0.95, b: 6, o: 0, y: 6), identity: .rest))
            } else if let id = m.selectedNote, let n = m.s.notes.first(where: { $0.id == id }) {
                pill {
                    ForEach(palette.indices, id: \.self) { i in
                        Button { m.setColor(i) } label: {
                            Circle().fill(palette[i]).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.white, lineWidth: n.mark.color == i ? 2 : 0).padding(-3))
                                .frame(width: 22, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(Squish())
                    }
                    action("Delete", "⌫", destructive: true) { m.deleteSelection() }
                }
                .transition(.modifier(active: Pop(s: 0.95, b: 6, o: 0, y: 6), identity: .rest))
            } else if let id = m.selectedSeg, let g = m.s.camSegs.first(where: { $0.id == id }) {
                pill {
                    Image(systemName: "person.crop.square").foregroundStyle(.white.opacity(0.6))
                    Text(Recordings.precise(g.end - g.start)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                    divider
                    camModes(g.mode)
                    divider
                    action("Split camera", "Cut only the camera at the playhead  S") { m.splitCamera(at: m.time) }
                }
                .transition(.modifier(active: Pop(s: 0.95, b: 6, o: 0, y: 6), identity: .rest))
            } else if let id = m.selectedClip, let i = m.s.clips.firstIndex(where: { $0.id == id }) {
                pill {
                    Text(Recordings.precise(m.s.clips[i].len)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                    if m.hasCamera && m.s.camLinked {
                        divider
                        camModes(m.s.clips[i].cam)
                    }
                    if m.s.clips.count > 1 {
                        divider
                        action("Delete clip", "⌫", destructive: true) { m.deleteSelection() }
                    }
                }
                .transition(.modifier(active: Pop(s: 0.95, b: 6, o: 0, y: 6), identity: .rest))
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .animation(gentle, value: m.mode)
        .animation(gentle, value: m.selectedClip)
        .animation(gentle, value: m.selectedNote)
        .animation(gentle, value: m.selectedSeg)
    }

    var divider: some View { Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16) }

    /// Bubble, only you, or hidden: for the selected clip, or the selected piece of an unlinked camera.
    func camModes(_ current: CamMode) -> some View {
        HStack(spacing: 2) {
            ForEach(CamMode.allCases, id: \.self) { md in
                let on = current == md
                Button { m.setCamMode(md) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: md.symbol).font(.system(size: 10.5, weight: .bold))
                        Text(md.label)
                    }
                    .foregroundStyle(on ? onAccent : Color.white.opacity(0.85))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(on ? accent : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(Squish())
                .help(md == .bubble ? "Your camera in its corner" : md == .full ? "Only you, full frame" : "Hide your camera here")
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .animation(gentle, value: current)
    }

    var cropControls: some View {
        pill {
            Text("Aspect").foregroundStyle(.white.opacity(0.5))
            ForEach([("Free", CGFloat?.none), ("16:9", CGFloat?(16.0 / 9)), ("4:3", CGFloat?(4.0 / 3)), ("1:1", CGFloat?(1)), ("9:16", CGFloat?(9.0 / 16))], id: \.0) { item in
                let on = m.cropAspect == item.1
                Button { m.setAspect(item.1) } label: {
                    Text(item.0).foregroundStyle(on ? onAccent : Color.white.opacity(0.85))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(on ? accent : Color.white.opacity(0.08)))
                }
                .buttonStyle(Squish())
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
            action("Full frame", "Undo the crop. Nothing was cut away.") { m.resetCrop() }
            action("Done", "Apply the crop  Return", primary: true) { m.applyCrop() }
        }
    }

    func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .padding(.leading, 14).padding(.trailing, 5).frame(height: 36)
            .background(Capsule().fill(editorPanel))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    func action(_ title: String, _ help: String, primary: Bool = false, destructive: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .foregroundStyle(primary ? onAccent : (destructive ? Color(red: 1, green: 0.45, blue: 0.4) : Color.white))
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(primary ? accent : Color.white.opacity(0.08)))
        }
        .buttonStyle(Squish()).help(help)
    }
}

/// Ruler, clips, annotation lane and playhead.
struct TimelineView2: View {
    @ObservedObject var m: VideoEditorModel
    @State private var frozenPPS: CGFloat?
    @State private var trim: (id: UUID, left: Bool, start: Double, end: Double, dx: CGFloat)?
    @State private var noteDrag: (id: UUID, start: Double, end: Double)?
    @State private var bladeX: CGFloat?

    let rulerH: CGFloat = 20, clipH: CGFloat = 56, laneH: CGFloat = 22, camH: CGFloat = 30
    var camGap: CGFloat { m.layersShown ? camH + 6 : 0 }

    var body: some View {
        GeometryReader { g in
            let W = g.size.width
            let pps = frozenPPS ?? W / CGFloat(max(m.total, 0.1))
            let x = { (t: Double) -> CGFloat in CGFloat(t) * pps }
            ZStack(alignment: .topLeading) {
                ruler(W, pps)
                clipsRow(W, pps)
                    .offset(y: rulerH)
                if m.layersShown {
                    camLane(W, pps)
                        .offset(y: rulerH + clipH + 6)
                        .transition(.modifier(active: Pop(s: 0.98, b: 4, o: 0, y: -10), identity: .rest))
                }
                lane(W, pps)
                    .offset(y: rulerH + clipH + 10 + camGap)
                if m.mode == .blade, let bx = bladeX {
                    let snapped = abs(bx - x(m.time)) < 10
                    let px = snapped ? x(m.time) : bx
                    Rectangle().fill(snapped ? accent : Color.white).frame(width: 2, height: clipH + 12)
                        .overlay(alignment: .top) {
                            Image(systemName: "scissors").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 20, height: 20).background(Circle().fill(snapped ? accent : Color.white))
                                .offset(y: -22)
                        }
                        .offset(x: px - 1, y: rulerH - 6)
                        .allowsHitTesting(false)
                }
                PlayheadView(clock: m.clock, pps: pps, height: rulerH + clipH + laneH + 14 + camGap)
            }
            .frame(width: W, height: g.size.height, alignment: .topLeading)
            .coordinateSpace(name: "tl")
        }
    }

    func ruler(_ W: CGFloat, _ pps: CGFloat) -> some View {
        let total = m.total
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { CGFloat($0) * pps >= 70 } ?? 600
        let ticks = total > 0 ? Array(stride(from: 0.0, through: total, by: step)) : []
        return ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
            ForEach(ticks, id: \.self) { t in
                let whole = abs(t - t.rounded()) < 0.001
                VStack(alignment: .leading, spacing: 2) {
                    Text(whole ? Recordings.time(t) : " ").font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                    Rectangle().fill(.white.opacity(whole ? 0.3 : 0.15)).frame(width: 1, height: whole ? 5 : 3)
                }
                .offset(x: CGFloat(t) * pps)
            }
        }
        .frame(width: W, height: rulerH, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            m.pause()
            m.seek(Double(min(max(0, v.location.x), W) / pps))
        }.onEnded { _ in
            withAnimation(snappy) { m.selectedClip = nil; m.selectedNote = nil }
        })
        .onContinuousHover { _ in NSCursor.resizeLeftRight.set() }
    }

    func clipsRow(_ W: CGFloat, _ pps: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04))
                .frame(width: W, height: clipH)
            ForEach(Array(m.s.clips.enumerated()), id: \.element.id) { i, c in
                let x0 = CGFloat(m.outStart(i)) * pps
                let w = CGFloat(c.len) * pps
                let live = trim?.id == c.id ? trim : nil
                let dx = (live?.left ?? false) ? (live?.dx ?? 0) : 0
                ClipBlock(m: m, clip: c, width: max(4, w - dx), selected: m.selectedClip == c.id)
                    .offset(x: x0 + dx)
                    .transition(.modifier(active: Pop(s: 0.85, b: 6, o: 0), identity: .rest))
                    .overlay(alignment: .topLeading) {
                        if m.mode == .edit {
                            let sel = m.selectedClip == c.id
                            if sel || i == 0 { handle(c, i, left: true, pps).offset(x: x0 + dx - 1) }
                            if sel || i == m.s.clips.count - 1 { handle(c, i, left: false, pps).offset(x: x0 + w - 13) }
                        }
                    }
            }
        }
        .frame(width: W, height: clipH, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard m.mode != .blade else { return }
            m.pause()
            m.seek(Double(min(max(0, v.location.x), W) / pps))
        }.onEnded { v in
            let t = Double(min(max(0, v.location.x), W) / pps)
            if m.mode == .blade {
                let snapped = abs(v.location.x - CGFloat(m.time) * pps) < 10
                m.split(at: snapped ? m.time : t)
                if !snapped { m.seek(t) }
                withAnimation(gentle) { m.mode = .edit }      // one cut, then back to normal
                NSCursor.arrow.set()
                return
            }
            if abs(v.translation.width) < 3 {
                withAnimation(gentle) {
                    m.selectedNote = nil
                    m.selectedSeg = nil
                    // Clicking into a recording with a camera opens its camera layer.
                    if m.s.clips.count > 1 || m.hasCamera, let (i, _) = m.locate(t) { m.selectedClip = m.s.clips[i].id } else { m.selectedClip = nil }
                }
            }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                bladeX = p.x
                if m.mode == .blade { NSCursor.blade.set() } else { NSCursor.arrow.set() }
            case .ended:
                bladeX = nil
            }
        }
    }

    func handle(_ c: VClip, _ i: Int, left: Bool, _ pps: CGFloat) -> some View {
        let sel = m.selectedClip == c.id
        return RoundedRectangle(cornerRadius: 4, style: .continuous).fill(sel ? accent : Color.white)
            .frame(width: 14, height: clipH)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 13, weight: .heavy)).foregroundStyle((sel ? onAccent : Color.black).opacity(0.65)))
            .contentShape(Rectangle().inset(by: -6))
            .onContinuousHover { _ in NSCursor.resizeLeftRight.set() }
            // Measured in the timeline's own space, so the handle moving under the cursor cannot feed back.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { v in
                if trim == nil {
                    m.snapshot()
                    m.pause()
                    frozenPPS = pps
                    trim = (c.id, left, c.start, c.end, 0)
                }
                guard let t0 = trim else { return }
                let p = frozenPPS ?? pps
                let d = Double(v.translation.width / p)
                let out0 = m.outStart(i)
                if left {
                    let ns = min(max(0, t0.start + d), t0.end - 0.15)
                    trim?.dx = CGFloat(ns - t0.start) * p
                    if ns >= t0.start { m.preview(out0 + ns - t0.start) }
                } else {
                    let ne = max(min(m.duration, t0.end + d), t0.start + 0.15)
                    m.setClip(c.id, end: ne)
                    if ne <= t0.end { m.preview(out0 + ne - t0.start - 0.02) }
                }
            }.onEnded { _ in
                if let t0 = trim, t0.left, let p = frozenPPS {
                    let ns = t0.start + Double(t0.dx / p)
                    withAnimation(gentle) { m.setClip(c.id, start: ns); trim = nil }
                } else {
                    trim = nil
                }
                withAnimation(gentle) { frozenPPS = nil }
                m.rebuild(keepTime: left ? m.outStart(i) : m.outStart(i) + (m.s.clips.first { $0.id == c.id }?.len ?? 0) - 0.03)
            })
    }

    /// Your camera, as its own layer under the video. Linked, its pieces are the video's clips; unlinked, it has its own cuts.
    func camLane(_ W: CGFloat, _ pps: CGFloat) -> some View {
        let pieces = m.camPieces()
        return ZStack(alignment: .topLeading) {
            ForEach(pieces) { p in
                CamPieceView(m: m, piece: p, width: max(4, CGFloat(p.len) * pps),
                             selected: p.clip.map { $0 == m.selectedClip } ?? (p.seg == m.selectedSeg && p.seg != nil))
                    .offset(x: CGFloat(p.x) * pps)
                    .transition(.modifier(active: Pop(s: 0.9, b: 4, o: 0), identity: .rest))
            }
            Button { m.s.camLinked ? m.unlinkCamera() : m.linkCamera() } label: {
                HStack(spacing: 5) {
                    Image(systemName: m.s.camLinked ? "link" : "link.badge.plus").font(.system(size: 10, weight: .bold))
                    Text(m.s.camLinked ? "Linked" : "Link").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(m.s.camLinked ? Color.white.opacity(0.85) : onAccent)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(m.s.camLinked ? Color.black.opacity(0.6) : accent))
                .contentShape(Capsule())
            }
            .buttonStyle(Squish())
            .help(m.s.camLinked ? "Your camera moves with every cut. Click to give it its own cuts."
                                : "Your camera has its own cuts. Click to make it follow the video again.")
            .offset(x: 4, y: 4)
            .animation(gentle, value: m.s.camLinked)
        }
        .frame(width: W, height: camH, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard m.mode != .blade else { return }
            m.pause()
            m.seek(Double(min(max(0, v.location.x), W) / pps))
        }.onEnded { v in
            let t = Double(min(max(0, v.location.x), W) / pps)
            if m.mode == .blade {
                let snapped = abs(v.location.x - CGFloat(m.time) * pps) < 10
                m.splitCamera(at: snapped ? m.time : t)
                if !snapped { m.seek(t) }
                withAnimation(gentle) { m.mode = .edit }
                NSCursor.arrow.set()
                return
            }
            guard abs(v.translation.width) < 3, let p = pieces.first(where: { t >= $0.x && t < $0.x + $0.len }) ?? pieces.last else { return }
            withAnimation(gentle) {
                m.selectedNote = nil
                if let c = p.clip { m.selectedClip = c; m.selectedSeg = nil } else { m.selectedSeg = p.seg; m.selectedClip = nil }
            }
        })
        .onContinuousHover { phase in
            if case .active = phase, m.mode == .blade { NSCursor.blade.set() }
        }
    }

    func lane(_ W: CGFloat, _ pps: CGFloat) -> some View {
        let snaps = m.boundaries + [m.time]
        let snap = { (t: Double) -> Double in
            if let s = snaps.min(by: { abs($0 - t) < abs($1 - t) }), CGFloat(abs(s - t)) * pps < 8 { return s }
            return t
        }
        return ZStack(alignment: .topLeading) {
            if m.s.notes.isEmpty && m.markupOpen {
                Text("Draw on the video to add an annotation")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.3))
                    .frame(width: W, height: laneH)
                    .transition(.opacity)
            }
            ForEach(m.s.notes) { n in
                let sel = m.selectedNote == n.id
                let x0 = CGFloat(n.start) * pps, w = max(18, CGFloat(n.end - n.start) * pps)
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                ZStack {
                    shape.fill(palette[n.mark.color].opacity(sel ? 0.95 : 0.6))
                    HStack(spacing: 4) {
                        Image(systemName: n.mark.tool.symbol).font(.system(size: 9.5, weight: .bold))
                        if w > 70 { Text(n.mark.tool == .text && !n.mark.text.isEmpty ? n.mark.text : n.mark.tool.label).lineLimit(1) }
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(n.mark.color == 4 || n.mark.color == 1 ? Color.black : Color.white)
                    .padding(.horizontal, 12)
                    .frame(width: w, alignment: .leading)
                }
                .overlay(shape.strokeBorder(accent, lineWidth: sel ? 2 : 0))
                .frame(width: w, height: laneH)
                .contentShape(shape)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { v in
                    if noteDrag == nil { m.snapshot(); noteDrag = (n.id, n.start, n.end); withAnimation(snappy) { m.selectedNote = n.id; m.selectedClip = nil } }
                    guard let d = noteDrag else { return }
                    let len = d.end - d.start
                    var s0 = d.start + Double(v.translation.width / pps)
                    let a = snap(s0), b = snap(s0 + len)
                    if a != s0 { s0 = a } else if b != s0 + len { s0 = b - len }
                    s0 = min(max(0, s0), m.total - len)
                    m.setNoteTime(n.id, start: s0, end: s0 + len)
                }.onEnded { _ in
                    noteDrag = nil
                    if let n2 = m.s.notes.first(where: { $0.id == n.id }), !(n2.start <= m.time && m.time < n2.end) { m.pause(); m.seek(n2.start) }
                })
                .overlay(alignment: .leading) { edge(n, left: true, snap, pps) }
                .overlay(alignment: .trailing) { edge(n, left: false, snap, pps) }
                .offset(x: x0)
                .transition(.modifier(active: Pop(s: 0.8, b: 4, o: 0), identity: .rest))
            }
        }
        .frame(width: W, height: laneH, alignment: .topLeading)
    }

    func edge(_ n: VNote, left: Bool, _ snap: @escaping (Double) -> Double, _ pps: CGFloat) -> some View {
        UnevenRoundedEdge(left: left)
            .fill(Color.white.opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: 1, style: .continuous).fill(.white).frame(width: 2, height: 9))
            .frame(width: 10, height: laneH)
            .contentShape(Rectangle().inset(by: -3))
            .onContinuousHover { _ in NSCursor.resizeLeftRight.set() }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { v in
                if noteDrag == nil { m.snapshot(); noteDrag = (n.id, n.start, n.end); m.selectedNote = n.id; m.selectedClip = nil }
                guard let d = noteDrag else { return }
                let t = snap((left ? d.start : d.end) + Double(v.translation.width / pps))
                if left { m.setNoteTime(n.id, start: min(t, d.end - 0.15), end: d.end) }
                else { m.setNoteTime(n.id, start: d.start, end: max(t, d.start + 0.15)) }
            }.onEnded { _ in noteDrag = nil })
    }
}

/// One clip on the timeline: the frames from its own source range, rounded, with a gap from its neighbors.
struct ClipBlock: View {
    @ObservedObject var m: VideoEditorModel
    let clip: VClip
    let width: CGFloat
    let selected: Bool

    var body: some View {
        let h: CGFloat = 56
        let tileW = h * 16 / 10
        let n = max(1, Int((width / tileW).rounded(.up)))
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let t = clip.start + (Double(k) + 0.5) / Double(n) * clip.len
                let idx = m.strip.isEmpty ? nil : min(m.strip.count - 1, max(0, Int(t / max(m.duration, 0.001) * Double(m.strip.count))))
                ZStack {
                    Color.white.opacity(0.06)
                    if let idx { Image(nsImage: m.strip[idx]).resizable().aspectRatio(contentMode: .fill) }
                }
                .frame(width: width / CGFloat(n), height: h).clipped()
            }
        }
        .frame(width: max(1, width - 3), height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? accent : Color.white.opacity(0.12), lineWidth: selected ? 2.5 : 1))
        .overlay(alignment: .topLeading) {
            if m.hasCamera && clip.cam != .bubble && width > 34 {
                Image(systemName: clip.cam.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 18).background(Capsule().fill(.black.opacity(0.55)))
                    .padding(5)
                    .transition(.modifier(active: Pop(s: 0.6, b: 4, o: 0), identity: .rest))
                    .help(clip.cam == .full ? "Only your camera in this clip" : "Camera hidden in this clip")
            }
        }
        .animation(settle, value: clip.cam)
        .brightness(selected ? 0.04 : 0)
    }
}

/// One piece of the camera layer: small frames of you, and what the camera does there.
struct CamPieceView: View {
    @ObservedObject var m: VideoEditorModel
    let piece: VideoEditorModel.CamPiece
    let width: CGFloat
    let selected: Bool

    var body: some View {
        let h: CGFloat = 30
        let tileW = h * 4 / 3
        let n = max(1, Int((width / tileW).rounded(.up)))
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let off = piece.mode == .off
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { k in
                    let t = piece.src + (Double(k) + 0.5) / Double(n) * piece.len
                    let idx = m.camStrip.isEmpty ? nil : min(m.camStrip.count - 1, max(0, Int(t / max(m.duration, 0.001) * Double(m.camStrip.count))))
                    ZStack {
                        Color.white.opacity(0.06)
                        if let idx { Image(nsImage: m.camStrip[idx]).resizable().aspectRatio(contentMode: .fill) }
                    }
                    .frame(width: width / CGFloat(n), height: h).clipped()
                }
            }
            .opacity(off ? 0.18 : 1)
            .saturation(off ? 0 : 1)
            if piece.mode == .full { accent.opacity(0.28) }
            if piece.mode != .bubble && width > 30 {
                Image(systemName: piece.mode.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 18).background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.leading, piece.x < 0.01 && m.s.camLinked ? 76 : 5)
                    .transition(.modifier(active: Pop(s: 0.6, b: 4, o: 0), identity: .rest))
            }
        }
        .frame(width: max(1, width - 3), height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? accent : Color.white.opacity(off ? 0.18 : 0.12),
                                    style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: off && !selected ? [4, 3] : [])))
        .animation(settle, value: piece.mode)
        .help(piece.mode == .off ? "Camera hidden here" : piece.mode == .full ? "Only you here" : "Your camera in its corner")
    }
}

/// Annotation tools, tucked away until you ask for them.
struct MarkupTray: View {
    @ObservedObject var m: VideoEditorModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MarkTool.allCases, id: \.self) { t in
                Button { m.pick(m.tool == t ? nil : t) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol).font(.system(size: 12.5, weight: .semibold))
                        Text(t.label).font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(m.tool == t ? onAccent : Color.white.opacity(0.85))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background {
                        if m.tool == t { Capsule().fill(accent).matchedGeometryEffect(id: "tool", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(Squish()).help("\(t.label)  \(t.key.uppercased())")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 6)
            ForEach(palette.indices, id: \.self) { i in
                Button { m.setColor(i) } label: {
                    Circle().fill(palette[i]).frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(.white, lineWidth: m.color == i ? 2 : 0).padding(-3))
                        .frame(width: 24, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(Squish()).help("Color  \(i + 1)")
            }
        }
        .padding(4)
        .background(Capsule().fill(editorPanel))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

struct EditorBar: View {
    @ObservedObject var m: VideoEditorModel
    let done: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { m.togglePlay() } label: {
                Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 36, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(Squish()).help(m.playing ? "Pause  Space" : "Play  Space")
            TimeLabel(clock: m.clock, total: m.total)
            sep
            Button { withAnimation(gentle) { m.mode = m.mode == .blade ? .edit : .blade; m.tool = nil; m.markupOpen = false; m.cameraOpen = false } } label: {
                HStack(spacing: 7) {
                    SplitGlyph()
                    Text("Split").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(m.mode == .blade ? onAccent : Color.white.opacity(0.88))
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(m.mode == .blade ? accent : Color.white.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(Squish()).help("Split  S at the playhead, B to pick a spot")
            labeled("crop", "Crop", "Crop the frame. Nothing is cut away.  C", on: m.mode == .crop) {
                if m.mode == .crop { m.applyCrop() } else { m.enterCrop() }
            }
            sep
            labeled("pencil.tip", "Annotate", "Arrows, boxes, text and steps over the video", on: m.markupOpen) {
                withAnimation(gentle) {
                    m.markupOpen.toggle()
                    if !m.markupOpen { m.tool = nil } else { m.cameraOpen = false; m.tool = m.tool ?? .arrow; if m.mode == .crop { m.applyCrop() }; m.mode = .edit }
                }
            }
            if m.hasCamera {
                labeled("person.crop.square", "Camera", "Shape, size and when your camera shows", on: m.cameraOpen) { m.toggleCamera() }
            }
            if m.hasAudio {
                labeled(m.s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", m.s.muted ? "Muted" : "Sound",
                        m.s.muted ? "Turn the sound back on  M" : "Remove the sound  M", on: m.s.muted) { m.toggleMute() }
            }
            sep
            icon("arrow.uturn.backward", "Undo  ⌘Z", enabled: m.canUndo) { m.undo() }
            icon("arrow.uturn.forward", "Redo  ⇧⌘Z", enabled: m.canRedo) { m.redo() }
            Button(action: done) {
                HStack(spacing: 8) {
                    if m.exporting { Spinner(color: onAccent).transition(.scale.combined(with: .opacity)) }
                    Text(m.exporting ? "Saving" : (m.dirty ? "Save and copy" : "Done")).font(.system(size: 13, weight: .semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(onAccent)
                .padding(.horizontal, 16).frame(height: 34)
                .background(Capsule().fill(accent))
                .animation(gentle, value: m.exporting)
            }
            .buttonStyle(Squish()).padding(.leading, 6).disabled(m.exporting)
            .help("Save a copy and put it on the clipboard  Return")
        }
        .padding(5)
        .background(Capsule().fill(editorPanel))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .animation(gentle, value: m.dirty)
    }

    var sep: some View { Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4) }

    func labeled(_ symbol: String, _ title: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(on ? onAccent : Color.white.opacity(0.88))
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(on ? accent : Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(Squish()).help(help)
    }

    func icon(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 34, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(Squish()).disabled(!enabled).help(help)
    }
}

// MARK: - Window

@MainActor final class ClipEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: VideoEditorModel?
    private var monitor: Any?
    var onSaved: (URL) -> Void = { _ in }
    var onCancel: (URL) -> Void = { _ in }

    func open(_ url: URL) {
        if window != nil { close() }
        let m = VideoEditorModel(url: url)
        model = m
        let vf = NSScreen.underMouse.visibleFrame
        let size = CGSize(width: min(vf.width * 0.84, 1440), height: min(vf.height * 0.9, 980))
        let w = NSWindow(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = NSColor(editorBG)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 900, height: 600)
        w.delegate = self
        w.contentView = NSHostingView(rootView: VideoEditorView(m: m, done: { [weak self] in self?.finish() }))
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handle(e)
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let m = model, e.window === window, !m.exporting else { return e }
        if m.editingText != nil {
            if e.keyCode == 53 { m.commitText(); return nil }
            return e
        }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if f.contains(.command) {
            switch ch {
            case "z": if f.contains(.shift) { m.redo() } else { m.undo() }; return nil
            case "w": requestClose(); return nil
            case "b": m.split(at: m.time); return nil
            default: return e
            }
        }
        switch e.keyCode {
        case 53: escape(); return nil
        case 36, 76: if m.mode == .crop { m.applyCrop() } else { finish() }; return nil
        case 49: m.togglePlay(); return nil
        case 51, 117:
            // A camera piece cannot be cut out of the video; deleting it hides the camera there.
            if m.selectedSeg != nil { m.setCamMode(.off) } else { m.deleteSelection() }
            return nil
        case 123: m.step(f.contains(.shift) ? -1 : -1.0 / 30); return nil
        case 124: m.step(f.contains(.shift) ? 1 : 1.0 / 30); return nil
        case 126: m.jumpBoundary(false); return nil
        case 125: m.jumpBoundary(true); return nil
        default: break
        }
        switch ch {
        case "s": if m.selectedSeg != nil { m.splitCamera(at: m.time) } else { m.split(at: m.time) }; return nil
        case "b": withAnimation(gentle) { m.mode = m.mode == .blade ? .edit : .blade; m.tool = nil }; return nil
        case "c": if m.mode == .crop { m.applyCrop() } else { m.enterCrop() }; return nil
        case "m": if m.hasAudio { m.toggleMute() }; return nil
        case "v": m.pick(nil); return nil
        default: break
        }
        if let t = MarkTool.allCases.first(where: { $0.key == ch }) { m.pick(t); return nil }
        if let d = Int(ch), d >= 1, d <= palette.count { m.setColor(d - 1); return nil }
        return e
    }

    /// Esc steps back one level at a time: crop, split mode, annotation tool, selection, then the window.
    private func escape() {
        guard let m = model else { return }
        if m.mode == .crop { m.applyCrop(); return }
        if m.mode == .blade { withAnimation(gentle) { m.mode = .edit }; return }
        if m.tool != nil || m.markupOpen || m.cameraOpen { withAnimation(gentle) { m.tool = nil; m.markupOpen = false; m.cameraOpen = false }; return }
        if m.selectedClip != nil || m.selectedNote != nil || m.selectedSeg != nil {
            withAnimation(gentle) { m.selectedClip = nil; m.selectedNote = nil; m.selectedSeg = nil }; return
        }
        requestClose()
    }

    /// Edits are never thrown away by accident: with unsaved changes the first close only explains the choice.
    private func requestClose() {
        guard let m = model else { return }
        if m.dirty && !m.escArmed {
            m.escArmed = true
            m.say("Return saves and copies. Press Esc again to close without saving.")
            return
        }
        let u = m.url
        close()
        onCancel(u)
    }

    private func finish() {
        guard let m = model, !m.exporting else { return }
        m.commitText()
        if m.mode == .crop { m.applyCrop() }
        guard m.dirty else {
            let u = m.url
            close()
            onSaved(u)
            return
        }
        m.pause()
        withAnimation(gentle) { m.exporting = true }
        Task {
            do {
                let out = try await m.export()
                close()
                onSaved(out)
            } catch {
                withAnimation(gentle) { m.exporting = false }
                m.say("Could not save: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        model?.teardown()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let w = window
        window = nil
        model = nil
        w?.delegate = nil
        w?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }
}


/// Split, drawn the way editors draw it: two clip blocks parted by the cut line.
struct SplitGlyph: View {
    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).frame(width: 5, height: 10)
            Capsule().frame(width: 1.6, height: 15)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).frame(width: 5, height: 10)
        }
        .frame(width: 16, height: 16)
    }
}

extension NSCursor {
    /// Scissors, white with a soft edge so it reads on the dark timeline.
    static let blade: NSCursor = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        guard let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Split")?.withSymbolConfiguration(cfg) else { return .crosshair }
        let size = NSSize(width: sym.size.width + 4, height: sym.size.height + 4)
        let img = NSImage(size: size, flipped: false) { r in
            let inner = r.insetBy(dx: 2, dy: 2)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
            shadow.shadowBlurRadius = 2
            shadow.set()
            let tinted = NSImage(size: inner.size, flipped: false) { ir in
                sym.draw(in: ir)
                NSColor.white.set()
                ir.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: inner)
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()
}


/// The grip at either end of an annotation bar: a rectangle rounded only on its outer side.
struct UnevenRoundedEdge: Shape {
    let left: Bool
    func path(in r: CGRect) -> Path {
        let k: CGFloat = 5
        var p = Path()
        if left {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + k, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + k), control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - k))
            p.addQuadCurve(to: CGPoint(x: r.minX + k, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + k), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
            p.addQuadCurve(to: CGPoint(x: r.maxX - k, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}
