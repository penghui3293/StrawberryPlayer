//
//  StrawberryPlayerApp.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/2/15.
//

import SwiftUI
import Darwin


@main
struct StrawberryPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var playbackService = PlaybackService()
    @StateObject private var libraryService = LibraryService()
    @StateObject private var userService = UserService()
    @StateObject private var lyricsService = LyricsService()
    @StateObject var virtualArtistService = VirtualArtistService()
    @StateObject var tabSelection = TabSelection()
    
    init() {
        
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if kerr == KERN_SUCCESS {
                let usedMB = Double(info.resident_size) / 1048576.0
                print("🟢 当前常驻内存: \(String(format: "%.1f", usedMB)) MB")
            } else {
                print("⚠️ 获取内存失败")
            }
        }
        
        // 设置全局 URLCache，容量 20MB 内存，200MB 磁盘
        let memoryCapacity = 20 * 1024 * 1024   // 20 MB
        let diskCapacity = 200 * 1024 * 1024    // 200 MB
        let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: "strawberry_cache")
        URLCache.shared = cache
        print("✅ URLCache 已设置：内存 \(memoryCapacity/1024/1024) MB，磁盘 \(diskCapacity/1024/1024) MB")
        
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabSelection)
                .environmentObject(playbackService)
                .environmentObject(libraryService)
                .environmentObject(userService)
                .environmentObject(lyricsService)
                .environmentObject(virtualArtistService)
            
            
//                .onReceive(NotificationCenter.default.publisher(for: .handleUniversalLink)) { notification in
//                    if let url = notification.object as? URL {
//                        playbackService.handleUniversalLink(url: url)
//                    }
//                }
//                .onOpenURL { url in
//                    playbackService.handleUniversalLink(url: url)
//                }
                .onOpenURL { url in
                    DeepLinkHandler.shared.handle(url: url)
                }
        }
    }
}

extension Notification.Name {
    static let handleUniversalLink = Notification.Name("handleUniversalLink")
}
