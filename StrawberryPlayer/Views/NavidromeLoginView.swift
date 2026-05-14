//
//  NavidromeLoginView.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/3/2.
//

// NavidromeLoginView.swift
import SwiftUI

struct NavidromeLoginView: View {
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.presentationMode) var presentationMode
    
    var onSuccess: (() -> Void)?
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器信息")) {
//                    TextField("服务器地址", text: $serverURL)
//                        .keyboardType(.URL)
//                        .autocapitalization(.none)
//                        .disableAutocorrection(true)
//                        .placeholder("例如：http://192.168.1.100:4533")
                    
                    TextField("服务器地址", text: $serverURL, prompt: Text("例如：http://192.168.1.100:4533"))
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("账号信息")) {
//                    TextField("用户名", text: $username).autocapitalization(.none)
                    TextField("用户名", text: $username, prompt: Text("输入用户名")).autocapitalization(.none)
//                    SecureField("密码", text: $password)
                    SecureField("密码", text: $password, prompt: Text("输入密码"))
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button(action: login) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("登录")
                    }
                }
                .disabled(isLoading || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("连接 Navidrome")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private func login() {
        // 自动补全协议头
            var server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !server.lowercased().hasPrefix("http://") && !server.lowercased().hasPrefix("https://") {
                server = "http://" + server
            }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            let service = NavidromeService.shared
            service.saveCredentials(server: serverURL, username: username, password: password)
            
            do {
                _ = try await service.getAlbumList(limit: 1)
                DispatchQueue.main.async {
                    isLoading = false
                    presentationMode.wrappedValue.dismiss()
                    onSuccess?()
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    errorMessage = "连接失败：\(error.localizedDescription)"
                    service.clearCredentials()
                }
            }
        }
    }
}

// 占位符扩展
extension View {
    func placeholder(_ text: String, when shouldShow: Bool) -> some View {
        ZStack(alignment: .leading) {
            Text(text).foregroundColor(.gray).opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
