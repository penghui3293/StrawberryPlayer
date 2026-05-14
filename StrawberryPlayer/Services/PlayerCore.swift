import AVFoundation
import Combine

class PlayerCore: ObservableObject {
    // MARK: - 公共属性
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false
    
    var isReady: Bool {
        if enableEffects {
            return scheduledBuffer != nil && engine.isRunning
        } else {
            return audioPlayer != nil
        }
    }
    
    var isAtEnd: Bool {
        if enableEffects {
            guard let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
                  let buffer = scheduledBuffer else { return false }
            let sampleRate = buffer.format.sampleRate
            let totalSamples = Double(buffer.frameLength)
            return Double(playerTime.sampleTime) >= totalSamples - sampleRate * 0.1
        } else {
            guard let player = audioPlayer else { return false }
            return player.currentTime >= player.duration - 0.1
        }
    }
    
    var isEngineRunning: Bool {
        if enableEffects { return engine.isRunning }
        return audioPlayer?.isPlaying ?? false
    }
    
    // MARK: - 音效开关（修改后自动重新加载当前歌曲）
    // 3. 修改 enableEffects 的 didSet，在切换时抑制回调
    var enableEffects = false {
        didSet {
            guard !ignoreAutoReload else { return }
            guard oldValue != enableEffects, let url = currentURL else { return }
            let savedOnEnd = currentOnEnd
            suppressEndCallback = true
            stop()
            load(url: url, onEnd: savedOnEnd ?? {}) { [weak self] in
                self?.suppressEndCallback = false
            }
        }
    }
    
    // 4. 修改 setSurroundEnabled 方法
    func setSurroundEnabled(_ enabled: Bool, wasPlaying: Bool, onEnd: @escaping () -> Void) {
        shouldEnable3DSurround = enabled
        guard let url = currentURL else { return }
        
        // 1. 先清空旧回调，防止 stop 过程中触发
        onEndHandler = nil
        
        suppressEndCallback = true   // ✅ 抑制 stop 过程中所有可能的结束回调
        
        // 2. 停止并清理引擎
        stop()
        
        // 阻止 enableEffects 的 didSet 自动重载，我们手动控制
        ignoreAutoReload = true
        // 3. 切换播放模式（开启环绕则启用引擎模式；关闭则回普通播放器）
        enableEffects = enabled
        ignoreAutoReload = false
        
        
        // 4. 重新加载音频，并传入正确的结束回调
        load(url: url, onEnd: onEnd) { [weak self] in
            self?.suppressEndCallback = false   // ✅ 新音频就绪后恢复正常切歌逻辑
            if wasPlaying { self?.play() } else { self?.pause() }
        }
    }
    
    // MARK: - 私有成员
    private var audioPlayer: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?   // 防止 delegate 提前释放
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var scheduledBuffer: AVAudioPCMBuffer?
    private var displayLink: CADisplayLink?
    private var onEndHandler: (() -> Void)?
    private var currentURL: URL?
    private var currentOnEnd: (() -> Void)?
    
    // 音效节点
    private var reverbNode: AVAudioUnitReverb?
    private var eqNode: AVAudioUnitEQ?
    
    // 3D 环绕相关
    private var environmentNode: AVAudioEnvironmentNode?
    private var surroundTimer: Timer?
    
    private var shouldEnable3DSurround = false
    private var ignoreAutoReload = false
    
    
    // 远程流播（仅在本地无缓存时使用，下载后自动切回引擎/播放器）
    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var playerEndObserver: NSObjectProtocol?
    
    // 1. 添加新的私有属性
    private var suppressEndCallback = false
    private var isInterruptedBySystem = false
    private var isJustResumedFromInterruption = false
    private var isSessionActivated = false
    
    private var activationRetryCount = 0
    private let maxActivationRetries = 2
    
    
    init() {
        setupAudioSession()
        // 引擎模式基础连接
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
    }
    
    // MARK: - 音频会话
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
//            try session.setActive(true)
        } catch {
            debugLog("❌ 设置音频会话类别失败: \(error)")
        }
    }
    
   

    private func activateSessionIfNeeded() {
        guard !isSessionActivated else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            isSessionActivated = true
            activationRetryCount = 0
            debugLog("✅ 音频会话延迟激活成功")
        } catch {
            debugLog("⚠️ 音频会话激活失败: \(error)")
            if activationRetryCount < maxActivationRetries {
                activationRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.activateSessionIfNeeded()
                }
            } else {
                debugLog("❌ 已达最大重试次数，放弃激活会话")
            }
        }
    }
    
    // MARK: - 加载音频
    func load(url: URL, onEnd: @escaping () -> Void, onReady: (() -> Void)? = nil) {
        stop()
        currentURL = url
        currentOnEnd = onEnd
        onEndHandler = onEnd
        
        
        // ✅ 远程流播：HTTP/HTTPS 直接播放，不等下载
        if url.scheme == "https" || url.scheme == "http" {
            loadRemote(url: url, onEnd: onEnd, onReady: onReady)
            return
        }
        
        if enableEffects {
            loadWithEngine(url: url, onEnd: onEnd, onReady: onReady)
        } else {
            loadWithPlayer(url: url, onEnd: onEnd, onReady: onReady)
        }
        
    }
    
    private func loadRemote(url: URL, onEnd: @escaping () -> Void, onReady: (() -> Void)?) {
        let item = AVPlayerItem(url: url)
        self.avPlayerItem = item
        let player = AVPlayer(playerItem: item)
        self.avPlayer = player
        
        // 进度回调已被 CADisplayLink 接管，不再需要用 PeriodicTimeObserver
        self.onEndHandler = onEnd
        
        // 播放结束回调
        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackFinished()
        }
        
        // ✅ 延迟激活音频会话
        activateSessionIfNeeded()
        
        player.play()
        isPlaying = true
        startProgressTimer()
        DispatchQueue.main.async { onReady?() }
        
        
        // 异步获取时长（必须恢复，否则 duration 始终为 0）
        Task { [weak self] in
            guard let self = self else { return }
            if let duration = try? await item.asset.load(.duration) {
                await MainActor.run { self.duration = duration.seconds }
            }
        }
        
    }
    
    private func loadWithPlayer(url: URL, onEnd: @escaping () -> Void, onReady: (() -> Void)?) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let delegate = PlayerDelegate(onEnd: onEnd)   // ✅ 先创建
            self.playerDelegate = delegate                // ✅ 强引用防止释放
            player.delegate = delegate                    // ✅ 设置给播放器
            self.audioPlayer = player
            self.duration = player.duration
            self.onEndHandler = onEnd
            
            // ✅ 延迟激活音频会话
            activateSessionIfNeeded()
            
            DispatchQueue.main.async { onReady?() }
        } catch {
            debugLog("❌ 加载音频失败: \(error)")
            DispatchQueue.main.async { onReady?() }
        }
    }
    
    private func loadWithEngine(url: URL, onEnd: @escaping () -> Void, onReady: (() -> Void)?) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            
            // 1. 读取原始音频文件
            guard let originalBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                DispatchQueue.main.async { onReady?() }
                return
            }
            try file.read(into: originalBuffer)
            originalBuffer.frameLength = frameCount
            
            // 2. 强制转换为单声道格式 (Mono)
            guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1) else {
                print("❌ 无法创建单声道格式")
                DispatchQueue.main.async { onReady?() }
                return
            }
            guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
                DispatchQueue.main.async { onReady?() }
                return
            }
            // 3. 创建单声道转换器并执行转换
            guard let converter = AVAudioConverter(from: file.processingFormat, to: monoFormat) else {
                DispatchQueue.main.async { onReady?() }
                return
            }
            
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return originalBuffer
            }
            
            var error: NSError?
            let status = converter.convert(to: monoBuffer, error: &error, withInputFrom: inputBlock)
            guard status != .error, error == nil else {
                print("❌ 单声道转换失败: \(error?.localizedDescription ?? "未知错误")")
                DispatchQueue.main.async { onReady?() }
                return
            }
            
            // ✅ 使用转换后的实际帧长（convert 会自动更新 monoBuffer.frameLength）
            self.scheduledBuffer = monoBuffer
            self.duration = Double(monoBuffer.frameLength) / monoFormat.sampleRate
            print("🎵 已转换为单声道 (Mono) 格式，帧数: \(monoBuffer.frameLength)")
            
            
            // ------------ 根据环绕状态构建音频链 ----------
            // 1. 先断开所有输出
            engine.disconnectNodeOutput(playerNode)
            if let reverb = reverbNode { engine.disconnectNodeOutput(reverb) }
            if let env = environmentNode { engine.disconnectNodeOutput(env) }
            
            if shouldEnable3DSurround {
                // 插入环境节点：playerNode → environmentNode → mainMixer
                if environmentNode == nil {
                    let env = AVAudioEnvironmentNode()
                    engine.attach(env)
                    environmentNode = env
                }
                guard let env = environmentNode else {
                    // 理论上不会
                    DispatchQueue.main.async { onReady?() }
                    return
                }
                
                
                // ✅ 改为：环境节点输出到 mainMixer 时用 nil，让引擎自动匹配立体声
                engine.connect(playerNode, to: env, format: monoFormat)
                engine.connect(env, to: engine.mainMixerNode, format: nil)
                
                // 配置 3D 参数
                playerNode.renderingAlgorithm = .HRTFHQ
                playerNode.reverbBlend = 0.3
                playerNode.position = AVAudio3DPoint(x: 0, y: 0, z: 0)
                
                env.renderingAlgorithm = .HRTFHQ
                env.reverbBlend = 0.3
                env.distanceAttenuationParameters.maximumDistance = 10
                env.distanceAttenuationParameters.referenceDistance = 1
                env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
                
                // 启动环绕移动定时器
                startSurroundTimer()
            } else {
                // 正常链路：playerNode → (可选 reverb) → mainMixer
                if let reverb = reverbNode {
                    engine.connect(playerNode, to: reverb, format: format)
                    engine.connect(reverb, to: engine.mainMixerNode, format: format)
                } else {
                    engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                }
                
                // 恢复普通立体声设置
                playerNode.renderingAlgorithm = .stereoPassThrough
                playerNode.reverbBlend = 0
                stopSurroundTimer()
                
                
                // 在 else 分支中
                self.playerNode.sourceMode = .bypass
                self.playerNode.renderingAlgorithm = .stereoPassThrough
                self.playerNode.pointSourceInHeadMode = .bypass
                self.playerNode.position = AVAudio3DPoint(x: 0, y: 0, z: 0)
                self.playerNode.rate = 1.0
                self.playerNode.pan = 0.0
                self.playerNode.reverbBlend = 0.0
                self.playerNode.obstruction = -100.0
                self.playerNode.occlusion = -100.0
                
            }
            
            // ✅ 延迟激活音频会话
            activateSessionIfNeeded()
            
            try engine.start()
            playerNode.scheduleBuffer(monoBuffer, at: nil, options: []) { [weak self] in   // ✅ 使用单声道 buffer
                DispatchQueue.main.async {
                    self?.handlePlaybackFinished()
                }
            }
            
            DispatchQueue.main.async { onReady?() }
        } catch {
            debugLog("❌ 引擎加载失败: \(error)")
            DispatchQueue.main.async { onReady?() }
        }
    }
    
    private func startSurroundTimer() {
        stopSurroundTimer()
        // 一次性配置环境节点参数，不再每帧重复设置
        if let env = environmentNode {
            env.reverbBlend = 0.2
            env.distanceAttenuationParameters.rolloffFactor = -1
            env.distanceAttenuationParameters.referenceDistance = 100
            env.distanceAttenuationParameters.maximumDistance = 100
        }
        playerNode.renderingAlgorithm = .HRTFHQ
        playerNode.sourceMode = .pointSource
        playerNode.pointSourceInHeadMode = .bypass
        
        var angle: Float = 0
        surroundTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            angle += 0.08
            let radius: Float = 3
            let x = radius * sin(angle)
            let z = -radius * cos(angle)
            self.playerNode.position = AVAudio3DPoint(x: x, y: 0.5, z: z)
        }
    }
    
    private func stopSurroundTimer() {
        surroundTimer?.invalidate()
        surroundTimer = nil
    }
    
    // MARK: - 播放控制
    func play() {
        if let avPlayer = avPlayer {
            avPlayer.play()
            isPlaying = true
            startProgressTimer()
            return
        }
        if enableEffects { playWithEngine() } else { playWithPlayer() }
    }
    
    private func playWithPlayer() {
        guard let player = audioPlayer, !isAtEnd else { return }
        if player.play() {
            isPlaying = true
            startProgressTimer()
        }
    }
    
    private func playWithEngine() {
        guard let buffer = scheduledBuffer, !isAtEnd else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        playerNode.play()
        isPlaying = true
        startProgressTimer()
    }
    
    func pause() {
        if let avPlayer = avPlayer {
            avPlayer.pause()
            isPlaying = false
            stopProgressTimer()
            return
        }
        if enableEffects {
            playerNode.pause()
        } else {
            audioPlayer?.pause()
        }
        isPlaying = false
        stopProgressTimer()
    }
    
    func stop() {
        // 1. 清理远程流播
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let obs = playerEndObserver {
            NotificationCenter.default.removeObserver(obs)
            playerEndObserver = nil
        }
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        avPlayerItem = nil
        
        // 2. 重置中断状态
        isInterruptedBySystem = false
        pause()
        onEndHandler = nil      // ✅ 防止 stop 过程中意外触发旧回调
        // ✅ 防止 stop 触发旧的 delegate 回调（如 playNext）
        audioPlayer?.delegate = nil
        self.playerDelegate = nil
        
        // 3. 清理引擎/播放器
        if enableEffects {
            playerNode.stop()
            engine.stop()
            engine.reset()
            scheduledBuffer = nil
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        } else {
            audioPlayer?.stop()
            audioPlayer = nil
        }
        
        currentTime = 0
        duration = 0
        currentURL = nil
        currentOnEnd = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.playerDelegate = nil
        stopSurroundTimer()
        
        
        // 4. 重置音频节点参数
        self.playerNode.sourceMode = .bypass
        self.playerNode.renderingAlgorithm = .stereoPassThrough
        self.playerNode.pointSourceInHeadMode = .bypass
        self.playerNode.position = AVAudio3DPoint(x: 0, y: 0, z: 0)
        self.playerNode.rate = 1.0
        self.playerNode.pan = 0.0
        self.playerNode.reverbBlend = 0.0
        self.playerNode.obstruction = -100.0
        self.playerNode.occlusion = -100.0
        
    }
    
    
    func seek(to time: TimeInterval, completion: (() -> Void)? = nil) {
        if let avPlayer = avPlayer {
            avPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            completion?()
            return
        }
        let wasPlaying = isPlaying
        pause()
        if enableEffects {
            // 引擎模式下的 seek 暂不完整实现，此处仅重置播放位置
            guard let buffer = scheduledBuffer else { completion?(); return }
            let sampleRate = buffer.format.sampleRate
            let startFrame = AVAudioFramePosition(max(0, time * sampleRate))
            let remainingFrames = AVAudioFrameCount(Int64(buffer.frameLength) - startFrame)
            guard remainingFrames > 0 else { completion?(); return }
            // 在实际项目中，应创建子 buffer 来精确 seek，这里给出基本框架
            debugLog("⚠️ 引擎模式下 seek 功能有限，建议切回普通模式使用")
        } else {
            guard let player = audioPlayer else { completion?(); return }
            player.currentTime = min(time, player.duration)
            currentTime = player.currentTime
        }
        if wasPlaying { play() }
        completion?()
    }
    
    func resetEngine() { stop() }
    
    // MARK: - 进度
    private func startProgressTimer() {
        stopProgressTimer()
        let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.onTick))
        link.preferredFramesPerSecond = 0
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    private func stopProgressTimer() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateProgress() {
        if let avPlayer = avPlayer {
            currentTime = avPlayer.currentTime().seconds
            if currentTime >= duration - 0.05, duration > 0 {
                handlePlaybackFinished()
            }
            return
        }
        
        if enableEffects {
            guard isPlaying,
                  let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
                  let buffer = scheduledBuffer else { return }
            let sampleRate = buffer.format.sampleRate
            let newTime = Double(playerTime.sampleTime) / sampleRate
            currentTime = min(newTime, duration)
        } else {
            guard let player = audioPlayer, player.isPlaying else { return }
            let newTime = player.currentTime
            currentTime = newTime
        }
        
    }
    
    
    // MARK: - 音效设置
    func enableReverb(preset: AVAudioUnitReverbPreset?, wetDryMix: Float = 50) {
        guard enableEffects else { return }
        if let preset = preset {
            if reverbNode == nil {
                reverbNode = AVAudioUnitReverb()
                engine.attach(reverbNode!)
            }
            reverbNode?.loadFactoryPreset(preset)
            reverbNode?.wetDryMix = wetDryMix
        } else {
            if let node = reverbNode {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
                reverbNode = nil
            }
        }
        // 重新加载以应用音效链
        if let url = currentURL { load(url: url, onEnd: currentOnEnd ?? {}) }
    }
    
    // MARK: - 中断处理
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began {
            isInterruptedBySystem = true
            pause()
        } else if type == .ended {
            isInterruptedBySystem = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    isJustResumedFromInterruption = true
                    play()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.isJustResumedFromInterruption = false
                    }
                }
            }
        }
    }

    private func handlePlaybackFinished() {
        stopProgressTimer()
        isPlaying = false
        guard !isInterruptedBySystem && !isJustResumedFromInterruption else { return }
        if !suppressEndCallback {
            let handler = onEndHandler
            onEndHandler = nil
            handler?()
        }
    }
    
    
    deinit {
        stopProgressTimer()
        audioPlayer?.stop()
        playerNode.stop()
        engine.stop()
        NotificationCenter.default.removeObserver(self)
        surroundTimer?.invalidate()
    }
    
    private class WeakProxy: NSObject {
        weak var target: PlayerCore?
        init(_ target: PlayerCore) { self.target = target }
        @objc func onTick() { target?.updateProgress() }
    }
}

// MARK: - AVAudioPlayer Delegate
private class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onEnd: () -> Void
    init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onEnd()
    }
}


