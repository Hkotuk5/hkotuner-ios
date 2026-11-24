import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AvatarCropImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: CGImage

    init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else {
            throw HKError("Выбери изображение до 20 МБ")
        }
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        guard data.count <= 20_000_000 else { throw HKError("Выбери изображение до 20 МБ") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let preview = Self.frame(source, at: 0, maxSize: 1536) else {
            throw HKError("Не удалось открыть изображение")
        }
        self.data = data
        self.preview = preview
    }

    private static func frame(_ source: CGImageSource, at index: Int, maxSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    static func export(_ data: Data, rect: CGRect) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw HKError("Не удалось открыть изображение")
        }
        let gif = (CGImageSourceGetType(source) as String?) == UTType.gif.identifier
        let type = gif ? UTType.gif : UTType.jpeg
        let count = gif ? CGImageSourceGetCount(source) : 1
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, type.identifier as CFString, count, nil) else {
            throw HKError("Не удалось подготовить аватар")
        }
        if gif {
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            let info = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let loop = info?[kCGImagePropertyGIFLoopCount] as? Int ?? 0
            CGImageDestinationSetProperties(
                destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary
            )
        }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let frame = frame(source, at: index, maxSize: 1536),
                      let output = cropFrame(frame, rect: rect) else {
                    throw HKError("Не удалось кадрировать аватар")
                }
                let options: [CFString: Any]
                if gif {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                    let info = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = info?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                        ?? info?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                    options = [kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay
                    ]]
                } else {
                    options = [kCGImageDestinationLossyCompressionQuality: 0.85]
                }
                CGImageDestinationAddImage(destination, output, options as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw HKError("Не удалось сохранить аватар") }
        let prefix = gif ? "data:image/gif;base64," : "data:image/jpeg;base64,"
        guard ((bytes.length + 2) / 3) * 4 + prefix.utf8.count <= 6 * 1024 * 1024 else {
            throw HKError("Кадрированный GIF слишком большой. Выбери изображение покороче.")
        }
        return prefix + (bytes as Data).base64EncodedString()
    }

    private static func cropFrame(_ image: CGImage, rect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let pixelRect = CGRect(x: rect.minX * width, y: rect.minY * height,
                               width: rect.width * width, height: rect.height * height)
            .integral.intersection(bounds)
        guard !pixelRect.isEmpty, let cropped = image.cropping(to: pixelRect) else { return nil }
        let side = 256
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        return context.makeImage()
    }
}

struct AvatarCropView: View {
    @Environment(\.dismiss) private var dismiss
    let image: AvatarCropImage
    let onSave: (String) throws -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @GestureState private var pinch = CGFloat(1)
    @State private var exportTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    GeometryReader { geometry in
                        cropPreview(geometry.size.width)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel("Область кадрирования аватара")
                    .accessibilityActions {
                        Button("Сдвинуть фото влево") { nudge(x: -0.1, y: 0) }
                        Button("Сдвинуть фото вправо") { nudge(x: 0.1, y: 0) }
                        Button("Сдвинуть фото вверх") { nudge(x: 0, y: -0.1) }
                        Button("Сдвинуть фото вниз") { nudge(x: 0, y: 0.1) }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Масштаб")
                        Slider(value: $zoom, in: 1...4)
                            .accessibilityLabel("Масштаб аватара")
                            .onChange(of: zoom) { offset = constrained(offset, zoom: $0) }
                    }
                    Button("Сбросить кадрирование") {
                        zoom = 1
                        offset = .zero
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(24)
                .disabled(exportTask != nil)
            }
            .navigationTitle("Кадрирование аватара")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if exportTask != nil {
                        ProgressView()
                    } else {
                        Button("Готово", action: finishCrop)
                    }
                }
            }
        }
        .onDisappear { exportTask?.cancel() }
    }

    private func cropPreview(_ width: CGFloat) -> some View {
        let side = max(1, width)
        let scale = min(4, max(1, zoom * pinch))
        let size = fittedSize(zoom: scale)
        let moved = constrained(CGSize(width: offset.width + drag.width / side,
                                       height: offset.height + drag.height / side), zoom: scale)
        return Circle()
            .fill(.black.opacity(0.25))
            .overlay {
                Image(decorative: image.preview, scale: 1)
                    .resizable()
                    .frame(width: size.width * side, height: size.height * side)
                    .offset(x: moved.width * side, y: moved.height * side)
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.65), lineWidth: 1) }
            .contentShape(Circle())
            .gesture(
                DragGesture().updating($drag) { value, change, _ in change = value.translation }
                    .onEnded { value in
                        offset = constrained(CGSize(width: offset.width + value.translation.width / side,
                                                    height: offset.height + value.translation.height / side), zoom: zoom)
                    }
            )
            .simultaneousGesture(
                MagnificationGesture().updating($pinch) { value, scale, _ in scale = value }
                    .onEnded { zoom = min(4, max(1, zoom * $0)) }
            )
    }

    private func fittedSize(zoom: CGFloat) -> CGSize {
        let width = CGFloat(image.preview.width)
        let height = CGFloat(image.preview.height)
        let side = min(width, height)
        return CGSize(width: width / side * zoom, height: height / side * zoom)
    }

    private func constrained(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let size = fittedSize(zoom: zoom)
        let x = (size.width - 1) / 2
        let y = (size.height - 1) / 2
        return CGSize(width: min(x, max(-x, offset.width)), height: min(y, max(-y, offset.height)))
    }

    private func nudge(x: CGFloat, y: CGFloat) {
        offset = constrained(CGSize(width: offset.width + x, height: offset.height + y), zoom: zoom)
    }

    private func finishCrop() {
        let size = fittedSize(zoom: zoom)
        let position = constrained(offset, zoom: zoom)
        let rect = CGRect(x: ((size.width - 1) / 2 - position.width) / size.width,
                          y: ((size.height - 1) / 2 - position.height) / size.height,
                          width: 1 / size.width, height: 1 / size.height)
        let bytes = image.data
        error = nil
        exportTask = Task {
            let work = Task.detached(priority: .userInitiated) { try AvatarCropImage.export(bytes, rect: rect) }
            do {
                let avatar = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                try Task.checkCancellation()
                try onSave(avatar)
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            exportTask = nil
        }
    }
}
