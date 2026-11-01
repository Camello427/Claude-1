import Foundation
import Observation

/// Saves web videos to the iPhone so they can be watched or cast later.
@MainActor
@Observable
final class DownloadManager {
    enum State: Equatable {
        case running, finished, failed(String), cancelled
    }

    struct Download: Identifiable {
        let id: UUID
        var title: String
        var source: URL
        var received: Int64 = 0
        var expected: Int64 = 0
        var state: State = .running
        var savedTo: URL?

        var progress: Double { expected > 0 ? Double(received) / Double(expected) : 0 }
    }

    private(set) var downloads: [Download] = []
    var onFinished: (() -> Void)?

    @ObservationIgnored private let delegate: DownloadDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]

    var activeCount: Int { downloads.filter { $0.state == .running }.count }

    init() {
        let delegate = DownloadDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.manager = self
    }

    func start(_ item: MediaItem, headers: [String: String], cookies: [HTTPCookie]) {
        var request = URLRequest(url: item.url)
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let matching = cookies.filter { $0.applies(to: item.url) }
        for (k, v) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(v, forHTTPHeaderField: k) }

        let id = UUID()
        let task = session.downloadTask(with: request)
        let ext = item.url.pathExtension.isEmpty ? "mp4" : item.url.pathExtension
        let cleanTitle = String(item.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "|", with: "-").prefix(80))
        task.taskDescription = "\(id.uuidString)|\(cleanTitle).\(ext)"
        tasks[id] = task
        downloads.insert(Download(id: id, title: item.title, source: item.url), at: 0)
        task.resume()
    }

    func cancel(_ download: Download) {
        tasks[download.id]?.cancel()
        tasks[download.id] = nil
        update(download.id) { $0.state = .cancelled }
    }

    func remove(_ download: Download) {
        if download.state == .running { cancel(download) }
        downloads.removeAll { $0.id == download.id }
    }

    func clearFinished() {
        downloads.removeAll { $0.state != .running }
    }

    // Called by the delegate.

    fileprivate func progress(_ id: UUID, received: Int64, expected: Int64) {
        update(id) {
            $0.received = received
            $0.expected = expected
        }
    }

    fileprivate func finished(_ id: UUID, at url: URL) {
        tasks[id] = nil
        update(id) {
            $0.state = .finished
            $0.savedTo = url
            if $0.expected <= 0 { $0.expected = $0.received }
        }
        onFinished?()
    }

    fileprivate func failed(_ id: UUID, message: String) {
        tasks[id] = nil
        update(id) { d in
            if d.state == .running { d.state = .failed(message) }
        }
    }

    private func update(_ id: UUID, _ change: (inout Download) -> Void) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[i])
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var manager: DownloadManager?

    private func info(_ task: URLSessionTask) -> (UUID, String)? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
        return (id, parts[1])
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, _) = info(downloadTask) else { return }
        Task { @MainActor [weak self] in
            self?.manager?.progress(id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, fallbackName) = info(downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            Task { @MainActor [weak self] in self?.manager?.failed(id, message: "The website refused the download (error \(code)).") }
            return
        }
        var name = downloadTask.response?.suggestedFilename ?? fallbackName
        if name.isEmpty || !name.contains(".") { name = fallbackName }
        let dest = LocalFiles.uniqueDestination(for: name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor [weak self] in self?.manager?.finished(id, at: dest) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.manager?.failed(id, message: message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (id, _) = info(task) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.manager?.failed(id, message: message) }
    }
}
