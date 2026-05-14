import AVFoundation
import Accelerate

class DynamicEQAudioUnit: AUAudioUnit {
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    private var threshold: Float = 0.1
    private var boostGain: Float = 1.5
    private var sideGain: Float = 1.5

    // 静态注册
    private static let registration: Void = {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64716e78, // 'dqnx'
            componentManufacturer: 0x53747242, // 'StrB'
            componentFlags: 0,
            componentFlagsMask: 0
        )
        AUAudioUnit.registerSubclass(DynamicEQAudioUnit.self, as: desc, name: "Dynamic EQ", version: 1)
        debugLog("✅ DynamicEQAudioUnit 注册成功")
    }()

    class func register() {
        _ = registration
    }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        debugLog("🔧 DynamicEQAudioUnit 初始化中...")
        try super.init(componentDescription: componentDescription, options: options)

        // 创建支持任意格式的输入总线（先创建占位，格式在 allocateRenderResources 中确定）
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let inputBus = try AUAudioUnitBus(format: defaultFormat)
        inputBus.maximumChannelCount = 2
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])

        let outputBus = try AUAudioUnitBus(format: defaultFormat)
        outputBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        debugLog("✅ DynamicEQAudioUnit 初始化完成")
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        // 获取输入总线的实际格式（通常由上游节点设置）
        let inputFormat = inputBusses[0].format
        // 强制输出总线使用相同格式
        try outputBusses[0].setFormat(inputFormat)
        debugLog("🎛️ 动态均衡节点输入格式: \(inputFormat)")
    }

//    override var internalRenderBlock: AUInternalRenderBlock {
//        // 捕获参数
//        let threshold = self.threshold
//        let boostGain = self.boostGain
//        let sideGain = self.sideGain
//
//        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in
//            
//            guard let pullInput = pullInputBlock else { return kAudioUnitErr_NoConnection }
//            
//
//            // 拉取输入数据
//            var inputBufferList = AudioBufferList()
//            inputBufferList.mNumberBuffers = outputData.pointee.mNumberBuffers
//            let status = pullInput(actionFlags, timestamp, frameCount, 0, &inputBufferList)
//            guard status == noErr else { return status }
//
//            let ablIn = UnsafeMutableAudioBufferListPointer(&inputBufferList)
//            let ablOut = UnsafeMutableAudioBufferListPointer(outputData)

//            // 确保声道数匹配（预期为2）
//            guard ablIn.count == 2, ablOut.count == 2 else { return kAudioUnitErr_FormatNotSupported }
//
//            let inBufL = ablIn[0]
//            let inBufR = ablIn[1]
//            let outBufL = ablOut[0]
//            let outBufR = ablOut[1]
//
//            // 确保每个声道的缓冲区大小一致且非空
//            guard inBufL.mData != nil, inBufR.mData != nil,
//                  outBufL.mData != nil, outBufR.mData != nil else {
//                return kAudioUnitErr_FormatNotSupported
//            }
//
//            let inPtrL = inBufL.mData!.assumingMemoryBound(to: Float.self)
//            let inPtrR = inBufR.mData!.assumingMemoryBound(to: Float.self)
//            let outPtrL = outBufL.mData!.assumingMemoryBound(to: Float.self)
//            let outPtrR = outBufR.mData!.assumingMemoryBound(to: Float.self)
//            let count = Int(frameCount)

            // 计算 RMS（左右声道合并）
//            var sumSqL: Float = 0
//            vDSP_svesq(inPtrL, 1, &sumSqL, vDSP_Length(count))
//            var sumSqR: Float = 0
//            vDSP_svesq(inPtrR, 1, &sumSqR, vDSP_Length(count))
//            let rms = sqrt((sumSqL + sumSqR) / Float(2 * count))
//
//            let dynamicGain: Float = (rms < threshold) ? boostGain : 1.0
//
//            for i in 0..<count {
//                let left = inPtrL[i]
//                let right = inPtrR[i]
//
//                let mid = (left + right) * 0.5
//                let side = (left - right) * 0.5
//                let sideEnhanced = side * sideGain
//                var newLeft = mid + sideEnhanced
//                var newRight = mid - sideEnhanced
//
//                newLeft *= dynamicGain
//                newRight *= dynamicGain
//
//                // 限制幅值
//                newLeft = max(-1.0, min(1.0, newLeft))
//                newRight = max(-1.0, min(1.0, newRight))
//
//                outPtrL[i] = newLeft
//                outPtrR[i] = newRight
//            }
//
//            return noErr
//        }
//    }
    
    override var internalRenderBlock: AUInternalRenderBlock {
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in
            guard let pullInput = pullInputBlock else { return kAudioUnitErr_NoConnection }

            var inputBufferList = AudioBufferList()
            inputBufferList.mNumberBuffers = outputData.pointee.mNumberBuffers
            let status = pullInput(actionFlags, timestamp, frameCount, 0, &inputBufferList)
            guard status == noErr else { return status }

            let ablIn = UnsafeMutableAudioBufferListPointer(&inputBufferList)
            let ablOut = UnsafeMutableAudioBufferListPointer(outputData)

            // 确保声道数一致
            guard ablIn.count == ablOut.count else { return kAudioUnitErr_FormatNotSupported }

            for i in 0..<ablIn.count {
                let inBuf = ablIn[i]
                let outBuf = ablOut[i]
                guard let inData = inBuf.mData, let outData = outBuf.mData else { continue }
                let byteSize = Int(inBuf.mDataByteSize)
                memcpy(outData, inData, byteSize)
            }
            return noErr
        }
    }
}
