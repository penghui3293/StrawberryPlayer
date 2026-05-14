import Foundation
import UIKit

class CoverMatcher {
    static let shared = CoverMatcher()
    
    private let cache = NSCache<NSString, UIImage>()
    private let session = URLSession.shared
    
    /// 基于风格和艺术家的简单占位图 URL（使用 picsum 随机图片）
    private func placeholderCover(style: String, artist: String) -> URL {
        let seed = abs((style + artist).hashValue)
        return URL(string: "https://picsum.photos/400/400?random=\(seed)")!
    }
    
    /// 获取封面 URL（优先网络查询，失败返回占位）
    func matchCover(for songTitle: String, artist: String, style: String, completion: @escaping (URL?) -> Void) {
        fetchCoverFromiTunes(songTitle: songTitle, artist: artist) { [weak self] url in
            guard let self = self else { return }
            if let url = url {
                completion(url)
            } else {
                completion(self.placeholderCover(style: style, artist: artist))
            }
        }
    }
    
    /// 异步获取封面图片（带缓存）
    func fetchCoverImage(for songTitle: String, artist: String, style: String) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            matchCover(for: songTitle, artist: artist, style: style) { url in
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                let key = url.absoluteString as NSString
                if let cached = self.cache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                Task {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        if let image = UIImage(data: data) {
                            self.cache.setObject(image, forKey: key)
                            continuation.resume(returning: image)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
    
    // 使用 iTunes Search API 查询专辑封面
    private func fetchCoverFromiTunes(songTitle: String, artist: String, completion: @escaping (URL?) -> Void) {
        let query = "\(artist) \(songTitle)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://itunes.apple.com/search?term=\(query)&media=music&entity=song&limit=1"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   let first = results.first,
                   let artworkUrl = first["artworkUrl100"] as? String {
                    // 替换为更高分辨率
                    let highResUrl = artworkUrl.replacingOccurrences(of: "100x100", with: "400x400")
                    if let coverURL = URL(string: highResUrl) {
                        DispatchQueue.main.async { completion(coverURL) }
                        return
                    }
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }
}
