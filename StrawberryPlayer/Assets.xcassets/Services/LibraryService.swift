//
//  LibraryService.swift
//  Player
//  扫描本地文件、提取元数据
//  Created by penghui zhang on 2026/2/14.
//

import Foundation
import AVFoundation

class LibraryService {
    /// 扫描指定文件夹下的所有音频文件（递归）
    func scanSongs(in directory: URL) -> [Song] {
        var songs: [Song] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        
        for case let fileURL as URL in enumerator {
            
            // 检查文件类型
            if isAudioFile(fileURL) {
                // 寻找同名的 .lrc 文件
                let lyricsURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
                let exists = fileManager.fileExists(atPath: lyricsURL.path)
                print("🎵 音频: \(fileURL.lastPathComponent), 歌词存在: \(exists), 路径: \(lyricsURL.path)")
                let asset = AVAsset(url: fileURL)
                if let song = Song.from(asset: asset, url: fileURL,lyricsURL: exists ? lyricsURL : nil) {
                    songs.append(song)
                }
            }
        }
        return songs
    }
    
    /// 判断是否为支持的音频格式
        private func isAudioFile(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            return ext == "mp3" || ext == "wav" || ext == "m4a" || ext == "aiff" || ext == "caf"
        }
    }

