//
//  ApiClient.swift
//  ChatAll
//
//  URLSession + async/await 封装全部 REST 接口。
//  统一解析 ApiResponse，code != 0 时抛出 ApiError(msg)。
//

import Foundation

/// 业务错误
struct ApiError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

/// 网络层
final class ApiClient {

    static let shared = ApiClient()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// 用于解码 null data 的占位类型
    struct EmptyBody: Codable {}

    // MARK: - 基础请求

    /// 发起请求并解析统一响应，返回 data（可能为 nil 的情况请用 requestVoid）
    private func request<T: Codable>(_ method: String,
                                     _ path: String,
                                     query: [String: String] = [:],
                                     body: [String: Any]? = nil,
                                     auth: Bool = true) async throws -> T {
        var urlString = AppConfig.httpBase + path
        if !query.isEmpty {
            var comps = URLComponents(string: urlString)
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let s = comps?.url?.absoluteString { urlString = s }
        }
        guard let url = URL(string: urlString) else {
            throw ApiError(msg: "服务器地址无效")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if auth {
            let token = AppConfig.token
            if !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw ApiError(msg: "登录已失效，请重新登录")
            }
            if http.statusCode >= 500 {
                throw ApiError(msg: "服务器错误(\(http.statusCode))")
            }
        }

        let decoder = JSONDecoder()
        let resp: ApiResponse<T>
        do {
            resp = try decoder.decode(ApiResponse<T>.self, from: data)
        } catch {
            throw ApiError(msg: "数据解析失败")
        }
        if resp.code != 0 {
            throw ApiError(msg: resp.msg.isEmpty ? "请求失败" : resp.msg)
        }
        guard let value = resp.data else {
            throw ApiError(msg: resp.msg.isEmpty ? "空数据" : resp.msg)
        }
        return value
    }

    /// 只关心成功/失败、忽略 data 的请求
    private func requestVoid(_ method: String,
                            _ path: String,
                            body: [String: Any]? = nil,
                            auth: Bool = true) async throws {
        let _: EmptyBody = try await requestAllowEmpty(method, path, body: body, auth: auth)
    }

    /// 允许 data 为 null 的请求（内部使用）
    private func requestAllowEmpty<T: Codable>(_ method: String,
                                               _ path: String,
                                               query: [String: String] = [:],
                                               body: [String: Any]? = nil,
                                               auth: Bool = true) async throws -> T {
        var urlString = AppConfig.httpBase + path
        if !query.isEmpty {
            var comps = URLComponents(string: urlString)
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let s = comps?.url?.absoluteString { urlString = s }
        }
        guard let url = URL(string: urlString) else {
            throw ApiError(msg: "服务器地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if auth {
            let token = AppConfig.token
            if !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ApiError(msg: "登录已失效，请重新登录") }
            if http.statusCode >= 500 { throw ApiError(msg: "服务器错误(\(http.statusCode))") }
        }
        let decoder = JSONDecoder()
        let resp: ApiResponse<T>
        do {
            resp = try decoder.decode(ApiResponse<T>.self, from: data)
        } catch {
            throw ApiError(msg: "数据解析失败")
        }
        if resp.code != 0 {
            throw ApiError(msg: resp.msg.isEmpty ? "请求失败" : resp.msg)
        }
        // data 为 nil 时返回一个"空"对象（EmptyBody 可空解码）
        if let value = resp.data { return value }
        if let empty = EmptyBody() as? T { return empty }
        throw ApiError(msg: resp.msg.isEmpty ? "空数据" : resp.msg)
    }

    // MARK: - 认证

    func register(username: String, password: String, nickname: String) async throws -> AuthResult {
        return try await request("POST", "/api/auth/register",
                                 body: ["username": username, "password": password, "nickname": nickname],
                                 auth: false)
    }

    func login(username: String, password: String) async throws -> AuthResult {
        return try await request("POST", "/api/auth/login",
                                 body: ["username": username, "password": password],
                                 auth: false)
    }

    // MARK: - 用户

    func searchUser(keyword: String) async throws -> [UserInfo] {
        return try await request("GET", "/api/user/search", query: ["kw": keyword])
    }

    func getUser(id: Int64) async throws -> UserInfo {
        return try await request("GET", "/api/user/\(id)")
    }

    func updateProfile(nickname: String, avatar: String) async throws -> UserInfo {
        return try await request("PUT", "/api/user/profile",
                                 body: ["nickname": nickname, "avatar": avatar])
    }

    func updatePassword(oldPassword: String, newPassword: String) async throws {
        try await requestVoid("PUT", "/api/user/password",
                              body: ["oldPassword": oldPassword, "newPassword": newPassword])
    }

    func getBark() async throws -> BarkInfo {
        return try await request("GET", "/api/user/bark")
    }

    func setBark(barkKey: String) async throws -> BarkInfo {
        return try await request("POST", "/api/user/bark", body: ["barkKey": barkKey])
    }

    // MARK: - 好友

    func friendList() async throws -> [FriendItem] {
        return try await request("GET", "/api/friend/list")
    }

    func sendFriendRequest(toId: Int64, msg: String) async throws {
        try await requestVoid("POST", "/api/friend/request",
                              body: ["toId": toId, "msg": msg])
    }

    func pendingRequests() async throws -> [PendingRequest] {
        return try await request("GET", "/api/friend/request/pending")
    }

    func handleFriendRequest(requestId: Int64, accept: Bool) async throws {
        try await requestVoid("POST", "/api/friend/request/handle",
                              body: ["requestId": requestId, "accept": accept])
    }

    func deleteFriend(friendId: Int64) async throws {
        try await requestVoid("DELETE", "/api/friend/\(friendId)")
    }

    func setRemark(friendId: Int64, remark: String) async throws {
        try await requestVoid("POST", "/api/friend/\(friendId)/remark",
                              body: ["remark": remark])
    }

    // MARK: - 群组

    func createGroup(name: String, memberIds: [Int64]) async throws -> GroupItem {
        return try await request("POST", "/api/group/create",
                                 body: ["name": name, "memberIds": memberIds])
    }

    func myGroups() async throws -> [GroupItem] {
        return try await request("GET", "/api/group/my")
    }

    func groupMembers(groupId: Int64) async throws -> [GroupMember] {
        return try await request("GET", "/api/group/\(groupId)/members")
    }

    func inviteToGroup(groupId: Int64, userId: Int64) async throws {
        try await requestVoid("POST", "/api/group/\(groupId)/invite",
                              body: ["userId": userId])
    }

    // MARK: - 动态（朋友圈）

    func momentFeed() async throws -> [MomentItem] {
        return try await request("GET", "/api/moment/feed")
    }

    /// 发布动态；images 为 URL 字符串数组
    func createMoment(content: String, images: [String]) async throws {
        let imagesJSON = (try? JSONSerialization.data(withJSONObject: images))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try await requestVoid("POST", "/api/moment/create",
                              body: ["content": content, "images": imagesJSON])
    }

    /// 点赞 / 取消点赞，返回 true=已赞 false=已取消
    func toggleMomentLike(momentId: Int64) async throws -> Bool {
        return try await request("POST", "/api/moment/\(momentId)/like")
    }

    func addMomentComment(momentId: Int64, content: String) async throws {
        try await requestVoid("POST", "/api/moment/\(momentId)/comment",
                              body: ["content": content])
    }

    func deleteMoment(momentId: Int64) async throws {
        try await requestVoid("DELETE", "/api/moment/\(momentId)")
    }

    // MARK: - 消息

    func offlineMessages() async throws -> [ChatMessage] {
        return try await request("GET", "/api/message/offline")
    }

    /// 单聊未读统计（服务端口径：对方发给我且我还没读的消息数）
    func unreadCounts() async throws -> [UnreadCountItem] {
        return try await request("GET", "/api/message/unread")
    }

    func singleHistory(peerId: Int64, limit: Int = 100) async throws -> [ChatMessage] {
        return try await request("GET", "/api/message/history/single",
                                 query: ["peerId": "\(peerId)", "limit": "\(limit)"])
    }

    func groupHistory(groupId: Int64, limit: Int = 100) async throws -> [ChatMessage] {
        return try await request("GET", "/api/message/history/group",
                                 query: ["groupId": "\(groupId)", "limit": "\(limit)"])
    }

    // MARK: - 文件上传（multipart，字段名 file）

    func uploadFile(data: Data, fileName: String, mimeType: String) async throws -> UploadResult {
        guard let url = URL(string: AppConfig.httpBase + "/api/file/upload") else {
            throw ApiError(msg: "服务器地址无效")
        }
        let boundary = "----ChatAllBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let token = AppConfig.token
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        let lineBreak = "\r\n"
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(data)
        body.append(lineBreak.data(using: .utf8)!)
        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        req.httpBody = body

        let (respData, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw ApiError(msg: "登录已失效，请重新登录")
        }
        do {
            let resp = try JSONDecoder().decode(ApiResponse<UploadResult>.self, from: respData)
            if resp.code != 0 {
                throw ApiError(msg: resp.msg.isEmpty ? "上传失败" : resp.msg)
            }
            guard let value = resp.data else { throw ApiError(msg: "上传返回为空") }
            return value
        } catch let e as ApiError {
            throw e
        } catch {
            throw ApiError(msg: "上传解析失败")
        }
    }
}
