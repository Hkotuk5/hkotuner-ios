import SwiftUI

struct LyricSweep: View {
    let line: LyricLine
    let offset: Double
    let span: Double
    let reduceMotion: Bool

    var body: some View {
        Text(highlighted)
    }

    private var highlighted: AttributedString {
        let onsets = line.wordOnsets(span: span)
        var output = AttributedString()
        for (index, word) in line.words.enumerated() {
            if index > 0 { output.append(AttributedString(" ")) }
            let elapsed = offset - onsets[index]
            let alpha = elapsed < 0 ? 0.42 : reduceMotion ? 1 : 0.72 + 0.28 * min(1, elapsed / 0.12)
            var fragment = AttributedString(word.text)
            fragment.foregroundColor = Theme.ink.opacity(alpha)
            output.append(fragment)
        }
        return output
    }
}
