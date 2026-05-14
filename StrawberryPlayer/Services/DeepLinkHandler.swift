// DeepLinkHandler.swift
import Foundation

@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()
    @Published var pendingURL: URL?

    func handle(url: URL) {
        pendingURL = url
        // 如果 ContentView 已存在，通知它；否则 pendingURL 会被 onAppear 消费
        NotificationCenter.default.post(name: .handleIncomingURL, object: url)
    }
}
