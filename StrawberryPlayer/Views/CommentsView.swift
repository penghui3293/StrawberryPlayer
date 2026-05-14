// CommentsView.swift 修改后

import SwiftUI

// MARK: - 通知名称
extension Notification.Name {
    static let repliesLoaded = Notification.Name("repliesLoaded")
}

struct ExpandedCommentIdsKey: EnvironmentKey {
    static let defaultValue: Binding<Set<String>>? = nil
}

extension EnvironmentValues {
    var expandedCommentIds: Binding<Set<String>>? {
        get { self[ExpandedCommentIdsKey.self] }
        set { self[ExpandedCommentIdsKey.self] = newValue }
    }
}

// MARK: - 带缓存的压缩头像视图
struct AsyncImageWithResizing: View {
    let url: URL
    let targetSize: CGSize
    
    // 全局缓存（避免重复下载和解码）
    internal static let cache = NSCache<NSString, UIImage>()
    
    @State private var image: UIImage?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: targetSize.width, height: targetSize.height)
                    .clipShape(Circle())
            } else if isLoading {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: targetSize.width, height: targetSize.height)
                    .foregroundColor(.gray)
                    .onAppear(perform: loadImage)
                
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: targetSize.width, height: targetSize.height)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private func loadImage() {
        let cacheKey = "\(url.absoluteString)_\(targetSize.width)x\(targetSize.height)" as NSString
        if let cachedImage = Self.cache.object(forKey: cacheKey) {
            DispatchQueue.main.async {
                self.image = cachedImage
                self.isLoading = false
            }
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let originalImage = UIImage(data: data) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                return
            }
            let resizedImage = originalImage.resized(to: targetSize)
            Self.cache.setObject(resizedImage, forKey: cacheKey)
            DispatchQueue.main.async {
                self.image = resizedImage
                self.isLoading = false
            }
        }.resume()
    }
}

extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - CommentsView
struct CommentsView: View {
    let song: Song
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var userService: UserService
    @Environment(\.dismiss) var dismiss
    
    @State private var comments: [Comment] = []
    @State private var newCommentText = ""
    @State private var replyingTo: Comment? = nil
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showLoginSheet = false
    @State private var loadingReplyIds = Set<String>()
    @State private var expandedCommentIds = Set<String>()   // 存储已展开的评论 ID
    
    // 构建树形结构
    private var commentTree: [CommentNode] {
        // 构建评论 ID 到 Comment 的映射
        var dict = [String: Comment]()
        for comment in comments {
            dict[comment.id] = comment
        }
        
        // 构建父子关系映射：父ID -> 子评论列表
        var childrenMap = [String: [Comment]]()
        for comment in comments {
            if let parentId = comment.parentId {
                childrenMap[parentId, default: []].append(comment)
            }
        }
        
        // 递归构建节点
        func buildNode(comment: Comment) -> CommentNode {
            let children = childrenMap[comment.id, default: []].map { buildNode(comment: $0) }
            return CommentNode(id: comment.id, comment: comment, children: children)
        }
        
        // 返回根节点（parentId 为 nil 的评论）
        let rootComments = comments.filter { $0.parentId == nil }
        return rootComments.map { buildNode(comment: $0) }
    }
    
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // 使用 List 替代 ScrollView，实现单元格复用
                        //                List {
                        ForEach(commentTree) { node in
                            CommentRow(
                                node: node,
                                isExpanded: expandedCommentIds.contains(node.comment.id),
                                onToggleExpanded: { commentId in
                                    if expandedCommentIds.contains(commentId) {
                                        expandedCommentIds.remove(commentId)
                                    } else {
                                        expandedCommentIds.insert(commentId)
                                    }
                                },
                                onReply: { comment in
                                    replyingTo = comment
                                },
                                onLike: { comment in
                                    Task { await likeComment(comment) }
                                },
                                onLoadReplies: { comment in
                                    loadReplies(for: comment)
                                },
                                isLoadingReplies: loadingReplyIds.contains(node.comment.id)
                            )
                        }
                    }
                    .padding()
                }
                .environment(\.expandedCommentIds, $expandedCommentIds)
                
                Divider()
                
                VStack(spacing: 8) {
                    if let replyingTo = replyingTo {
                        HStack {
                            Text("回复 \(replyingTo.userName)：")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("取消") {
                                self.replyingTo = nil
                            }
                            .font(.caption)
                        }
                        .padding(.horizontal)
                    }
                    
                    HStack {
                        TextField(replyingTo == nil ? "写评论..." : "写回复...", text: $newCommentText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(!userService.isLoggedIn)
                        
                        Button(action: postComment) {
                            Text("发送").bold()
                        }
                        .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !userService.isLoggedIn)
                    }
                    .padding()
                }
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("评论")
            .navigationBarItems(trailing: Button("关闭") { dismiss() })
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定") {}
            } message: {
                Text(errorMessage)
            }
            .fullScreenCover(isPresented: $showLoginSheet) {
                LoginView()
            }
            .onAppear {
                loadComments()
            }
        }
    }
    
    // MARK: - 加载顶级评论
    private func loadComments() {
        isLoading = true
        debugLog("🔍 开始加载顶级评论，歌曲: \(song.title)")
        playbackService.fetchComments(for: song) { result in
            isLoading = false
            switch result {
            case .success(let comments):
                self.comments = comments
                debugLog("✅ 加载到 \(comments.count) 条顶级评论")
                for comment in comments {
                    debugLog("   - 评论 \(comment.id): 回复数 \(comment.replyCount)")
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
                debugLog("❌ 加载顶级评论失败: \(error)")
            }
        }
    }
    
    // MARK: - 按需加载回复
    private func loadReplies(for parent: Comment) {
        guard !loadingReplyIds.contains(parent.id) else {
            debugLog("⚠️ 评论 \(parent.id) 已在加载中，跳过")
            return
        }
        
        // 如果已经加载过子评论，直接展开
        if comments.contains(where: { $0.parentId == parent.id }) {
            debugLog("✅ 评论 \(parent.id) 已有子评论，直接展开")
            expandedCommentIds.insert(parent.id)
            return
        }
        
        debugLog("📥 开始加载评论 \(parent.id) 的回复...")
        loadingReplyIds.insert(parent.id)
        
        playbackService.fetchReplies(for: song, parentId: parent.id) { result in
            DispatchQueue.main.async {
                loadingReplyIds.remove(parent.id)
                switch result {
                case .success(let replies):
                    debugLog("✅ 加载到 \(replies.count) 条回复")
                    var updated = self.comments
                    updated.append(contentsOf: replies)
                    self.comments = updated
                    
                    // 加载成功后自动展开
                    self.expandedCommentIds.insert(parent.id)
                    debugLog("📢 自动展开评论: \(parent.id)")
                case .failure(let error):
                    debugLog("❌ 加载回复失败: \(error)")
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    // MARK: - 发表评论
    private func postComment() {
        let trimmed = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isLoading = true
        playbackService.postComment(trimmed, for: song, parentId: replyingTo?.id) { result in
            switch result {
            case .success(let comment):
                DispatchQueue.main.async {
                    var updated = self.comments
                    if comment.parentId == nil {
                        updated.insert(comment, at: 0)
                    } else {
                        updated.append(comment)
                        // 如果是回复，自动展开父评论
                        if let parentId = comment.parentId {
                            self.expandedCommentIds.insert(parentId)   // 原 expandedSet 改为 expandedCommentIds
                        }
                    }
                    self.comments = updated
                    self.newCommentText = ""
                    self.replyingTo = nil
                    self.playbackService.fetchCommentCount(for: song)
                    
                    // ✅ 关闭键盘
                    UIApplication.shared.endEditing()
                    debugLog("✅ 评论发表成功，ID: \(comment.id)")
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
                debugLog("❌ 发表评论失败: \(error)")
            }
            isLoading = false
        }
    }
    
    // MARK: - 点赞
    private func likeComment(_ comment: Comment) async {
        do {
            let newLikes = try await playbackService.likeComment(comment)
            await MainActor.run {
                let updatedComments = self.comments.map { c in
                    if c.id == comment.id {
                        var copy = c
                        copy.likesCount = newLikes
                        return copy
                    }
                    return c
                }
                self.comments = updatedComments
                debugLog("👍 点赞成功，评论ID: \(comment.id)，新点赞数: \(newLikes)")
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
                debugLog("❌ 点赞失败: \(error)")
            }
        }
    }
}

// MARK: - 单条评论视图
struct CommentRow: View {
    let node: CommentNode
    let isExpanded: Bool
    let onToggleExpanded: (String) -> Void
    let onReply: (Comment) -> Void
    let onLike: (Comment) -> Void
    let onLoadReplies: (Comment) -> Void
    let isLoadingReplies: Bool
    
    @Environment(\.expandedCommentIds) var expandedCommentIds  // 获取环境值
    
    
    var body: some View {
//        let _ = debugLog("🔍 渲染评论 \(node.comment.id), isExpanded=\(isExpanded), childrenCount=\(node.children.count)")
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：头像 + 用户名 + 置顶标识 + 点赞按钮（保持不变）
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    
                    if let avatarURL = node.comment.avatarURL,
                       let url = URL(string: avatarURL) {
                        AsyncImageWithResizing(url: url, targetSize: CGSize(width: 32, height: 32))
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(.gray)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(node.comment.userName)
                                .font(.headline)
                            if node.comment.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("置顶")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                Spacer()
                Button(action: { onLike(node.comment) }) {
                    HStack(spacing: 4) {
                        Image(systemName: node.comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text("\(node.comment.likesCount)")
                            .font(.caption)
                    }
                }
                .buttonStyle(BorderlessButtonStyle())
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            
            // 评论内容
            Text(node.comment.content)
                .font(.body)
                .padding(.leading, 40)
            
            // 第二行：时间 + 回复按钮
            HStack(spacing: 12) {
                Text(node.comment.createdAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("回复") {
                    onReply(node.comment)
                }
                .font(.caption)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .padding(.leading, 40)
            
            // 第三行：回复区域
            if !node.children.isEmpty {
                // 已有子评论
                HStack {
                    Button(action: { onToggleExpanded(node.comment.id) }) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            Text(isExpanded ? "收起回复" : "查看 \(node.children.count) 条回复")
                                .font(.caption)
                        }
                    }
                    .font(.caption)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    Spacer()
                }
                .padding(.leading, 40)
                
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(node.children) { child in
                            CommentRow(
                                node: child,
                                isExpanded: expandedCommentIds?.wrappedValue.contains(child.id) ?? false,  // ✅ 从环境读取
                                onToggleExpanded: onToggleExpanded,
                                onReply: onReply,
                                onLike: onLike,
                                onLoadReplies: onLoadReplies,
                                isLoadingReplies: isLoadingReplies
                            )
                            .padding(.leading, 20)
                        }
                    }
                    .padding(.leading, 40)
                }
            } else if node.comment.replyCount > 0 {
                // 有回复但尚未加载
                HStack {
                    if isLoadingReplies {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 20, height: 20)
                        Text("加载中...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button(action: { onLoadReplies(node.comment) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                Text("查看 \(node.comment.replyCount) 条回复")
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(.blue)
                        .font(.caption)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            debugLog("评论 \(node.comment.id) 头像 URL: \(node.comment.avatarURL ?? "nil")")
        }
    }
}


