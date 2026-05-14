//
//  LyricsParser.swift
//  Player
//  负责解析 LRC 文本并返回按时间排序的歌词行数组
//  Created by penghui zhang on 2026/2/15.
//

// LyricsParser.swift
import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

class LyricsParser {
    static func parse(url: URL) -> [LyricLine]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(content: content)
    }

    static func parse(content: String) -> [LyricLine] {
        var lyrics: [LyricLine] = []
        let lines = content.components(separatedBy: .newlines)
        let regex = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})\\.(\\d{2})\\]")

        for line in lines {
            guard let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }

            // 提取时间
            let nsLine = line as NSString
            let minuteRange = match.range(at: 1)
            let secondRange = match.range(at: 2)
            let millisecondRange = match.range(at: 3)

            let minutes = Int(nsLine.substring(with: minuteRange)) ?? 0
            let seconds = Int(nsLine.substring(with: secondRange)) ?? 0
            let milliseconds = Int(nsLine.substring(with: millisecondRange)) ?? 0

            let time = TimeInterval(minutes * 60 + seconds) + TimeInterval(milliseconds) / 100.0

            // 提取歌词文本：去掉时间标签
            let timeTag = nsLine.substring(with: match.range)
            let text = line.replacingOccurrences(of: timeTag, with: "").trimmingCharacters(in: .whitespaces)

            if !text.isEmpty {
                lyrics.append(LyricLine(time: time, text: text))
            }
        }

        return lyrics.sorted { $0.time < $1.time }
    }
}

