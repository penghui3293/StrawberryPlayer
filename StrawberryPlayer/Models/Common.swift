import QuartzCore

private var lastDebugLogTime: TimeInterval = 0
private let debugLogThrottle: TimeInterval = 0.5

func debugLog(_ message: String) {
    #if DEBUG
    let now = CACurrentMediaTime()
    if now - lastDebugLogTime >= debugLogThrottle {
        print(message)
        lastDebugLogTime = now
    }
    #endif
}
