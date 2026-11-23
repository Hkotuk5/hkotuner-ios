import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An ImageIO source keeps animated images compressed, decoding one display-sized frame at a time.
struct MotionImage: UIViewRepresentable {
    let data: Data
    var plays = true

    func makeUIView(context: Context) -> FrameView { FrameView() }
    func updateUIView(_ view: FrameView, context: Context) {
        view.load(data)
        view.setPlaying(plays)
    }

    static func dismantleUIView(_ view: FrameView, coordinator: ()) { view.setPlaying(false) }

    final class FrameView: UIView {
        private let picture = UIImageView()
        private var data: Data?
        private var source: CGImageSource?
        private var frame = 0
        private var nextFrame = 0.0
        private var timer: CADisplayLink?
        private var plays = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            picture.contentMode = .scaleAspectFill
            clipsToBounds = true
            addSubview(picture)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            picture.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateTimer()
        }

        func load(_ bytes: Data) {
            guard data != bytes else { return }
            data = bytes
            source = CGImageSourceCreateWithData(bytes as CFData, nil)
            frame = 0
            nextFrame = 0
            draw()
            updateTimer()
        }

        func setPlaying(_ value: Bool) {
            guard plays != value else { return }
            plays = value
            updateTimer()
        }

        private func updateTimer() {
            timer?.invalidate()
            timer = nil
            guard window != nil, plays, let source, CGImageSourceGetCount(source) > 1,
                  !UIAccessibility.isReduceMotionEnabled else { return }
            let link = CADisplayLink(target: self, selector: #selector(advance(_:)))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            timer = link
        }

        @objc private func advance(_ link: CADisplayLink) {
            guard let source, link.timestamp >= nextFrame else { return }
            if nextFrame != 0 {
                frame = (frame + 1) % CGImageSourceGetCount(source)
                draw()
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            nextFrame = link.timestamp + max(0.033, delay)
        }

        private func draw() {
            guard let source else { picture.image = nil; return }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCache: false
            ] as [CFString: Any]
            picture.image = CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary)
                .map { UIImage(cgImage: $0) }
        }
    }
}

struct WallpaperCrop: Codable {
    var zoom = 1.0
    var x = 0.0
    var y = 0.0
    var blur = 0.0
    var dim = 0.6
}

@MainActor
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()
    @Published private(set) var image: Data?
    private(set) var aspect = 1.0
    @Published private(set) var looks: [Look] = []

    struct Look: Codable, Identifiable {
        let id: UUID
        let name: String
        let backdrop: Bool
        let crop: WallpaperCrop
        let appearance: String
        let accent: String
        let accentHex: String
    }
    @Published var crop = WallpaperCrop() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(crop), forKey: "wallpaper.crop") }
    }

    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wallpaper")
    private var looksFile: URL { file.deletingLastPathComponent().appendingPathComponent("wallpaper-looks.json") }

    private init() {
        image = try? Data(contentsOf: file)
        if let image { aspect = Self.imageAspect(image) }
        if let data = try? Data(contentsOf: looksFile),
           let saved = try? JSONDecoder().decode([Look].self, from: data) {
            looks = saved
        }
        if let raw = UserDefaults.standard.data(forKey: "wallpaper.crop"),
           let saved = try? JSONDecoder().decode(WallpaperCrop.self, from: raw) {
            crop = saved
        }
    }

    func importImage(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let maxSize = 24 * 1024 * 1024
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxSize else {
            throw HKError("Выбери изображение до 24 МБ")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maxSize,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let kind = CGImageSourceGetType(source), UTType(kind as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              CGImageSourceGetCount(source) > 0 else {
            throw HKError("Выбери GIF или изображение размером до 4096 × 4096")
        }
        try createFolder()
        try bytes.write(to: file, options: .atomic)
        aspect = Self.imageAspect(bytes)
        image = bytes
        crop = WallpaperCrop()
    }

    func remove() throws {
        try FileManager.default.removeItem(at: file)
        image = nil
        aspect = 1
    }

    func saveLook(name: String, appearance: String, accent: String, accentHex: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, looks.count < 12 else { return }
        let look = Look(id: UUID(), name: String(name.prefix(40)), backdrop: image != nil, crop: crop,
                        appearance: appearance, accent: accent, accentHex: accentHex)
        try createFolder()
        if let image { try image.write(to: lookFile(look), options: .atomic) }
        do { try saveLooks(looks + [look]) }
        catch { try? FileManager.default.removeItem(at: lookFile(look)); throw error }
    }

    func apply(_ look: Look) throws {
        if look.backdrop {
            let data = try Data(contentsOf: lookFile(look))
            try data.write(to: file, options: .atomic)
            aspect = Self.imageAspect(data)
            image = data
        } else if image != nil {
            try remove()
        }
        crop = look.crop
    }

    func delete(_ look: Look) throws {
        try saveLooks(looks.filter { $0.id != look.id })
        if look.backdrop { try? FileManager.default.removeItem(at: lookFile(look)) }
    }

    private func lookFile(_ look: Look) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("wallpaper-\(look.id.uuidString)")
    }

    private func saveLooks(_ list: [Look]) throws {
        try JSONEncoder().encode(list).write(to: looksFile, options: .atomic)
        looks = list
    }

    private func createFolder() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func imageAspect(_ data: Data) -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 else { return 1 }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? height / width : width / height
    }
}

struct WallpaperImage: View {
    let bytes: Data
    let aspect: Double
    let crop: WallpaperCrop
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let aspect = CGFloat(self.aspect)
            let margin = CGFloat(crop.blur) * 2
            let width = max(size.width, size.height * aspect) * CGFloat(crop.zoom)
            let height = width / aspect
            MotionImage(data: bytes, plays: visible)
                .frame(width: width + margin * 2, height: height + margin * 2)
                .blur(radius: crop.blur)
                .position(x: (size.width + (width - size.width) * CGFloat(crop.x)) / 2,
                          y: (size.height + (height - size.height) * CGFloat(crop.y)) / 2)
                .overlay(.black.opacity(crop.dim))
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

struct WallpaperSettingsView: View {
    @ObservedObject private var wallpaper = WallpaperStore.shared
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        List {
            if let bytes = wallpaper.image {
                WallpaperImage(bytes: bytes, aspect: wallpaper.aspect, crop: wallpaper.crop)
                    .frame(width: 133, height: 265)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity)
            }
            Button { choosing = true } label: { Label("Выбрать GIF или фото…", systemImage: "photo") }
            if wallpaper.image != nil {
                Section("Кадрирование") {
                    slider("Масштаб", value: $wallpaper.crop.zoom, range: 1...4)
                    slider("По горизонтали", value: $wallpaper.crop.x, range: -1...1)
                    slider("По вертикали", value: $wallpaper.crop.y, range: -1...1)
                }
                Section("Фон") {
                    slider("Размытие", value: $wallpaper.crop.blur, range: 0...40)
                    slider("Затемнение", value: $wallpaper.crop.dim, range: 0...0.9)
                    Button("Убрать фон", role: .destructive) {
                        do { try wallpaper.remove() } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Свой фон")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            do {
                try wallpaper.importImage(result.get())
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
