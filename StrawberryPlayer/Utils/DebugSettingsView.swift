//import SwiftUI
//
//struct DebugSettingsView: View {
//    @AppStorage("serverBaseURL") var serverBaseURL: String = "http://10.0.0.4:8080"
//    @Environment(\.dismiss) var dismiss
//    
//    @State private var showCleanupConfirmation = false
//
//    var body: some View {
//        Form {
//            Section(header: Text("服务器地址")) {
//                TextField("例如 http://10.0.0.4:8080", text: $serverBaseURL)
//                    .autocapitalization(.none)
//                    .disableAutocorrection(true)
//                Text("当前地址：\(serverBaseURL)")
//                    .font(.caption)
//                    .foregroundColor(.gray)
//            }
//            Section {
//                Button("保存并关闭") {
//                    dismiss()
//                }
//                .frame(maxWidth: .infinity, alignment: .center)
//            }
//        #if DEBUG
//           Section {
//               Button("🧹 清理所有测试数据 (UserDefaults, Keychain, 文件)") {
//                   showCleanupConfirmation = true
//               }
//               .foregroundColor(.red)
//               .alert("确认清理", isPresented: $showCleanupConfirmation) {
//                   Button("取消", role: .cancel) { }
//                   Button("清理", role: .destructive) {
//                       TestDataCleaner.performCleanup()
//                       // 可选：发送通知或刷新界面，但最彻底的是让用户手动重启应用
//                       // 由于数据已清空，可提示用户重启应用
//                   }
//               } message: {
//                   Text("此操作将清除所有本地数据，包括登录信息、缓存等。应用需要重启才能完全生效。")
//               }
//           }
//           #endif
//        }
//        .navigationTitle("调试设置")
//    }
//}


import SwiftUI

struct DebugSettingsView: View {
    @EnvironmentObject var userService: UserService
    @State private var showCleanupAlert = false
    @State private var cleanupMessage = ""
    
    var body: some View {
        List {
            #if DEBUG
            Section("调试工具") {
                Button("清理所有测试数据") {
                    showCleanupAlert = true
                }
                .foregroundColor(.red)
            }
            #endif
        }
        .navigationTitle("调试设置")
        .alert("清理数据", isPresented: $showCleanupAlert) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                TestDataCleaner.performCleanup()
                cleanupMessage = "数据已清理，请重启应用"
                // 可选：退出登录
                userService.logout()
            }
        } message: {
            Text("这将清除所有用户数据、缓存和钥匙串，应用将回到初始状态。确定继续吗？")
        }
        .alert("提示", isPresented: .constant(!cleanupMessage.isEmpty)) {
            Button("确定") {
                cleanupMessage = ""
            }
        } message: {
            Text(cleanupMessage)
        }
    }
}
