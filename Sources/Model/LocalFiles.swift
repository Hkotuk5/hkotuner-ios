import AVFoundation
import Foundation

/// The listener's own music files, copied into Documents/Music. That folder
/// also shows up in the Files app (На iPhone → hkotuner), so songs can be
/// dropped there from a computer or a chat, then picked up with «Обновить».
enum LocalFiles {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf", "mp4"]

    static var musicDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(_ track: Track) -> URL { musicDir.appendingPathComponent(track.url) }

    /// copies picked files in and reads their tags
    static func importFiles(_ urls: [URL]) async -> [Track] {
        var out: [Track] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard extensions.contains(source.pathExtension.lowercased()) else { continue }
            let target = freeName(for: source.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: source, to: target)
                out.append(await track(for: target))
            } catch {
                continue
            }
        }
        return out
    }

    /// every audio file in Documents/Music, including ones dropped in through Files
    static func scan() async -> [Track] {
        let files = (try? FileManager.default.contentsOfDirectory(at: musicDir, includingPropertiesForKeys: nil)) ?? []
        var out: [Track] = []
        for file in files where extensions.contains(file.pathExtension.lowercased()) {
            out.append(await track(for: file))
        }
        return out
    }

    static func delete(_ track: Track) {
        guard track.isLocal, !track.url.contains("/"), !track.url.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: fileURL(track))
    }

    static func track(for file: URL) async -> Track {
        let asset = AVURLAsset(url: file)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first,
                  let text = try? await item.load(.stringValue) else { return nil }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let name = file.lastPathComponent
        let title = await value(.commonIdentifierTitle)
        let artist = await value(.commonIdentifierArtist)
        let album = await value(.commonIdentifierAlbumName)
        let composer = await value(.commonIdentifierCreator)
        var duration: Double?
        if let seconds, seconds.isFinite, seconds > 0 { duration = seconds }
        return Track(
            id: "local:\(name)",
            source: "local",
            title: title ?? file.deletingPathExtension().lastPathComponent,
            artist: artist ?? "",
            album: album,
            duration: duration,
            thumbnail: nil,
            url: name,
            artistId: nil,
            composer: composer
        )
    }

    private static func freeName(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = musicDir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = musicDir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
