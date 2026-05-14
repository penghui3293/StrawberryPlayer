
import Foundation
import AVFoundation

struct AudioMetadata {
    let title: String
    let artist: String
    let duration: TimeInterval
}

class AudioMetadataExtractor {
    
    static func extract(from url: URL) async throws -> AudioMetadata? {
        let asset = AVAsset(url: url)
        
        do {
            let metadata = try await asset.load(.commonMetadata)
            let duration = try await asset.load(.duration).seconds
            
            var title: String?
            var artist: String?
            
            // 提取标题，忽略空值
            if let titleItem = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierTitle
            ).first {
                let value = try await titleItem.load(.value) as? String
                if let value = value, !value.isEmpty {
                    title = value
                }
            }
            
            // 提取艺术家，忽略空值
            if let artistItem = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierArtist
            ).first {
                let value = try await artistItem.load(.value) as? String
                if let value = value, !value.isEmpty {
                    artist = value
                }
            }
            
            // 只有至少有一个有效字段时才返回 metadata
            if title != nil || artist != nil {
                return AudioMetadata(
                    title: title ?? "",
                    artist: artist ?? "未知艺术家",
                    duration: duration
                )
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }
}
