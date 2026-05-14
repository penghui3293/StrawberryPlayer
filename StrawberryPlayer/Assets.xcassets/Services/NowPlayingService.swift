//
//  NowPlayingService.swift
//  Player
//  控制中心 & 锁屏信息管理
//  Created by penghui zhang on 2026/2/14.
//

import MediaPlayer
import UIKit

class NowPlayingService {
    static let shared = NowPlayingService()
    private init() {}
    
    /// 设置控制中心的远程命令
    func setupRemoteCommands(for playerManager: PlayerManager) {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // 播放/暂停
        commandCenter.playCommand.addTarget { _ in
            playerManager.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { _ in
            playerManager.pause()
            return .success
        }
        
        // 上一首/下一首
        commandCenter.nextTrackCommand.addTarget { _ in
            playerManager.playNext()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { _ in
            playerManager.playPrevious()
            return .success
        }
        
        // 拖动进度条
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            playerManager.seek(to: event.positionTime)
            return .success
        }
        
        // 启用这些命令
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }
    
    /// 更新控制中心显示的信息
    func updateNowPlayingInfo(song: Song?, currentTime: TimeInterval, isPlaying: Bool) {
        guard let song = song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = song.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if let data = song.artworkData, let image = UIImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }

            /// 仅更新播放进度和时间（避免重复设置封面等数据）
            func updatePlaybackTime(currentTime: TimeInterval, isPlaying: Bool) {
                var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
                nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        }

