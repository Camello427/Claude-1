import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Where imported videos are kept. Not actor-bound, so file-transfer callbacks can use it.
enum LocalFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var subtitlesDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let subtitleExtensions: Set<String> = ["srt", "vtt"]

    static func uniqueDestination(for name: String, in folder: URL? = nil) -> URL {
        let directory = folder ?? directory
        let clean = name.isEmpty ? "video.mp4" : name
        var dest = directory.appendingPathComponent(clean)
        var n = 2
        let stem = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return dest
    }
}

/// A video picked from the Photos library.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = LocalFiles.uniqueDestination(for: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// Videos and audio the user imported to cast from the phone.
@MainActor
@Observable
final class LocalMediaLibrary {
    private(set) var items: [MediaItem] = []
    private(set) var subtitles: [SubtitleTrack] = []

    init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: LocalFiles.directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        items = urls
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.hasDirectoryPath }
            .filter { !LocalFiles.subtitleExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
            .map { MediaItem(url: $0, title: $0.deletingPathExtension().lastPathComponent, kind: MediaKind.detect(url: $0, mime: nil), source: .local) }
        let subs = (try? FileManager.default.contentsOfDirectory(at: LocalFiles.subtitlesDirectory, includingPropertiesForKeys: nil)) ?? []
        subtitles = subs
            .filter { LocalFiles.subtitleExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { SubtitleTrack(url: $0, label: $0.deletingPathExtension().lastPathComponent, language: nil) }
    }

    /// Copies an .srt or .vtt file picked in Files and returns it as a subtitle track.
    func importSubtitle(from url: URL) throws -> SubtitleTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard LocalFiles.subtitleExtensions.contains(url.pathExtension.lowercased()) else {
            throw CastError.unsupported("that subtitle format. Pick an .srt or .vtt file")
        }
        let dest = LocalFiles.uniqueDestination(for: url.lastPathComponent, in: LocalFiles.subtitlesDirectory)
        try FileManager.default.copyItem(at: url, to: dest)
        reload()
        return SubtitleTrack(url: dest, label: dest.deletingPathExtension().lastPathComponent, language: nil)
    }

    /// Copies a file picked in the Files app into the app's own storage.
    func importFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = LocalFiles.uniqueDestination(for: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        reload()
    }

    func delete(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    private func date(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
