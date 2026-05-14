import SwiftUI

/// 完全基于 Canvas 的静态文本，不会产生 CTFont / CTRun / ResolvedStyledText
struct StaticLyricText: View, Equatable {
    let text: String
    let fontSize: CGFloat
    let color: Color

    static func == (lhs: StaticLyricText, rhs: StaticLyricText) -> Bool {
        lhs.text == rhs.text && lhs.fontSize == rhs.fontSize
    }

    var body: some View {
        Canvas { context, size in
            let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
            // 解析文本一次，后续不参与 diff
            let resolved = context.resolve(
                Text(text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(color)
            )
            let textSize = resolved.measure(in: CGSize(width: size.width, height: .infinity))
            context.draw(resolved, in: CGRect(origin: .zero, size: textSize))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true) // 高度自适应
    }
}
