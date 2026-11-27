import SwiftUI

enum HomeSection: String, CaseIterable, Identifiable {
    case wave, smart, releases, recent, liked, feed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wave: return "Моя волна"
        case .smart: return "Умные подборки"
        case .releases: return "Новое у ваших исполнителей"
        case .recent: return "Недавно слушали"
        case .liked: return "Любимые"
        case .feed: return "Подборки YouTube Music"
        }
    }

    static func order(_ raw: String) -> [Self] {
        var seen: Set<Self> = []
        let saved = raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }
        return (saved + allCases).filter { seen.insert($0).inserted }
    }
}

struct HomeOrderSettings: View {
    @AppStorage("home.order") private var saved = ""

    var body: some View {
        List {
            Section {
                ForEach(HomeSection.order(saved)) { section in Text(section.title) }
                    .onMove { indices, destination in
                        var order = HomeSection.order(saved)
                        order.move(fromOffsets: indices, toOffset: destination)
                        saved = order.map(\.rawValue).joined(separator: ",")
                    }
            } footer: {
                Text("Нажмите «Править» и перетащите блоки в нужном порядке.")
            }
            Button("Вернуть исходный порядок") { saved = "" }.disabled(saved.isEmpty)
        }
        .navigationTitle("Порядок блоков")
        .toolbar { EditButton() }
    }
}

struct MiniPlayerSettings: View {
    @AppStorage("mini.previous") private var previous = false
    @AppStorage("mini.next") private var next = true
    @AppStorage("mini.like") private var like = true

    var body: some View {
        Form {
            Toggle("Предыдущий трек", isOn: $previous)
            Toggle("Следующий трек", isOn: $next)
            Toggle("В любимые", isOn: $like)
        }
        .navigationTitle("Кнопки мини-плеера")
    }
}
