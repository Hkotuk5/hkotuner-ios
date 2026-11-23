import SwiftUI

struct YearRecapView: View {
    @ObservedObject private var stats = StatsStore.shared
    @ObservedObject private var sync = DeviceSync.shared
    @State private var selectedYear = ""

    var body: some View {
        let local = stats.localListening.years
        let remote = sync.remoteListening.years
        let years = Set(local.keys).union(remote.keys).sorted(by: >)
        let year = years.contains(selectedYear) ? selectedYear : years.first ?? ""
        var combined = remote[year] ?? ListeningSummary.Year()
        if let heard = local[year] { combined.add(heard) }
        return List {
            if !years.isEmpty {
                Picker("Год", selection: Binding(get: { year }, set: { selectedYear = $0 })) {
                    ForEach(years, id: \.self) { Text($0).tag($0) }
                }
                if let name = sync.profile?.name {
                    LabeledContent("Профиль", value: name)
                }
                Section {
                    LabeledContent("Время", value: listenedText(combined.seconds))
                    LabeledContent("Прослушивания", value: combined.plays.formatted())
                    LabeledContent("Разные песни", value: combined.tracks.values.filter { $0.plays > 0 }.count.formatted())
                }
                Section("Песни") {
                    let songs = combined.tracks.sorted {
                        if $0.value.plays != $1.value.plays { return $0.value.plays > $1.value.plays }
                        if $0.value.seconds != $1.value.seconds { return $0.value.seconds > $1.value.seconds }
                        return $0.key < $1.key
                    }.filter { $0.value.plays > 0 }.prefix(5)
                    ForEach(Array(songs), id: \.key) { item in
                        LabeledContent(item.value.title, value: item.value.artist)
                    }
                }
                Section("Исполнители") {
                    let artists = combined.artists.sorted {
                        if $0.value.seconds != $1.value.seconds { return $0.value.seconds > $1.value.seconds }
                        return $0.key < $1.key
                    }.prefix(5)
                    ForEach(Array(artists), id: \.key) { item in
                        LabeledContent(item.key, value: listenedText(item.value.seconds))
                    }
                }
                if !genres(for: combined).isEmpty {
                    Section("Жанры") {
                        ForEach(genres(for: combined), id: \.self) { Text($0) }
                    }
                }
            } else {
                EmptyNote(icon: "chart.bar", title: "Пока нет итогов", text: "Послушай музыку или синхронизируй статистику с ПК.")
            }
        }
        .screenBackground()
        .navigationTitle("Итоги года")
    }

    private func genres(for year: ListeningSummary.Year) -> [String] {
        var weights: [String: Double] = [:]
        let artists = year.artists.sorted {
            if $0.value.seconds != $1.value.seconds { return $0.value.seconds > $1.value.seconds }
            return $0.key < $1.key
        }.prefix(20)
        for (artist, count) in artists {
            for genre in sync.remoteListening.genres[artist.lowercased()] ?? [] {
                weights[genre, default: 0] += count.seconds
            }
        }
        return Array(weights.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.prefix(3).map(\.key))
    }
}
