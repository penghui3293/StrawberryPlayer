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
    @State private var coverImage: UIImage? = nil   // 新增：存储下载好的封面图
    
    var body: some View {
        if playbackService.isMiniPlayerVisible, !playbackService.showFullPlayer, let song = playbackService.currentSong {
            Button(action: {
                playbackService.setPlayerUIMode(.full)
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        if let image = coverImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                                .rotationEffect(.degrees(rotationAngle))
                        } else {
                            Circle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 56, height: 56)
                                .overlay(ProgressView())
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
                    
                    Spacer()
                    
                    Button(action: {
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
            .buttonStyle(PlainButtonStyle())
            .frame(width: 130, height: 70)
            .id(song.id)   // ✅ 关键修复：强制每个歌曲独立视图
            .onAppear {
                print("🟢 [MiniPlayerView] onAppear, song: \(song.title), isPlaying: \(playbackService.isPlaying)")
                loadCoverImage(for: song)
                if playbackService.isPlaying {
                    print("🎬 [MiniPlayerView] 启动旋转")
                    startRotation()
                }
            }
            .onDisappear {
                stopRotation()
            }
            .onChange(of: playbackService.isPlaying) { isPlaying in
                if isPlaying { startRotation() } else { stopRotation() }
            }
            .onChange(of: playbackService.currentSong) { newSong in
                if let newSong = newSong {
                    loadCoverImage(for: newSong)
                }
            }
        }
    }
        
    private func loadCoverImage(for song: Song) {
        guard let coverURL = song.coverURL else {
            print("❌ [loadCoverImage] coverURL 为空")
            return
        }
        print("🌐 [loadCoverImage] 开始加载: \(coverURL)")
        if let cached = ImageCacheManager.shared.image(for: coverURL) {
            print("✅ [loadCoverImage] 缓存命中")
            self.coverImage = cached
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10          // 缩短超时
        let session = URLSession(configuration: config)
        
        var retryCount = 0
        func attemptDownload() {
            print("📡 [loadCoverImage] 下载尝试 \(retryCount+1)")
            session.dataTask(with: coverURL) { data, _, error in
                if let error = error {
                    print("❌ 下载失败: \(error)")
                    if retryCount < 2 {
                        retryCount += 1
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                            attemptDownload()
                        }
                    }
                    return
                }
                guard let data = data, let image = UIImage(data: data) else {
                    print("❌ 数据无效")
                    return
                }
                let targetSize = CGSize(width: 120, height: 120)
                let downsampled = image.preparingThumbnail(of: targetSize) ?? image
                ImageCacheManager.shared.setImage(downsampled, for: coverURL)
                DispatchQueue.main.async {
                    self.coverImage = downsampled
                    print("✅ 加载成功并缓存")
                }
            }.resume()
        }
        attemptDownload()
    }
    
    
    private func startRotation() {
        print("🌀 [startRotation] 开始旋转")
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            rotationAngle += 1
            if rotationAngle >= 360 { rotationAngle -= 360 }
        }
    }
    
    private func stopRotation() {
        print("🛑 [stopRotation] 停止旋转")
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
    
}
