import Accelerate

class AIAudioProcessor {
    /// 使用 vDSP 实现动态范围压缩
    func process(audioBuffer: [Float]) -> [Float]? {
        var output = audioBuffer
        let count = vDSP_Length(audioBuffer.count)
        
        // 1. 计算 RMS 值（取绝对值平均）
        var absBuffer = [Float](repeating: 0, count: audioBuffer.count)
        vDSP_vabs(audioBuffer, 1, &absBuffer, 1, count)
        var mean: Float = 0
        vDSP_meanv(absBuffer, 1, &mean, count)
        
        // 2. 计算增益：如果平均幅度小于阈值则提升
        let threshold: Float = 0.2
        let targetGain: Float = 1.5
        var gain: Float = 1.0
        if mean < threshold {
            gain = targetGain
        }
        
        // 3. 应用增益
        vDSP_vsmul(audioBuffer, 1, &gain, &output, 1, count)
        
        // 4. 限制幅值防止削波
        var maxVal: Float = 1.0
        var minVal: Float = -1.0
        vDSP_vclip(output, 1, &minVal, &maxVal, &output, 1, count)
        
        return output
    }
}
