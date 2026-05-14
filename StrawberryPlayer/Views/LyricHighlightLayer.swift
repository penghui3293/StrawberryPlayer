import UIKit
import SwiftUI

//方案B (Core Animation / CALayer)：最稳妥的商业级方案
final class LyricHighlightLayer: CALayer {
    private var words: [WordLyrics] = []
    private var currentTime: TimeInterval = 0
    private var activeColor: UIColor = .white
    private var inactiveColor: UIColor = UIColor.white.withAlphaComponent(0.2)
    private var fontSize: CGFloat = 18
    private var containerWidth: CGFloat = UIScreen.main.bounds.width - 32
    
    private var inactiveImageLayer: CALayer?
    private var completedLayer: CALayer?
    private var currentLineLayer: CALayer?
    private var currentLineMask: CALayer?
    
    private var lastWordsHash: Int = 0
    private var font: UIFont = .systemFont(ofSize: 18, weight: .bold)
    private var lineHeight: CGFloat = 0
    private var totalHeight: CGFloat = 0
    private var linesInfo: [(wordIndices: Range<Int>, y: CGFloat)] = []
    private var lastCompletedLines: Int = -1 // 缓存已完成行数
    
    private static let heightCache = NSCache<NSString, NSNumber>()   // ✅ 静态类属性
    
    
    func configure(words: [WordLyrics],
                   currentTime: TimeInterval,
                   activeColor: UIColor,
                   inactiveColor: UIColor,
                   fontSize: CGFloat,
                   containerWidth: CGFloat) {
        
        // ✅ 新增：如果时间为 NaN，直接放弃本次渲染，等待下一次有效数据
        guard !currentTime.isNaN else { return }
        
        // 确保容器宽度有效
        self.containerWidth = max(containerWidth, 1)
        if self.containerWidth <= 1 {
            self.containerWidth = max(UIScreen.main.bounds.width - 32, 1)
        }
        self.currentTime = currentTime
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.fontSize = fontSize
        self.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        
        let newHash = words.map(\.id).hashValue
        if newHash != lastWordsHash || inactiveImageLayer == nil {
            self.words = words
            lastWordsHash = newHash
            lastCompletedLines = -1
            rebuildAll()
        } else {
            self.words = words
            updateProgress()
        }
    }
    
    private func rebuildAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        inactiveImageLayer?.contents = nil
        inactiveImageLayer?.removeFromSuperlayer()
        inactiveImageLayer = nil
        completedLayer?.contents = nil
        completedLayer?.removeFromSuperlayer()
        completedLayer = nil
        currentLineLayer?.contents = nil
        currentLineLayer?.removeFromSuperlayer()
        currentLineLayer = nil
        currentLineMask?.removeFromSuperlayer()
        currentLineMask = nil
                
        linesInfo.removeAll()
        
        lineHeight = font.lineHeight * 1.05   // ✅ 更紧凑，接近原版
        let maxWidth = max(containerWidth, 1)
        
        var currentStart = 0
        var currentLineWidth: CGFloat = 0
        for i in 0..<words.count {
            let w = (words[i].word as NSString).size(withAttributes: [.font: font]).width
            if currentLineWidth + w > maxWidth, i > currentStart {
                linesInfo.append((currentStart..<i, 0))
                currentStart = i
                currentLineWidth = w
            } else {
                currentLineWidth += w
            }
        }
        if currentStart < words.count {
            linesInfo.append((currentStart..<words.count, 0))
        }
        var y: CGFloat = 0
        for i in 0..<linesInfo.count {
            linesInfo[i].y = y
            y += lineHeight
        }
        totalHeight = max(y, lineHeight)
        // 新增：防止首次渲染时 totalHeight 为 0
        totalHeight = max(totalHeight, lineHeight)
        
        let inactiveImage = renderFullImage(color: inactiveColor)
        let inactiveLayer = CALayer()
        inactiveLayer.contents = inactiveImage.cgImage
        inactiveLayer.frame = CGRect(x: 0, y: 0, width: containerWidth, height: totalHeight)
        addSublayer(inactiveLayer)
        self.inactiveImageLayer = inactiveLayer
        self.frame = inactiveLayer.frame
        
        let activeImage = renderFullImage(color: activeColor)
        
        let completed = CALayer()
        completed.contents = activeImage.cgImage
        completed.frame = inactiveLayer.frame
        // 初始透明 mask，避免首次出现全白闪烁
        let initialMask = CALayer()
        initialMask.frame = completed.bounds
        initialMask.backgroundColor = UIColor.clear.cgColor
        completed.mask = initialMask
        addSublayer(completed)
        self.completedLayer = completed
        
        let currentLine = CALayer()
        currentLine.contents = activeImage.cgImage
        currentLine.frame = inactiveLayer.frame
        let mask = CALayer()
        mask.backgroundColor = UIColor.black.cgColor
        mask.frame = .zero
        currentLine.mask = mask
        addSublayer(currentLine)
        self.currentLineLayer = currentLine
        self.currentLineMask = mask
        
        CATransaction.commit()
        
        lastCompletedLines = -1
        updateProgress()
    }
    
    private func updateProgress() {
        // 1. 在后台执行所有纯计算工作
        let localWords = words
        let localTime = currentTime
        let localFont = font
        let localLinesInfo = linesInfo
        let localLastCompleted = lastCompletedLines
        let localContainerWidth = containerWidth
        let localLineHeight = lineHeight
        let localTotalHeight = totalHeight
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            var completedLines = 0
            var scanWidth: CGFloat = 0
            var currentLineIndex = -1
            
            for (lineIdx, line) in localLinesInfo.enumerated() {
                var lineCompleted = true
                var currentScan: CGFloat = 0
                for wordIdx in line.wordIndices {
                    guard wordIdx < localWords.count else { break }
                    let word = localWords[wordIdx]
                    let w = (word.word as NSString).size(withAttributes: [.font: localFont]).width
                    if localTime >= word.endTime {
                        currentScan += w
                    } else if localTime > word.startTime {
                        let p = CGFloat(max(0, min(1, (localTime - word.startTime) / max(word.endTime - word.startTime, 0.001))))
                        currentScan += w * p
                        lineCompleted = false
                        break
                    } else {
                        lineCompleted = false
                        break
                    }
                }
                if lineCompleted {
                    completedLines += 1
                } else {
                    scanWidth = currentScan
                    currentLineIndex = lineIdx
                    break
                }
            }
            
            // 2. 回到主线程仅更新 UI
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let completedLayer = self.completedLayer,
                      let currentMask = self.currentLineMask else { return }
                
                // 更新已完成行 mask（仅在行数变化时）
                if completedLines != self.lastCompletedLines {
                    self.lastCompletedLines = completedLines
                    let completedMask = CALayer()
                    completedMask.frame = CGRect(x: 0, y: 0, width: localContainerWidth, height: localTotalHeight)
                    completedMask.backgroundColor = UIColor.clear.cgColor
                    if completedLines > 0 {
                        for i in 0..<completedLines {
                            let line = localLinesInfo[i]
                            let block = CALayer()
                            block.backgroundColor = UIColor.black.cgColor
                            block.frame = CGRect(x: 0, y: line.y, width: localContainerWidth, height: localLineHeight)
                            completedMask.addSublayer(block)
                        }
                    }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    completedLayer.mask = completedMask
                    CATransaction.commit()
                }
                
                // 更新当前行扫描宽度
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if currentLineIndex >= 0, currentLineIndex < localLinesInfo.count {
                    let line = localLinesInfo[currentLineIndex]
                    currentMask.frame = CGRect(x: 0, y: line.y, width: scanWidth, height: localLineHeight)
                } else {
                    currentMask.frame = .zero
                }
                CATransaction.commit()
            }
        }
    }
    
    
    private func renderFullImage(color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: containerWidth, height: totalHeight), format: format)
        return renderer.image { ctx in
            var x: CGFloat = 0
            var y: CGFloat = 0
            for word in words {
                let w = (word.word as NSString).size(withAttributes: [.font: font]).width
                if x + w > containerWidth, x > 0 {
                    x = 0
                    y += lineHeight
                }
                (word.word as NSString).draw(in: CGRect(x: x, y: y, width: w, height: lineHeight),
                                             withAttributes: [.font: font, .foregroundColor: color])
                x += w
            }
        }
    }
    
    /// 判断单词在当前宽度下是否只有一行
    static func isSingleLine(words: [WordLyrics], fontSize: CGFloat, containerWidth: CGFloat) -> Bool {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let maxWidth = max(containerWidth, 1)
        var x: CGFloat = 0
        for word in words {
            let w = (word.word as NSString).size(withAttributes: [.font: font]).width
            if x + w > maxWidth, x > 0 { return false }
            x += w
        }
        return true
    }
    
    // ✅ 添加静态方法 computeHeight
    static func computeHeight(words: [WordLyrics], fontSize: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let key = "\(words.map(\.id).joined())-\(fontSize)-\(containerWidth)" as NSString
        if let cached = LyricHighlightLayer.heightCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let lineHeight = font.lineHeight * 1.05
        let maxWidth = max(containerWidth, 1)
        var lines = 1
        var currentWidth: CGFloat = 0
        for (index, word) in words.enumerated() {
            let w = (word.word as NSString).size(withAttributes: [.font: font]).width
            if index == 0 {
                currentWidth = w
            } else if currentWidth + w > maxWidth {
                lines += 1
                currentWidth = w
            } else {
                currentWidth += w
            }
        }
        let height = CGFloat(lines) * lineHeight
        LyricHighlightLayer.heightCache.setObject(NSNumber(value: height), forKey: key)
        return height
    }
    
}

struct LyricHighlightLayerView: UIViewRepresentable {
    var words: [WordLyrics]
    var currentTime: TimeInterval
    var activeColor: Color
    var inactiveColor: Color
    var fontSize: CGFloat
    var containerWidth: CGFloat
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let layer = LyricHighlightLayer()
        view.layer.addSublayer(layer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let highlightLayer = uiView.layer.sublayers?.first as? LyricHighlightLayer else { return }
        
        // ✅ 再次确保不会传入 NaN，双重保险
        guard !currentTime.isNaN else { return }
        
        highlightLayer.configure(words: words,
                                 currentTime: currentTime,
                                 activeColor: UIColor(activeColor),
                                 inactiveColor: UIColor(inactiveColor),
                                 fontSize: fontSize,
                                 containerWidth: containerWidth)
    }
}
