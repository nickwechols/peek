// Updates: Peek checks for a new version, downloads it, checks its signature and swaps itself in place.
//
// There are no accounts and no server. Each release on GitHub carries update.json (the version, its notes and
// an Ed25519 signature of Peek.zip). The check is one plain request for that file: no identifier, no cookies,
// nothing about you or your Mac. An update only installs if it was signed with Peek's own release key, so a
// tampered download, or one from anywhere else, is thrown away.

import AppKit
import SwiftUI
import CryptoKit

/// Peek's release key, public half. The private half lives only in the release workflow's secrets.
private let updatePublicKey = "veTvwSOqCJ5G4smeKBxmMWSrxH9hQvdNE8SFWG06WNQ="
private let updateFeed = URL(string: "https://github.com/nickwechols/peek/releases/latest/download/update.json")!
private let downloadPage = URL(string: "https://peekmac.xyz/download")!

struct UpdateInfo: Codable, Equatable {
    let version: String
    let notes: String?
    let url: String
    let size: Int64?
    let signature: String
    let minimumSystem: String?
}

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable { case idle, checking, upToDate, available, downloading, installing, restarting, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var info: UpdateInfo?
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    /// "Later" hides the card until the next launch; the menu still offers the update.
    @Published var dismissed = false
    /// The menu bar rebuilds its menu when an update shows up or goes away.
    var onChange: () -> Void = {}

    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "update.auto") }
    }
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    var busy: Bool { [.downloading, .installing, .restarting].contains(phase) }

    private var timer: Timer?
    private var session: URLSession?

    /// Quietly, a little after launch and then every six hours.
    func start() {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Self.automatic { await check(quiet: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in if Updater.automatic { await Updater.shared.check(quiet: true) } }
        }
    }

    func check(quiet: Bool) async {
        guard !busy, phase != .checking else { return }
        if !quiet { set(.checking) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 20
        do {
            let (data, resp) = try await URLSession(configuration: cfg).data(from: updateFeed)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let i = try JSONDecoder().decode(UpdateInfo.self, from: data)
            if Self.newer(i.version, than: current), Self.systemAllows(i.minimumSystem) {
                if info != i { dismissed = false }
                info = i
                set(.available)
            } else if quiet {
                if phase == .available { set(.idle) }
            } else {
                set(.upToDate)
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                if phase == .upToDate { set(.idle) }
            }
        } catch {
            if !quiet { set(.failed("Couldn't reach GitHub. Check your connection and try again.")) }
        }
    }

    /// Download, verify, unpack, swap, restart. Everything you made stays where it is.
    func install() {
        guard let i = info, let url = URL(string: i.url), url.scheme == "https", !busy else { return }
        let app = Bundle.main.bundleURL
        guard Self.canReplace(app) else {
            set(.failed("Peek can only update itself from the Applications folder. Download it once more to fix this."))
            return
        }
        received = 0
        expected = i.size ?? 0
        set(.downloading)
        Task {
            do {
                let dir = try Self.workDir()
                let zip = dir.appendingPathComponent("Peek.zip")
                try await download(url, to: zip)
                set(.installing)
                let newApp = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    try Self.verify(zip, signature: i.signature)
                    return try Self.unpack(zip, in: dir, expecting: i.version)
                }.value
                set(.restarting)
                try? await Task.sleep(nanoseconds: 900_000_000)     // long enough to read, short enough not to wait
                try Self.relaunch(replacing: app, with: newApp, backup: dir.appendingPathComponent("Previous.app"))
            } catch {
                session?.invalidateAndCancel()
                session = nil
                set(.failed((error as? UpdateError)?.message ?? "The update didn't finish. Nothing was changed."))
            }
        }
    }

    func openDownloadPage() { NSWorkspace.shared.open(downloadPage) }
    func later() { withAnimation(gentle) { dismissed = true } }
    func reset() { set(info != nil ? .available : .idle) }

    private func set(_ p: Phase) {
        withAnimation(bouncy) { phase = p }
        onChange()
    }

    // MARK: Download

    private func download(_ url: URL, to dest: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let d = DownloadDelegate(dest: dest,
                progress: { w, t in Task { @MainActor in
                    let u = Updater.shared
                    u.received = w
                    if t > 0 { u.expected = t }
                } },
                done: { r in cont.resume(with: r) })
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.urlCache = nil
            let s = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
            session = s
            s.downloadTask(with: url).resume()
        }
        session?.finishTasksAndInvalidate()
        session = nil
    }

    // MARK: Checks

    struct UpdateError: Error { let message: String }

    /// Only Peek's release key can produce a valid signature for the downloaded file.
    nonisolated static func verify(_ zip: URL, signature: String) throws {
        guard let keyData = Data(base64Encoded: updatePublicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature),
              let data = try? Data(contentsOf: zip, options: .mappedIfSafe),
              key.isValidSignature(sig, for: data) else {
            throw UpdateError(message: "The download didn't pass Peek's signature check, so it was thrown away.")
        }
    }

    nonisolated static func unpack(_ zip: URL, in dir: URL, expecting version: String) throws -> URL {
        let out = dir.appendingPathComponent("Unpacked", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        let app = out.appendingPathComponent("Peek.app")
        guard p.terminationStatus == 0, let b = Bundle(url: app),
              b.bundleIdentifier == Bundle.main.bundleIdentifier,
              b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError(message: "The update didn't unpack correctly. Nothing was changed.")
        }
        return app
    }

    /// Updating in place needs a real, writable install: not a disk image, not a quarantined copy macOS moved.
    static func canReplace(_ app: URL) -> Bool {
        let p = app.path
        guard !p.contains("/AppTranslocation/"), !p.hasPrefix("/Volumes/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: p)
    }

    nonisolated static func workDir() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.nickechols.peek/Update", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A tiny helper waits for Peek to quit, swaps the app (putting the old one back if anything fails) and opens it.
    /// Paths go in as arguments, never into the script text.
    static func relaunch(replacing app: URL, with new: URL, backup: URL) throws {
        let script = """
        i=0; while kill -0 "$0" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        rm -rf "$3"
        if mv "$1" "$3"; then
          if mv "$2" "$1"; then rm -rf "$3"; else mv "$3" "$1"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), app.path, new.path, backup.path]
        try p.run()
        NSApp.terminate(nil)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for k in 0..<max(x.count, y.count) {
            let l = k < x.count ? x[k] : 0, r = k < y.count ? y[k] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func systemAllows(_ min: String?) -> Bool {
        guard let min else { return true }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return !newer(min, than: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let dest: URL
    let progress: @Sendable (Int64, Int64) -> Void
    let done: @Sendable (Result<Void, Error>) -> Void
    private var finished = false
    private let lock = NSLock()

    init(dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void, done: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.dest = dest; self.progress = progress; self.done = done
    }
    private func finish(_ r: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        done(r)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let r = downloadTask.response as? HTTPURLResponse, r.statusCode != 200 { finish(.failure(URLError(.badServerResponse))); return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - The update card, at the foot of the sidebar

/// Quiet until there is something new. Then one card: what's new, one button, and the update happening in it.
struct UpdateCard: View {
    @ObservedObject var u = Updater.shared

    var body: some View {
        Group {
            if visible {
                card.transition(.modifier(active: Pop(s: 0.9, b: 8, o: 0, y: 14), identity: .rest))
            }
        }
        .animation(bouncy, value: visible)
    }

    var visible: Bool {
        switch u.phase {
        case .available: return !u.dismissed
        case .downloading, .installing, .restarting, .failed: return true
        default: return false
        }
    }

    var card: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(tint.opacity(0.14))
                    Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        .contentTransition(.opacity)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.55)).monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            switch u.phase {
            case .available:
                if let n = u.info?.notes, !n.isEmpty {
                    Text(n).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.7)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    button("Update", primary: true) { u.install() }
                    button("Later", primary: false) { u.later() }
                }
            case .downloading:
                bar(u.progress)
            case .installing, .restarting:
                bar(1)
            case .failed:
                HStack(spacing: 6) {
                    button("Try again", primary: true) { u.reset(); u.install() }
                    button("Download", primary: false) { u.openDownloadPage() }
                }
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hairline, lineWidth: 1))
        .animation(bouncy, value: u.phase)
    }

    var tint: Color {
        if case .failed = u.phase { return Color(red: 0.92, green: 0.32, blue: 0.27) }
        return accent
    }
    var icon: String {
        switch u.phase {
        case .installing: return "gearshape.fill"
        case .restarting: return "checkmark"
        case .failed: return "exclamationmark"
        default: return "arrow.down"
        }
    }
    var title: String {
        let v = u.info?.version ?? ""
        switch u.phase {
        case .available: return "Peek \(v) is here"
        case .downloading: return "Downloading \(v)"
        case .installing: return "Installing"
        case .restarting: return "Restarting Peek"
        case .failed: return "Update paused"
        default: return ""
        }
    }
    var subtitle: String {
        switch u.phase {
        case .available: return "You have \(u.current)"
        case .downloading:
            let mb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_000_000) }
            return u.expected > 0 ? "\(mb(u.received)) of \(mb(u.expected)) MB" : "\(mb(u.received)) MB"
        case .installing: return "Checking the signature"
        case .restarting: return "Back in a second"
        case .failed(let m): return m
        default: return ""
        }
    }

    func bar(_ p: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.08))
                Capsule().fill(tint).frame(width: max(6, g.size.width * p))
                    .animation(.easeOut(duration: 0.25), value: p)
            }
        }
        .frame(height: 5)
    }

    func button(_ t: String, primary: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(t).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? onAccent : ink.opacity(0.75))
                .frame(maxWidth: primary ? .infinity : nil).padding(.horizontal, primary ? 0 : 12)
                .frame(height: 28)
                .background(Capsule().fill(primary ? accent : ink.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(Squish())
    }
}

/// Settings: the version you have, automatic checks, and a way to check right now.
struct UpdateSettings: View {
    @ObservedObject var u = Updater.shared
    @State private var auto = Updater.automatic

    var body: some View {
        Toggle(isOn: $auto) { label("Check for updates automatically", "One small request to GitHub, nothing about you") }
            .onChange(of: auto) { v in Updater.automatic = v }
            .padding(16)
        Rectangle().fill(hairline).frame(height: 1)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Peek \(u.current)").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                Text(status).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.5)).contentTransition(.opacity)
            }
            Spacer()
            Button { Task { await u.check(quiet: false) } } label: {
                HStack(spacing: 6) {
                    if u.phase == .checking { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(u.phase == .checking ? "Checking" : "Check now").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(ink.opacity(0.8)).padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(ink.opacity(0.07))).contentShape(Capsule())
            }
            .buttonStyle(Squish())
            .disabled(u.busy || u.phase == .checking)
        }
        .padding(16)
        .animation(gentle, value: u.phase)
    }

    var status: String {
        switch u.phase {
        case .upToDate: return "You have the latest version"
        case .available: return "Peek \(u.info?.version ?? "") is ready. Update from the sidebar."
        case .checking: return "Looking for a newer version"
        case .downloading, .installing, .restarting: return "Updating now"
        case .failed(let m): return m
        case .idle: return "Updates install in place. Your screenshots and recordings stay put."
        }
    }

    func label(_ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
            Text(s).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.5))
        }
    }
}
