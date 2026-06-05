//
//  负责管理用户登录状态、持久化存储及登录/退出逻辑。
//  支持自动刷新 access token。
//

import Foundation
import Combine

enum APIError: Error, LocalizedError {
    case tokenRefreshFailed
    case unauthorized
    case unknown
    case invalidURL
    case noData
    case badRequest
    case notFound
    
    var errorDescription: String? {
        switch self {
        case .tokenRefreshFailed: return "登录已过期，请重新登录"
        case .unauthorized: return "未授权，请登录"
        default: return "未知错误"
        }
    }
}

class UserService: ObservableObject {
    @Published var isLoggedIn: Bool = false {
        didSet {
            UserDefaults.standard.set(isLoggedIn, forKey: "isLoggedInFlag")
        }
    }
    @Published var currentUser: User? {
        didSet {
            if let user = currentUser {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(user) {
                    UserDefaults.standard.set(data, forKey: userKey)
                }
                KeychainHelper.saveUser(user, forKey: userKey)
            } else {
                UserDefaults.standard.removeObject(forKey: userKey)
                KeychainHelper.delete(key: userKey)
            }
        }
    }
    @Published var isVIP = false
    
    private let accessTokenKey = "accessToken"
    private let refreshTokenKey = "refreshToken"
    private let tokenExpirationKey = "tokenExpiration"
    private let userKey = "currentUser"
    
    private var refreshContinuations: [CheckedContinuation<String, Error>] = []
    private var isRefreshing = false
    
    var currentToken: String? {
        KeychainHelper.load(key: accessTokenKey)
    }
    var accessToken: String? { currentToken }
    var refreshToken: String? {
        KeychainHelper.load(key: refreshTokenKey)
    }
    var tokenExpiration: TimeInterval? {
        get {
            if let value = KeychainHelper.load(key: tokenExpirationKey),
               let double = Double(value) {
                return double
            }
            return nil
        }
        set {
            if let newValue = newValue {
                KeychainHelper.save(String(newValue), forKey: tokenExpirationKey)
            } else {
                KeychainHelper.delete(key: tokenExpirationKey)
            }
        }
    }
    
    var isTokenValid: Bool {
        guard let token = currentToken, !token.isEmpty else { return false }
        if let expiration = tokenExpiration {
            return expiration > Date().timeIntervalSince1970 + 300
        }
        return true
    }
    
    private var refreshTimer: Timer?
    private let preRefreshInterval: TimeInterval = 25 * 60 // 每25分钟刷新一次，留5分钟余量
    
    // MARK: - 优化后的 init()：简化版本，启动时不主动验证 Token
    init() {
        debugLog("[Auth] 🔧 UserService init 开始，尝试从 Keychain 恢复会话")
        
        // 从 Keychain 恢复用户
        if let user = KeychainHelper.loadUser(forKey: userKey) {
            self.currentUser = user
            // 直接标记为已登录，不检查 Token 有效性（避免网络问题导致登出）
            self.isLoggedIn = true
            debugLog("[Auth] 🔐 启动恢复：从 Keychain 读取用户成功，用户：\(user.nickname ?? "")，标记为已登录")
            NotificationCenter.default.post(name: .userDidLogin, object: nil)
            
        } else {
            debugLog("[Auth] ❌ 未找到用户数据，保持未登录状态")
        }
        
        // 登录成功后启动定时器
        NotificationCenter.default.addObserver(
            forName: .userDidLogin,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPreRefreshTimer()
        }
        
        NotificationCenter.default.addObserver(
            forName: .userDidLogout,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPreRefreshTimer()
        }
        
        // 如果当前已登录（从 Keychain 恢复），也启动定时器
        if self.isLoggedIn {
            startPreRefreshTimer()
        }
        
    }
    
    private func startPreRefreshTimer() {
        stopPreRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: preRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isLoggedIn else { return }
            Task {
                do {
                    _ = try await self.refreshAccessToken(silent: true)
                    debugLog("[Auth] 🔄 定时预刷新成功")
                } catch {
                    debugLog("[Auth] ⚠️ 定时预刷新失败: \(error.localizedDescription)")
                    // 不登出，仅记录
                }
            }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }
    
    private func stopPreRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    deinit {
        stopPreRefreshTimer()
        NotificationCenter.default.removeObserver(self)
    }
    
    
    // MARK: - 公共方法
    func getValidAccessToken() async throws -> String {
        if let token = currentToken, isTokenValid {
            debugLog("[Auth] 🔑 获取有效 token：当前 token 有效，直接返回")
            return token
        }
        debugLog("[Auth] 🔑 Token 无效或已过期，将尝试静默刷新")
        return try await refreshAccessToken(silent: true)
    }
    
    func getValidAccessTokenSilently() async throws -> String {
        return try await getValidAccessToken()
    }
    
    @discardableResult
    func refreshAccessToken() async throws -> String {
        return try await refreshAccessToken(silent: false)
    }
    
    
    @discardableResult
    func refreshAccessToken(silent: Bool) async throws -> String {
        guard let refreshToken = self.refreshToken else {
            debugLog("[Auth] ❌ 无 refresh token，无法刷新")
            if silent {
                await handleTokenRefreshFailure()
            }
            throw APIError.tokenRefreshFailed
        }
        
        if isRefreshing {
            debugLog("[Auth] ⚠️ 并发刷新等待中...")
            return try await withCheckedThrowingContinuation { continuation in
                refreshContinuations.append(continuation)
            }
        }
        
        isRefreshing = true
        debugLog("[Auth] 🔄 开始刷新 token...")
        defer { isRefreshing = false }
        
        do {
            let newToken = try await performTokenRefreshRequest(refreshToken: refreshToken)
            KeychainHelper.save(newToken.accessToken, forKey: accessTokenKey)
            self.tokenExpiration = Date().timeIntervalSince1970 + newToken.expiresIn
            if !silent {
                await MainActor.run { self.isLoggedIn = true }
            }
            debugLog("[Auth] ✅ 刷新 token 成功，唤醒等待任务")
            refreshContinuations.forEach { $0.resume(returning: newToken.accessToken) }
            refreshContinuations.removeAll()
            return newToken.accessToken
        } catch {
            debugLog("[Auth] ❌ 刷新 token 失败: \(error.localizedDescription)")
            refreshContinuations.forEach { $0.resume(throwing: error) }
            refreshContinuations.removeAll()
            
            // 静默失败时不要登出，仅抛出错误
               if !silent {
                   await handleTokenRefreshFailure()
               }
               throw error
        }
    }

    // 新增方法：处理 token 刷新失败
    @MainActor
    private func handleTokenRefreshFailure() {
        // 避免重复处理
        guard isLoggedIn else { return }
        debugLog("[Auth] 🚪 Token 刷新失败，主动登出并提示重新登录")
        clearLocalData()           // 清除 Keychain 和 UserDefaults
        refreshContinuations.removeAll()
        NotificationCenter.default.post(name: .needReLogin, object: nil)
    }
    
    // MARK: - 优化后的核心刷新逻辑：静默失败不登出，不清除 Refresh Token
//    @discardableResult
//    func refreshAccessToken(silent: Bool) async throws -> String {
//        guard let refreshToken = self.refreshToken else {
//            debugLog("[Auth] ❌ 无 refresh token，无法刷新")
//            throw APIError.tokenRefreshFailed
//        }
//        
//        if isRefreshing {
//            debugLog("[Auth] ⚠️ 并发刷新等待中...")
//            return try await withCheckedThrowingContinuation { continuation in
//                refreshContinuations.append(continuation)
//            }
//        }
//        
//        isRefreshing = true
//        debugLog("[Auth] 🔄 开始刷新 token...")
//        defer { isRefreshing = false }
//        
//        do {
//            let newToken = try await performTokenRefreshRequest(refreshToken: refreshToken)
//            KeychainHelper.save(newToken.accessToken, forKey: accessTokenKey)
//            self.tokenExpiration = Date().timeIntervalSince1970 + newToken.expiresIn
//            if !silent {
//                await MainActor.run { self.isLoggedIn = true }
//            }
//            debugLog("[Auth] ✅ 刷新 token 成功，唤醒等待任务")
//            refreshContinuations.forEach { $0.resume(returning: newToken.accessToken) }
//            refreshContinuations.removeAll()
//            return newToken.accessToken
//        } catch {
//            debugLog("[Auth] ❌ 刷新 token 失败: \(error.localizedDescription)")
//            refreshContinuations.forEach { $0.resume(throwing: error) }
//            refreshContinuations.removeAll()
//            
//            throw error
//        }
//    }
    
    func logout() {
        debugLog("[Auth] 🚪 手动登出，清除 Keychain 和用户数据")
        clearLocalData()
        refreshContinuations.removeAll()
        NotificationCenter.default.post(name: .userDidLogout, object: nil)
    }
    
    func loginOrRegister(phone: String, code: String, completion: @escaping (Result<User, Error>) -> Void) {
        let url = URL(string: AppConfig.baseURL + "/api/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["phone": phone, "code": code]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1)))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    completion(.failure(APIError.unauthorized))
                    return
                }
                do {
                    struct LoginResponse: Decodable {
                        let accessToken: String
                        let refreshToken: String
                        let expiresIn: TimeInterval
                        let user: User
                    }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let loginResponse = try decoder.decode(LoginResponse.self, from: data)
                    self?.saveUserAndTokens(user: loginResponse.user,
                                            accessToken: loginResponse.accessToken,
                                            refreshToken: loginResponse.refreshToken,
                                            expiresIn: loginResponse.expiresIn)
                    completion(.success(loginResponse.user))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    func sendVerificationCode(to phone: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: AppConfig.baseURL + "/api/auth/send-code") else {
            completion(false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["phone": phone])
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                completion((response as? HTTPURLResponse)?.statusCode == 200)
            }
        }.resume()
    }
    
    // MARK: - 服务端 Token 验证（保留，但不在 init 中自动调用）
    private func verifyTokenWithServer() async throws {
        guard let token = currentToken else {
            throw APIError.unauthorized
        }
        guard let url = URL(string: AppConfig.baseURL + "/api/users/me") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }
        if httpResponse.statusCode == 200 {
            debugLog("[Auth] ✅ verifyToken: 服务端确认 Token 有效")
            return
        } else if httpResponse.statusCode == 401 {
            debugLog("[Auth] ⚠️ verifyToken: 服务端返回 401，Token 无效")
            throw APIError.unauthorized
        } else {
            debugLog("[Auth] ⚠️ verifyToken: 服务器响应非预期状态码: \(httpResponse.statusCode)")
            throw APIError.unknown
        }
    }
    
    func refreshUserInfo() async throws {
        guard let token = currentToken else {
            throw APIError.unauthorized
        }
        guard let url = URL(string: AppConfig.baseURL + "/api/users/me") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }
        guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 {
                    // 不主动登出，仅抛出异常
                    throw APIError.unauthorized
                }
                throw APIError.unauthorized
            }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let user = try decoder.decode(User.self, from: data)
        await MainActor.run {
            self.currentUser = user
        }
    }
    
    // MARK: - 私有辅助
    private func saveUserAndTokens(user: User, accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
        self.currentUser = user
        self.isLoggedIn = true
        KeychainHelper.save(accessToken, forKey: accessTokenKey)
        KeychainHelper.save(refreshToken, forKey: refreshTokenKey)
        self.tokenExpiration = Date().timeIntervalSince1970 + expiresIn
        NotificationCenter.default.post(name: .userDidLogin, object: nil)
        debugLog("[Auth] ✅ 首次登录成功，Token 已保存到 Keychain，用户：\(user.nickname ?? "")")
    }
    
    private func clearLocalData() {
        KeychainHelper.delete(key: accessTokenKey)
        KeychainHelper.delete(key: refreshTokenKey)
        KeychainHelper.delete(key: tokenExpirationKey)
        KeychainHelper.delete(key: userKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.removeObject(forKey: "isLoggedInFlag")
        currentUser = nil
        isLoggedIn = false
    }
    
    private func performTokenRefreshRequest(refreshToken: String) async throws -> (accessToken: String, expiresIn: TimeInterval) {
        guard let url = URL(string: AppConfig.baseURL + "/api/auth/refresh") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // ✅ 关键修复：将 refreshToken 放入请求体，与后端 RefreshRequest 结构一致
        let body = ["refreshToken": refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // 可选：保留 Authorization 头部（后端可能不使用，但无副作用）
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }
        if httpResponse.statusCode == 200 {
            struct RefreshResponse: Decodable {
                let accessToken: String
                let refreshToken: String?
                let expiresIn: TimeInterval
            }
            let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
            if let newRefresh = refreshResponse.refreshToken {
                KeychainHelper.save(newRefresh, forKey: refreshTokenKey)
                print("✅ 滚动刷新：已保存新 Refresh Token")
            }
            KeychainHelper.save(refreshResponse.accessToken, forKey: accessTokenKey)
            self.tokenExpiration = Date().timeIntervalSince1970 + refreshResponse.expiresIn
            return (refreshResponse.accessToken, refreshResponse.expiresIn)
        } else if httpResponse.statusCode == 422 {
            throw APIError.tokenRefreshFailed
        } else {
            throw APIError.tokenRefreshFailed
        }
    }
}

extension Notification.Name {
    static let tokenRefreshFailed = Notification.Name("tokenRefreshFailed")
    static let needReLogin = Notification.Name("needReLogin")
}
