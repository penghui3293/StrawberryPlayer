import Foundation

struct SmartMetadataParser {
    /// 从文件名中智能解析标题和艺术家
    /// - Parameter filename: 原始文件名（不带扩展名）
    /// - Returns: (标题, 艺术家) 元组，若无法识别则返回 nil
    static func parse(_ filename: String) -> (title: String, artist: String)? {
        let name = (filename as NSString).deletingPathExtension
        
        // ----- 维瓦尔第四季 -----
        if name.contains("RV 293") && name.contains("'Autumn'") {
            return ("Violin Concerto in F major, RV 293 'Autumn'", "Vivaldi")
        }
        if name.contains("RV 269") && name.contains("'Spring'") {
            return ("Violin Concerto in E major, RV 269 'Spring'", "Vivaldi")
        }
        if name.contains("RV 315") && name.contains("'Summer'") {
            return ("Violin Concerto in G minor, RV 315 'Summer'", "Vivaldi")
        }
        if name.contains("RV 297") && name.contains("'Winter'") {
            return ("Violin Concerto in F minor, RV 297 'Winter'", "Vivaldi")
        }
        
        // ----- 贝多芬交响曲 -----
        if name.contains("Symphony") && name.contains("No. 5") {
            return ("Symphony No. 5 in C minor", "Beethoven")
        }
        if name.contains("Symphony") && name.contains("No. 9") {
            return ("Symphony No. 9 in D minor 'Choral'", "Beethoven")
        }
        
        // ----- 莫扎特 -----
        if name.contains("Eine kleine Nachtmusik") {
            return ("Eine kleine Nachtmusik", "Mozart")
        }
        
        // ----- 柴可夫斯基 -----
        if name.contains("Swan Lake") {
            return ("Swan Lake", "Tchaikovsky")
        }
        if name.contains("Nutcracker") {
            return ("The Nutcracker", "Tchaikovsky")
        }
        
        // ----- 通用格式 "艺术家 - 作品名" -----
        let components = name.components(separatedBy: " - ")
        if components.count >= 2 {
            let possibleArtist = components[0].trimmingCharacters(in: .whitespaces)
            let possibleTitle = components[1].trimmingCharacters(in: .whitespaces)
            if possibleArtist.count < 50 && possibleTitle.count < 100 {
                return (possibleTitle, possibleArtist)
            }
        }
        
        return nil
    }
}
