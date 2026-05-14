//  AudioConverter.swift
//  使用 AVAssetExportSession 将音频转为 FLAC（若不可用则降级为 M4A）

import AVFoundation

enum AudioConversionError: Error {
    case conversionFailed(Error?)
}

struct AudioConverter {
    /// 将任何音频文件转换为 FLAC（或降级为 M4A AAC 高质量）
    static func convertToFlac(sourceURL: URL) throws -> URL {
        let flacURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("flac")

        // 1. 如果目标 FLAC 已存在，直接返回
        if FileManager.default.fileExists(atPath: flacURL.path) {
            print("✅ FLAC 已存在，跳过转换")
            return flacURL
        }

        let asset = AVAsset(url: sourceURL)

        // 2. 先尝试导出为 FLAC（无损）
        if let passthroughSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            let flacFileType = AVFileType(rawValue: "org.xiph.flac") // 不会返回 nil，总是有效对象
            // 检查设备是否支持 FLAC 导出
            if passthroughSession.supportedFileTypes.contains(flacFileType) {
                passthroughSession.outputFileType = flacFileType
                passthroughSession.outputURL = flacURL
                var exportError: Error?
                let semaphore = DispatchSemaphore(value: 0)
                passthroughSession.exportAsynchronously {
                    if passthroughSession.status == .failed {
                        exportError = passthroughSession.error
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                if let error = exportError {
                    // FLAC 导出失败，清理可能残留的文件，然后降级
                    try? FileManager.default.removeItem(at: flacURL)
                    print("⚠️ FLAC 导出失败: \(error)，降级为 M4A")
                } else if passthroughSession.status == .completed {
                    print("✅ 无损 FLAC 转换完成")
                    return flacURL
                }
            }
        }

        // 3. 降级方案：导出为 M4A（AAC 高质量），体积远小于 WAV
        guard let m4aSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioConversionError.conversionFailed(nil)
        }
        let m4aURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("m4a")
        m4aSession.outputFileType = .m4a
        m4aSession.outputURL = m4aURL
        // 注意：AVAssetExportSession 没有 audioSettings，系统会使用预设的高质量 AAC

        let semaphore = DispatchSemaphore(value: 0)
        var exportError: Error?
        m4aSession.exportAsynchronously {
            if m4aSession.status == .failed {
                exportError = m4aSession.error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = exportError {
            throw AudioConversionError.conversionFailed(error)
        }
        print("✅ 高质量 AAC M4A 转换完成")
        return m4aURL
    }
}
