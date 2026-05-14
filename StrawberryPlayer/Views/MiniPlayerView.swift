
//
//  MiniPlayerView.swift
//  最终稳定版：封面和按钮可点击，背景穿透，无日志刷屏
//

import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @EnvironmentObject var userService: UserService
    
    @State private var rotationAngle: Double = 0
    @State private var rotationTimer: Timer?
    
    var body: some View {
        if playbackService.isMiniPlayerVisible, !playbackService.showFullPlayer, let song = playbackService.currentSong {
            ZStack {
                // 背景
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
                
                HStack(spacing: 12) {   // 增加内部间距
                    // 封面区域（增大点击区域）
                    ZStack {
                        if let coverURL = song.coverURL {
                            AsyncImage(url: coverURL) { phase in
                                if let image = phase.image {
                                    image.resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Circle().fill(Color.gray.opacity(0.5))
                                }
                            }
                            .frame(width: 56, height: 56)  // 增大封面尺寸
                            .clipShape(Circle())
                            .rotationEffect(.degrees(rotationAngle))
                        } else {
                            Circle().fill(Color.blue)
                                .frame(width: 56, height: 56)
                        }
                        
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.4))
                                    .frame(width: 28, height: 28)
                            )
                    }
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                    .onTapGesture {
                        playbackService.setPlayerUIMode(.full)
                    }
                    
                    // 关闭按钮（增大点击区域）
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.gray)
                        .padding(8)
                        .background(Circle().fill(Color.white))
                        .shadow(radius: 1)
                        .frame(width: 40, height: 40)  // 固定按钮区域
                        .contentShape(Circle())
                        .onTapGesture {
                            //                            playbackService.stop()
                            playbackService.setPlayerUIMode(.hidden)
                            // 可选：如果需要停止播放，则调用 stop()
                            playbackService.stop()
                        }
                }
                .padding(8)
            }
            .frame(width: 130, height: 70)   // 与 MiniPlayerWindow 中的尺寸一致
            .onAppear { if playbackService.isPlaying { startRotation() } }
            .onDisappear { stopRotation() }
            .onChange(of: playbackService.isPlaying) { isPlaying in
                if isPlaying { startRotation() } else { stopRotation() }
            }
        }
    }
    
    
    private func startRotation() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            rotationAngle += 1
            if rotationAngle >= 360 { rotationAngle -= 360 }
        }
    }
    
    private func stopRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
}
