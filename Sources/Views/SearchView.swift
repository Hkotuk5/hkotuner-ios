import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.orange).font(.footnote)
                }
                if results.isEmpty && !searching && query.isEmpty {
                    if !recent.isEmpty {
                        Section("Недавние запросы") {
                            ForEach(recent, id: \.self) { q in
                                Button { query = q; run() } label: {
                                    Label(q, systemImage: "clock.arrow.circlepath").foregroundStyle(Theme.ink)
                                }
                            }
                            Button("Очистить", role: .destructive) { recentRaw = "" }
                        }
                    } else {
                        Text("Песни ищутся в YouTube Music. Можно вставить ссылку на трек YouTube.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                }
                ForEach(results) { track in
                    TrackRow(track: track)
                        .onTapGesture { player.playSingle(track) }
                        .trackMenu(track)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .overlay { if searching && results.isEmpty { ProgressView() } }
            .navigationTitle("Поиск")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Песня, исполнитель или ссылка")
            .onSubmit(of: .search) { run() }
            .onChange(of: query) { value in
                if value.isEmpty { results = []; error = nil }
            }
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        remember(q)
        task?.cancel()
        searching = true
        error = nil
        task = Task {
            do {
                let found = try await YTMusic.search(q)
                guard !Task.isCancelled else { return }
                results = found
                if found.isEmpty { error = "Ничего не нашлось" }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            searching = false
        }
    }

    private func remember(_ q: String) {
        var list = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentRaw = list.prefix(12).joined(separator: "\n")
    }
}
