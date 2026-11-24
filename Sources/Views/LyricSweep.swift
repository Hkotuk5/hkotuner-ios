import SwiftUI
import UIKit

struct LyricSweep: View, Animatable {
    let text: String
    let fontSize: CGFloat
    let color: Color
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        LyricDrawing(text: text, font: .systemFont(ofSize: fontSize, weight: .bold),
                     color: UIColor(color), progress: progress)
    }
}

private struct LyricDrawing: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    let progress: Double

    func makeUIView(context: Context) -> DrawingView {
        let view = DrawingView()
        view.isOpaque = false
        view.contentMode = .redraw
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.layoutManager.addTextContainer(view.textContainer)
        view.storage.addLayoutManager(view.layoutManager)
        return view
    }

    func updateUIView(_ view: DrawingView, context: Context) {
        view.update(text: text, font: font, color: color, progress: progress)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DrawingView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        uiView.update(text: text, font: font, color: color, progress: progress)
        return uiView.measure(width: width)
    }

    final class DrawingView: UIView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        private var font: UIFont?
        private var color: UIColor?
        private var progress = 0.0

        func update(text: String, font: UIFont, color: UIColor, progress: Double) {
            let needsLayout = storage.string != text || self.font != font || self.color != color
            if needsLayout {
                self.font = font
                self.color = color
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .natural
                storage.setAttributedString(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(0.42),
                    .paragraphStyle: paragraph
                ]))
            }
            if needsLayout || self.progress != progress {
                self.progress = progress
                setNeedsDisplay()
            }
        }

        @discardableResult
        func measure(width: CGFloat) -> CGSize {
            textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            return CGSize(width: width, height: ceil(layoutManager.usedRect(for: textContainer).height))
        }

        override func draw(_ rect: CGRect) {
            guard bounds.width > 0, let context = UIGraphicsGetCurrentContext(), let color else { return }
            measure(width: bounds.width)
            let glyphs = layoutManager.glyphRange(for: textContainer)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            guard progress > 0, glyphs.length > 0 else { return }
            var lines: [CGRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                lines.append(used)
            }
            var remaining = lines.reduce(0) { $0 + $1.width } * CGFloat(min(1, progress))
            let path = CGMutablePath()
            for line in lines where remaining > 0 {
                var part = line
                part.size.width = min(remaining, line.width)
                path.addRect(part.insetBy(dx: 0, dy: -0.5))
                remaining -= part.width
            }
            let characters = NSRange(location: 0, length: storage.length)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: characters)
            context.saveGState()
            context.addPath(path)
            context.clip()
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            context.restoreGState()
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: characters)
        }
    }
}
