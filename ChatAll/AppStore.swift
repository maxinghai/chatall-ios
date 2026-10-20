//
//  AppStore.swift
//  ChatAll
//
//  全局状态与业务逻辑：登录态、好友/群组/申请列表、未读计数、会话消息、WS 事件处理、各业务动作。
//

import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {

    // MARK: - 登录态
    @Published var token: String = ""
    @Published var currentUser: UserInfo? = nil
    @Published var isLoggedIn: Bool = false

    // MARK: - 连接状态
    @Published var connected: Bool = false
    /// 通话界面显隐（镜像 CallManager.showUI，让 MainView 能可靠订阅）
    @Published var callUIVisible: Bool = false

    // MARK: - 列表数据
    @Published var friends: [FriendItem] = []
    @Published var groups: [GroupItem] = []
    @Published var pendingRequests: [PendingRequest] = []

    // MARK: - 消息
    /// peerKey -> 消息列表
    @Published var messagesByPeer: [Int64: [ChatMessage]] = [:]
    /// peerKey -> 未读数
    @Published var unreadCounts: [Int64: Int] = [:]
    /// 当前打开的会话（peerKey）
    @Published var activePeerId: Int64? = nil

    // MARK: - 提示
    @Published var errorMessage: String? = nil
    @Published var toastMessage: String? = nil

    // MARK: - 其它
    let ws = WsClient()
    let call: CallManager
    /// 本地消息占位 id 种子（负数递减）
    private var localIdSeed: Int64 = -1
    /// 已完成历史加载的会话（含空会话），再次进入不重复请求网络，新消息由 WS 实时推送
    private var historyLoadedPeers: Set<Int64> = []
    /// 是否成功连上过（区分首次连接与断线重连）
    private var everConnected = false

    init() {
        self.call = CallManager()
        self.token = AppConfig.token
        self.currentUser = AppConfig.user
        self.isLoggedIn = !AppConfig.token.isEmpty

        ws.onPacket = { [weak self] type, data in
            guard let self = self else { return }
            Task { @MainActor in
                self.handlePacket(type: type, data: data)
            }
        }
        ws.onStateChange = { [weak self] value in
            guard let self = self else { return }
            Task { @MainActor in
                self.connected = value
                if value && self.isLoggedIn {
                    if self.everConnected {
                        // 断线重连成功：补拉列表与离线消息
                        Task { await self.reloadAll() }
                    }
                    self.everConnected = true
                }
            }
        }
        call.store = self
        call.onShowUIChange = { [weak self] visible in
            Task { @MainActor in
                self?.callUIVisible = visible
            }
        }
    }

    // MARK: - 登录 / 注册

    func login(username: String, password: String) async {
        do {
            let result = try await ApiClient.shared.login(username: username, password: password)
            applyAuth(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func register(username: String, password: String, nickname: String) async {
        do {
            let result = try await ApiClient.shared.register(username: username,
                                                              password: password,
                                                              nickname: nickname)
            applyAuth(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyAuth(_ result: AuthResult) {
        AppConfig.token = result.token
        AppConfig.user = result.user
        token = result.token
        currentUser = result.user
        isLoggedIn = true
        connectWS()
        Task { await self.reloadAll() }
    }

    func logout() {
        ws.disconnect()
        call.reset()
        AppConfig.clearAuth()
        token = ""
        currentUser = nil
        isLoggedIn = false
        friends = []
        groups = []
        pendingRequests = []
        messagesByPeer = [:]
        unreadCounts = [:]
        activePeerId = nil
        historyLoadedPeers.removeAll()
    }

    func connectWS() {
        guard !token.isEmpty else { return }
        ws.connect(token: token)
    }

    // MARK: - 拉取数据

    func reloadAll() async {
        await refreshFriends()
        await refreshGroups()
        await refreshPending()
        await loadOffline()
    }

    func refreshFriends() async {
        do { friends = try await ApiClient.shared.friendList() }
        catch { /* 静默失败 */ }
    }

    func refreshGroups() async {
        do { groups = try await ApiClient.shared.myGroups() }
        catch { /* 静默失败 */ }
    }

    func refreshPending() async {
        do { pendingRequests = try await ApiClient.shared.pendingRequests() }
        catch { /* 静默失败 */ }
    }

    func loadOffline() async {
        do {
            let list = try await ApiClient.shared.offlineMessages()
            for m in list {
                appendIncoming(m)
            }
        } catch { /* 静默失败 */ }
    }

    func refreshUser() async {
        guard let id = currentUser?.id else { return }
        do {
            let u = try await ApiClient.shared.getUser(id: id)
            currentUser = u
            AppConfig.user = u
        } catch { /* 静默失败 */ }
    }

    // MARK: - 会话消息

    func messages(for peerId: Int64) -> [ChatMessage] {
        messagesByPeer[peerId] ?? []
    }

    func unread(_ peerId: Int64) -> Int {
        unreadCounts[peerId] ?? 0
    }

    var totalPendingCount: Int { pendingRequests.count }

    func openConversation(peerId: Int64, isGroup: Bool) async {
        activePeerId = peerId
        unreadCounts[peerId] = 0
        // 历史只加载一次：已有缓存直接用，避免每次进入都重新请求
        guard !historyLoadedPeers.contains(peerId) else { return }
        do {
            let list: [ChatMessage]
            if isGroup {
                list = try await ApiClient.shared.groupHistory(groupId: peerId)
            } else {
                list = try await ApiClient.shared.singleHistory(peerId: peerId)
            }
            // 合并历史（历史在前，本地未完成的在后）
            let pendingLocal = (messagesByPeer[peerId] ?? []).filter { $0.localState == 0 }
            var merged = list
            for p in pendingLocal where !merged.contains(where: { $0.msgId == p.msgId }) {
                merged.append(p)
            }
            messagesByPeer[peerId] = merged
            historyLoadedPeers.insert(peerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeConversation(peerId: Int64) {
        if activePeerId == peerId { activePeerId = nil }
    }

    /// 会话 key：群聊用群 id；单聊用对方 id（自己发的取收件人，收到的取发件人）
    private func conversationKey(for msg: ChatMessage) -> Int64 {
        if msg.chatType == 2 { return msg.groupId ?? 0 }
        if msg.fromId == currentUser?.id { return msg.toId ?? 0 }
        return msg.fromId
    }

    private func appendIncoming(_ msg: ChatMessage) {
        let key = conversationKey(for: msg)
        var list = messagesByPeer[key] ?? []
        // 用 msgId 去重
        if list.contains(where: { $0.msgId == msg.msgId && !$0.msgId.isEmpty }) { return }
        list.append(msg)
        messagesByPeer[key] = list

        if activePeerId != key {
            unreadCounts[key] = (unreadCounts[key] ?? 0) + 1
            if msg.fromId != currentUser?.id {
                let senderName = friendName(msg.fromId) ?? "新消息"
                toastMessage = "\(senderName)：\(previewText(msg))"
            }
        }
    }

    private func previewText(_ msg: ChatMessage) -> String {
        switch msg.contentType {
        case "IMAGE": return "[图片]"
        case "FILE": return "[文件]"
        case "VOICE": return "[语音]"
        default: return msg.content ?? ""
        }
    }

    func friendName(_ id: Int64) -> String? {
        return friends.first(where: { $0.id == id })?.displayName
    }

    // MARK: - 发送消息

    /// 发送文本 / 媒体消息
    func sendMessage(to peerId: Int64,
                      isGroup: Bool,
                      contentType: String,
                      content: String,
                      fileUrl: String = "",
                      fileName: String = "",
                      fileSize: Int64 = 0,
                      duration: Int = 0) {
        let msgId = UUID().uuidString
        localIdSeed -= 1
        var msg = ChatMessage()
        msg.id = localIdSeed
        msg.msgId = msgId
        msg.fromId = currentUser?.id ?? 0
        if isGroup {
            msg.groupId = peerId
            msg.toId = nil
            msg.chatType = 2
        } else {
            msg.toId = peerId
            msg.groupId = nil
            msg.chatType = 1
        }
        msg.contentType = contentType
        msg.content = content
        msg.fileUrl = fileUrl
        msg.fileName = fileName
        msg.fileSize = fileSize
        msg.duration = duration
        msg.createdAt = AppConfig.nowString()
        msg.localState = 0

        var list = messagesByPeer[peerId] ?? []
        list.append(msg)
        messagesByPeer[peerId] = list

        var data: [String: Any] = [
            "msgId": msgId,
            "contentType": contentType,
            "content": content,
            "fileUrl": fileUrl,
            "fileName": fileName,
            "fileSize": fileSize,
            "duration": duration
        ]
        if isGroup {
            data["groupId"] = peerId
            ws.send(type: "CHAT_GROUP", data: data)
        } else {
            data["toId"] = peerId
            ws.send(type: "CHAT_SINGLE", data: data)
        }
    }

    /// 上传文件并返回相对 URL
    func upload(data: Data, fileName: String, mimeType: String) async -> UploadResult? {
        do {
            return try await ApiClient.shared.uploadFile(data: data, fileName: fileName, mimeType: mimeType)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - WS 事件分发

    private func handlePacket(type: String, data: [String: Any]?) {
        switch type {
        case "PONG":
            ws.notePong()
        case "ACK":
            if let data = data, let msg = decodeMessage(data) {
                handleAck(msg)
            }
        case "MESSAGE":
            if let data = data, let msg = decodeMessage(data) {
                appendIncoming(msg)
            }
        case "CALL":
            if let data = data { call.handleSignal(data) }
        case "CALL_SIGNAL":
            if let data = data { call.handleSignal(data) }
        case "FRIEND_REQUEST":
            handleFriendRequestEvent(data)
        case "ONLINE_STATUS":
            handleOnlineStatus(data)
        default:
            break
        }
    }

    private func decodeMessage(_ dict: [String: Any]) -> ChatMessage? {
        guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(ChatMessage.self, from: d)
    }

    private func handleAck(_ msg: ChatMessage) {
        let key = conversationKey(for: msg)
        var list = messagesByPeer[key] ?? []
        if let idx = list.firstIndex(where: { $0.msgId == msg.msgId }) {
            list[idx].localState = 1
            if msg.id > 0 { list[idx].id = msg.id }
            messagesByPeer[key] = list
        }
    }

    private func handleFriendRequestEvent(_ data: [String: Any]?) {
        guard let data = data else { return }
        let action = data["action"] as? String ?? ""
        if action == "new" {
            Task { await self.refreshPending() }
            toastMessage = "收到新的好友申请"
        } else if action == "accepted" {
            Task { await self.refreshFriends() }
            toastMessage = "好友申请已通过"
        }
    }

    private func handleOnlineStatus(_ data: [String: Any]?) {
        guard let data = data,
              let userId = (data["userId"] as? NSNumber)?.int64Value,
              let online = data["online"] as? Bool else { return }
        if let idx = friends.firstIndex(where: { $0.id == userId }) {
            friends[idx].online = online
        }
    }

    // MARK: - 好友业务

    func searchUser(_ keyword: String) async -> [UserInfo] {
        do { return try await ApiClient.shared.searchUser(keyword: keyword) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    func addFriend(toId: Int64, msg: String) async {
        do {
            try await ApiClient.shared.sendFriendRequest(toId: toId, msg: msg)
            toastMessage = "好友申请已发送"
        } catch { errorMessage = error.localizedDescription }
    }

    func handleRequest(_ request: PendingRequest, accept: Bool) async {
        do {
            try await ApiClient.shared.handleFriendRequest(requestId: request.requestId, accept: accept)
            pendingRequests.removeAll(where: { $0.requestId == request.requestId })
            if accept { await refreshFriends() }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteFriend(_ friendId: Int64) async {
        do {
            try await ApiClient.shared.deleteFriend(friendId: friendId)
            friends.removeAll(where: { $0.id == friendId })
            messagesByPeer[friendId] = nil
            unreadCounts[friendId] = nil
            historyLoadedPeers.remove(friendId)
        } catch { errorMessage = error.localizedDescription }
    }

    func setRemark(friendId: Int64, remark: String) async {
        do {
            try await ApiClient.shared.setRemark(friendId: friendId, remark: remark)
            if let idx = friends.firstIndex(where: { $0.id == friendId }) {
                friends[idx].remark = remark
            }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - 群组业务

    func createGroup(name: String, memberIds: [Int64]) async -> GroupItem? {
        do {
            let g = try await ApiClient.shared.createGroup(name: name, memberIds: memberIds)
            await refreshGroups()
            return g
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func groupMembers(_ groupId: Int64) async -> [GroupMember] {
        do { return try await ApiClient.shared.groupMembers(groupId: groupId) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    func inviteToGroup(groupId: Int64, userId: Int64) async {
        do {
            try await ApiClient.shared.inviteToGroup(groupId: groupId, userId: userId)
            toastMessage = "已邀请"
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - 个人资料

    func updateProfile(nickname: String, avatar: String) async {
        do {
            let u = try await ApiClient.shared.updateProfile(nickname: nickname, avatar: avatar)
            currentUser = u
            AppConfig.user = u
            toastMessage = "已保存"
        } catch { errorMessage = error.localizedDescription }
    }

    func changePassword(old: String, new: String) async -> Bool {
        do {
            try await ApiClient.shared.updatePassword(oldPassword: old, newPassword: new)
            toastMessage = "密码已修改"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func loadBark() async -> String {
        do { return try await ApiClient.shared.getBark().barkKey }
        catch { return "" }
    }

    func saveBark(_ key: String) async -> Bool {
        do {
            let r = try await ApiClient.shared.setBark(barkKey: key)
            toastMessage = "Bark 绑定已保存"
            return !r.barkKey.isEmpty || key.isEmpty
        } catch { errorMessage = error.localizedDescription; return false }
    }

    // MARK: - 通话

    func sendCallSignal(callId: String, toId: Int64, mode: String, action: String, payload: String?) {
        var data: [String: Any] = [
            "callId": callId,
            "toId": toId,
            "mode": mode,
            "action": action
        ]
        if let payload = payload {
            data["payload"] = payload
        } else {
            data["payload"] = NSNull()
        }
        ws.send(type: "CALL", data: data)
    }

    func currentUserName() -> String { currentUser?.displayName ?? "我" }
}
