import SwiftUI

/// Minutes, streaks and favourites, counted on this phone.
struct StatsView: View {
    @EnvironmentObject private var player: Player
    @ObservedObject private var stats = StatsStore.shared
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            if stats.isEmpty {
                EmptyNote(icon: "chart.bar", title: "Пока нечего считать",
                          text: "Послушай пару песен — здесь появятся минуты, любимые песни и исполнители.")
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    totals
                    week
                    monthTop
                    topArtists
                    allTimeTop
                    Button("Сбросить статистику", role: .destructive) { confirmReset = true }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
        .background(ScreenBackground())
        .navigationTitle("Статистика")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink("Итоги года") { YearRecapView() }
            }
        }
        .confirmationDialog("Сбросить статистику этого iPhone?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { stats.reset() }
        }
    }

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            number("Сегодня", listenedText(stats.seconds(lastDays: 1)))
            number("За неделю", listenedText(stats.seconds(lastDays: 7)))
            number("За месяц", listenedText(stats.seconds(lastDays: 30)))
            number("Дней подряд", "\(stats.streak())")
        }
    }

    private func number(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            Text(value).font(.title2.weight(.bold)).foregroundStyle(Theme.ink).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private var week: some View {
        let days = stats.week()
        let top = max(60, days.map { $0.seconds }.max() ?? 60)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Неделя").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Calendar.current.isDateInToday(day.day) ? Theme.accent : Theme.accent.opacity(0.45))
                            .frame(height: max(4, CGFloat(day.seconds / top) * 120))
                        Text(day.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 150, alignment: .bottom)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    @ViewBuilder private var monthTop: some View {
        let top = stats.topTracks(month: Date(), limit: 5)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Итоги месяца").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                ForEach(Array(top.enumerated()), id: \.offset) { i, item in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(Theme.accent).frame(width: 22)
                        TrackRow(track: item.track)
                        Text("×\(item.plays)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    .onTapGesture { player.play(top.map { $0.track }, at: i) }
                }
            }
        }
    }

    @ViewBuilder private var topArtists: some View {
        let artists = stats.topArtists(6)
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Исполнители").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    NavigationLink { ArtistView(artistId: nil, name: artist.name) } label: {
                        HStack {
                            Text(artist.name).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(listenedText(artist.seconds)).font(.caption).foregroundStyle(Theme.muted)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var allTimeTop: some View {
        let top = stats.topTracks(10)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Чаще всего").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                ForEach(Array(top.enumerated()), id: \.offset) { i, stat in
                    HStack {
                        TrackRow(track: stat.track)
                        Text("×\(stat.plays)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    .onTapGesture { player.play(top.map(\.track), at: i) }
                    .trackMenu(stat.track)
                }
            }
        }
    }
}
