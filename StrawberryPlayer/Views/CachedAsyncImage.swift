import SwiftUI

struct CachedAsyncImage: View {
    let url: URL?
    let placeholder: () -> AnyView
    let errorView: (Error) -> AnyView
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var error: Error?
    
    init(url: URL?,
         @ViewBuilder placeholder: @escaping () -> some View,
         @ViewBuilder error: @escaping (Error) -> some View) {
        self.url = url
        self.placeholder = { AnyView(placeholder()) }
        self.errorView = { AnyView(error($0)) }
    }
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
            } else if let error = error {
                errorView(error)
            } else {
                placeholder()
                    .onAppear {
                        loadImage()
                    }
            }
        }
    }
    
    private func loadImage() {
        guard let url = url else {
            error = NSError(domain: "CachedAsyncImage", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的URL"])
            return
        }
        
        isLoading = true
        
        // 先检查缓存
        let request = URLRequest(url: url)
        if let cachedResponse = URLCache.shared.cachedResponse(for: request),
           let uiImage = UIImage(data: cachedResponse.data) {
            self.image = uiImage
            isLoading = false
            return
        }
        
        // 下载
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    self.error = error
                    return
                }
                guard let data = data, let uiImage = UIImage(data: data) else {
                    self.error = NSError(domain: "CachedAsyncImage", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效图片数据"])
                    return
                }
                // 缓存响应
                if let response = response {
                    let cachedResponse = CachedURLResponse(response: response, data: data)
                    URLCache.shared.storeCachedResponse(cachedResponse, for: request)
                }
                self.image = uiImage
            }
        }.resume()
    }
}
