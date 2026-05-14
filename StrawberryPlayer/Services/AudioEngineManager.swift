
//
//  AudioEngineManager.swift
//  StrawberryPlayer
//  该模块封装所有 AVAudioEngine 相关操作，包括节点创建、连接、启动、停止以及获取当前时间。
//  Created by penghui zhang on 2026/2/19.
//

import AVFoundation
import Accelerate

class AudioEngineManager: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    private let delay = AVAudioUnitDelay()
    
    // 保存当前使用的格式，用于配置变化时重新连接
    private var currentFileFormat: AVAudioFormat?
    
    // AI 处理器节点（始终附加但不一定连接）
    private let aiProcessor = AIAudioProcessor()
    private var aiNode: AVAudioSourceNode?
    var isAIEnhancementEnabled = false {
        didSet {
            // 当开关变化时，重新配置引擎（通过上层调用）
        }
    }
    
    // 空间音频节点（始终附加）
    private let environmentNode = AVAudioEnvironmentNode()
    var isSpatialAudioEnabled = false
    
    init() {
        setupEngine()
        registerForNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupEngine() {
        // 1. 附加所有可能用到的节点
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.attach(reverb)
        engine.attach(delay)
        engine.attach(environmentNode)  // ✅ 确保环境节点被附加
        // AI 节点
        createAINode()
        
        // 2. 初始化效果参数（保持关闭）
        timePitch.pitch = 0
        timePitch.rate = 1.0
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0
        delay.delayTime = 0.3
        delay.feedback = 30
        delay.wetDryMix = 0
        
        // 3. 配置环境节点（但暂不连接）
        environmentNode.renderingAlgorithm = .HRTFHQ
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
    }
    
    private func createAINode() {
        aiNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frameCountInt = Int(frameCount)
            for buffer in abl {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let inputArray = Array(UnsafeBufferPointer(start: ptr, count: frameCountInt))
                if let outputArray = self.aiProcessor.process(audioBuffer: inputArray) {
                    ptr.update(from: outputArray, count: frameCountInt)
                }
            }
            return noErr
        }
        if let aiNode = aiNode {
            engine.attach(aiNode)
        }
    }
    
    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }
    
    @objc private func handleConfigurationChange(notification: Notification) {
        // 当音频引擎配置变化时，根据当前保存的文件格式重新建立连接
        guard let format = currentFileFormat else { return }
        try? configureForFile(format: format)
    }
    
    /// 配置音频链路，根据开关选择路径
    func configureForFile(format: AVAudioFormat) throws {
        // 如果引擎正在运行，先停止
        if engine.isRunning {
            engine.stop()
        }
        
        // 重置引擎，清除所有连接
        engine.reset()
        
        // --- 根据开关动态构建音频链 ---
        if isSpatialAudioEnabled {
            // 空间音频模式：使用 environmentNode
            // 注意：AI 增强和空间音频暂不叠加，可根据需要设计
            engine.connect(playerNode, to: environmentNode, format: format)
            engine.connect(environmentNode, to: engine.mainMixerNode, format: format)
            
            // 将声源放置在空间中
            if let positionalPlayer = playerNode as? AVAudio3DMixing {
                positionalPlayer.position = AVAudio3DPoint(x: 0, y: 0, z: -2.0) // 前方2米
            }
        } else {
            // 普通立体声模式：直接连接 mainMixerNode
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        }
        
        // 始终将主混音器连接到输出节点
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        
        // 保存当前格式，以便配置变化时重建
        currentFileFormat = format
        engine.prepare()
    }
    
    func startEngineIfNeeded() throws {
        if !engine.isRunning {
            do {
                try engine.start()
                debugLog("✅ 引擎已启动")
            } catch {
                debugLog("❌ 引擎启动失败: \(error)，尝试重置并重新连接")
                // 尝试恢复：停止、重置、重新连接
                engine.stop()
                engine.reset()
                if let format = currentFileFormat {
                    // 重新连接（根据当前开关）
                    if isSpatialAudioEnabled {
                        engine.connect(playerNode, to: environmentNode, format: format)
                        engine.connect(environmentNode, to: engine.mainMixerNode, format: format)
                    } else {
                        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                    }
                    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
                    try engine.start()
                    debugLog("✅ 引擎恢复启动成功")
                } else {
                    throw error
                }
            }
        } else {
            debugLog("ℹ️ 引擎已在运行")
        }
    }
    
    func playNode() {
        playerNode.play()
    }
    
    func pauseNode() {
        playerNode.pause()
    }
    
    func stopNode() {
        playerNode.stop()
    }
    
    func scheduleFile(_ file: AVAudioFile, at when: AVAudioTime? = nil, completionHandler: @escaping () -> Void) {
        playerNode.scheduleFile(file, at: when, completionHandler: completionHandler)
    }
    
    func scheduleSegment(_ file: AVAudioFile, startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount, at when: AVAudioTime? = nil, completionHandler: @escaping () -> Void) {
        playerNode.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount, at: when, completionHandler: completionHandler)
    }
    
    func currentTime(for file: AVAudioFile) -> TimeInterval? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
    
    var isNodePlaying: Bool {
        playerNode.isPlaying
    }
    
    // 音效控制方法（可选）
    func setPitchShift(_ value: Float) { timePitch.pitch = value }
    func setRate(_ value: Float) { timePitch.rate = value }
    func setReverbMix(_ value: Float) { reverb.wetDryMix = value }
    func setDelayMix(_ value: Float) { delay.wetDryMix = value }
}
