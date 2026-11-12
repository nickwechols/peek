// Presenting: record your screen or one window with yourself on camera.
//
// The camera is recorded as its own file next to the screen recording, so where it sits, its shape, its
// size and whether it shows at all stay editable after you stop. Retakes you mark while recording are cut
// back to your last pause, so the clip on your clipboard is the clean take. Everything stays on this Mac.

import AppKit
import SwiftUI
import AVFoundation
import CoreImage

// MARK: - Settings and layout

enum CamPrefs {
    static var on: Bool { UserDefaults.standard.bool(forKey: "rec.camera") }
    /// Asking for the camera needs a usage string in Info.plist. An unbundled debug build has none.
    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil }
}

enum CamShape: Int, CaseIterable, Codable {
    case rect, rounded, circle
    var label: String { ["Rectangle", "Rounded", "Circle"][rawValue] }
    var symbol: String { ["rectangle", "app", "circle"][rawValue] }
    var aspect: CGFloat { self == .circle ? 1 : 4.0 / 3 }
    /// Corner radius as a share of the short side. A circle is half of it.
    var radius: CGFloat { [0.05, 0.22, 0.5][rawValue] }
}

/// What the camera does during one clip.
enum CamMode: Int, Codable, CaseIterable {
    case bubble, full, off
    var label: String { ["Bubble", "Full", "Hidden"][rawValue] }
    var symbol: String { ["rectangle.inset.bottomright.filled", "person.crop.rectangle.fill", "video.slash.fill"][rawValue] }
}

struct CamLayout: Codable, Equatable {
    /// 0 top left, 1 top center, 2 top right, 3 bottom right, 4 bottom center, 5 bottom left
    var anchor = 3
    var shape = CamShape.rect
    var size = 1
    var mirror = false
    /// Width as a share of the video's width. Older layouts only have a size step.
    var w: Double?

    static let widths: [CGFloat] = [0.17, 0.23, 0.31]
    static let minW: CGFloat = 0.1, maxW: CGFloat = 0.5
    var width: CGFloat { w.map { CGFloat($0) } ?? CamLayout.widths[min(max(size, 0), 2)] }
    /// The S, M or L step this width sits on, if any.
    var step: Int? { CamLayout.widths.firstIndex { abs($0 - width) < 0.004 } }
    static var saved: CamLayout {
        get { (UserDefaults.standard.data(forKey: "cam.layout")).flatMap { try? JSONDecoder().decode(CamLayout.self, from: $0) } ?? CamLayout() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "cam.layout") }
    }

    func size(in c: CGSize) -> CGSize {
        let w = (c.width * width).rounded()
        return CGSize(width: w, height: (w / shape.aspect).rounded())
    }
    func margin(_ c: CGSize) -> CGFloat { (min(c.width, c.height) * 0.035).rounded() }

    /// The camera's frame inside a canvas, top-left origin.
    func frame(in c: CGSize, anchor a: Int? = nil) -> CGRect {
        let s = size(in: c), m = margin(c)
        let xs = [m, (c.width - s.width) / 2, c.width - s.width - m]
        let top = m, bottom = c.height - s.height - m
        let p: CGPoint
        switch a ?? anchor {
        case 0: p = CGPoint(x: xs[0], y: top)
        case 1: p = CGPoint(x: xs[1], y: top)
        case 2: p = CGPoint(x: xs[2], y: top)
        case 4: p = CGPoint(x: xs[1], y: bottom)
        case 5: p = CGPoint(x: xs[0], y: bottom)
        default: p = CGPoint(x: xs[2], y: bottom)
        }
        return CGRect(origin: p, size: s)
    }
    /// The anchor whose spot is closest to a point, for snapping after a drag.
    func nearest(to center: CGPoint, in c: CGSize) -> Int {
        (0..<6).min { a, b in
            let fa = frame(in: c, anchor: a), fb = frame(in: c, anchor: b)
            return hypot(fa.midX - center.x, fa.midY - center.y) < hypot(fb.midX - center.x, fb.midY - center.y)
        } ?? anchor
    }
    func radius(for r: CGRect) -> CGFloat { min(r.width, r.height) * shape.radius }
}

/// A snappier spring for things you throw: the camera settling into its corner.
let settle = Animation.spring(response: 0.42, dampingFraction: 0.76)

// MARK: - Sources on disk

/// A presentation keeps its raw screen recording and camera file in a hidden folder beside the clip, with a
/// small description of the edit, so the editor can re-open it with the camera still movable.
struct PresentMeta: Codable {
    var screen: String
    var camera: String?
    var layout: CamLayout
    var clips: [[Double]]          // start, end, camera mode
    var removed: Int = 0           // retakes taken out automatically
    var linked: Bool?              // nil or true: the camera follows the video's cuts
    var segs: [[Double]]?          // when unlinked: camera ranges in source time, start, end, mode
    var crop: [Double]?            // x, y, width, height as shares of the screen recording
    var muted: Bool?
}

enum Present {
    static func sources(_ url: URL) -> URL {
        let d = url.deletingLastPathComponent().appendingPathComponent(".Peek Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func metaURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".Peek Sources", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json")
    }
    static func load(_ url: URL) -> (PresentMeta, URL, URL?)? {
        guard let d = try? Data(contentsOf: metaURL(url)), let m = try? JSONDecoder().decode(PresentMeta.self, from: d) else { return nil }
        let dir = sources(url)
        let s = dir.appendingPathComponent(m.screen)
        guard FileManager.default.fileExists(atPath: s.path) else { return nil }
        let c = m.camera.map { dir.appendingPathComponent($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return (m, s, c)
    }
    static func save(_ m: PresentMeta, for url: URL) {
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: metaURL(url), options: .atomic) }
    }

    /// After recording: cut the marked retakes, put the camera in, and write the clip people will paste.
    static func finish(screen: URL, camera: URL?, retakes: [Double], main: URL, layout: CamLayout) async -> URL? {
        var src = screen
        let fm = FileManager.default
        if src == main {
            let moved = sources(main).appendingPathComponent(main.deletingPathExtension().lastPathComponent + " screen.mp4")
            guard (try? fm.moveItem(at: main, to: moved)) != nil else { return main }
            src = moved
        }
        let asset = AVURLAsset(url: src)
        let dur = await videoEnd(asset)
        let keep = await Takes.keep(marks: retakes, asset: asset, duration: dur)
        let clips = keep.map { RenderClip(start: $0.0, end: $0.1, mode: .bubble) }
        do {
            try await render(screen: src, camera: camera, clips: clips, layout: layout, notes: [], crop: nil, muted: false, to: main)
            save(PresentMeta(screen: src.lastPathComponent, camera: camera?.lastPathComponent, layout: layout,
                             clips: clips.map { [$0.start, $0.end, Double($0.mode.rawValue)] }, removed: max(0, keep.count - 1)), for: main)
            return main
        } catch {
            try? fm.copyItem(at: src, to: main)
            return fm.fileExists(atPath: main.path) ? main : nil
        }
    }

    struct RenderClip { var start: Double; var end: Double; var mode: CamMode }

    /// Where the picture ends. Sound and the camera can run a few frames past the last screen frame, and those
    /// frames would play as black with only your camera on them, so everything is measured against the picture.
    static func videoEnd(_ asset: AVAsset) async -> Double {
        let d = (try? await asset.load(.duration).seconds) ?? 0
        guard let v = try? await asset.loadTracks(withMediaType: .video).first, let r = try? await v.load(.timeRange), r.end.isNumeric else { return d }
        return max(0, min(d, r.end.seconds))
    }

    /// Put the part of the camera that overlaps a clip at the right spot, leaving the rest of the clip empty.
    /// The camera can start a moment after the screen (it was still waking up) and stop a moment before it.
    /// Those edges hold the nearest camera frame, so your camera is there from the first frame to the last.
    static func place(_ src: AVAssetTrack, range r: CMTimeRange, available: CMTimeRange, into t: AVMutableCompositionTrack, at cur: CMTime) {
        let cr = r.intersection(available)
        guard !cr.isEmpty else { return }
        let frame = CMTime(value: 1, timescale: 30)
        func pad(to time: CMTime) {
            let e = t.timeRange.end
            if e.isValid, e.isNumeric, time > e { t.insertEmptyTimeRange(CMTimeRange(start: e, end: time)) }
        }
        func hold(_ from: CMTime, _ dst: CMTimeRange) {
            guard dst.duration.seconds > 0.002 else { return }
            let piece = CMTimeRange(start: from, duration: frame).intersection(available)
            guard !piece.isEmpty else { return }
            pad(to: dst.start)
            guard (try? t.insertTimeRange(piece, of: src, at: dst.start)) != nil else { return }
            t.scaleTimeRange(CMTimeRange(start: dst.start, duration: piece.duration), toDuration: dst.duration)
        }
        let at = cur + (cr.start - r.start)
        hold(cr.start, CMTimeRange(start: cur, end: at))
        pad(to: at)
        try? t.insertTimeRange(cr, of: src, at: at)
        hold(max(cr.start, cr.end - frame), CMTimeRange(start: at + cr.duration, end: cur + r.duration))
    }

    /// Screen, camera and annotations, composed frame by frame. Used for the first clip and for every save.
    static func render(screen: URL, camera: URL?, clips: [RenderClip], layout: CamLayout, notes: [(CGImage, Double, Double)],
                       crop: CGRect?, muted: Bool, to out: URL) async throws {
        let sAsset = AVURLAsset(url: screen)
        guard let sv = try await sAsset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let natural = try await sv.load(.naturalSize)
        let fps = (try? await sv.load(.nominalFrameRate)) ?? 60
        let comp = AVMutableComposition()
        guard let st = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileWriteUnknown) }
        let audios = muted ? [] : try await sAsset.loadTracks(withMediaType: .audio)
        let ats = audios.map { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        // The asset has to outlive the composition work: a track does not keep its asset alive.
        let camAsset = camera.map { AVURLAsset(url: $0) }
        var camTrack: AVAssetTrack?, camRange = CMTimeRange.zero
        if let ca = camAsset {
            camTrack = try? await ca.loadTracks(withMediaType: .video).first
            if let camTrack { camRange = (try? await camTrack.load(.timeRange)) ?? .zero }
        }
        let ct = camTrack != nil ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        let c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let cropPx = CGRect(x: (c.minX * natural.width).rounded(), y: (c.minY * natural.height).rounded(),
                            width: CGFloat(RecEngine.even(c.width * natural.width)), height: CGFloat(RecEngine.even(c.height * natural.height)))
        let scene = PresentScene(natural: natural, crop: cropPx, layout: layout,
                                 notes: notes.map { (CIImage(cgImage: $0.0), $0.1, $0.2) })
        var cur = CMTime.zero
        var ins: [PresentInstruction] = []
        let vEnd = await videoEnd(sAsset)
        for var cl in clips {
            cl.end = min(cl.end, vEnd)
            guard cl.end - cl.start > 0.02 else { continue }
            let r = CMTimeRange(start: CMTime(seconds: cl.start, preferredTimescale: 6000), end: CMTime(seconds: cl.end, preferredTimescale: 6000))
            try st.insertTimeRange(r, of: sv, at: cur)
            for (a, t) in zip(audios, ats) { try? t?.insertTimeRange(r, of: a, at: cur) }
            if let camTrack, let ct { place(camTrack, range: r, available: camRange, into: ct, at: cur) }
            ins.append(PresentInstruction(range: CMTimeRange(start: cur, duration: r.duration), screen: st.trackID, camera: ct?.trackID, mode: cl.mode, scene: scene))
            cur = cur + r.duration
        }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = PresentCompositor.self
        vc.renderSize = cropPx.size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(fps.rounded(), 24), 60)))
        vc.instructions = ins

        let preset: String
        switch (RecPrefs.hevc, RecPrefs.quality) {
        case (true, 0): preset = AVAssetExportPresetHEVC1920x1080
        case (true, _): preset = AVAssetExportPresetHEVCHighestQuality
        case (false, 0): preset = AVAssetExportPreset1920x1080
        default: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { throw CocoaError(.fileWriteUnknown) }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = vc
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in session.exportAsynchronously { cont.resume() } }
        withExtendedLifetime((sAsset, camAsset)) {}
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Retakes

/// A retake mark means "that last attempt was bad". The bad part runs from the pause before the attempt
/// to where you start talking again after the mark, found from the loudness of the recording.
enum Takes {
    static func keep(marks: [Double], asset: AVAsset, duration: Double) async -> [(Double, Double)] {
        guard duration > 0 else { return [] }
        guard !marks.isEmpty else { return [(0, duration)] }
        let env = await loudness(asset)            // 20 values a second, in dB
        let hop = 0.05
        var bad: [(Double, Double)] = []
        var floor = 0.0
        for t in marks.sorted() where t > floor + 0.2 {
            var a = max(floor, t - 8), b = min(duration, t + 0.4)
            if !env.isEmpty {
                let quiet = threshold(env)
                func silent(_ i: Int) -> Bool { i < 0 || i >= env.count || env[i] < quiet }
                let ti = Int(t / hop)
                // Back to the last pause of at least 0.45 s before the mark.
                var i = ti, run = 0, found: Int?
                while Double(i) * hop > max(floor, t - 30) {
                    if silent(i) { run += 1; if run >= 9 { found = i + run / 2; break } } else { run = 0 }
                    i -= 1
                }
                a = found.map { max(floor, Double($0) * hop) } ?? max(floor, t - 8)
                // Forward to where you start again.
                var j = ti
                while Double(j) * hop < min(duration, t + 8), silent(j) || j < ti + 2 { j += 1 }
                b = min(duration, max(t + 0.2, Double(j) * hop - 0.15))
            }
            bad.append((a, b))
            floor = b
        }
        var out: [(Double, Double)] = []
        var s = 0.0
        for (a, b) in bad {
            if a - s > 0.2 { out.append((s, a)) }
            s = b
        }
        if duration - s > 0.2 { out.append((s, duration)) }
        return out.isEmpty ? [(0, duration)] : out
    }

    private static func threshold(_ env: [Float]) -> Float {
        let sorted = env.sorted()
        let noise = sorted[min(sorted.count - 1, sorted.count / 5)]
        return max(-50, min(-28, noise + 8))
    }

    /// Loudness every 50 ms of the first audio track, in dB. Empty when there is no sound.
    static func loudness(_ asset: AVAsset) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                                         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                                                                         AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }
        var env: [Float] = []
        var acc: Float = 0, n = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            let count = len / 4
            ptr.withMemoryRebound(to: Float.self, capacity: count) { f in
                for k in 0..<count {
                    acc += f[k] * f[k]; n += 1
                    if n == 800 { env.append(10 * log10(max(acc / 800, 1e-10))); acc = 0; n = 0 }
                }
            }
        }
        return env
    }
}

// MARK: - Compositor

final class PresentScene: @unchecked Sendable {
    let natural: CGSize
    let crop: CGRect           // pixels, top-left origin
    let layout: CamLayout
    let notes: [(CIImage, Double, Double)]
    init(natural: CGSize, crop: CGRect, layout: CamLayout, notes: [(CIImage, Double, Double)]) {
        self.natural = natural; self.crop = crop; self.layout = layout; self.notes = notes
    }
}

final class PresentInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screen: CMPersistentTrackID
    let camera: CMPersistentTrackID?
    let mode: CamMode
    let scene: PresentScene
    init(range: CMTimeRange, screen: CMPersistentTrackID, camera: CMPersistentTrackID?, mode: CamMode, scene: PresentScene) {
        timeRange = range
        self.screen = screen
        self.camera = camera
        self.mode = mode
        self.scene = scene
        requiredSourceTrackIDs = ([screen] + (camera.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

final class PresentCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ r: AVAsynchronousVideoCompositionRequest) {
        guard let ins = r.videoCompositionInstruction as? PresentInstruction, let out = r.renderContext.newPixelBuffer() else {
            r.finish(with: CocoaError(.fileWriteUnknown)); return
        }
        let sc = ins.scene
        let W = sc.crop.width, H = sc.crop.height
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        // Core Image's origin is bottom left; the crop is stored top left.
        let shift = CGAffineTransform(translationX: -sc.crop.minX, y: -(sc.natural.height - sc.crop.maxY))
        var img = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        if let sb = r.sourceFrame(byTrackID: ins.screen) {
            img = CIImage(cvPixelBuffer: sb).transformed(by: shift).composited(over: img)
        }
        if ins.mode != .off, let id = ins.camera, let cb = r.sourceFrame(byTrackID: id) {
            img = camera(CIImage(cvPixelBuffer: cb), mode: ins.mode, layout: sc.layout, W: W, H: H).composited(over: img)
        }
        let t = r.compositionTime.seconds
        for n in sc.notes where t >= n.1 && t < n.2 {
            img = n.0.transformed(by: shift).composited(over: img)
        }
        ctx.render(img.cropped(to: canvas), to: out, bounds: canvas, colorSpace: space)
        r.finish(withComposedVideoFrame: out)
    }

    private func camera(_ src: CIImage, mode: CamMode, layout: CamLayout, W: CGFloat, H: CGFloat) -> CIImage {
        var cam = src
        if layout.mirror {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -cam.extent.width, y: 0))
        }
        let tl = mode == .full ? CGRect(x: 0, y: 0, width: W, height: H) : layout.frame(in: CGSize(width: W, height: H))
        let rect = CGRect(x: tl.minX, y: H - tl.maxY, width: tl.width, height: tl.height)
        let e = cam.extent
        let k = max(rect.width / e.width, rect.height / e.height)
        cam = cam.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: k, y: k))
        let e2 = cam.extent
        cam = cam.transformed(by: CGAffineTransform(translationX: rect.midX - e2.midX, y: rect.midY - e2.midY)).cropped(to: rect)
        guard mode == .bubble else { return cam }
        let radius = layout.radius(for: rect)
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator",
                                  parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": CIColor.white])?.outputImage else { return cam }
        let shaped = cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        // A soft shadow, so the camera sits on the slides instead of being pasted onto them.
        let blur = min(rect.width, rect.height) * 0.06
        let shadow = mask
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.32)])
            .applyingGaussianBlur(sigma: blur)
            .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.5))
        return shaped.composited(over: shadow)
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Camera capture

/// One camera session for the whole app: the live bubble shows it, the recorder writes it.
final class CamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = CamCapture()
    let session = AVCaptureSession()
    private let q = DispatchQueue(label: "peek.camera", qos: .userInteractive)
    private var configured = false
    private var sink: ((CMSampleBuffer) -> Void)?
    private(set) var dims = CGSize(width: 1280, height: 720)

    /// Asks for access the first time, then starts the camera. False when there is no camera or no access.
    func start() async -> Bool {
        guard CamPrefs.available else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        default: return false
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            q.async {
                if !self.configured {
                    guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { cont.resume(returning: false); return }
                    self.session.beginConfiguration()
                    if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    let out = AVCaptureVideoDataOutput()
                    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                    out.alwaysDiscardsLateVideoFrames = true
                    out.setSampleBufferDelegate(self, queue: self.q)
                    if self.session.canAddOutput(out) { self.session.addOutput(out) }
                    self.session.commitConfiguration()
                    let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
                    self.dims = CGSize(width: Int(d.width), height: Int(d.height))
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() { q.async { if self.session.isRunning { self.session.stopRunning() }; self.gotFrame = false } }
    func setSink(_ s: ((CMSampleBuffer) -> Void)?) { q.sync { sink = s } }

    private var gotFrame = false
    /// Waits, briefly, for the camera to deliver a picture, so a recording never starts before your camera does.
    func waitForFrame(timeout: Double = 1.5) async {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if q.sync(execute: { gotFrame }) { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Camera timestamps on the host clock, the same clock ScreenCaptureKit uses.
    func hostTime(_ t: CMTime) -> CMTime {
        guard let clock = session.synchronizationClock else { return t }
        return CMSyncConvertTime(t, from: clock, to: CMClockGetHostTimeClock())
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        gotFrame = true
        sink?(sb)
    }
}

// MARK: - The live camera bubble

@MainActor final class BubbleModel: ObservableObject {
    @Published var layout = CamLayout.saved
    @Published var shown = false
    @Published var hover = false
    @Published var dragging = false
}

/// Your camera while you set up and record. It never ends up in the screen recording (the camera is
/// recorded on its own), you can drag it anywhere, and it settles into the nearest corner.
@MainActor final class CamBubble {
    let model = BubbleModel()
    private var panel: KeyPanel?
    private var area = CGRect.zero        // global, bottom-left origin: where the bubble lives
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    var isVisible: Bool { panel != nil }

    func show(in area: CGRect) {
        self.area = area
        wanted += 1
        let ticket = wanted
        Task {
            guard await CamCapture.shared.start() else { return }
            // Hidden, cancelled or shown again while the camera was starting: this request is stale.
            guard ticket == wanted else { if panel == nil { CamCapture.shared.stop() }; return }
            guard panel == nil else { place(animated: true); return }
            let p = overlayPanel(frameFor(model.layout.anchor), level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1), mouse: true)
            p.hasShadow = false
            p.contentView = NSHostingView(rootView: BubbleView(m: model, bubble: self))
            p.orderFrontRegardless()
            panel = p
            withAnimation(bouncy) { model.shown = true }
        }
    }

    /// Follow the recording: once the area or window is picked, the bubble moves into it.
    func move(to area: CGRect) {
        self.area = area
        place(animated: true)
    }

    private var wanted = 0
    func hide() {
        wanted += 1
        guard let p = panel else { return }
        panel = nil
        withAnimation(.easeIn(duration: 0.18)) { model.shown = false }
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            p.orderOut(nil)
        }
    }

    func frameFor(_ anchor: Int) -> NSRect {
        var l = model.layout
        l.anchor = anchor
        // Live size: the share of the recorded width it will have in the video, within reason.
        // A small, fixed-size preview: shape and size are decided later, in the editor.
        let w: CGFloat = l.shape == .circle ? 112 : 152
        let s = CGSize(width: w, height: (w / l.shape.aspect).rounded())
        let m = max(l.margin(area.size), 18)
        let xs = [area.minX + m, area.midX - s.width / 2, area.maxX - s.width - m]
        let top = area.maxY - s.height - m, bottom = area.minY + m
        let o: CGPoint
        switch anchor {
        case 0: o = CGPoint(x: xs[0], y: top)
        case 1: o = CGPoint(x: xs[1], y: top)
        case 2: o = CGPoint(x: xs[2], y: top)
        case 4: o = CGPoint(x: xs[1], y: bottom)
        case 5: o = CGPoint(x: xs[0], y: bottom)
        default: o = CGPoint(x: xs[2], y: bottom)
        }
        return NSRect(origin: o, size: s)
    }

    func place(animated: Bool) {
        guard let p = panel else { return }
        let f = frameFor(model.layout.anchor)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.42
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.06)
                p.animator().setFrame(f, display: true)
            }
        } else {
            p.setFrame(f, display: true)
        }
    }

    func update(_ change: (inout CamLayout) -> Void) {
        withAnimation(settle) { change(&model.layout) }
        CamLayout.saved = model.layout
        place(animated: true)
    }

    func dragChanged() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, p.frame.origin)
            withAnimation(snappy) { model.dragging = true }
        }
        guard let d = dragStart else { return }
        p.setFrameOrigin(NSPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
    }

    func dragEnded() {
        guard let p = panel else { return }
        dragStart = nil
        let c = CGPoint(x: p.frame.midX, y: p.frame.midY)
        let best = (0..<6).min { a, b in
            let fa = frameFor(a), fb = frameFor(b)
            return hypot(fa.midX - c.x, fa.midY - c.y) < hypot(fb.midX - c.x, fb.midY - c.y)
        } ?? model.layout.anchor
        withAnimation(snappy) { model.dragging = false }
        update { $0.anchor = best }
    }
}

final class CamPreviewView: NSView {
    override func makeBackingLayer() -> CALayer {
        let l = AVCaptureVideoPreviewLayer(session: CamCapture.shared.session)
        l.videoGravity = .resizeAspectFill
        if let c = l.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        return l
    }
}

struct CamPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> CamPreviewView {
        let v = CamPreviewView()
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: CamPreviewView, context: Context) {}
}

struct BubbleView: View {
    @ObservedObject var m: BubbleModel
    let bubble: CamBubble

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) * m.layout.shape.radius
            let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
            CamPreview()
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(m.dragging ? 0.9 : (m.hover ? 0.5 : 0.22)), lineWidth: m.dragging ? 2 : 1))
                .scaleEffect(m.shown ? (m.dragging ? 1.05 : 1) : 0.6)
                .opacity(m.shown ? 1 : 0)
                .onHover { h in
                    withAnimation(snappy) { m.hover = h }
                    if h { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { _ in NSCursor.closedHand.set(); bubble.dragChanged() }
                    .onEnded { _ in NSCursor.openHand.set(); bubble.dragEnded() })
                .help("Drag to move. Shape and size are set in the editor.")
        }
        .animation(settle, value: m.layout)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Editor camera

/// The camera over the video in the editor: drag it and it springs into the nearest spot, which lights up.
struct CamOverlay: View {
    @ObservedObject var m: VideoEditorModel
    @ObservedObject var clock: PlayClock
    let area: CGRect
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var hover = false
    @State private var target: Int?
    @State private var liveW: CGFloat?          // width while resizing, before it is committed
    @State private var startW: CGFloat = 0
    @State private var resizing = false

    var body: some View {
        var L = m.s.cam ?? CamLayout()
        if let liveW { L.w = Double(liveW) }
        let mode = m.camMode(at: clock.t)
        let f = mode == .full ? CGRect(origin: .zero, size: area.size) : L.frame(in: area.size)
        let r = mode == .full ? 0 : L.radius(for: f)
        let active = mode == .bubble && m.tool == nil
        return ZStack(alignment: .topLeading) {
            if dragging {
                ForEach(0..<6, id: \.self) { a in
                    let g = L.frame(in: area.size, anchor: a)
                    RoundedRectangle(cornerRadius: L.radius(for: g), style: .continuous)
                        .strokeBorder(Color.white.opacity(a == target ? 0.95 : 0.3), style: StrokeStyle(lineWidth: a == target ? 2 : 1.2, dash: [5, 4]))
                        .background(RoundedRectangle(cornerRadius: L.radius(for: g), style: .continuous).fill(Color.white.opacity(a == target ? 0.1 : 0)))
                        .frame(width: g.width, height: g.height)
                        .position(x: g.midX, y: g.midY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            if let p = m.camPlayer {
                PlayerSurface(player: p, gravity: .resizeAspectFill)
                    .scaleEffect(x: L.mirror ? -1 : 1, y: 1)
                    .frame(width: f.width, height: f.height)
                    .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                        .strokeBorder(Color.white.opacity(dragging || resizing ? 0.9 : (hover && active ? 0.55 : 0)), lineWidth: 2))
                    .overlay(alignment: corner(L.anchor)) {
                        if active && (hover || resizing) && !dragging { grip(L) }
                    }
                    .overlay {
                        if resizing {
                            Text(L.step.map { ["Small", "Medium", "Large"][$0] } ?? "\(Int((L.width * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .contentTransition(.numericText())
                                .transition(.modifier(active: Pop(s: 0.8, b: 4, o: 0), identity: .rest))
                        }
                    }
                    .shadow(color: .black.opacity(mode == .bubble ? 0.35 : 0), radius: 14, y: 6)
                    .scaleEffect(dragging ? 1.03 : 1)
                    .position(x: f.midX + drag.width, y: f.midY + drag.height)
                    .opacity(mode == .off ? 0 : 1)
                    .onHover { h in
                        withAnimation(snappy) { hover = h }
                        if h && active { NSCursor.openHand.set() }
                    }
                    .gesture(moveGesture(L, f))
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { v in
                            if liveW == nil { startW = L.width; withAnimation(snappy) { resizing = true } }
                            resize(to: startW * v)
                        }
                        .onEnded { _ in commitSize() })
                    .allowsHitTesting(active)
                    .help("Drag to move, drag the corner or pinch to resize")
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .offset(x: area.minX, y: area.minY)
        .animation(settle, value: mode)
        .animation(liveW == nil ? settle : nil, value: L)
    }

    /// The inner corner, the one facing the middle of the video: dragging it out grows the camera.
    func corner(_ a: Int) -> Alignment {
        switch a {
        case 0, 1: return .bottomTrailing
        case 2: return .bottomLeading
        case 3: return .topLeading
        default: return .topTrailing
        }
    }

    func grip(_ L: CamLayout) -> some View {
        let right = [0, 1, 4, 5].contains(L.anchor), down = L.anchor <= 2
        return Circle().fill(.white)
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .offset(x: right ? 9 : -9, y: down ? 9 : -9)
            .transition(.modifier(active: Pop(s: 0.3, b: 2, o: 0), identity: .rest))
            .onHover { h in if h { hover = true; NSCursor.crosshair.set() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { g in
                    if liveW == nil { startW = L.width; withAnimation(snappy) { resizing = true } }
                    // Grow along the diagonal that points away from the corner the camera sits in.
                    let dx = g.translation.width * (right ? 1 : -1)
                    let dy = g.translation.height * (down ? 1 : -1) * L.shape.aspect
                    let centered = L.anchor == 1 || L.anchor == 4
                    resize(to: startW + (dx + dy) / 2 * (centered ? 2 : 1) / max(area.width, 1))
                }
                .onEnded { _ in commitSize() })
    }

    /// Free sizing that settles onto Small, Medium and Large when you pass near them.
    func resize(to v: CGFloat) {
        var w = min(max(v, CamLayout.minW), CamLayout.maxW)
        if let d = CamLayout.widths.first(where: { abs($0 - w) < 0.012 }) { w = d }
        let was = liveW.flatMap { lw in CamLayout.widths.first { abs($0 - lw) < 0.0005 } }
        let now = CamLayout.widths.first { abs($0 - w) < 0.0005 }
        if now != nil, now != was {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(snappy) { liveW = w }
        } else {
            liveW = w
        }
    }

    func commitSize() {
        guard let w = liveW else { return }
        withAnimation(settle) {
            m.setCam { $0.w = Double(w) }
            liveW = nil
            resizing = false
        }
    }

    func moveGesture(_ L: CamLayout, _ f: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard !resizing else { return }
                if !dragging { NSCursor.closedHand.set(); withAnimation(snappy) { dragging = true } }
                drag = g.translation
                let t = L.nearest(to: CGPoint(x: f.midX + g.translation.width, y: f.midY + g.translation.height), in: area.size)
                if t != target {
                    if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    withAnimation(snappy) { target = t }
                }
            }
            .onEnded { g in
                guard dragging else { return }
                let a = L.nearest(to: CGPoint(x: f.midX + g.translation.width, y: f.midY + g.translation.height), in: area.size)
                NSCursor.openHand.set()
                // Only a real move is an undo step.
                if a != L.anchor { m.snapshot() }
                withAnimation(settle) {
                    drag = .zero
                    dragging = false
                    target = nil
                    m.s.cam?.anchor = a
                }
                CamLayout.saved = m.s.cam ?? L
            }
    }
}

/// Camera controls, tucked away like the annotation tools.
struct CameraTray: View {
    @ObservedObject var m: VideoEditorModel
    @ObservedObject var clock: PlayClock
    @Namespace private var ns

    var body: some View {
        let L = m.s.cam ?? CamLayout()
        HStack(spacing: 2) {
            ForEach(CamShape.allCases, id: \.self) { s in
                seg(s.symbol, s.label, on: L.shape == s, id: "shape") { m.setCam { $0.shape = s } }
            }
            sep
            ForEach(0..<3, id: \.self) { i in
                seg(nil, ["S", "M", "L"][i], on: L.step == i, id: "size") { m.setCam { $0.size = i; $0.w = Double(CamLayout.widths[i]) } }
            }
            sep
            seg("arrow.left.and.right.righttriangle.left.righttriangle.right", "Mirror", on: L.mirror, id: "mirror") { m.setCam { $0.mirror.toggle() } }
        }
        .padding(4)
        .background(Capsule().fill(editorPanel))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .animation(gentle, value: L)
    }

    var sep: some View { Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 6) }

    func seg(_ symbol: String?, _ title: String, on: Bool, id: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(on ? onAccent : Color.white.opacity(0.85))
            .padding(.horizontal, symbol == nil ? 11 : 12).frame(height: 30)
            .background { if on { Capsule().fill(accent).matchedGeometryEffect(id: id, in: ns) } }
            .contentShape(Capsule())
        }
        .buttonStyle(Squish())
        .help(title)
    }
}
