//import SwiftUI
//
//struct KaraokeAttributedText: View {
//    let words: [WordLyrics]
//    let progresses: [Double]
//    let fontSize: CGFloat
//    let accentColor: Color
//
//    var body: some View {
//        // 构建 AttributedString，每个单词独立着色
//        var attributedString = AttributedString()
//        for index in words.indices {
//            let word = words[index]
//            var wordAttr = AttributedString(word.word)
//            let progress = progresses[safe: index] ?? 0
//            let color: Color = progress >= 1.0 ? accentColor : .white.opacity(0.5)
//            wordAttr.foregroundColor = UIColor(color)
//            attributedString.append(wordAttr)
//        }
//        return Text(attributedString)
//            .font(.system(size: fontSize))
//            .lineSpacing(4)
//    }
//}
//
//
//
//// 确保 safe 索引扩展可用
////extension Collection {
////    subscript(safe index: Index) -> Element? {
////        return indices.contains(index) ? self[index] : nil
////    }
////}


import SwiftUI

struct KaraokeAttributedText: View {
    let words: [WordLyrics]
    let progresses: [Double]
    let fontSize: CGFloat
    let accentColor: Color

    var body: some View {
        var attributedString = AttributedString()
        for index in words.indices {
            let word = words[index]
            var wordAttr = AttributedString(word.word)
            let progress = index < progresses.count ? progresses[index] : 0
            // 根据进度决定颜色：完全高亮后为主题色，否则为半透明白色
            let color: Color = progress >= 1.0 ? accentColor : .white.opacity(0.5)
            wordAttr.foregroundColor = color
            attributedString.append(wordAttr)
        }
        return Text(attributedString)
            .font(.system(size: fontSize))
            .lineSpacing(4)
    }
}

// 可选：添加安全下标扩展，但上述代码已直接判断边界，无需此扩展
// extension Collection {
//     subscript(safe index: Index) -> Element? {
//         return indices.contains(index) ? self[index] : nil
//     }
// }
