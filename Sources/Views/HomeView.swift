import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    waveCard
                    if let message = player.message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                    if !library.library.history.isEmpty {
                        shelf("Недавно играли", Array(library.library.history.prefix(15)))
                    }
                    if !library.library.liked.isEmpty {
                        shelf("Любимые", Array(library.library.liked.prefix(15)))
                    }
                    if library.library.history.isEmpty && library.library.liked.isEmpty {
                        Text("Найди песню во вкладке «Поиск» или перенеси библиотеку с компьютера: Библиотека → ⚙︎ → Перенести с компьютера.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("hkotuner")
        }
    }

    private var waveCard: some View {
        Button { player.startWave() } label: {
            HStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Theme.background.opacity(0.25)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Моя волна").font(.title2.weight(.bold))
                    Text("Бесконечный подбор по твоим любимым и истории")
                        .font(.subheadline)
                        .opacity(0.8)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if player.isWave && player.isPlaying {
                    Image(systemName: "waveform").font(.title2)
                }
            }
            .foregroundStyle(Color.black)
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }

    private func shelf(_ title: String, _ tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                        Button { player.play(tracks, at: i) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Artwork(url: track.thumbnailURL, size: 132, radius: 10)
                                Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                        .trackMenu(track)
                    }
                }
            }
        }
    }
}
