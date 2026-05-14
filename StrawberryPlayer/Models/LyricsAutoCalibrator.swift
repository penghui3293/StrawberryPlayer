import AVFoundation
import Accelerate

class LyricsAutoCalibrator: ObservableObject {
    static let shared = LyricsAutoCalibrator()
    
    private let energyThreshold: Float = 0.008
    private let detectionDuration: TimeInterval = 5.0
    private let minPeaksCount = 3
    
    // MARK: - 公开接口
    func autoCalibrate(audioURL: URL,
                       firstWordStartTime: TimeInterval,
                       completion: @escaping (TimeInterval) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 检查文件是否存在
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                debugLog("❌ 自动校准失败：文件不存在 \(audioURL.path)")
                DispatchQueue.main.async { completion(0) }
                return
            }
            
            // 获取文件属性
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
                  let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
                debugLog("❌ 自动校准失败：文件大小为 0 或无法读取")
                DispatchQueue.main.async { completion(0) }
                return
            }
            debugLog("📁 校准文件大小: \(fileSize) 字节")
            
            // 直接使用 AVAssetReader 检测
            let actualVoiceStart = self.detectFirstVoiceTimeWithAssetReader(audioURL)
            
            DispatchQueue.main.async {
                if let actualStart = actualVoiceStart {
                    let offset = actualStart - firstWordStartTime
                    debugLog("🎯 自动校准结果: 实际人声开始 = \(actualStart)s, Whisper 时间戳 = \(firstWordStartTime)s, 偏移量 = \(offset)s")
                    completion(offset)
                } else {
                    debugLog("⚠️ 自动校准失败，无法检测到人声开始位置")
                    completion(0)
                }
            }
        }
    }
    
    // MARK: - 人声检测（仅使用 AVAssetReader，兼容性最好）
    private func detectFirstVoiceTimeWithAssetReader(_ audioURL: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: audioURL)
        let semaphore = DispatchSemaphore(value: 0)
        var audioTrack: AVAssetTrack?
        
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            if status == .loaded {
                audioTrack = asset.tracks(withMediaType: .audio).first
            } else {
                debugLog("❌ 加载音频轨道失败: \(error?.localizedDescription ?? "未知错误")")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3.0)
        
        guard let track = audioTrack else {
            debugLog("❌ 无法获取音频轨道")
            return nil
        }
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            debugLog("❌ 无法创建 AVAssetReader")
            return nil
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()
        
        var energyPeaks: [(time: TimeInterval, energy: Float)] = []
        
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { continue }
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let bufferLength = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: bufferLength)
                _ = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: bufferLength, destination: bytes.baseAddress!)
                }
                let samples = data.withUnsafeBytes { ptr in
                    Array(UnsafeBufferPointer<Int16>(start: ptr.bindMemory(to: Int16.self).baseAddress, count: bufferLength / 2))
                }
                let avgEnergy = calculateEnergy(samples: samples)
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let currentTime = CMTimeGetSeconds(presentationTime)
                if avgEnergy > energyThreshold {
                    energyPeaks.append((currentTime, avgEnergy))
                }
                if currentTime >= detectionDuration {
                    break
                }
            }
        }
        
        reader.cancelReading()
        
        if energyPeaks.count >= minPeaksCount {
            let firstPeaks = Array(energyPeaks.prefix(minPeaksCount))
            let avgTime = firstPeaks.reduce(0) { $0 + $1.time } / Double(firstPeaks.count)
            let voiceStart = max(0, avgTime - 0.3)
            debugLog("✅ AVAssetReader 检测到人声开始: \(voiceStart) 秒")
            return voiceStart
        }
        return nil
    }
    
    // MARK: - 能量计算辅助方法
    private func calculateEnergy(samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let floatSample = Float(sample) / 32768.0
            sum += floatSample * floatSample
        }
        return sqrt(sum / Float(samples.count))
    }
    
    // MARK: - 可选：MP3 转 WAV（保留以备不时之需，但当前未使用）
    private func convertMP3ToWAV(mp3URL: URL) -> URL? {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        do {
            let sourceFile = try AVAudioFile(forReading: mp3URL)
            let format = sourceFile.processingFormat
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: format.channelCount,
                                             interleaved: false) ?? format
            
            let destinationFile = try AVAudioFile(forWriting: wavURL,
                                                  settings: outputFormat.settings,
                                                  commonFormat: outputFormat.commonFormat,
                                                  interleaved: outputFormat.isInterleaved)
            
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat,
                                          frameCapacity: 4096)
            while true {
                try sourceFile.read(into: buffer!)
                guard buffer!.frameLength > 0 else { break }
                try destinationFile.write(from: buffer!)
            }
            debugLog("✅ MP3 转 WAV 成功: \(wavURL.lastPathComponent)")
            return wavURL
        } catch {
            debugLog("❌ MP3 转 WAV 失败: \(error)")
            return nil
        }
    }
}
