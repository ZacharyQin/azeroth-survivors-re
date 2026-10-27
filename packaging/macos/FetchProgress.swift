import AppKit
import Darwin
import Foundation

/// First-launch downloader. Same archive as scripts/fetch-data.sh. A window shows
/// bytes, rate, and a progress bar. An existing Data folder, or a set WOW_DATA, skips it.
final class Fetcher: NSObject, NSApplicationDelegate, NSWindowDelegate, URLSessionDataDelegate {
    private let archiveURL = URL(string: ProcessInfo.processInfo.environment["WOW_DATA_URL"]
        ?? "https://archive.org/download/WoW_1.12.1-5875/1.12.1-5875_enUS.zip")!
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Azeroth Survivors", isDirectory: true)
    private lazy var partialURL: URL = support.appendingPathComponent(zipName + ".partial")
    private lazy var logURL: URL = support.appendingPathComponent("download.log")

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var baseOffset: Int64 = 0
    private var sessionReceived: Int64 = 0
    private var expectedTotal: Int64 = -1
    private var speed: Double = 0
    private var lastSpeedBytes: Int64 = 0
    private var lastSpeedStamp = CFAbsoluteTimeGetCurrent()
    private var lastUI = CFAbsoluteTime(0)
    private var sinceSync: Int64 = 0
    private var allowResume = true
    private var restart = false
    private var cancelled = false
    private var failure: String?
    private let io = DispatchQueue(label: "azeroth.fetch")

    private var window: NSWindow!
    private var bar: NSProgressIndicator!
    private var titleLabel: NSTextField!
    private var bytesLabel: NSTextField!
    private var speedLabel: NSTextField!
    private var cancelButton: NSButton!

    private var zipName: String {
        archiveURL.lastPathComponent.isEmpty ? "client.zip" : archiveURL.lastPathComponent
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        if let preset = ProcessInfo.processInfo.environment["WOW_DATA"] {
            execGame(dataPath: preset)
        }
        if let found = existingData() {
            execGame(dataPath: found)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            alert("无法创建数据目录：\(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        if let short = lowDiskSpace() {
            alert(short)
            NSApp.terminate(nil)
            return
        }
        buildWindow()
        let already = fileSize(partialURL)
        if already > 0 {
            titleLabel.stringValue = "继续下载游戏数据"
            bytesLabel.stringValue = "已下载 \(formatBytes(already))，正在连接…"
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        startRequest()
    }

    private func existingData() -> String? {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        let candidates = [
            support.appendingPathComponent("Data").path,
            (parent as NSString).appendingPathComponent("Data"),
            (parent as NSString).appendingPathComponent("WoW/Data"),
        ]
        return candidates.first(where: hasData)
    }

    private func hasData(_ dir: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: (dir as NSString).appendingPathComponent("terrain.MPQ"))
            && fm.fileExists(atPath: (dir as NSString).appendingPathComponent("patch.MPQ"))
    }

    private func lowDiskSpace() -> String? {
        let values = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        let need: Int64 = 12 * 1024 * 1024 * 1024
        if free >= need { return nil }
        return "磁盘剩余 \(formatBytes(free))，下载和解压需要大约 12 GB。"
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 176),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Azeroth Survivors"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let view = window.contentView!

        titleLabel = label("正在下载游戏数据", size: 15, weight: .semibold, secondary: false)
        bar = NSProgressIndicator(frame: NSRect(x: 20, y: 96, width: 420, height: 18))
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bytesLabel = label("正在连接…", size: 13, weight: .regular, secondary: false)
        speedLabel = label(" ", size: 13, weight: .regular, secondary: true)
        cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 360, y: 16, width: 80, height: 28)
        titleLabel.frame = NSRect(x: 20, y: 128, width: 420, height: 22)
        bytesLabel.frame = NSRect(x: 20, y: 68, width: 420, height: 18)
        speedLabel.frame = NSRect(x: 20, y: 44, width: 320, height: 18)
        view.addSubview(titleLabel)
        view.addSubview(bar)
        view.addSubview(bytesLabel)
        view.addSubview(speedLabel)
        view.addSubview(cancelButton)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, secondary: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func startRequest() {
        var request = URLRequest(url: archiveURL)
        let offset = (allowResume && FileManager.default.fileExists(atPath: partialURL.path)) ? fileSize(partialURL) : 0
        baseOffset = offset
        sessionReceived = 0
        lastSpeedBytes = 0
        lastSpeedStamp = CFAbsoluteTimeGetCurrent()
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        task = session.dataTask(with: request)
        task?.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range"),
           next.value(forHTTPHeaderField: "Range") == nil {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = "服务器没有返回 HTTP 响应。"
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206:
                try openHandle(append: true)
                expectedTotal = totalLength(http, status: 206)
                completionHandler(.allow)
            case 200:
                baseOffset = 0
                try openHandle(append: false)
                expectedTotal = totalLength(http, status: 200)
                completionHandler(.allow)
            case 416 where allowResume:
                allowResume = false
                restart = true
                try? FileManager.default.removeItem(at: partialURL)
                completionHandler(.cancel)
            default:
                failure = "下载失败，HTTP \(http.statusCode)。"
                completionHandler(.cancel)
            }
        } catch {
            failure = "无法写入下载文件：\(error.localizedDescription)"
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = "写入中断：\(error.localizedDescription)"
            task?.cancel()
            return
        }
        sessionReceived += Int64(data.count)
        sinceSync += Int64(data.count)
        if sinceSync >= 8 * 1024 * 1024 {
            try? handle?.synchronize()
            sinceSync = 0
        }
        publish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        if restart {
            restart = false
            startRequest()
            return
        }
        if cancelled {
            let kept = fileSize(partialURL)
            appendLog("paused at \(kept) bytes")
            DispatchQueue.main.async {
                self.speedLabel.stringValue = kept > 0
                    ? "已保留 \(self.formatBytes(kept))，下次打开从这里继续"
                    : "已取消"
                self.cancelButton.isEnabled = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let failure {
            let message = failure
            DispatchQueue.main.async {
                self.alert(message)
                NSApp.terminate(nil)
            }
            return
        }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            let message = "下载失败：\(error.localizedDescription)"
            DispatchQueue.main.async {
                self.alert(message)
                NSApp.terminate(nil)
            }
            return
        }
        if error != nil {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async { self.showExtracting() }
        io.async { self.extract() }
    }

    private func openHandle(append: Bool) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partialURL.path) {
            fm.createFile(atPath: partialURL.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: partialURL)
        if append {
            try file.seekToEnd()
        } else {
            try file.truncate(atOffset: 0)
        }
        handle = file
    }

    private func publish() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastSpeedStamp
        if dt >= 0.5 {
            speed = Double(sessionReceived - lastSpeedBytes) / dt
            lastSpeedBytes = sessionReceived
            lastSpeedStamp = now
        }
        if now - lastUI < 0.1 { return }
        lastUI = now
        let received = baseOffset + sessionReceived
        let total = expectedTotal
        let rate = speed
        DispatchQueue.main.async { self.render(received: received, total: total, rate: rate) }
    }

    private func render(received: Int64, total: Int64, rate: Double) {
        if total > 0 {
            bar.isIndeterminate = false
            bar.doubleValue = min(1, Double(received) / Double(total))
            let pct = Int((100 * Double(received) / Double(total)).rounded())
            bytesLabel.stringValue = "\(formatBytes(received)) / \(formatBytes(total))（\(pct)%）"
        } else {
            bar.isIndeterminate = true
            bytesLabel.stringValue = "\(formatBytes(received))"
        }
        var speedText = formatBytes(Int64(rate)) + "/s"
        if rate > 1, total > received {
            speedText += " · " + formatDuration(Double(total - received) / rate)
        }
        speedLabel.stringValue = speedText
    }

    private func showExtracting() {
        titleLabel.stringValue = "正在解压"
        bytesLabel.stringValue = "解压大约需要几分钟"
        speedLabel.stringValue = " "
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        cancelButton.isEnabled = false
    }

    private func extract() {
        let dataDir = support.appendingPathComponent("Data").path
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", partialURL.path, "Data/*.MPQ", "-d", support.path]
            unzip.standardOutput = log
            unzip.standardError = log
            try unzip.run()
            unzip.waitUntilExit()
            try? log.close()
            guard unzip.terminationStatus == 0, hasData(dataDir) else {
                failOnMain("压缩包里没有 Data/terrain.MPQ 和 Data/patch.MPQ。详情见 \(logURL.path)")
                return
            }
            try? FileManager.default.removeItem(at: partialURL)
            execGame(dataPath: dataDir)
        } catch {
            failOnMain("解压失败：\(error.localizedDescription)")
        }
    }

    @objc private func cancelClicked() {
        userCancelled()
    }

    func windowWillClose(_ notification: Notification) {
        userCancelled()
    }

    private func userCancelled() {
        if cancelled { return }
        cancelled = true
        task?.cancel()
        if task == nil {
            NSApp.terminate(nil)
        }
    }

    private func failOnMain(_ message: String) {
        DispatchQueue.main.async {
            self.alert(message)
            NSApp.terminate(nil)
        }
    }

    private func alert(_ message: String) {
        let panel = NSAlert()
        panel.messageText = "Azeroth Survivors"
        panel.informativeText = message
        panel.runModal()
    }

    private func execGame(dataPath: String) -> Never {
        setenv("WOW_DATA", dataPath, 1)
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/warcraft-survivors").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            fputs("missing game binary: \(path)\n", stderr)
            exit(1)
        }
        let cPath = strdup(path)!
        execv(cPath, [cPath, nil])
        fputs("exec failed: \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] else {
            return 0
        }
        if let number = size as? NSNumber { return number.int64Value }
        return 0
    }

    private func totalLength(_ response: HTTPURLResponse, status: Int) -> Int64 {
        if let header = response.value(forHTTPHeaderField: "Content-Range"),
           let total = header.split(separator: "/").last,
           let value = Int64(total), value > 0 {
            return value
        }
        let length = response.expectedContentLength
        if length <= 0 { return -1 }
        return status == 206 ? baseOffset + length : length
    }

    private func appendLog(_ line: String) {
        let text = line + "\n"
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: logURL) {
            defer { try? log.close() }
            _ = try? log.seekToEnd()
            try? log.write(contentsOf: Data(text.utf8))
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(value)) \(units[index])" }
        return String(format: "%.1f %@", value, units[index])
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "剩余约 \(whole) 秒" }
        let minutes = whole / 60
        if minutes < 60 { return "剩余约 \(minutes) 分钟" }
        return "剩余约 \(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}

let fetcher = Fetcher()
fetcher.run()
