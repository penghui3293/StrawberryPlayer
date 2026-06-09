import UIKit
import SwiftUI
import Combine

class MiniPlayerUIKitView: UIView {
    private let playbackService: PlaybackService
    private let lyricsService: LyricsService
    private let userService: UserService
    
    private var coverImageView: UIImageView!
    private var playPauseImageView: UIImageView!
    private var closeButton: UIButton!
    private var rotationTimer: Timer?
    private var currentSong: Song?
    
    init(playbackService: PlaybackService, lyricsService: LyricsService, userService: UserService) {
        self.playbackService = playbackService
        self.lyricsService = lyricsService
        self.userService = userService
        super.init(frame: .zero)
        setupUI()
        setupObservers()
        updateCoverAndRotation()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupUI() {
        backgroundColor = .clear
        
        // 背景胶囊
        let backgroundView = UIView()
        backgroundView.backgroundColor = UIColor(white: 0.2, alpha: 0.9)
        backgroundView.layer.cornerRadius = 35
        backgroundView.clipsToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        // 封面图片
        coverImageView = UIImageView()
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.layer.cornerRadius = 28
        coverImageView.clipsToBounds = true
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(coverImageView)
        NSLayoutConstraint.activate([
            coverImageView.widthAnchor.constraint(equalToConstant: 56),
            coverImageView.heightAnchor.constraint(equalToConstant: 56),
            coverImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        ])
        
        // 播放/暂停指示图标
        playPauseImageView = UIImageView()
        playPauseImageView.contentMode = .center
        playPauseImageView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        playPauseImageView.layer.cornerRadius = 14
        playPauseImageView.clipsToBounds = true
        playPauseImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.addSubview(playPauseImageView)
        NSLayoutConstraint.activate([
            playPauseImageView.centerXAnchor.constraint(equalTo: coverImageView.centerXAnchor),
            playPauseImageView.centerYAnchor.constraint(equalTo: coverImageView.centerYAnchor),
            playPauseImageView.widthAnchor.constraint(equalToConstant: 28),
            playPauseImageView.heightAnchor.constraint(equalToConstant: 28)
        ])
        
        // 关闭按钮
        closeButton = UIButton(type: .custom)
        let closeImage = UIImage(systemName: "xmark")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        closeButton.setImage(closeImage, for: .normal)
        closeButton.tintColor = .gray
        closeButton.backgroundColor = .white
        closeButton.layer.cornerRadius = 20
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        
        // 添加手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    }
    
    private func setupObservers() {
        playbackService.$currentSong.sink { [weak self] song in
            self?.currentSong = song
            self?.updateCoverAndRotation()
        }.store(in: &cancellables)
        playbackService.$isPlaying.sink { [weak self] isPlaying in
            self?.updatePlayPauseIcon(isPlaying)
            if isPlaying { self?.startRotation() } else { self?.stopRotation() }
        }.store(in: &cancellables)
    }
    
    private func updateCoverAndRotation() {
        guard let song = playbackService.currentSong, let coverURL = song.coverURL else { return }
        URLSession.shared.dataTask(with: coverURL) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.coverImageView.image = image
            }
        }.resume()
        if playbackService.isPlaying { startRotation() } else { stopRotation() }
    }
    
    private func updatePlayPauseIcon(_ isPlaying: Bool) {
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        let image = UIImage(systemName: iconName)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        playPauseImageView.image = image
        playPauseImageView.tintColor = .white
    }
    
    private func startRotation() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.coverImageView.transform = self?.coverImageView.transform.rotated(by: .pi / 180) ?? .identity
        }
    }
    
    private func stopRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
    
    @objc private func handleTap() {
        playbackService.setPlayerUIMode(.full)
    }
    
    @objc private func closeTapped() {
        playbackService.setPlayerUIMode(.hidden)
        playbackService.stop()
    }
    
    private var cancellables = Set<AnyCancellable>()
}
