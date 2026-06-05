//
////
////  MiniPlayerView.swift
////  最终稳定版：封面和按钮可点击，背景穿透，无日志刷屏
////
//
//import SwiftUI
//
//struct MiniPlayerView: View {
//    @EnvironmentObject var playbackService: PlaybackService
//    @EnvironmentObject var lyricsService: LyricsService
//    @EnvironmentObject var userService: UserService
//    
//    @State private var rotationAngle: Double = 0
//    @State private var rotationTimer: Timer?
//    
//    var body: some View {
//        if playbackService.isMiniPlayerVisible, !playbackService.showFullPlayer, let song = playbackService.currentSong {
//            ZStack {
//                // 背景
//                Capsule()
//                    .fill(.ultraThinMaterial)
//                    .shadow(radius: 2)
//                    .allowsHitTesting(false)
//                
//                HStack(spacing: 12) {   // 增加内部间距
//                    // 封面区域（增大点击区域）
//                    ZStack {
//                        if let coverURL = song.coverURL {
//                            AsyncImage(url: coverURL) { phase in
//                                if let image = phase.image {
//                                    image.resizable()
//                                        .aspectRatio(contentMode: .fill)
//                                } else {
//                                    Circle().fill(Color.gray.opacity(0.5))
//                                }
//                            }
//                            .frame(width: 56, height: 56)  // 增大封面尺寸
//                            .clipShape(Circle())
//                            .rotationEffect(.degrees(rotationAngle))
//                        } else {
//                            Circle().fill(Color.blue)
//                                .frame(width: 56, height: 56)
//                        }
//                        
//                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
//                            .font(.title3)
//                            .foregroundColor(.white)
//                            .shadow(radius: 2)
//                            .background(
//                                Circle()
//                                    .fill(Color.black.opacity(0.4))
//                                    .frame(width: 28, height: 28)
//                            )
//                    }
//                    .frame(width: 56, height: 56)
//                    .contentShape(Circle())
//                    .onTapGesture {
//                        print("🎵 [MiniPlayerView] 封面被点击，准备切换到全屏")
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                            print("🎵 [MiniPlayerView] 延迟后调用 setPlayerUIMode(.full)")
//                            playbackService.setPlayerUIMode(.full)
//                        }
//                    }
//                    Image(systemName: "xmark")
//                        .font(.system(size: 16, weight: .medium))
//                        .foregroundColor(.gray)
//                        .padding(8)
//                        .background(Circle().fill(Color.white))
//                        .shadow(radius: 1)
//                        .frame(width: 40, height: 40)  // 固定按钮区域
//                        .contentShape(Circle())
//                        .onTapGesture {
//                            print("❌ [MiniPlayerView] 关闭按钮被点击")
//                            playbackService.setPlayerUIMode(.hidden)
//                            playbackService.stop()
//                        }
//                }
//                .padding(8)
//            }
//            .frame(width: 130, height: 70)   // 与 MiniPlayerWindow 中的尺寸一致
//            .onAppear { if playbackService.isPlaying { startRotation() } }
//            .onDisappear { stopRotation() }
//            .onChange(of: playbackService.isPlaying) { isPlaying in
//                if isPlaying { startRotation() } else { stopRotation() }
//            }
//        }
//    }
//    
//    
//    private func startRotation() {
//        rotationTimer?.invalidate()
//        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
//            rotationAngle += 1
//            if rotationAngle >= 360 { rotationAngle -= 360 }
//        }
//    }
//    
//    private func stopRotation() {
//        rotationTimer?.invalidate()
//        rotationTimer = nil
//    }
//}


import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @EnvironmentObject var userService: UserService
    
    @State private var rotationAngle: Double = 0
    @State private var rotationTimer: Timer?
    
    var body: some View {
        if playbackService.isMiniPlayerVisible, !playbackService.showFullPlayer, let song = playbackService.currentSong {
            // ✅ 使用 Button 包裹整个内容，点击任意区域（除了关闭按钮）都切换到全屏
            Button(action: {
                print("🎵 [MiniPlayerView] 点击迷你播放器，切换到全屏")
                playbackService.setPlayerUIMode(.full)
            }) {
                HStack(spacing: 12) {
                    // 封面区域
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
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                            .rotationEffect(.degrees(rotationAngle))
                        } else {
                            Circle().fill(Color.blue)
                                .frame(width: 56, height: 56)
                        }
                        
                        // 播放/暂停指示图标
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
                    
                    Spacer()
                    
                    // ✅ 关闭按钮独立，避免触发父 Button
                    Button(action: {
                        print("❌ [MiniPlayerView] 关闭按钮被点击")
                        playbackService.setPlayerUIMode(.hidden)
                        playbackService.stop()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                            .padding(8)
                            .background(Circle().fill(Color.white))
                            .shadow(radius: 1)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(width: 40, height: 40)
                }
                .padding(8)
                .background(Capsule().fill(.ultraThinMaterial).shadow(radius: 2))
            }
            .buttonStyle(PlainButtonStyle())  // 移除默认高亮效果
            .frame(width: 130, height: 70)
            .onAppear {
                if playbackService.isPlaying { startRotation() }
            }
            .onDisappear {
                stopRotation()
            }
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
