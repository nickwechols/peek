// Screen recording: pick an area or a whole screen, record it with ScreenCaptureKit, and hand the clip
// straight to the clipboard. Trimming, cutting, cropping and markup live in ClipEditor.swift.
// Everything stays on this Mac.

import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Carbon.HIToolbox

// MARK: - Settings and storage

enum RecPrefs {
    private static var d: UserDefaults { .standard }
    static var mic: Bool { d.object(forKey: "rec.mic") as? Bool ?? false }
    static var audio: Bool { d.object(forKey: "rec.audio") as? Bool ?? false }
    static var clicks: Bool { d.object(forKey: "rec.clicks") as? Bool ?? true }
    static var cursor: Bool { d.object(forKey: "rec.cursor") as? Bool ?? true }
    static var countdown: Bool { d.object(forKey: "rec.countdown") as? Bool ?? true }
    static var fps: Int { d.object(forKey: "rec.fps") as? Int ?? 60 }
    static var hevc: Bool { d.string(forKey: "rec.codec") == "hevc" }
    /// 0 smaller, 1 balanced, 2 best
    static var quality: Int { d.object(forKey: "rec.quality") as? Int ?? 1 }
    static var keepOriginal: Bool { d.object(forKey: "rec.keepOriginal") as? Bool ?? true }
    /// Asking for the microphone needs a usage string in Info.plist. An unbundled debug build has none.
    static var micAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil }
}

enum Recordings {
    static let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Peek")
    /// Where recordings go. Settings can point this anywhere; a missing folder falls back to Movies/Peek.
    static var dir: URL {
        var d = defaultDir
        if let p = UserDefaults.standard.string(forKey: "rec.dir"), !p.isEmpty { d = URL(fileURLWithPath: p, isDirectory: true) }
        if (try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)) == nil {
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            return defaultDir
        }
        return d
    }
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
    static func newURL() -> URL { dir.appendingPathComponent("Peek Recording \(stamp.string(from: Date())).mp4") }

    /// A sibling that does not exist yet: "Name edited.mp4", "Name edited 2.mp4", ...
    static func sibling(_ url: URL, _ suffix: String, ext: String = "mp4") -> URL {
        let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " \(suffix)", with: "")
        let dir = url.deletingLastPathComponent()
        var u = dir.appendingPathComponent("\(base) \(suffix).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) \(suffix) \(n).\(ext)"); n += 1 }
        return u
    }

    static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func precise(_ s: Double) -> String {
        let v = max(0, s)
        return String(format: "%d:%04.1f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }
}

extension Clip {
    /// A video or GIF goes on the clipboard as a file, which Claude, Slack, Mail, Messages and Finder all accept.
    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static var underMouse: NSScreen {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main ?? screens[0]
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor func overlayPanel(_ frame: NSRect, level: NSWindow.Level, mouse: Bool) -> KeyPanel {
    let p = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = level
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.ignoresMouseEvents = !mouse
    p.isReleasedWhenClosed = false
    p.animationBehavior = .none
    return p
}

// MARK: - Engine

/// ScreenCaptureKit frames and audio go straight into an AVAssetWriter on one serial queue.
/// Pausing drops samples and shifts every later timestamp back by the gap, so the file has no dead air.
final class RecEngine: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let url: URL
    private let q = DispatchQueue(label: "peek.recorder", qos: .userInteractive)
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var sys: AVAssetWriterInput?
    private var mic: AVAssetWriterInput?
    private var armed = false
    private var began = false
    private var startPTS = CMTime.invalid
    private var paused = false
    private var resync = false
    private var offset = CMTime.zero
    private var last = CMTime.invalid
    private var frame = CMTime(value: 1, timescale: 60)
    private var camWriter: AVAssetWriter?
    private var camInput: AVAssetWriterInput?
    private var camBegan = false
    private var camWrote = false
    private var camLast = CMTime.invalid
    private var lastBuf: CMSampleBuffer?     // the newest screen frame, held to the end on a still screen
    private var pauseHost = CMTime.invalid
    private var camURL: URL?
    var onFailure: ((String) -> Void)?
    /// Your camera, recorded beside the screen so it stays movable in the editor. Nil when it was off or failed.
    var cameraFile: URL? { camWriter?.status == .completed ? camURL : nil }
    var hasTwoAudioTracks: Bool { sys != nil && mic != nil }

    init(url: URL) { self.url = url }

    func start(filter: SCContentFilter, pixels: CGSize, sourceRect: CGRect?, fps: Int, cursor: Bool, audio: Bool, micOn: Bool,
               camera: URL? = nil) async throws {
        let w = RecEngine.even(pixels.width), h = RecEngine.even(pixels.height)
        if let camera { startCamera(camera) }
        let w0 = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Fast-start rewrites the whole file at Stop. Skip it when this file is only an intermediate: with Mac sound
        // and the mic both on, Remux.mixAudio writes a fresh fast-start file right after; with the camera on, this is
        // the screen source that Present.finish renders into the clip people paste (and the editor reads locally).
        w0.shouldOptimizeForNetworkUse = !(audio && micOn) && camera == nil
        let codec: AVVideoCodecType = (RecPrefs.hevc || max(w, h) > 4096) ? .hevc : .h264
        let k = [0.035, 0.07, 0.13][min(max(RecPrefs.quality, 0), 2)] * (codec == .hevc ? 0.6 : 1)
        let bitrate = Int(min(max(Double(w * h * fps) * k, 2_000_000), 60_000_000))
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate,
                                          AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalKey: fps * 2]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                       AVVideoCompressionPropertiesKey: compression])
        v.expectsMediaDataInRealTime = true
        w0.add(v)
        if audio { let a = RecEngine.aac(2); w0.add(a); sys = a }
        if micOn { let a = RecEngine.aac(1); w0.add(a); mic = a }
        guard w0.startWriting() else { throw w0.error ?? CocoaError(.fileWriteUnknown) }
        writer = w0
        video = v
        frame = CMTime(value: 1, timescale: CMTimeScale(fps))

        let c = SCStreamConfiguration()
        c.width = w
        c.height = h
        if let sourceRect { c.sourceRect = sourceRect }
        c.showsCursor = cursor
        c.minimumFrameInterval = frame
        c.queueDepth = 8
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // what the encoder wants: no color conversion, a third of the memory traffic
        c.capturesAudio = audio
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48000
        c.channelCount = 2
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if audio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q) }
        stream = s

        if micOn, let dev = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: dev) {
            let session = AVCaptureSession()
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
            out.setSampleBufferDelegate(self, queue: q)
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(out) { session.addOutput(out) }
            session.startRunning()
            micSession = session
        }
        try await s.startCapture()
    }

    static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }

    private func startCamera(_ url: URL) {
        let d = CamCapture.shared.dims
        guard let cw = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: RecEngine.even(d.width), AVVideoHeightKey: RecEngine.even(d.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoMaxKeyFrameIntervalKey: 60,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
        input.expectsMediaDataInRealTime = true
        guard cw.canAdd(input) else { return }
        cw.add(input)
        guard cw.startWriting() else { return }
        camWriter = cw
        camInput = input
        camURL = url
        CamCapture.shared.setSink { [weak self] sb in
            guard let self else { return }
            self.q.async { self.appendCamera(sb) }
        }
    }

    /// Camera frames run on the camera's clock; they are moved to the host clock, then follow the screen's
    /// start, pauses and gaps exactly, so the two files line up frame for frame.
    private func appendCamera(_ sb: CMSampleBuffer) {
        guard began, !paused, !resync, let cw = camWriter, let input = camInput, cw.status == .writing else { return }
        let host = CamCapture.shared.hostTime(sb.presentationTimeStamp)
        // The camera's first frame is pinned to the screen's first frame (it was captured a moment earlier,
        // camera latency), so the camera track starts exactly with the video instead of a beat later.
        let t = camWrote ? host - offset : startPTS
        if camWrote { guard t > camLast else { return } }
        if !camBegan { cw.startSession(atSourceTime: startPTS); camBegan = true }
        guard input.isReadyForMoreMediaData else { return }
        var info = CMSampleTimingInfo(duration: sb.duration, presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &out)
        if let out, input.append(out) { camWrote = true; camLast = t }
    }

    private static func aac(_ channels: Int) -> AVAssetWriterInput {
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                       AVNumberOfChannelsKey: channels,
                                                                       AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000])
        i.expectsMediaDataInRealTime = true
        return i
    }

    /// Capture starts during the countdown so there is no delay at "go"; frames only count once armed.
    func arm() { q.async { self.armed = true } }

    func setPaused(_ p: Bool) {
        q.async {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if p, !self.paused { self.paused = true; self.pauseHost = now }
            else if !p, self.paused {
                self.paused = false
                if self.pauseHost.isValid, self.began { self.offset = self.offset + (now - self.pauseHost) } else { self.resync = true }
                self.pauseHost = .invalid
            }
        }
    }

    // ScreenCaptureKit
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            appendVideo(sb)
        case .audio:
            appendAudio(sb, to: sys)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let msg = error.localizedDescription
        DispatchQueue.main.async { self.onFailure?(msg) }
    }

    // Microphone
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        appendAudio(sb, to: mic)
    }

    private func appendVideo(_ sb: CMSampleBuffer) {
        guard armed, !paused, let writer, let video, writer.status == .writing else { return }
        let pts = sb.presentationTimeStamp
        if !began {
            writer.startSession(atSourceTime: pts)
            began = true
            startPTS = pts
        }
        if resync {
            if last.isValid { offset = offset + (pts - last) - frame }
            resync = false
        }
        guard video.isReadyForMoreMediaData, let out = RecEngine.retime(sb, by: offset) else { return }
        if video.append(out) { last = pts; lastBuf = out }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, began, !paused, !resync, let writer, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        guard sb.presentationTimeStamp - offset >= startPTS, let out = RecEngine.retime(sb, by: offset) else { return }
        input.append(out)
    }

    private static func retime(_ sb: CMSampleBuffer, by off: CMTime) -> CMSampleBuffer? {
        if off == .zero { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in info.indices {
            info[i].presentationTimeStamp = info[i].presentationTimeStamp - off
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = info[i].decodeTimeStamp - off }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &info, sampleBufferOut: &out)
        return out
    }

    /// Stops capture and closes the file. Returns nil when nothing was recorded.
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        if camWriter != nil { CamCapture.shared.setSink(nil) }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            q.async {
                guard let writer = self.writer, self.began, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    self.camWriter?.cancelWriting()
                    if let c = self.camURL { try? FileManager.default.removeItem(at: c) }
                    cont.resume(returning: nil)
                    return
                }
                // A still screen sends no new frames, so the clip runs to the moment Stop was pressed.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                var end = (self.paused || !self.last.isValid) ? self.last : max(self.last + self.frame, now)
                if !end.isValid { end = self.startPTS + self.frame }
                // A still screen sends no frames, but sound and camera keep going: repeat the last frame at the
                // end so the picture lasts as long as everything else, instead of ending in black.
                if self.last.isValid, end - self.last > self.frame, let held = self.lastBuf, let v = self.video, v.isReadyForMoreMediaData {
                    var info = CMSampleTimingInfo(duration: self.frame, presentationTimeStamp: end - self.offset - self.frame, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: held, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &copy)
                    if let copy { v.append(copy) }
                }
                self.lastBuf = nil
                self.video?.markAsFinished()
                self.sys?.markAsFinished()
                self.mic?.markAsFinished()
                writer.endSession(atSourceTime: end - self.offset)
                let group = DispatchGroup()
                group.enter()
                writer.finishWriting { group.leave() }
                if let cw = self.camWriter {
                    if self.camBegan, cw.status == .writing {
                        self.camInput?.markAsFinished()
                        cw.endSession(atSourceTime: end - self.offset)
                        group.enter()
                        cw.finishWriting { group.leave() }
                    } else {
                        cw.cancelWriting()
                    }
                }
                group.notify(queue: self.q) {
                    cont.resume(returning: writer.status == .completed ? self.url : nil)
                }
            }
        }
    }

    func cancel() async {
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        if camWriter != nil { CamCapture.shared.setSink(nil) }
        q.sync { writer?.cancelWriting(); camWriter?.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
        if let camURL { try? FileManager.default.removeItem(at: camURL) }
    }
}

/// When both the Mac's sound and the microphone were recorded, they are two tracks, and most players and
/// web apps only play the first. This mixes them into one track; the video is copied as is, not re-encoded.
enum Remux {
    static func mixAudio(_ src: URL) async -> URL {
        let tmp = src.deletingLastPathComponent().appendingPathComponent(".mix-\(UUID().uuidString).mp4")
        do {
            let asset = AVURLAsset(url: src)
            let vts = try await asset.loadTracks(withMediaType: .video)
            let ats = try await asset.loadTracks(withMediaType: .audio)
            guard let vt = vts.first, ats.count > 1 else { return src }
            let reader = try AVAssetReader(asset: asset)
            let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: ats, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(vOut)
            reader.add(aOut)
            let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            let hint = try await vt.load(.formatDescriptions).first
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
            writer.add(vIn)
            writer.add(aIn)
            guard reader.startReading(), writer.startWriting() else { return src }
            writer.startSession(atSourceTime: .zero)
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await pump(vOut, vIn, "peek.mix.v") }
                g.addTask { await pump(aOut, aIn, "peek.mix.a") }
            }
            await writer.finishWriting()
            guard writer.status == .completed else { try? FileManager.default.removeItem(at: tmp); return src }
            _ = try FileManager.default.replaceItemAt(src, withItemAt: tmp)
            return src
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return src
        }
    }

    private static func pump(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ label: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var done = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while input.isReadyForMoreMediaData {
                    if let sb = out.copyNextSampleBuffer() {
                        input.append(sb)
                    } else {
                        input.markAsFinished()
                        lock.lock()
                        let first = !done
                        done = true
                        lock.unlock()
                        if first { cont.resume() }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - Controller

@MainActor final class RecordController: NSObject, ObservableObject {
    enum Phase { case idle, picking, countdown, recording, finishing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var paused = false
    @Published private(set) var count = 3
    @Published private(set) var micDenied = false
    @Published private(set) var retakes: [Double] = []
    @Published private(set) var takeFlash = 0
    /// While picking: Space switches between dragging an area and clicking a window.
    @Published var windowMode = false
    /// The window list: every open window as a picture, for when there are too many to click through.
    @Published var gallery: CGDirectDisplayID?
    @Published var shots: [WinShot] = []
    @Published var shotsLoading = false
    @Published var sel = 0
    @Published var query = ""
    var onPhase: () -> Void = {}
    var onFinished: (URL) -> Void = { _ in }
    /// Cutting retakes and putting the camera in takes a moment after Stop.
    var onPreparing: (URL) -> Void = { _ in }
    let bubble = CamBubble()
    private var camOn = false
    private var mainURL: URL?

    private var startedAt = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var pickers: [KeyPanel] = []
    private var countPanel: KeyPanel?
    private var outline: NSPanel?
    private var bar: NSPanel?
    private var clicks: ClickLayer?
    private var engine: RecEngine?
    private var keyMon: Any?
    private var clickMon: Any?
    private var countTask: Task<Void, Never>?
    private var target: (screen: NSScreen, rect: CGRect?, window: CGWindowID?)?
    private var clickLayers: [CGDirectDisplayID: ClickLayer] = [:]
    private var prepared = false
    private var goNow = false

    var isActive: Bool { phase != .idle }
    var elapsed: TimeInterval { max(0, (pausedAt ?? Date()).timeIntervalSince(startedAt) - pausedTotal) }

    func toggle() {
        switch phase {
        case .idle: pick()
        case .picking, .countdown: cancel()
        case .recording: stop()
        case .finishing: break
        }
    }

    private func set(_ p: Phase) {
        withAnimation(snappy) { phase = p }
        onPhase()
    }

    // Step 1: pick an area, or click for the whole screen.
    func pick() {
        guard CGPreflightScreenCaptureAccess() else { _ = CGRequestScreenCaptureAccess(); return }
        set(.picking)
        // Wake ScreenCaptureKit while the user is still choosing an area: the first shareable-content query in a
        // session is the slow one, and prepare() needs it the moment the pick ends (no countdown means no slack).
        Task.detached(priority: .userInitiated) { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        retakes = []
        windowMode = false
        NSApp.activate(ignoringOtherApps: true)
        let here = NSScreen.underMouse
        if CamPrefs.on && CamPrefs.available { bubble.show(in: here.frame) }
        gallery = nil
        shots = []
        for s in NSScreen.screens {
            let p = overlayPanel(s.frame, level: .screenSaver, mouse: true)
            p.contentView = NSHostingView(rootView: PickerView(c: self, screen: s, done: { [weak self] r in self?.picked(s, r) }))
            p.orderFrontRegardless()
            if s == here { p.makeKey() }
            pickers.append(p)
            if RecPrefs.clicks { clickLayers[s.displayID] = ClickLayer(screen: s) }
        }

        keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if self.gallery != nil {
                switch e.keyCode {
                case 53: self.closeGallery(); return nil
                case 36, 76: self.chooseSelected(); return nil
                case 123: self.moveSel(-1); return nil
                case 124: self.moveSel(1); return nil
                case 125: self.moveSel(3); return nil
                case 126: self.moveSel(-3); return nil
                default: return e        // typing goes to the search field
                }
            }
            switch e.keyCode {
            case 53: self.cancel(); return nil
            case 36, 76: if self.phase == .picking { self.picked(NSScreen.underMouse, .screen); return nil }
            case 49:
                if e.isARepeat { return nil }     // holding Space should not flicker between modes
                if self.phase == .countdown { self.countTask?.cancel(); self.begin(); return nil }
                if self.phase == .picking { withAnimation(snappy) { self.windowMode.toggle() }; return nil }
            default: break
            }
            return e
        }
    }

    // The window list
    var filtered: [WinShot] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? shots : shots.filter { $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q) }
    }

    func openGallery(on s: NSScreen) {
        query = ""
        sel = 0
        withAnimation(soft) { gallery = s.displayID; windowMode = false }
        shotsLoading = shots.isEmpty
        Task { [weak self] in
            let list = await WinShot.load()
            guard let self else { return }
            withAnimation(snappy) { self.shots = list; self.shotsLoading = false }
            // Pictures need macOS 14. Fetch the window list once for all of them, and not at all on macOS 13.
            guard #available(macOS 14.0, *), !list.isEmpty else { return }
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            for i in list.indices {
                guard self.gallery != nil else { return }
                if let img = await WinShot.picture(list[i].id, in: content), let k = self.shots.firstIndex(where: { $0.id == list[i].id }) {
                    withAnimation(.easeOut(duration: 0.25)) { self.shots[k].image = img }
                }
            }
        }
    }

    func closeGallery() { withAnimation(soft) { gallery = nil } }

    func moveSel(_ d: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        withAnimation(snappy) { sel = min(max(0, sel + d), n - 1) }
    }

    func chooseSelected() {
        let f = filtered
        if f.indices.contains(sel) { choose(f[sel]) }
    }

    /// Bring the window forward and record it.
    func choose(_ w: WinShot) {
        let H0 = NSScreen.screens.first?.frame.height ?? 0
        let mid = CGPoint(x: w.frame.midX, y: H0 - w.frame.midY)
        let s = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.underMouse
        let local = CGRect(x: w.frame.minX - s.frame.minX, y: w.frame.minY - (H0 - s.frame.maxY), width: w.frame.width, height: w.frame.height)
        gallery = nil
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
        picked(s, .window(w.id, local))
    }

    /// The camera bubble from the options row: on shows it right away, so you can place it before you record.
    func setCamera(_ on: Bool) {
        if on { bubble.show(in: NSScreen.underMouse.frame) } else { bubble.hide(); CamCapture.shared.stop() }
    }

    private func picked(_ s: NSScreen, _ pick: PickResult) {
        guard phase == .picking else { return }
        pickers.forEach { $0.orderOut(nil) }
        pickers = []
        var r: CGRect?, wid: CGWindowID?
        switch pick {
        case .screen: break
        case .area(let a): r = a
        case .window(let id, let a): r = a; wid = id
        }
        let rect = r.map { CGRect(x: $0.minX.rounded(), y: $0.minY.rounded(), width: $0.width.rounded(), height: $0.height.rounded()) }
        target = (s, rect, wid)
        camOn = CamPrefs.on && CamPrefs.available && bubble.isVisible
        if camOn {
            let a = rect ?? CGRect(origin: .zero, size: s.frame.size)
            bubble.move(to: CGRect(x: s.frame.minX + a.minX, y: s.frame.maxY - a.maxY, width: a.width, height: a.height))
        }
        // Click rings are drawn on the screen; a window is recorded on its own, so they would not line up.
        clicks = wid == nil ? clickLayers.removeValue(forKey: s.displayID) : nil
        clickLayers.values.forEach { $0.panel.orderOut(nil) }
        clickLayers = [:]
        if let rect { showOutline(s, rect) }
        makeBar(s, rect)          // exists, invisible, before capture starts, so it can be left out of the video
        prepare()
        if RecPrefs.countdown { countdown(s, rect) } else { begin() }
    }

    // Step 2: an optional 3, 2, 1. Space skips it, Esc cancels.
    private func countdown(_ s: NSScreen, _ r: CGRect?) {
        set(.countdown)
        let area = r ?? CGRect(origin: .zero, size: s.frame.size)
        let c = CGPoint(x: s.frame.minX + area.midX, y: s.frame.maxY - area.midY)
        let p = overlayPanel(NSRect(x: c.x - 110, y: c.y - 110, width: 220, height: 220), level: .screenSaver, mouse: false)
        p.contentView = NSHostingView(rootView: CountdownView(c: self))
        p.orderFrontRegardless()
        p.makeKey()
        countPanel = p
        countTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                withAnimation(bouncy) { self.count = n }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            guard let self, !Task.isCancelled, self.phase == .countdown else { return }
            self.begin()
        }
    }

    private func closeCountdown() {
        countPanel?.orderOut(nil)
        countPanel = nil
    }

    // Step 3: set up capture in the background while the countdown runs.
    private var prepToken = 0
    private func prepare() {
        guard let t = target else { return }
        prepared = false
        goNow = false
        prepToken += 1
        let token = prepToken
        Task { [weak self] in
            guard let self else { return }
            do {
                var micOn = RecPrefs.mic && RecPrefs.micAvailable
                if micOn {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized: break
                    case .notDetermined: micOn = await AVCaptureDevice.requestAccess(for: .audio)
                    default: micOn = false
                    }
                    self.micDenied = !micOn
                }
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = shareable.displays.first(where: { $0.displayID == t.screen.displayID }) else {
                    throw CocoaError(.featureUnsupported)
                }
                // Leave out every Peek window except the click rings. Anything not listed is recorded, so the
                // rings always make it into the video, whatever macOS thinks of a clear window.
                let pid = ProcessInfo.processInfo.processIdentifier
                let clickID = self.clicks.map { CGWindowID($0.panel.windowNumber) }
                let mine = shareable.windows.filter { $0.owningApplication?.processID == pid && $0.windowID != clickID }
                var filter = SCContentFilter(display: display, excludingWindows: mine)
                var source = t.rect
                let scale = t.screen.backingScaleFactor
                var px = CGSize(width: (t.rect?.width ?? t.screen.frame.width) * scale, height: (t.rect?.height ?? t.screen.frame.height) * scale)
                if let wid = t.window, let w = shareable.windows.first(where: { $0.windowID == wid }) {
                    // One window, recorded on its own: what moves in front of it never ends up in the video.
                    filter = SCContentFilter(desktopIndependentWindow: w)
                    source = nil
                    px = CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
                }
                let longSide = max(px.width, px.height)
                if longSide > 3840 { px = CGSize(width: px.width * 3840 / longSide, height: px.height * 3840 / longSide) }
                let main = Recordings.newURL()
                self.mainURL = main
                var file = main, cam: URL?
                if self.camOn {
                    let stem = main.deletingPathExtension().lastPathComponent
                    let dir = Present.sources(main)
                    file = dir.appendingPathComponent(stem + " screen.mp4")
                    cam = dir.appendingPathComponent(stem + " camera.mov")
                }
                // Your camera has to be awake before the first frame, or the video starts without you.
                if cam != nil { await CamCapture.shared.waitForFrame() }
                let e = RecEngine(url: file)
                e.onFailure = { [weak self] msg in self?.fail(msg) }
                try await e.start(filter: filter, pixels: px, sourceRect: source, fps: RecPrefs.fps, cursor: RecPrefs.cursor,
                                  audio: RecPrefs.audio, micOn: micOn, camera: cam)
                guard token == self.prepToken, self.phase == .countdown || self.phase == .recording else { await e.cancel(); return }
                self.engine = e
                self.prepared = true
                if self.goNow { e.arm(); self.startedAt = Date() }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// "Go": the bar appears at once; frames start counting the moment capture is ready (usually already).
    private func begin() {
        guard target != nil else { return }
        closeCountdown()
        if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        set(.recording)
        NSApp.deactivate()
        startedAt = Date()
        pausedTotal = 0
        pausedAt = nil
        paused = false
        goNow = true
        if prepared { engine?.arm() }
        HotKeys.register(9001, Hotkey(keyCode: 25, mods: UInt32(cmdKey | shiftKey), key: "9")) { [weak self] in self?.markRetake() }
        if let b = bar {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                b.animator().alphaValue = 1
            }
        }
        if let c = clicks {
            clickMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                let p = NSEvent.mouseLocation
                Task { @MainActor in c.ripple(at: p) }
            }
        }
    }

    func togglePause() {
        guard phase == .recording, let engine else { return }
        if paused {
            if let a = pausedAt { pausedTotal += Date().timeIntervalSince(a) }
            pausedAt = nil
        } else {
            pausedAt = Date()
        }
        withAnimation(snappy) { paused.toggle() }
        engine.setPaused(paused)
        onPhase()
    }

    /// "That last try was bad." The take is cut back to the pause before it when you stop.
    func markRetake() {
        guard phase == .recording, !paused, elapsed > 0.5 else { return }
        if let last = retakes.last, elapsed - last < 1 { return }
        withAnimation(bouncy) {
            retakes.append(elapsed)
            takeFlash += 1
        }
    }

    func stop() {
        guard phase == .recording else { cancel(); return }
        guard let engine, prepared else { return }   // capture is still starting; one more press will stop it
        let twoTracks = engine.hasTwoAudioTracks
        let marks = retakes, main = mainURL
        set(.finishing)
        tearDown()
        Task { [weak self] in
            var url = await engine.stop()
            let cam = engine.cameraFile
            if let u = url, twoTracks { url = await Remux.mixAudio(u) }
            if let u = url, let main, cam != nil || !marks.isEmpty {
                self?.onPreparing(u)
                url = await Present.finish(screen: u, camera: cam, retakes: marks, main: main, layout: self?.bubble.model.layout ?? CamLayout.saved)
            } else if let u = url, let main, u != main {
                // The camera failed, so this is a plain recording: it belongs next to the others.
                if (try? FileManager.default.moveItem(at: u, to: main)) != nil { url = main }
            }
            guard let self else { return }
            self.engine = nil
            self.set(.idle)
            if let url { self.onFinished(url) }
        }
    }

    func discard() {
        guard let engine else { cancel(); return }
        self.engine = nil
        tearDown()
        set(.idle)
        Task { await engine.cancel() }
    }

    func cancel() {
        countTask?.cancel()
        pickers.forEach { $0.orderOut(nil) }
        pickers = []
        closeCountdown()
        if let engine { self.engine = nil; Task { await engine.cancel() } }
        tearDown()
        set(.idle)
    }

    private func fail(_ msg: String) {
        guard phase != .idle else { return }
        cancel()
        let a = NSAlert()
        a.messageText = "Recording stopped"
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func tearDown() {
        HotKeys.unregister(9001)
        bubble.hide()
        CamCapture.shared.stop()
        camOn = false
        if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        if let m = clickMon { NSEvent.removeMonitor(m); clickMon = nil }
        bar?.orderOut(nil)
        bar = nil
        outline?.orderOut(nil)
        outline = nil
        clicks?.panel.orderOut(nil)
        clicks = nil
        clickLayers.values.forEach { $0.panel.orderOut(nil) }
        clickLayers = [:]
        prepared = false
        goNow = false
        target = nil
        paused = false
        pausedAt = nil
    }

    private func showOutline(_ s: NSScreen, _ r: CGRect) {
        let p = overlayPanel(s.frame, level: .statusBar, mouse: false)
        p.contentView = NSHostingView(rootView: OutlineView(rect: r))
        p.orderFrontRegardless()
        outline = p
    }

    /// The recording bar sits just outside the recorded area when there is room, so it never ends up in the video.
    private func makeBar(_ s: NSScreen, _ r: CGRect?) {
        let host = NSHostingView(rootView: RecBar(c: self))
        let size = host.fittingSize
        let vf = s.visibleFrame, f = s.frame
        var origin: CGPoint
        if let r {
            let below = f.maxY - r.maxY - 14 - size.height
            let above = f.maxY - r.minY + 14
            let x = min(max(f.minX + r.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
            if below > vf.minY + 8 { origin = CGPoint(x: x, y: below) }
            else if above + size.height < vf.maxY - 8 { origin = CGPoint(x: x, y: above) }
            else { origin = CGPoint(x: x, y: vf.maxY - size.height - 12) }
        } else {
            origin = CGPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12)
        }
        let p = overlayPanel(NSRect(origin: origin, size: size), level: .statusBar, mouse: true)
        p.isMovableByWindowBackground = true
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        bar = p
    }
}

// MARK: - Views

/// The area picker: drag for an area, click or Return for the whole screen. The options float at the bottom.
enum PickResult { case screen, area(CGRect), window(CGWindowID, CGRect) }

/// Other apps' windows on one screen, front to back, in that screen's top-left coordinates.
struct PickWindow: Identifiable { let id: CGWindowID; let rect: CGRect; let app: String }

enum WindowList {
    static func on(_ s: NSScreen) -> [PickWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        let H0 = NSScreen.screens.first?.frame.height ?? s.frame.height
        let top = H0 - s.frame.maxY
        let bounds = CGRect(origin: .zero, size: s.frame.size)
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != pid,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 80, ht > 60 else { return nil }
            let r = CGRect(x: x - s.frame.minX, y: y - top, width: wd, height: ht)
            guard r.intersects(bounds) else { return nil }
            return PickWindow(id: id, rect: r, app: w[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

struct PickerView: View {
    @ObservedObject var c: RecordController
    let screen: NSScreen
    let done: (PickResult) -> Void
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @State private var overOptions = false
    @State private var windows: [PickWindow] = []
    @State private var hovered: PickWindow?

    var rect: CGRect? {
        guard let start, let end else { return nil }
        return box(start, end)
    }

    var body: some View {
        ZStack {
            Canvas { ctx, s in
                var p = Path(CGRect(origin: .zero, size: s))
                let hole = c.windowMode ? hovered.map { Path(roundedRect: $0.rect, cornerRadius: 10, style: .continuous) } : rect.map { Path($0) }
                if let hole { p.addPath(hole) }
                ctx.fill(p, with: .color(.black.opacity(c.windowMode ? 0.42 : 0.3)), style: FillStyle(eoFill: true))
                if c.windowMode, let w = hovered {
                    let r = Path(roundedRect: w.rect, cornerRadius: 10, style: .continuous)
                    ctx.fill(r, with: .color(accent.opacity(0.12)))
                    ctx.stroke(r, with: .color(accent), lineWidth: 3)
                } else if let r = rect {
                    ctx.stroke(Path(r.insetBy(dx: -0.5, dy: -0.5)), with: .color(.white.opacity(0.95)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if !overOptions { (c.windowMode ? NSCursor.pointingHand : NSCursor.crosshair).set() }
                guard c.windowMode, case .active(let p) = phase else { return }
                let w = windows.first { $0.rect.contains(p) }
                if w?.id != hovered?.id { withAnimation(snappy) { hovered = w } }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !c.windowMode else { return }
                    if start == nil { start = g.startLocation }
                    end = g.location
                }
                .onEnded { g in
                    if c.windowMode {
                        if let w = windows.first(where: { $0.rect.contains(g.location) }) { done(.window(w.id, w.rect)) }
                        return
                    }
                    let r = box(g.startLocation, g.location)
                    start = nil
                    end = nil
                    done(r.width < 8 || r.height < 8 ? .screen : .area(r))
                })
            if c.windowMode, let w = hovered, !w.app.isEmpty {
                Text(w.app)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(accent))
                    .position(x: w.rect.midX, y: max(24, w.rect.minY + 26))
                    .allowsHitTesting(false)
                    .transition(.modifier(active: Pop(s: 0.85, b: 4, o: 0), identity: .rest))
                    .id(w.id)
            }
            if let r = rect, r.width > 60, r.height > 30 {
                Text("\(Int(r.width)) × \(Int(r.height))")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .position(x: r.maxX - 36, y: r.maxY + 16)
                    .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                RecOptions(windowMode: c.windowMode, onCamera: { c.setCamera($0) }, onWindows: { c.openGallery(on: screen) })
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: overOptions = true; NSCursor.arrow.set()
                        case .ended: overOptions = false; NSCursor.crosshair.set()
                        }
                    }
                    .padding(.bottom, 72)
            }
            .opacity(rect == nil ? (c.gallery == nil ? 1 : 0) : 0.25)
            .animation(snappy, value: rect == nil)
            if c.gallery == screen.displayID {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { c.closeGallery() }
                    .onContinuousHover { _ in NSCursor.arrow.set() }
                    .transition(.opacity)
                WindowGallery(c: c)
                    .transition(.modifier(active: Pop(s: 0.94, b: 10, o: 0, y: 16), identity: .rest))
            }
        }
        .onAppear { windows = WindowList.on(screen) }
        .onChange(of: c.windowMode) { on in
            if on { windows = WindowList.on(screen) } else { hovered = nil }
        }
    }
}

struct RecOptions: View {
    var windowMode = false
    var onCamera: (Bool) -> Void = { _ in }
    var onWindows: () -> Void = {}
    @AppStorage("rec.camera") private var camera = false
    @AppStorage("rec.mic") private var mic = false
    @AppStorage("rec.audio") private var audio = false
    @AppStorage("rec.clicks") private var clicks = true
    @AppStorage("rec.cursor") private var cursor = true
    @AppStorage("rec.countdown") private var countdown = true

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                if CamPrefs.available {
                    chip(camera ? "video.fill" : "video.slash", "Camera", "Record yourself presenting", Binding(get: { camera }, set: { v in
                        camera = v
                        // Presenting means talking: the camera brings the mic with it.
                        if v && RecPrefs.micAvailable { mic = true }
                        onCamera(v)
                    }))
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 3)
                }
                chip(mic ? "mic.fill" : "mic.slash", "Mic", "Record your voice", $mic, enabled: RecPrefs.micAvailable)
                chip(audio ? "speaker.wave.2.fill" : "speaker.slash", "Sound", "Record what your Mac plays", $audio)
                chip("cursorarrow.click.2", "Clicks", "Show a ring where you click", $clicks)
                chip("cursorarrow", "Pointer", "Show the pointer in the video", $cursor)
                chip("timer", "3s", "Count down before recording", $countdown)
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 3)
                Button(action: onWindows) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 12, weight: .semibold))
                        Text("Windows").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(Squish())
                .help("Pick a window to record from a list")
            }
            .padding(5)
            .glass(999)
            Text(windowMode ? "Click a window to record it. Space to drag an area instead."
                            : "Drag to record an area. Click to record this screen. Space to click a window.")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.opacity)
                .animation(snappy, value: windowMode)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.55)))
        }
        .environment(\.colorScheme, .dark)
    }

    func chip(_ symbol: String, _ title: String, _ help: String, _ on: Binding<Bool>, enabled: Bool = true) -> some View {
        Button { withAnimation(snappy) { on.wrappedValue.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(on.wrappedValue ? onAccent : Color.white.opacity(0.8))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(on.wrappedValue ? accent : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(Squish())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help("\(help). \(on.wrappedValue ? "On" : "Off").")
    }
}

struct OutlineView: View {
    let rect: CGRect
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(Color.white.opacity(0.85))
            .shadow(color: .black.opacity(0.35), radius: 2)
            .frame(width: rect.width + 6, height: rect.height + 6)
            .position(x: rect.midX, y: rect.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CountdownView: View {
    @ObservedObject var c: RecordController
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.black.opacity(0.42)).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
                Text("\(c.count)")
                    .font(.system(size: 60, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .id(c.count)
                    .transition(.asymmetric(insertion: .modifier(active: Pop(s: 0.6, b: 8, o: 0), identity: .rest),
                                            removal: .modifier(active: Pop(s: 1.3, b: 8, o: 0), identity: .rest)))
            }
            .frame(width: 124, height: 124)
            Text("Space to start now · Esc to cancel")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.5)))
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecBar: View {
    @ObservedObject var c: RecordController
    @State private var flashing = false

    var body: some View {
        HStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 8, height: 8)
                        .opacity(c.paused ? 0.35 : (Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.55))
                    ZStack(alignment: .leading) {
                        Text(Recordings.time(c.elapsed)).monospacedDigit()
                            .opacity(flashing ? 0 : 1)
                        Text("Take \(c.retakes.count + 1)")
                            .opacity(flashing ? 1 : 0)
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(minWidth: 52, alignment: .leading)
                }
            }
            .padding(.leading, 12).padding(.trailing, 6)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 4)
            icon(c.paused ? "play.fill" : "pause.fill", c.paused ? "Resume" : "Pause") { c.togglePause() }
            Button { c.markRetake() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .rotationEffect(.degrees(Double(c.takeFlash) * -360))
                    .frame(width: 32, height: 30).contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if !c.retakes.isEmpty {
                            Text("\(c.retakes.count)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(onAccent)
                                .frame(minWidth: 14, minHeight: 14).background(Capsule().fill(accent))
                                .offset(x: -1, y: 1)
                                .transition(.modifier(active: Pop(s: 0.4, b: 3, o: 0), identity: .rest))
                        }
                    }
            }
            .buttonStyle(Squish())
            .help("Retake: cut the last try back to your last pause  ⇧⌘9")
            icon("trash", "Discard this recording") { c.discard() }
            Button { c.stop() } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.black).frame(width: 9, height: 9)
                    Text("Stop").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.black)
                }
                .padding(.horizontal, 13).frame(height: 30)
                .background(Capsule().fill(.white))
            }
            .buttonStyle(Squish()).padding(.leading, 2)
            .help("Stop and copy  \(Shortcuts.shared.key(.record).symbols.joined(separator: " "))")
        }
        .padding(5)
        .glass(999)
        .environment(\.colorScheme, .dark)
        .padding(14)   // room for the glass shadow inside the panel
        .onChange(of: c.takeFlash) { _ in
            withAnimation(snappy) { flashing = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(snappy) { flashing = false }
            }
        }
    }

    func icon(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(Squish()).help(help)
    }
}

/// A clear window over the recorded screen that draws a soft ring wherever you click. It is the only Peek
/// window the recording includes.
@MainActor final class ClickLayer {
    let panel: KeyPanel
    private let screen: NSScreen

    init(screen: NSScreen) {
        self.screen = screen
        panel = overlayPanel(screen.frame, level: .screenSaver, mouse: false)
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        panel.contentView = v
        panel.orderFrontRegardless()
    }

    func ripple(at global: NSPoint) {
        guard screen.frame.contains(global), let root = panel.contentView?.layer else { return }
        let p = CGPoint(x: global.x - screen.frame.minX, y: global.y - screen.frame.minY)
        let d: CGFloat = 44
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        ring.fillColor = NSColor.black.withAlphaComponent(0.16).cgColor
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 3
        ring.shadowOffset = .zero
        ring.opacity = 0
        root.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 0.55
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(g, forKey: "ripple")
        CATransaction.commit()
    }
}

// MARK: - Window list

struct WinShot: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let icon: NSImage?
    let frame: CGRect          // global, top-left origin
    var image: NSImage?

    /// Other apps' normal windows that are on screen, frontmost first.
    static func load() async -> [WinShot] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return content.windows
            .filter { w in
                guard let app = w.owningApplication, app.processID != me, w.windowLayer == 0, w.isOnScreen else { return false }
                return w.frame.width > 120 && w.frame.height > 80
            }
            .sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
            .map { w in
                let pid = w.owningApplication?.processID ?? 0
                let title = (w.title ?? "").trimmingCharacters(in: .whitespaces)
                let app = w.owningApplication?.applicationName ?? ""
                return WinShot(id: w.windowID, pid: pid, app: app, title: title.isEmpty ? app : title,
                               icon: NSRunningApplication(processIdentifier: pid)?.icon, frame: w.frame)
            }
    }

    /// A small picture of one window, even when it is behind others.
    /// Pass the shareable content fetched once for the whole gallery; querying it again for every window cost a
    /// round trip to the window server per picture.
    static func picture(_ id: CGWindowID, in shared: SCShareableContent? = nil) async -> NSImage? {
        guard #available(macOS 14.0, *) else { return nil }
        var content = shared
        if content == nil { content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        guard let w = content?.windows.first(where: { $0.windowID == id }) else { return nil }
        let cfg = SCStreamConfiguration()
        let k = min(1, 560 / max(w.frame.width, 1)) * 2
        cfg.width = Int(w.frame.width * k)
        cfg.height = Int(w.frame.height * k)
        cfg.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Every open window as a picture. Type to filter, arrows to move, Return to record.
struct WindowGallery: View {
    @ObservedObject var c: RecordController
    @FocusState private var focus: Bool
    @State private var hovered: CGWindowID?
    private let cols = [GridItem(.adaptive(minimum: 196, maximum: 240), spacing: 14)]

    var body: some View {
        let list = c.filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                TextField("Search windows", text: $c.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .focused($focus)
                    .onChange(of: c.query) { _ in c.sel = 0 }
                Text("\(list.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.4))
                    .contentTransition(.numericText())
                Button { c.closeGallery() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(Squish()).help("Close  Esc")
            }
            .padding(.horizontal, 18).frame(height: 54)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    if c.shotsLoading {
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(0..<6, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)).aspectRatio(16 / 10, contentMode: .fit)
                                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.06)).frame(width: 110, height: 10)
                                }
                            }
                        }
                        .padding(18)
                    } else if list.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "macwindow").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.4))
                            Text(c.query.isEmpty ? "No other windows are open" : "No window matches \u{201C}\(c.query)\u{201D}")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, w in
                                card(w, on: i == c.sel || hovered == w.id, picked: i == c.sel)
                                    .id(w.id)
                                    .onHover { h in if h { hovered = w.id; c.sel = i } else if hovered == w.id { hovered = nil } }
                                    .onTapGesture { c.choose(w) }
                                    .transition(.modifier(active: Pop(s: 0.92, b: 6, o: 0, y: 8), identity: .rest))
                            }
                        }
                        .padding(18)
                        .onChange(of: c.sel) { i in
                            if list.indices.contains(i) { withAnimation(snappy) { proxy.scrollTo(list[i].id, anchor: .center) } }
                        }
                    }
                }
            }
            .frame(maxHeight: 470)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 14) {
                key("arrow.up.and.down.and.arrow.left.and.right", "Move")
                key("return", "Record")
                key("escape", "Back")
                Spacer()
                Text("The window comes to the front, then the countdown starts")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 18).frame(height: 40)
        }
        .frame(width: 760)
        .fixedSize(horizontal: false, vertical: true)
        .glass(22)
        .environment(\.colorScheme, .dark)
        .onAppear { focus = true }
        .animation(snappy, value: c.sel)
        .animation(snappy, value: list.map(\.id))
    }

    func card(_ w: WinShot, on: Bool, picked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05))
                if let img = w.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                        .padding(10)
                        .transition(.opacity)
                } else if let icon = w.icon {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44).opacity(0.85)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(picked ? accent : Color.white.opacity(on ? 0.25 : 0.08), lineWidth: picked ? 2.5 : 1))
            HStack(spacing: 7) {
                if let icon = w.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.app).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if w.title != w.app {
                        Text(w.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(on ? 1.025 : 1)
        .contentShape(Rectangle())
    }

    func key(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 18).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            Text(label).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}
