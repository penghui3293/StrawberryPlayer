
//
//  LyricsParser.swift
//  Player
//  负责解析 LRC 文本并返回按时间排序的歌词行数组
//  Created by penghui zhang on 2026/2/15.
//

import Foundation

class LyricsParser {
    /// 从文件 URL 解析歌词，返回可选数组（解析失败或无歌词时返回 nil）
    static func parse(url: URL) -> [LyricLine]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(content: content)
    }

    /// 从字符串解析歌词，返回可选数组（解析失败或无歌词时返回 nil）
    static func parse(content: String) -> [LyricLine]? {
        var lyrics: [LyricLine] = []
        let lines = content.components(separatedBy: .newlines)
        // 支持毫秒为2位或3位
        let regex = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})\\.(\\d{2,3})\\]")

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            guard let match = regex?.firstMatch(in: trimmedLine, range: NSRange(trimmedLine.startIndex..., in: trimmedLine)) else { continue }

            // 提取分钟、秒、毫秒
            guard let minuteRange = Range(match.range(at: 1), in: trimmedLine),
                  let secondRange = Range(match.range(at: 2), in: trimmedLine),
                  let millisecondRange = Range(match.range(at: 3), in: trimmedLine) else { continue }

            let minutes = Int(trimmedLine[minuteRange]) ?? 0
            let seconds = Int(trimmedLine[secondRange]) ?? 0
            let millisecondsStr = String(trimmedLine[millisecondRange])
            let milliseconds = Int(millisecondsStr) ?? 0

            // 计算时间：毫秒部分根据位数决定除以100还是1000
            let time: TimeInterval
            if millisecondsStr.count == 3 {
                time = TimeInterval(minutes * 60 + seconds) + TimeInterval(milliseconds) / 1000.0
            } else {
                time = TimeInterval(minutes * 60 + seconds) + TimeInterval(milliseconds) / 100.0
            }

            // 获取整个匹配范围（时间标签部分）
            let fullMatchRange = Range(match.range(at: 0), in: trimmedLine)!
            var text = trimmedLine
            text.removeSubrange(fullMatchRange)
            text = text.trimmingCharacters(in: .whitespaces)

            if !text.isEmpty {
                // 修正：创建 LyricLine 时必须提供所有存储属性
                lyrics.append(LyricLine(startTime: time, endTime: nil, text: text, words: []))
            }
        }

        // 如果没有任何有效歌词行，返回 nil；否则返回排序后的数组
        if lyrics.isEmpty {
            return nil
        }
        // 修正：处理可选值的比较，将 nil 视为无穷大
        return lyrics.sorted { ($0.startTime ?? .infinity) < ($1.startTime ?? .infinity) }
    }
    
    static func parseWordLyrics(content syncedLyrics: String, songDuration: TimeInterval = 0) -> [[WordLyrics]] {
        // 此方法未报错，暂不修改，但内部若有类似问题请按相同思路处理
        let lines = syncedLyrics.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let timestampPattern = "\\[(\\d{2}):(\\d{2})(?:\\.(\\d{2,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else {
            return []
        }

        var entries: [(startTime: TimeInterval, text: String)] = []

        for (lineIndex, line) in lines.enumerated() {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
            guard let match = matches.first else {
                continue
            }

            let minuteRange = match.range(at: 1)
            let secondRange = match.range(at: 2)
            let millisecondRange = match.range(at: 3)

            let minutes = Double(nsLine.substring(with: minuteRange)) ?? 0
            let seconds = Double(nsLine.substring(with: secondRange)) ?? 0
            var milliseconds: Double = 0
            if millisecondRange.location != NSNotFound {
                let msStr = nsLine.substring(with: millisecondRange)
                if msStr.count == 2 {
                    milliseconds = Double(msStr)! / 100
                } else {
                    milliseconds = Double(msStr)! / 1000
                }
            }
            let startTime = minutes * 60 + seconds + milliseconds

            let text = nsLine.replacingOccurrences(of: regex.pattern, with: "", options: .regularExpression, range: NSRange(location: 0, length: nsLine.length))
                .trimmingCharacters(in: .whitespaces)

            if !text.isEmpty {
                entries.append((startTime, text))
            }
        }

        entries.sort { $0.startTime < $1.startTime }

        var result = [[WordLyrics]]()
        for i in 0..<entries.count {
            let entry = entries[i]
            let startTime = entry.startTime

            let endTime: TimeInterval
            if i < entries.count - 1 {
                endTime = entries[i+1].startTime
            } else {
                endTime = (songDuration > startTime) ? songDuration : (startTime + 3.0)
            }
            let duration = endTime - startTime

            guard duration > 0 else {
                continue
            }

            let characters = Array(entry.text).map { String($0) }
            let charDuration = duration / Double(characters.count)

            let lineWords = characters.enumerated().map { index, char in
                WordLyrics(word: char, startTime: startTime + Double(index) * charDuration,
                                   endTime: startTime + Double(index + 1) * charDuration)
            }
            result.append(lineWords)
        }

        return result
    }
}
