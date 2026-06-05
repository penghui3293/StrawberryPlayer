import Foundation
import Combine

@MainActor
class AITaskManager: ObservableObject {
    static let shared = AITaskManager()
    
    @Published var pendingTasks: [AIGenerationTask] = []
    private var timer: Timer?
    private weak var userService: UserService?   // 改为 weak，避免循环引用
    private var isConfigured = false
    
    private init() {
        loadTasks()
        // 不在 init 中启动轮询，等待 configure 后再启动
    }
    
    /// 配置共享的 UserService 实例，必须在 App 启动后尽早调用
    func configure(userService: UserService) {
        self.userService = userService
        isConfigured = true
        startPolling()
    }
    
    // 在 AITaskManager 中添加
    func stopPolling() {
        timer?.invalidate()
        timer = nil
        isConfigured = false
    }
    
    func submitTask(
        originalSong: ReferenceSong,
        selectedCoverURL: URL,
        creativity: Double,
        duration: Double,
        artist: VirtualArtist,
        customLyrics: String,
        customStylePrompt: String,
        customTitle: String,
        lyricsTemperature: Double = 0.85,
        lyricsMaxTokens: Int = 4000,
        referenceAudioURL: URL? = nil,
        translatedLyrics: String? = nil,
        voiceModelIdOverride: String? = nil,
        referenceArtistLanguage: String? = nil,
        gender: String? = nil   // ✅ 新增
    ) async throws {
        print("🔍 [AITaskManager] 接收到 referenceArtistLanguage: \(referenceArtistLanguage ?? "nil")")
        guard isConfigured, let userService = userService else {
            throw APIError.unauthorized
        }
        guard let token = userService.currentToken else {
            throw APIError.unauthorized
        }
        print("🔍 [AITaskManager] 即将调用 submitGenerationTask，传递语言: \(referenceArtistLanguage ?? "nil")")
        let taskId = try await VirtualArtistService.shared.submitGenerationTask(
            originalSong: originalSong,
            selectedCoverURL: selectedCoverURL,
            creativity: creativity,
            duration: duration,
            artist: artist,
            customLyrics: customLyrics,
            customStylePrompt: customStylePrompt,
            customTitle: customTitle,
            token: token,
            lyricsTemperature: lyricsTemperature,
            lyricsMaxTokens: lyricsMaxTokens,
            referenceAudioURL: referenceAudioURL,
            translatedLyrics: translatedLyrics,
            voiceModelIdOverride: voiceModelIdOverride,
            referenceArtistLanguage: referenceArtistLanguage,
            gender: gender   // ✅ 传递
        )
        let task = AIGenerationTask(
            taskId: taskId,
            artistId: artist.id,
            songTitle: customTitle.isEmpty ? originalSong.title : customTitle,
            coverURL: selectedCoverURL,
            createdAt: Date(),
            status: "pending",
            songId: nil
        )
        pendingTasks.append(task)
        saveTasks()
    }
    
    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.pollAllTasks() }
        }
    }
    
    private func pollAllTasks() async {
        guard isConfigured, let userService = userService else { return }
        guard let token = userService.currentToken else { return }
        
        for task in pendingTasks where task.status == "pending" {
            do {
                let (status, song) = try await VirtualArtistService.shared.queryTaskStatus(taskId: task.taskId, token: token)
                if status == "completed", let song = song {
                    await MainActor.run {
                        // 发送通知（不直接添加到 LibraryService，由 ContentView 处理）
                        NotificationCenter.default.post(name: .aiSongGenerationCompleted, object: song)
                        self.removeTask(task)
                    }
                } else if status == "failed" {
                    await MainActor.run {
                        NotificationCenter.default.post(name: .aiSongGenerationFailed, object: task.taskId)
                        self.removeTask(task)
                    }
                }
            } catch {
                print("轮询任务失败: \(error)")
            }
        }
    }
    
    private func saveTasks() {
        if let data = try? JSONEncoder().encode(pendingTasks) {
            UserDefaults.standard.set(data, forKey: "AITaskManager.pendingTasks")
        }
    }
    
    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: "AITaskManager.pendingTasks"),
              let tasks = try? JSONDecoder().decode([AIGenerationTask].self, from: data) else { return }
        pendingTasks = tasks
    }
    
    private func removeTask(_ task: AIGenerationTask) {
        pendingTasks.removeAll { $0.taskId == task.taskId }
        saveTasks()
    }
}

struct AIGenerationTask: Codable {
    let taskId: String
    let artistId: String
    let songTitle: String
    let coverURL: URL?
    let createdAt: Date
    var status: String
    var songId: String?
}

extension Notification.Name {
    static let aiSongGenerationCompleted = Notification.Name("aiSongGenerationCompleted")
    static let aiSongGenerationFailed = Notification.Name("aiSongGenerationFailed")
}
