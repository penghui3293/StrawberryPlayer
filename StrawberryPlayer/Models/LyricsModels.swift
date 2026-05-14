
import Foundation

/// 表示一个单词及其时间范围的结构体
struct WordLyrics: Hashable, Codable {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    
    // ✅ 预计算字段（仅理论开始时间）
    var theoreticalStart: TimeInterval = 0
    
    var duration: TimeInterval {
        endTime - startTime
    }
    
    var isWhitespace: Bool {
        return word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var effectiveDuration: TimeInterval {
        max(endTime - startTime, 0.5)
    }
    
    func progress(at currentTime: TimeInterval) -> Double {
        guard currentTime >= startTime else { return 0.0 }
        guard currentTime < endTime else { return 1.0 }
        guard duration > 0 else { return 1.0 }
        let linearProgress = (currentTime - startTime) / duration
        return min(max(linearProgress, 0.0), 1.0)
    }
    
    // MARK: - Codable 忽略预计算字段
    private enum CodingKeys: String, CodingKey {
        case word
        case startTime
        case endTime
    }
}

struct LyricLine: Hashable {
    let id = UUID()
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    let text: String
    
    var duration: TimeInterval {
        endTime ?? 0
    }
    
    var words: [WordLyrics] = []
}

extension WordLyrics: Identifiable {
    public var id: String { "\(startTime)-\(word)" }
}
