import SwiftUI
import UIKit
import ImageIO

@main
struct HkotunerApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var player = Player.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var account = YTAccount.shared
    @StateObject private var sync = DeviceSync.shared
    @AppStorage("accent") private var accent = "amber"
    @AppStorage("accent.custom") private var customAccent = "#f0a640"
    @AppStorage("accent.fromCover") private var accentFromCover = false
    @AppStorage("appearance") private var appearance = "dark"
    @State private var artworkAccent: (url: URL, hex: UInt32)?
    @Environment(\.scenePhase) private var phase

    private struct SyncActivity: Equatable {
        let phase: ScenePhase
        let username: String?
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(account)
                .preferredColorScheme(scheme)
                .tint(activeAccent)
                .accentColor(activeAccent)
                .task(id: accentFromCover ? player.current?.thumbnailURL : nil) {
                    guard accentFromCover, let url = player.current?.thumbnailURL,
                          let hex = await Theme.accentFromArtwork(url), !Task.isCancelled else { return }
                    artworkAccent = (url, hex)
                }
                .task {
                    library.autoBackupIfDue()
                    await ClientConfigStore.shared.refresh()
                    await Updates.shared.checkIfDue()
                }
                .task(id: SyncActivity(phase: phase, username: sync.onlineUsername)) {
                    guard phase == .active else { return }
                    sync.schedule()
                    if sync.onlineUsername != nil {
                        await sync.followOnlineEvents()
                        return
                    }
                    while !Task.isCancelled {
                        await sync.sync()
                        do { try await Task.sleep(nanoseconds: 25_000_000_000) }
                        catch { return }
                    }
                }
                .onReceive(library.sharedChanges) { _ in sync.onlineChanged() }
                .onReceive(StatsStore.shared.listeningChanges) { _ in sync.onlineChanged() }
                .onChange(of: phase) { now in
                    if now == .background {
                        player.saveSession()
                        StatsStore.shared.save()
                    } else if now == .active {
                        player.refreshWebPlaybackState()
                    }
                }
        }
        .backgroundTask(.appRefresh(DeviceSync.refreshID)) {
            await DeviceSync.shared.schedule()
            await DeviceSync.shared.sync()
        }
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    private var activeAccent: Color {
        if accentFromCover, let value = artworkAccent, value.url == player.current?.thumbnailURL {
            return Theme.color(value.hex)
        }
        return Theme.color(accent, custom: customAccent)
    }
}

enum Theme {
    /// the chosen accent, from the environment (`.tint` / `.accentColor` at the root)
    static var accent: Color { Color.accentColor }

    static let background = dynamic(dark: (0.047, 0.043, 0.039), light: (0.976, 0.965, 0.949))
    static let surface = dynamic(dark: (0.106, 0.100, 0.092), light: (0.925, 0.910, 0.890))
    static let ink = dynamic(dark: (0.953, 0.945, 0.933), light: (0.098, 0.090, 0.082))
    static let muted = dynamic(dark: (0.953, 0.945, 0.933), light: (0.098, 0.090, 0.082), alpha: 0.55)

    static let accents: [(id: String, name: String, color: Color)] = [
        ("amber", "Янтарь", color(0xf0a640)),
        ("red", "Красный", color(0xef4f5a)),
        ("pink", "Розовый", color(0xee6aa7)),
        ("violet", "Фиолетовый", color(0x9d7bf5)),
        ("blue", "Синий", color(0x4f8ef7)),
        ("teal", "Бирюзовый", color(0x2fbfa8)),
        ("green", "Зелёный", color(0x6cc35a)),
    ]

    static func accentID(_ id: String) -> String {
        ["coral": "red", "rose": "pink", "sky": "blue", "mint": "teal"][id] ?? id
    }

    static func color(_ id: String, custom: String) -> Color {
        if id == "custom", let rgb = UInt32(custom.dropFirst(), radix: 16) { return color(rgb) }
        return accents.first(where: { $0.id == accentID(id) })?.color ?? accents[0].color
    }

    static func hex(_ color: Color) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let rgb = [red, green, blue].map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
    }

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }

    static func accentFromArtwork(_ url: URL) async -> UInt32? {
        let bytes: Data
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            bytes = data
        } else {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            bytes = data
        }
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 24
              ] as CFDictionary)
        else { return nil }
        let width = thumbnail.width
        let height = thumbnail.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let sampled = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(thumbnail, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard sampled else { return nil }
        var buckets: [Int: (weight: Double, rgb: [Double])] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] >= 240 {
            let rgb = pixels[index..<(index + 3)].map { Double($0) / 255 }
            let high = rgb.max() ?? 0, low = rgb.min() ?? 0
            let chroma = high - low
            guard chroma > 0.19 else { continue }
            let key = rgb.reduce(0) { $0 * 4 + Int(min(3, $1 * 4)) }
            let previous = buckets[key] ?? (0, [0, 0, 0])
            let weighted = zip(previous.rgb, rgb).map { $0.0 + $0.1 * chroma }
            buckets[key] = (previous.weight + chroma, weighted)
        }
        guard let best = buckets.values.max(by: { $0.weight < $1.weight }),
              best.weight > Double(width * height) * 0.025 else { return nil }
        return best.rgb.reduce(0) { result, channel in
            (result << 8) | UInt32(((channel / best.weight * 0.74 + 0.13) * 255).rounded())
        }
    }

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double), alpha: Double = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
    }
}
