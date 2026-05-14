////
////  UserService.swift
////  StrawberryPlayer
////  负责管理用户登录状态、持久化存储及登录/退出逻辑。
////  支持自动刷新 access token。
////  Created by penghui zhang on 2026/2/24.
////
//
//import Foundation
//import Combine
//
//// 保持 APIError 定义不变
//enum APIError: Error, LocalizedError {
//    case tokenRefreshFailed
//    case unauthorized
//    case unknown
//    case invalidURL
//    case noData
//    case badRequest
//    case notFound
//    
//    var errorDescription: String? {
//        switch self {
//        case .tokenRefreshFailed: return "登录已过期，请重新登录"
//        case .unauthorized: return "未授权，请登录"
//        default: return "未知错误"
//        }
//    }
//}
//
//class UserService: ObservableObject {
//    @Published var isLoggedIn: Bool = false {
//        didSet {
//            UserDefaults.standard.set(isLoggedIn, forKey: "isLoggedInFlag")
//        }
//    }
//    @Published var currentUser: User? {
//        didSet {
//            // 保持原有存储逻辑（UserDefaults + Keychain）
//            if let user = currentUser {
//                let encoder = JSONEncoder()
//                encoder.dateEncodingStrategy = .iso8601
//                if let data = try? encoder.encode(user) {
//                    UserDefaults.standard.set(data, forKey: userKey)
//                }
//                KeychainHelper.saveUser(user, forKey: userKey)
//            } else {
//                UserDefaults.standard.removeObject(forKey: userKey)
//                KeychainHelper.delete(key: userKey)
//            }
//        }
//    }
//    @Published var isVIP = false
//    
//    private let accessTokenKey = "accessToken"
//    private let refreshTokenKey = "refreshToken"
//    private let tokenExpirationKey = "tokenExpiration"
//    private let userKey = "currentUser"
//    
//    // 并发刷新控制：存储等待完成的续体
//    private var refreshContinuations: [CheckedContinuation<String, Error>] = []
//    private var isRefreshing = false
//    
//    // 便捷访问器（保持原有外部调用）
//    var currentToken: String? {
//        KeychainHelper.load(key: accessTokenKey)
//    }
//    var accessToken: String? { currentToken }
//    var refreshToken: String? {
//        KeychainHelper.load(key: refreshTokenKey)
//    }
//    var tokenExpiration: TimeInterval? {
//        get {
//            if let value = KeychainHelper.load(key: tokenExpirationKey),
//               let double = Double(value) {
//                return double
//            }
//            return nil
//        }
//        set {
//            if let newValue = newValue {
//                KeychainHelper.save(String(newValue), forKey: tokenExpirationKey)
//            } else {
//                KeychainHelper.delete(key: tokenExpirationKey)
//            }
//        }
//    }
//    
//    // 计算属性：Token 是否有效（提前5分钟过期）
//    var isTokenValid: Bool {
//        guard let token = currentToken, !token.isEmpty else { return false }
//        if let expiration = tokenExpiration {
//            return expiration > Date().timeIntervalSince1970 + 300
//        }
//        return true
//    }
//    
//    init() {
//        debugLog("[Auth] 🔧 UserService init 开始，尝试从 Keychain 恢复会话")
//        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
//        if !hasLaunchedBefore {
//            debugLog("[Auth] 🆕 检测到首次启动，清除所有旧的登录状态")
//            KeychainHelper.clearAll()
//            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
//            UserDefaults.standard.synchronize()
//            self.isLoggedIn = false
//            return
//        }
//
//        // 从 Keychain 恢复用户
//        if let user = KeychainHelper.loadUser(forKey: userKey) ??
//            (UserDefaults.standard.data(forKey: userKey).flatMap { try? JSONDecoder().decode(User.self, from: $0) }) {
//            self.currentUser = user
//
//            // 检查 Access Token 是否存在
//            guard let token = currentToken, !token.isEmpty else {
//                // 无 Access Token：检查是否有 Refresh Token 可用于刷新
//                if let refresh = self.refreshToken, !refresh.isEmpty {
//                    // 尝试静默刷新
//                    Task {
//                        do {
//                            _ = try await refreshAccessToken(silent: true)
//                            await MainActor.run {
//                                self.isLoggedIn = true
//                                NotificationCenter.default.post(name: .userDidLogin, object: nil)
//                            }
//                        } catch {
//                            // 刷新失败，彻底清除登录状态
//                            await MainActor.run {
//                                self.clearLocalData()
//                                debugLog("[Auth] 🚫 刷新失败，已清除登录状态")
//                            }
//                        }
//                    }
//                } else {
//                    // 完全无 Token，清除数据
//                    clearLocalData()
//                }
//                return
//            }
//
//            // 有 Access Token，先标记登录
//            self.isLoggedIn = true
//            debugLog("[Auth] 🔐 启动恢复：从 Keychain 读取 token 成功，用户已登录")
//            NotificationCenter.default.post(name: .userDidLogin, object: nil)
//
//            // 判断 Token 是否即将/已经过期
//            if isTokenValid {
//                // ✅ 本地有效，再向服务端验证一次（防止 Token 已被后端提前失效）
//                debugLog("[Auth] ✅ Token 本地有效，将向服务端验证")
//                Task {
//                    do {
//                        try await verifyTokenWithServer()
//                        debugLog("[Auth] ✅ 服务端验证通过，用户保持登录")
//                    } catch {
//                        // 服务端验证失败（Token 无效或网络问题），清除本地数据
//                        debugLog("[Auth] ❌ 服务端验证失败，清除本地登录数据")
//                        await MainActor.run {
//                            self.clearLocalData()
//                        }
//                    }
//                }
//            } else {
//                debugLog("[Auth] ⚠️ Token 即将或已过期，将尝试后台静默刷新")
//                Task {
//                    do {
//                        _ = try await refreshAccessToken(silent: true)
//                        debugLog("[Auth] ✅ 启动后静默刷新成功")
//                    } catch {
//                        await MainActor.run {
//                            self.clearLocalData()
//                            debugLog("[Auth] 🧹 静默刷新失败，已清除登录数据，下次启动将显示登录页")
//                        }
//                    }
//                }
//            }
//        } else {
//            debugLog("[Auth] ❌ 未找到用户数据，保持未登录状态")
//        }
//    }
//    
////    init() {
////        debugLog("[Auth] 🔧 UserService init 开始，尝试从 Keychain 恢复会话")
////        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
////        if !hasLaunchedBefore {
////            debugLog("[Auth] 🆕 检测到首次启动，清除所有旧的登录状态")
////            KeychainHelper.clearAll()
////            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
////            UserDefaults.standard.synchronize()
////            self.isLoggedIn = false
////            return
////        }
////
////        // 从 Keychain 恢复用户
////        if let user = KeychainHelper.loadUser(forKey: userKey) ??
////            (UserDefaults.standard.data(forKey: userKey).flatMap { try? JSONDecoder().decode(User.self, from: $0) }) {
////            self.currentUser = user
////
////            // 检查 Access Token 是否存在
////            guard let token = currentToken, !token.isEmpty else {
////                // 无 Access Token：检查是否有 Refresh Token 可用于刷新
////                if let refresh = self.refreshToken, !refresh.isEmpty {
////                    // 尝试静默刷新
////                    Task {
////                        do {
////                            _ = try await refreshAccessToken(silent: true)
////                            await MainActor.run {
////                                self.isLoggedIn = true
////                                NotificationCenter.default.post(name: .userDidLogin, object: nil)
////                            }
////                        } catch {
////                            // 刷新失败，彻底清除登录状态
////                            await MainActor.run {
////                                self.clearLocalData()
////                                debugLog("[Auth] 🚫 刷新失败，已清除登录状态")
////                            }
////                        }
////                    }
////                } else {
////                    // 完全无 Token，清除数据
////                    clearLocalData()
////                }
////                return
////            }
////
////            // 有 Access Token，先标记登录
////            self.isLoggedIn = true
////            debugLog("[Auth] 🔐 启动恢复：从 Keychain 读取 token 成功，用户已登录")
////            NotificationCenter.default.post(name: .userDidLogin, object: nil)
////
////            // 判断 Token 是否即将/已经过期
////            if isTokenValid {
////                debugLog("[Auth] ✅ Token 仍然有效，无需刷新")
////            } else {
////                debugLog("[Auth] ⚠️ Token 即将或已过期，将尝试后台静默刷新")
////                Task {
////                    do {
////                        _ = try await refreshAccessToken(silent: true)
////                        debugLog("[Auth] ✅ 启动后静默刷新成功")
////                    } catch {
////                        // 静默刷新失败 ⇒ Token 完全失效，清除登录状态
////                        await MainActor.run {
////                            self.clearLocalData()
////                            debugLog("[Auth] 🧹 静默刷新失败，已清除登录数据，下次启动将显示登录页")
////                        }
////                    }
////                }
////            }
////        } else {
////            debugLog("[Auth] ❌ 未找到用户数据，保持未登录状态")
////        }
////    }
//    
//    // MARK: - 公共：获取有效 Token（核心方法）
//    func getValidAccessToken() async throws -> String {
//        if let token = currentToken, isTokenValid {
//            debugLog("[Auth] 🔑 获取有效 token：当前 token 有效，直接返回")
//            return token
//        }
//        debugLog("[Auth] 🔑 Token 无效或已过期，将尝试静默刷新")
//        return try await refreshAccessToken(silent: true)
//    }
//    
//    // MARK: - 静默刷新（供后台使用，失败不登出）
//    func getValidAccessTokenSilently() async throws -> String {
//        return try await getValidAccessToken()
//    }
//    
//    // MARK: - 公开刷新方法（兼容旧代码）
//    @discardableResult
//    func refreshAccessToken() async throws -> String {
//        return try await refreshAccessToken(silent: false)
//    }
//    
//    // MARK: - 核心刷新逻辑
//    @discardableResult
//    func refreshAccessToken(silent: Bool) async throws -> String {
//        guard let refreshToken = self.refreshToken else {
//            debugLog("[Auth] ❌ 无 refresh token，无法刷新")
//            if !silent { await MainActor.run { self.logout() } }
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
//            // 刷新成功：更新存储与状态
//            KeychainHelper.save(newToken.accessToken, forKey: accessTokenKey)
//            self.tokenExpiration = Date().timeIntervalSince1970 + newToken.expiresIn
//            if !silent {
//                // 非静默模式才重置 isLoggedIn 等（实际上已经是 true）
//                await MainActor.run { self.isLoggedIn = true }
//            }
//            // 唤醒等待的续体
//            debugLog("[Auth] ✅ 刷新 token 成功，唤醒等待任务")
//            refreshContinuations.forEach { $0.resume(returning: newToken.accessToken) }
//            refreshContinuations.removeAll()
//            return newToken.accessToken
//        } catch {
//            // 刷新失败
//            debugLog("[Auth] ❌ 刷新 token 失败: \(error.localizedDescription)")
//            refreshContinuations.forEach { $0.resume(throwing: error) }
//            refreshContinuations.removeAll()
//            
//            if silent {
//                // ✅ 静默刷新失败时，清除无效 Refresh Token，避免下次启动继续尝试
//                KeychainHelper.delete(key: refreshTokenKey)
//                debugLog("[Auth] 🧹 已清除无效的 Refresh Token，下次需要重新登录")
//            } else {
//                await MainActor.run { self.logout() }
//            }
//            throw error
//        }
//    }
//    
//    // MARK: - 登出
//    func logout() {
//        debugLog("[Auth] 🚪 手动登出，清除 Keychain 和用户数据")
//        clearLocalData()
//        refreshContinuations.removeAll()
//        NotificationCenter.default.post(name: .userDidLogout, object: nil)
//    }
//    
//    // MARK: - 登录/注册（保持原样，略微调整以使用 saveUserAndTokens）
//    func loginOrRegister(phone: String, code: String, completion: @escaping (Result<User, Error>) -> Void) {
//        let url = URL(string: AppConfig.baseURL + "/api/auth/login")!
//        var request = URLRequest(url: url)
//        request.httpMethod = "POST"
//        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//        let body: [String: String] = ["phone": phone, "code": code]
//        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
//        
//        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
//            DispatchQueue.main.async {
//                if let error = error {
//                    completion(.failure(error))
//                    return
//                }
//                guard let data = data else {
//                    completion(.failure(NSError(domain: "NoData", code: -1)))
//                    return
//                }
//                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
//                    completion(.failure(APIError.unauthorized))
//                    return
//                }
//                do {
//                    struct LoginResponse: Decodable {
//                        let accessToken: String
//                        let refreshToken: String
//                        let expiresIn: TimeInterval
//                        let user: User
//                    }
//                    let decoder = JSONDecoder()
//                    decoder.dateDecodingStrategy = .iso8601
//                    let loginResponse = try decoder.decode(LoginResponse.self, from: data)
//                    self?.saveUserAndTokens(user: loginResponse.user,
//                                            accessToken: loginResponse.accessToken,
//                                            refreshToken: loginResponse.refreshToken,
//                                            expiresIn: loginResponse.expiresIn)
//                    completion(.success(loginResponse.user))
//                } catch {
//                    completion(.failure(error))
//                }
//            }
//        }.resume()
//    }
//    
//    func sendVerificationCode(to phone: String, completion: @escaping (Bool) -> Void) {
//        // 保持不变
//        guard let url = URL(string: AppConfig.baseURL + "/api/auth/send-code") else {
//            completion(false); return
//        }
//        var request = URLRequest(url: url)
//        request.httpMethod = "POST"
//        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//        request.httpBody = try? JSONSerialization.data(withJSONObject: ["phone": phone])
//        URLSession.shared.dataTask(with: request) { data, response, error in
//            DispatchQueue.main.async {
//                completion((response as? HTTPURLResponse)?.statusCode == 200)
//            }
//        }.resume()
//    }
//    
//    // MARK: - 服务端 Token 验证
//    /// 向服务端验证当前 Access Token 是否仍然有效
//    /// - Throws: 如果 token 无效或网络错误
//    private func verifyTokenWithServer() async throws {
//        guard let token = currentToken else {
//            debugLog("[Auth] ❌ verifyToken: 无 Access Token")
//            throw APIError.unauthorized
//        }
//        
//        guard let url = URL(string: AppConfig.baseURL + "/api/users/me") else {
//            debugLog("[Auth] ❌ verifyToken: 无效的 URL")
//            throw APIError.invalidURL
//        }
//        
//        var request = URLRequest(url: url)
//        request.httpMethod = "GET"
//        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
//        
//        do {
//            let (_, response) = try await URLSession.shared.data(for: request)
//            guard let httpResponse = response as? HTTPURLResponse else {
//                throw APIError.unknown
//            }
//            
//            if httpResponse.statusCode == 200 {
//                debugLog("[Auth] ✅ verifyToken: 服务端确认 Token 有效")
//                return
//            } else if httpResponse.statusCode == 401 {
//                debugLog("[Auth] ⚠️ verifyToken: 服务端返回 401，Token 无效")
//                throw APIError.unauthorized
//            } else {
//                debugLog("[Auth] ⚠️ verifyToken: 服务器响应非预期状态码: \(httpResponse.statusCode)")
//                throw APIError.unknown
//            }
//        } catch {
//            debugLog("[Auth] ❌ verifyToken: 请求失败 - \(error.localizedDescription)")
//            throw error
//        }
//    }
//    
//    // MARK: - 刷新用户信息
//    /// 从服务器获取当前用户的最新信息（包括剩余次数等），并更新 currentUser
//    func refreshUserInfo() async throws {
//        guard let token = currentToken else {
//            throw APIError.unauthorized
//        }
//        guard let url = URL(string: AppConfig.baseURL + "/api/users/me") else {
//            throw APIError.invalidURL
//        }
//        var request = URLRequest(url: url)
//        request.httpMethod = "GET"
//        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
//        
//        let (data, response) = try await URLSession.shared.data(for: request)
//        guard let httpResponse = response as? HTTPURLResponse else {
//            throw APIError.unknown
//        }
//        guard httpResponse.statusCode == 200 else {
//            throw APIError.unauthorized
//        }
//        
//        let decoder = JSONDecoder()
//        decoder.dateDecodingStrategy = .iso8601
//        let user = try decoder.decode(User.self, from: data)
//        await MainActor.run {
//            self.currentUser = user
//        }
//    }
//    
//    // MARK: - 私有辅助
//    private func saveUserAndTokens(user: User, accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
//        self.currentUser = user
//        self.isLoggedIn = true
//        KeychainHelper.save(accessToken, forKey: accessTokenKey)
//        KeychainHelper.save(refreshToken, forKey: refreshTokenKey)
//        self.tokenExpiration = Date().timeIntervalSince1970 + expiresIn
//        NotificationCenter.default.post(name: .userDidLogin, object: nil)
//        debugLog("[Auth] ✅ 首次登录成功，Token 已保存到 Keychain，用户：\(user.nickname ?? "")")
//    }
//    
//    private func clearLocalData() {
//        KeychainHelper.delete(key: accessTokenKey)
//        KeychainHelper.delete(key: refreshTokenKey)
//        KeychainHelper.delete(key: tokenExpirationKey)
//        KeychainHelper.delete(key: userKey)
//        UserDefaults.standard.removeObject(forKey: userKey)
//        UserDefaults.standard.removeObject(forKey: "isLoggedInFlag")
//        currentUser = nil
//        isLoggedIn = false
//    }
//    
//    private func performTokenRefreshRequest(refreshToken: String) async throws -> (accessToken: String, expiresIn: TimeInterval) {
//        guard let url = URL(string: AppConfig.baseURL + "/api/auth/refresh") else {
//            throw APIError.invalidURL
//        }
//        var request = URLRequest(url: url)
//        request.httpMethod = "POST"
//        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
//        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//        
//        let (data, response) = try await URLSession.shared.data(for: request)
//        guard let httpResponse = response as? HTTPURLResponse else {
//            throw APIError.unknown
//        }
//        if httpResponse.statusCode == 200 {
//            struct RefreshResponse: Decodable {
//                let accessToken: String
//                let refreshToken: String?   // 新增（后端现在一定会返回，但可选以兼容旧版）
//                let expiresIn: TimeInterval
//            }
//            
//            let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
//            
//            // 如果后端开始返回新的 refresh token，则保存它
//            if let newRefresh = refreshResponse.refreshToken {
//                KeychainHelper.save(newRefresh, forKey: refreshTokenKey)
//                print("✅ 滚动刷新：已保存新 Refresh Token")
//            }
//            KeychainHelper.save(refreshResponse.accessToken, forKey: accessTokenKey)
//            self.tokenExpiration = Date().timeIntervalSince1970 + refreshResponse.expiresIn
//            return (refreshResponse.accessToken, refreshResponse.expiresIn)
//            
//        } else if httpResponse.statusCode == 422 {
//            // 静默与否，刷新 token 无效都应该抛出错误，由上层决定是否登出
//            throw APIError.tokenRefreshFailed
//        } else {
//            throw APIError.tokenRefreshFailed
//        }
//    }
//}


//
//  UserService.swift
//  StrawberryPlayer
//  负责管理用户登录状态、持久化存储及登录/退出逻辑。
//  支持自动刷新 access token。
//  Created by penghui zhang on 2026/2/24.
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
    
    init() {
        debugLog("[Auth] 🔧 UserService init 开始，尝试从 Keychain 恢复会话")
        
        // 不再使用 hasLaunchedBefore 清除 Keychain，商业 App 也不会在首次启动时清空
        // 只有在用户主动登出或 Token 彻底无效时才清除
        
        // 从 Keychain 恢复用户
        if let user = KeychainHelper.loadUser(forKey: userKey) {
            self.currentUser = user
            self.isLoggedIn = true
            debugLog("[Auth] 🔐 启动恢复：从 Keychain 读取用户成功，用户：\(user.nickname ?? "")")
            NotificationCenter.default.post(name: .userDidLogin, object: nil)
            
            // 如果有 Access Token 且未过期，就保持登录（不主动验证，避免网络问题导致登出）
            if let token = currentToken, !token.isEmpty, isTokenValid {
                debugLog("[Auth] ✅ Token 仍然有效，无需刷新")
            } else {
                // Token 不存在或已过期，尝试静默刷新（不登出）
                debugLog("[Auth] ⚠️ Token 不存在或已过期，尝试静默刷新")
                Task {
                    do {
                        _ = try await refreshAccessToken(silent: true)
                        debugLog("[Auth] ✅ 静默刷新成功")
                    } catch {
                        // 刷新失败，不清除数据，但标记未登录，让用户下次主动操作时重新登录
                        debugLog("[Auth] ⚠️ 静默刷新失败，但保留登录数据，等待用户主动操作")
                        await MainActor.run {
                            self.isLoggedIn = false
                        }
                    }
                }
            }
        } else {
            debugLog("[Auth] ❌ 未找到用户数据，保持未登录状态")
        }
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
            if !silent { await MainActor.run { self.logout() } }
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
            
            // 静默刷新失败时，不清除 Refresh Token，避免下次启动无法尝试
            // 只在非静默模式（用户主动操作）时才登出
            if !silent {
                await MainActor.run { self.logout() }
            }
            throw error
        }
    }
    
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
    
    // MARK: - 服务端 Token 验证（仅在需要时手动调用，不在启动时自动调用）
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
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
