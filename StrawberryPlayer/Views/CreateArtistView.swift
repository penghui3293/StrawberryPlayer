import SwiftUI

struct CreateArtistView: View {
    @EnvironmentObject var virtualArtistService: VirtualArtistService
    @EnvironmentObject var userService: UserService
    @Environment(\.dismiss) var dismiss
    
    // 表单字段
    @State private var selectedStyle = "粤语流行"  // 默认风格
    @State private var artistName = ""
    @State private var artistBio = ""
    @State private var avatarImage: UIImage?
    @State private var isUploading = false
    @State private var showImagePicker = false
    @State private var downloadFailed = false      // 新增：头像下载失败状态
    
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // 风格与虚拟艺人名称的映射，并配置与之匹配的头像占位图
    let styleMapping: [String: (name: String, defaultAvatarURL: URL?)] = [
        "粤语流行": (
            "南风",
            URL(string: "https://picsum.photos/id/100/200/200") // 海边风光，象征粤语的海洋文化与南风之意
        ),
        "国语流行": (
            "天韵",
            URL(string: "https://picsum.photos/id/101/200/200") // 山脉与天空，体现国语流行的辽阔与天籁之韵
        ),
        "R&B": (
            "律动",
            URL(string: "https://picsum.photos/id/104/200/200") // 城市夜景，凸显 R&B 的现代律动感
        ),
        "中国风": (
            "墨韵",
            URL(string: "https://picsum.photos/id/110/200/200") // 竹林或古树，契合中国风的水墨意境
        ),
        // ✅ 新增欧美流行风格
        "欧美流行": (
            "星尘",   // 中性名称，带有浪漫与流行感
            URL(string: "https://picsum.photos/id/42/200/200") // 现代建筑，象征欧美流行的时尚与都市气息
        )
    ]
    
    var body: some View {
        Form {
            Section(header: Text("艺人风格")) {
                Picker("选择风格", selection: $selectedStyle) {
                    ForEach(Array(styleMapping.keys), id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
                .onChange(of: selectedStyle) { newStyle in
                    if let mapping = styleMapping[newStyle] {
                        artistName = mapping.name
                        downloadFailed = false              // 重置失败状态
                        if let url = mapping.defaultAvatarURL {
                            downloadAvatar(from: url)       // 尝试下载新头像
                        }
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
            
            Section(header: Text("基本信息")) {
                TextField("艺人名称", text: $artistName)
                    .autocapitalization(.none)
                TextField("简介（可选）", text: $artistBio)
                    .autocapitalization(.none)
            }
            
            Section(header: Text("艺人形象")) {
                if let image = avatarImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                    Button("更换图片") {
                        showImagePicker = true
                    }
                } else {
                    VStack(spacing: 8) {
                        Button("上传头像") {
                            showImagePicker = true
                        }
                        if downloadFailed {
                            Button("重试下载头像") {
                                downloadFailed = false
                                if let mapping = styleMapping[selectedStyle],
                                   let url = mapping.defaultAvatarURL {
                                    downloadAvatar(from: url)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
        }
        .navigationTitle("创建虚拟艺人")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("创建") {
                    createArtist()
                }
                .disabled(artistName.isEmpty || isUploading)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $avatarImage)
        }
        .onAppear {
            // 初始化时根据默认风格设置名称并尝试下载头像
            if let mapping = styleMapping[selectedStyle] {
                artistName = mapping.name
                downloadFailed = false
                if let url = mapping.defaultAvatarURL {
                    downloadAvatar(from: url)
                }
            }
        }
        .alert("创建失败", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
    
    // 下载网络图片，失败时标记 downloadFailed
    private func downloadAvatar(from url: URL) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let data = data, error == nil, let image = UIImage(data: data) {
                    self.avatarImage = image
                    self.downloadFailed = false
                } else {
                    debugLog("头像下载失败: \(error?.localizedDescription ?? "未知错误")")
                    self.downloadFailed = true
                }
            }
        }.resume()
    }
    
    private func createArtist() {
        guard let token = userService.currentToken else { return }
        isUploading = true
        
        virtualArtistService.createArtist(
            name: artistName,
            avatarImage: avatarImage,
            bio: artistBio,
            genre: selectedStyle,
            token: token
        ) { result in
            DispatchQueue.main.async {
                isUploading = false
                switch result {
                case .success:
                    dismiss()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                    
                }
            }
        }
    }
}
