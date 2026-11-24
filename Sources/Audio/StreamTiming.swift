import Foundation

/// The stream's timeline is normally authoritative. A second duration can correct
/// an overstated timeline without cutting small differences in catalog metadata.
struct StreamTiming {
    let length: Double
    let end: Double?

    init(reported: Double?, reference: Double?) {
        let asset = Self.valid(reported)
        let expected = Self.valid(reference)
        if let asset, let expected, asset >= expected * 1.5, asset - expected >= 5 {
            length = expected
            end = expected
        } else {
            length = asset ?? expected ?? 0
            end = nil
        }
    }

    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

enum HLSPlaylistTiming {
    enum Contents: Equatable {
        case duration(Double)
        case variant(URL)
    }

    static func read(_ address: URL) async -> Double? {
        var url = address
        do {
            for _ in 0..<3 {
                guard url.scheme == "https", url.user == nil, url.password == nil else { return nil }
                let request = URLRequest(url: url, timeoutInterval: 5)
                let (bytes, result) = try await URLSession.shared.bytes(for: request)
                guard let http = result as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let base = http.url, base.scheme == "https" else { return nil }
                var data = Data()
                for try await byte in bytes {
                    if Task.isCancelled || data.count == 512 * 1024 { return nil }
                    data.append(byte)
                }
                guard let text = String(data: data, encoding: .utf8), let contents = parse(text, base: base) else { return nil }
                switch contents {
                case .duration(let duration): return duration
                case .variant(let address): url = address
                }
            }
        } catch {}
        return nil
    }

    static func parse(_ playlist: String, base: URL) -> Contents? {
        let lines = playlist.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { return nil }
        if let variant = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
           let path = lines.dropFirst(variant + 1).first(where: { !$0.hasPrefix("#") }),
           let url = URL(string: path, relativeTo: base)?.absoluteURL {
            return .variant(url)
        }
        guard lines.contains("#EXT-X-ENDLIST") else { return nil }
        var total = 0.0
        for line in lines where line.hasPrefix("#EXTINF:") {
            guard let number = line.dropFirst(8).split(separator: ",", maxSplits: 1).first,
                  let duration = StreamTiming.valid(Double(number.trimmingCharacters(in: .whitespaces))) else { return nil }
            total += duration
        }
        return StreamTiming.valid(total).map { .duration($0) }
}
}
