import SwiftUI

struct DownloadAction: View {
    @EnvironmentObject private var player: Player
    @ObservedObject private var downloads = Downloads.shared
    let track: Track

    var body: some View {
        if Downloads.supports(track) {
            if downloads.running.contains(track.id) {
                Label("Скачивается…", systemImage: "hourglass")
            } else if downloads.source(for: track) != nil {
                Button(role: .destructive) {
                    do { try downloads.remove(track) } catch { player.message = error.localizedDescription }
                } label: { Label("Удалить скачанное", systemImage: "trash") }
            } else {
                Button {
                    Task {
                        do {
                            try await downloads.keep(track)
                            if downloads.source(for: track) != nil { player.message = "Скачано: \(track.title)" }
                        } catch is CancellationError {
                        } catch let block as YouTubeDownloadBlock {
                            player.message = block.localizedDescription
                        } catch {
                            player.message = "Не удалось скачать: \(error.localizedDescription)"
                        }
                    }
                } label: { Label("Скачать", systemImage: "arrow.down.circle") }
            }
        }
    }
}

struct DownloadedView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        let tracks = downloads.tracks(in: library.library)
        TrackListView(title: "Скачанные", tracks: tracks, empty: "Выбери «Скачать» в меню песни, чтобы слушать её без интернета.", onDelete: { offsets in
            do {
                for offset in offsets { try downloads.remove(tracks[offset]) }
            } catch {
                player.message = error.localizedDescription
            }
        })
    }
}
