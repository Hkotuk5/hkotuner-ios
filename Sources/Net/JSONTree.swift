import Foundation

/// Small helpers for walking YouTube's untyped JSON, the same ones the desktop
/// app uses in crates/hk-core/src/ytmusic.rs.
enum JSONTree {
    static let separator = "\u{2022}"

    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    /// every value stored under `key`, anywhere in the tree (not inside a match)
    static func collect(_ value: Any, key: String) -> [Any] {
        var out: [Any] = []
        collect(value, key: key, into: &out)
        return out
    }

    private static func collect(_ value: Any, key: String, into out: inout [Any]) {
        if let dict = value as? [String: Any] {
            for (k, child) in dict {
                if k == key { out.append(child) } else { collect(child, key: key, into: &out) }
            }
        } else if let array = value as? [Any] {
            for child in array { collect(child, key: key, into: &out) }
        }
    }

    static func firstString(_ value: Any, key: String) -> String? {
        collect(value, key: key).lazy.compactMap { $0 as? String }.first
    }

    /// "/a/b/0/c" into a nested value
    static func pointer(_ value: Any?, _ path: String) -> Any? {
        var current = value
        for part in path.split(separator: "/") {
            if let dict = current as? [String: Any] {
                current = dict[String(part)]
            } else if let array = current as? [Any], let i = Int(part), array.indices.contains(i) {
                current = array[i]
            } else {
                return nil
            }
        }
        return current
    }

    static func string(_ value: Any?, _ path: String) -> String? {
        pointer(value, path) as? String
    }

    /// the texts of a `{ "runs": [ { "text": ... } ] }` object
    static func runs(_ value: Any?) -> [String] {
        guard let runs = (value as? [String: Any])?["runs"] as? [Any] else { return [] }
        return runs.compactMap { ($0 as? [String: Any])?["text"] as? String }
    }

    static func text(_ value: Any?) -> String {
        if let simple = (value as? [String: Any])?["simpleText"] as? String {
            return simple.trimmingCharacters(in: .whitespaces)
        }
        return runs(value).joined().trimmingCharacters(in: .whitespaces)
    }

    /// "Artist A & Artist B • Album • 3:22" split at the dots
    static func groups(_ parts: [String]) -> [String] {
        var out = [""]
        for part in parts {
            if part.trimmingCharacters(in: .whitespaces) == separator {
                out.append("")
            } else {
                out[out.count - 1] += part
            }
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "3:22" or "1:02:03" in seconds
    static func parseDuration(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let n = UInt32(p) else { return nil }
            total = total * 60 + Double(n)
        }
        return total
    }

    static func isYear(_ text: String) -> Bool {
        text.count == 4 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// thumbnails come at 60-120 px; the same googleusercontent url serves any size
    static func bigThumbnail(_ value: Any?) -> String? {
        guard let value else { return nil }
        let lists = collect(value, key: "thumbnails").compactMap { $0 as? [Any] }
        var found: String?
        outer: for list in lists {
            for item in list.reversed() {
                if let url = (item as? [String: Any])?["url"] as? String {
                    found = url
                    break outer
                }
            }
        }
        guard var url = found else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        if url.contains("googleusercontent.com"), let cut = url.lastIndex(of: "=") {
            return String(url[..<cut]) + "=w544-h544-l90-rj"
        }
        return url
    }
}
