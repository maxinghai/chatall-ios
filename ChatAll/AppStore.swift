//
//  AppStore.swift
//  ChatAll
//
//  全局状态与业务逻辑：登录态、好友/群组/申请列表、未读计数、会话消息、WS 事件处理、各业务动作。
//

import Foundation
import SwiftUI

/// 顶部标题栏展示的连接状态
enum ConnectionState: Equatable {
    case offline
    case connecting
    case online

    var title: String {
        switch self {
        case .offline: return "离线"
        case .connecting: return "连接中"
        case .online: return "在线"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {

    // MARK: - 登录态
    @Published var token: String = ""
    @Published var currentUser: UserInfo? = nil
    @Published var isLoggedIn: Bool = false

    // MARK: - 连接状态
    @Published var connectionState: ConnectionState = .offline
    /// 通话界面显隐（镜像 CallManager.showUI，让 MainView 能可靠订阅）
    @Published var callUIVisible: Bool = false

    // MARK: - 列表数据
    @Published var friends: [FriendItem] = []
    @Published var groups: [GroupItem] = []
    @Published var pendingRequests: [PendingRequest] = []

    // MARK: - 动态（朋友圈）
    @Published var moments: [MomentItem] = []

    // MARK: - 消息
    /// peerKey -> 消息列表
    @Published var messagesByPeer: [Int64: [ChatMessage]] = [:]
    /// peerKey -> 未读数
    @Published var unreadCounts: [Int64: Int] = [:]
    /// 当前打开的会话（peerKey）
    @Published var activePeerId: Int64? = nil
    /// 当前打开的是否群聊（重连后补发已读用）
    private var activeIsGroup = false
    /// peerKey -> 最新一条消息的列表页预览文案
    @Published var lastPreviews: [Int64: String] = [:]
    /// peerKey -> 最新一条消息的时间串（已按微信列表规则格式化）
    @Published var lastTimes: [Int64: String] = [:]

    // MARK: - 提示
    @Published var errorMessage: String? = nil
    @Published var toastMessage: String? = nil

    // MARK: - 聊天背景（本地）
    /// 当前背景图 URL（nil = 未设置）。所有页面订阅它来重绘底图。
    @Published var backgroundURL: URL? = AppConfig.backgroundImageURL
    /// 玻璃叠加层不透明度（0.3~1.0）
    @Published var backgroundOpacity: Double = AppConfig.backgroundOpacity

    /// 应用新背景：保存到磁盘 + 广播给所有页面
    func setBackgroundImage(_ image: UIImage?) {
        guard let image else {
            AppConfig.clearBackground()
            _bgImageCache.removeAllObjects()
            backgroundURL = nil
            return
        }
        if AppConfig.saveBackgroundImage(image) {
            // 保存的是同一个 bg.jpg 路径，URL 不变，需要清缓存 + 强制刷新
            _bgImageCache.removeAllObjects()
            let url = AppConfig.backgroundImageURL
            backgroundURL = nil
            objectWillChange.send()
            backgroundURL = url
        } else {
            errorMessage = "背景图保存失败"
        }
    }

    func clearBackgroundImage() {
        AppConfig.clearBackground()
        _bgImageCache.removeAllObjects()
        backgroundURL = nil
    }

    func setBackgroundOpacity(_ value: Double) {
        AppConfig.backgroundOpacity = value
        backgroundOpacity = value
    }

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
        ws.onStatusChange = { [weak self] value in
            guard let self = self else { return }
            Task { @MainActor in
                switch value {
                case .offline: self.connectionState = .offline
                case .connecting: self.connectionState = .connecting
                case .online:
                    self.connectionState = .online
                    guard self.isLoggedIn else { return }
                    if self.everConnected {
                        // 断线重连成功：补拉列表与离线消息
                        Task { await self.reloadAll() }
                        // 断线期间可能漏收对方的已读回执，清掉"已加载"标记，
                        // 让会话再次打开时重新拉历史，校准已读/未读显示
                        self.historyLoadedPeers.removeAll()
                        if let peer = self.activePeerId {
                            Task { await self.openConversation(peerId: peer, isGroup: self.activeIsGroup) }
                        }
                    } else if let peer = self.activePeerId {
                        // 首次连接成功时若会话已打开，补发一次已读（连接建立前的 READ 会丢）
                        self.notifyRead(peerId: peer, isGroup: self.activeIsGroup)
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

        // 冷启动 / App 被杀后重开：还原登录态后必须主动重建连接，
        // 否则只有点击登录时才会连接，重进 App 会一直显示离线。
        if isLoggedIn {
            connectWS()
            Task { await reloadAll() }
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
        everConnected = false
        ws.connect(token: result.token, force: true)
        Task { await self.reloadAll() }
    }

    func logout() {
        ws.disconnect()
        call.reset()
        AppConfig.clearAuth()
        token = ""
        currentUser = nil
        isLoggedIn = false
        everConnected = false
        connectionState = .offline
        friends = []
        groups = []
        pendingRequests = []
        messagesByPeer = [:]
        unreadCounts = [:]
        activePeerId = nil
        activeIsGroup = false
        lastPreviews = [:]
        lastTimes = [:]
        historyLoadedPeers.removeAll()
        // 清空本地消息存储
        MessageStore.clearAll()
    }

    // MARK: - Demo 模式（仅本地展示，不联网）

    /// 进入 Demo 模式：跳过所有网络请求，直接注入 mock 数据
    func enterDemoMode() {
        AppConfig.demoMode = true
        let now = Date()
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let iso = { (offsetSec: TimeInterval) -> String in
            df.string(from: now.addingTimeInterval(-offsetSec))
        }

        var me = UserInfo()
        me.id = 1001; me.username = "demo"; me.nickname = "演示用户"
        currentUser = me
        token = "demo"
        isLoggedIn = true
        connectionState = .online

        // Mock 好友（自定义 init()，属性逐个赋值）
        var a = FriendItem(); a.id = 2001; a.username = "alice"; a.nickname = "爱丽丝"; a.remark = "好朋友"; a.online = true
        var b = FriendItem(); b.id = 2002; b.username = "bob"; b.nickname = "鲍勃"; b.online = false
        var c = FriendItem(); c.id = 2003; c.username = "carol"; c.nickname = "卡罗尔"; c.remark = "同事"; c.online = true
        var d = FriendItem(); d.id = 2004; d.username = "david"; d.nickname = "大卫"; d.online = false
        friends = [a, b, c, d]

        // Mock 群组
        var g1 = GroupItem(); g1.id = 3001; g1.name = "项目开发组"; g1.ownerId = 1001; g1.memberCount = 8
        var g2 = GroupItem(); g2.id = 3002; g2.name = "周末聚餐"; g2.ownerId = 2001; g2.memberCount = 12
        groups = [g1, g2]

        // Mock 消息
        messagesByPeer = [:]
        messagesByPeer[2001] = [
            demoMsg(id: 1, fromId: 2001, peerId: 2001, contentType: "TEXT", content: "明天一起吃饭？", createdAt: iso(120)),
            demoMsg(id: 2, fromId: 1001, peerId: 2001, contentType: "TEXT", content: "好啊，几点？", createdAt: iso(60)),
        ]
        messagesByPeer[2002] = [
            demoMsg(id: 3, fromId: 2002, peerId: 2002, contentType: "IMAGE", content: "", createdAt: iso(3600)),
        ]
        messagesByPeer[2003] = [
            demoMsg(id: 4, fromId: 2003, peerId: 2003, contentType: "TEXT", content: "下午的会议改到 3 点了", createdAt: iso(7200)),
        ]
        messagesByPeer[2004] = [
            demoMsg(id: 5, fromId: 2004, peerId: 2004, contentType: "VOICE", content: "", duration: 8, createdAt: iso(86400)),
        ]
        messagesByPeer[3001] = [
            demoMsg(id: 6, fromId: 2001, peerId: 3001, groupId: 3001, contentType: "TEXT", content: "大家今天辛苦了！", createdAt: iso(1800)),
            demoMsg(id: 7, fromId: 2002, peerId: 3001, groupId: 3001, contentType: "TEXT", content: "数据跑通了，发一下报告", createdAt: iso(900)),
        ]
        messagesByPeer[3002] = [
            demoMsg(id: 8, fromId: 2003, peerId: 3002, groupId: 3002, contentType: "FILE", content: "", fileName: "聚餐计划.pdf", createdAt: iso(43200)),
        ]

        unreadCounts = [2001: 2, 2003: 1, 3001: 1]
        reloadLastInfo()
    }

    /// 构造一条 demo 消息
    private func demoMsg(id: Int64, fromId: Int64, peerId: Int64,
                         groupId: Int64? = nil,
                         contentType: String,
                         content: String,
                         fileName: String? = nil,
                         duration: Int? = nil,
                         createdAt: String) -> ChatMessage {
        var m = ChatMessage()
        m.id = id
        m.msgId = "demo_\(id)"
        m.fromId = fromId
        m.toId = groupId == nil ? peerId : nil
        m.groupId = groupId
        m.chatType = groupId == nil ? 1 : 2
        m.contentType = contentType
        m.content = content
        m.fileName = fileName
        m.duration = duration
        m.status = 1
        m.localState = 1
        m.createdAt = createdAt
        return m
    }

    /// 退出 Demo 模式
    func exitDemoMode() {
        AppConfig.demoMode = false
        logout()
    }

    func connectWS() {
        guard !token.isEmpty else { return }
        ws.connect(token: token)
    }

    /// 进入前台时的连接自检：已登录则确保 socket 存在。
    /// connect 本身幂等；后台归来的强制重建由 WsClient 自己监听生命周期完成。
    func ensureConnected() {
        guard isLoggedIn, !token.isEmpty else { return }
        ws.connect(token: token)
    }

    // MARK: - 拉取数据

    func reloadAll() async {
        await refreshFriends()
        await refreshGroups()
        await refreshPending()
        await loadOffline()
        await refreshUnread()
        reloadLastInfo()
    }

    /// 刷新列表页的最新消息预览 + 时间（未加载过的会话从本地磁盘读取，冷启动也能显示）
    func reloadLastInfo() {
        var previews: [Int64: String] = [:]
        var times: [Int64: String] = [:]
        for f in friends {
            if let last = lastMessage(f.id) {
                let p = previewText(last)
                if !p.isEmpty { previews[f.id] = p }
                let t = AppConfig.listTimeString(last.createdAt)
                if !t.isEmpty { times[f.id] = t }
            }
        }
        for g in groups {
            if let last = lastMessage(g.id) {
                let p = previewText(last)
                if !p.isEmpty { previews[g.id] = p }
                let t = AppConfig.listTimeString(last.createdAt)
                if !t.isEmpty { times[g.id] = t }
            }
        }
        lastPreviews = previews
        lastTimes = times
    }

    private func lastMessage(_ peerId: Int64) -> ChatMessage? {
        let list = messagesByPeer[peerId] ?? MessageStore.load(peerId: peerId)
        return list.last
    }

    /// 某个会话的最后一条消息时间（内存没有则从磁盘读取），用于列表排序
    func lastMessageDate(for peerId: Int64) -> Date? {
        lastMessage(peerId).flatMap { AppConfig.parseDate($0.createdAt) }
    }

    /// 统一更新某个会话的最新预览 + 时间
    private func updateLastInfo(_ peerId: Int64, with msg: ChatMessage) {
        let p = previewText(msg)
        if !p.isEmpty { lastPreviews[peerId] = p }
        let t = AppConfig.listTimeString(msg.createdAt)
        if !t.isEmpty { lastTimes[peerId] = t }
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

    /// 用服务端口径校准单聊未读数（status < 2 即未读），群聊未读仍沿用本地计数
    func refreshUnread() async {
        guard let list = try? await ApiClient.shared.unreadCounts() else { return }
        // 先清掉所有单聊未读，只保留群聊（群 id）的本地计数
        let groupIds = Set(groups.map { $0.id })
        unreadCounts = unreadCounts.filter { groupIds.contains($0.key) }
        for item in list where item.count > 0 && item.peerId != activePeerId {
            unreadCounts[item.peerId] = item.count
        }
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
        activeIsGroup = isGroup
        unreadCounts[peerId] = 0

        // 本地优先：先从磁盘加载历史消息，瞬间渲染，避免空白等待网络
        if messagesByPeer[peerId] == nil {
            let local = MessageStore.load(peerId: peerId)
            messagesByPeer[peerId] = local
            if let last = local.last { updateLastInfo(peerId, with: last) }
        }

        // 真正打开会话 = 已读：通知服务端并让对方收到已读回执
        notifyRead(peerId: peerId, isGroup: isGroup)

        // 后台拉网络刷新；同一会话本生命周期内只拉一次
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
            if let last = merged.last { updateLastInfo(peerId, with: last) }
            historyLoadedPeers.insert(peerId)
            // 收到新消息后再补一次已读（历史里可能有打开前刚到达的未读消息）
            notifyRead(peerId: peerId, isGroup: isGroup)
            // 回写本地，下次冷启动直接显示
            MessageStore.save(peerId: peerId, messages: merged)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 上报会话已读（仅单聊有意义）。服务端会把对方发来的消息置为已读，并回推已读回执。
    /// 只表示"我读了对方的消息"，绝不能反过来推断"对方读了我的消息"。
    private func notifyRead(peerId: Int64, isGroup: Bool) {
        guard !isGroup, peerId > 0 else { return }
        ws.send(type: "READ", data: ["peerId": peerId])
    }

    func closeConversation(peerId: Int64) {
        if activePeerId == peerId {
            activePeerId = nil
            activeIsGroup = false
        }
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
        updateLastInfo(key, with: msg)
        // 持久化到本地
        MessageStore.save(peerId: key, messages: list)

        if activePeerId != key {
            unreadCounts[key] = (unreadCounts[key] ?? 0) + 1
            if msg.fromId != currentUser?.id {
                let senderName = friendName(msg.fromId) ?? "新消息"
                toastMessage = "\(senderName)：\(previewText(msg))"
            }
        } else if msg.chatType == 1 && msg.fromId != currentUser?.id {
            // 正停在这个会话里收到新消息：立即回报已读，让对方看到"已读"
            notifyRead(peerId: msg.fromId, isGroup: false)
        }
    }

    private func previewText(_ msg: ChatMessage) -> String {
        if msg.recalled {
            // 对方撤回的消息：列表预览不显示，避免干扰
            return ""
        }
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
        updateLastInfo(peerId, with: msg)
        // 持久化到本地（发送中态也保存，冷启动后仍显示）
        MessageStore.save(peerId: peerId, messages: list)

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
        case "READ_RECEIPT":
            // 对方读了我的消息：服务端已把消息置为已读，这里同步本地显示
            if let data = data, let readerId = (data["readerId"] as? NSNumber)?.int64Value {
                let lastReadId = (data["lastReadId"] as? NSNumber)?.int64Value ?? 0
                applyReadReceipt(readerId: readerId, lastReadId: lastReadId)
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
            // ACK 里若已带服务端已读态（重发幂等命中旧消息），同步显示
            if (msg.status ?? 0) >= 2 {
                list[idx].status = 2
                list[idx].readByPeer = true
            }
            messagesByPeer[key] = list
            // 回写本地（更新发送态）
            MessageStore.save(peerId: key, messages: list)
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
            lastPreviews[friendId] = nil
            lastTimes[friendId] = nil
            historyLoadedPeers.remove(friendId)
            // 同步删除本地消息文件
            MessageStore.remove(peerId: friendId)
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

    // MARK: - 动态（朋友圈）业务

    /// 拉取动态列表
    func refreshMoments() async {
        do {
            moments = try await ApiClient.shared.momentFeed()
        } catch { errorMessage = error.localizedDescription }
    }

    /// 发布动态
    func createMoment(content: String, images: [String]) async -> Bool {
        do {
            try await ApiClient.shared.createMoment(content: content, images: images)
            toastMessage = "发布成功"
            await refreshMoments()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// 点赞 / 取消点赞（本地乐观更新，失败回滚）
    func toggleMomentLike(momentId: Int64) async {
        guard let idx = moments.firstIndex(where: { $0.id == momentId }) else { return }
        let original = moments[idx]
        var updated = original
        updated.liked.toggle()
        updated.likeCount += updated.liked ? 1 : -1
        moments[idx] = updated

        do {
            let liked = try await ApiClient.shared.toggleMomentLike(momentId: momentId)
            // 以服务端返回为准
            if let i = moments.firstIndex(where: { $0.id == momentId }) {
                moments[i].liked = liked
            }
        } catch {
            // 回滚
            if let i = moments.firstIndex(where: { $0.id == momentId }) {
                moments[i] = original
            }
            errorMessage = error.localizedDescription
        }
    }

    /// 发表评论
    func addMomentComment(momentId: Int64, content: String) async {
        do {
            try await ApiClient.shared.addMomentComment(momentId: momentId, content: content)
            await refreshMoments()
        } catch { errorMessage = error.localizedDescription }
    }

    /// 删除动态
    func deleteMoment(momentId: Int64) async {
        do {
            try await ApiClient.shared.deleteMoment(momentId: momentId)
            moments.removeAll { $0.id == momentId }
            toastMessage = "已删除"
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

    // MARK: - 本地消息操作（撤回 / 删除 / 已读推断）

    /// 是否还在可撤回窗口（微信默认 2 分钟）
    static let recallWindowSeconds: TimeInterval = 120

    /// 判断一条消息是否还能撤回：必须是自己发的、已发出去（ACK）、2 分钟内、未被撤回过
    func canRecall(_ msg: ChatMessage) -> Bool {
        guard msg.fromId == (currentUser?.id ?? 0) else { return false }
        guard msg.localState != 0 else { return false }
        guard !msg.recalled else { return false }
        guard let date = AppConfig.parseDate(msg.createdAt) else { return true } // 时间缺失放宽限制
        return Date().timeIntervalSince(date) <= Self.recallWindowSeconds
    }

    /// 撤回消息（仅本地生效，对方仍能收到原消息）
    func recallMessage(peerId: Int64, msgId: String) {
        guard var list = messagesByPeer[peerId],
              let idx = list.firstIndex(where: { $0.msgId == msgId }) else { return }
        let msg = list[idx]
        guard canRecall(msg) else {
            toastMessage = "消息已超过 2 分钟，无法撤回"
            return
        }
        list[idx].recalled = true
        messagesByPeer[peerId] = list
        MessageStore.save(peerId: peerId, messages: list)

        // 撤回后重新计算列表页预览：跳过被撤回的消息，找最后一条"非撤回"的消息作预览
        rebuildLastInfo(peerId: peerId, from: list)
        toastMessage = "你撤回了一条消息"
    }

    /// 根据消息列表重建某个会话的列表页预览 + 时间（自动跳过 recalled）
    private func rebuildLastInfo(peerId: Int64, from list: [ChatMessage]) {
        guard let lastVisible = list.last(where: { !$0.recalled }) else {
            lastPreviews.removeValue(forKey: peerId)
            lastTimes.removeValue(forKey: peerId)
            return
        }
        lastPreviews[peerId] = previewText(lastVisible)
        lastTimes[peerId] = AppConfig.listTimeString(lastVisible.createdAt)
    }

    /// 删除消息（仅本地删除，数据库不受影响；用户明确说不改后端）
    func deleteMessage(peerId: Int64, msgId: String) {
        guard var list = messagesByPeer[peerId],
              let idx = list.firstIndex(where: { $0.msgId == msgId }) else { return }
        list.remove(at: idx)
        messagesByPeer[peerId] = list
        MessageStore.save(peerId: peerId, messages: list)
        if let last = list.last {
            updateLastInfo(peerId, with: last)
        } else {
            lastPreviews.removeValue(forKey: peerId)
            lastTimes.removeValue(forKey: peerId)
        }
    }

    /// 收到对方的已读回执：把该会话中自己已发出的、id 不超过 lastReadId 的消息标记为已读
    /// （lastReadId=0 表示服务端没给区间，退化为全部标记）
    private func applyReadReceipt(readerId: Int64, lastReadId: Int64) {
        guard var list = messagesByPeer[readerId], !list.isEmpty else { return }
        let myId = currentUser?.id ?? 0
        var changed = false
        for i in list.indices where list[i].chatType == 1 && list[i].fromId == myId {
            guard list[i].localState == 1, list[i].id > 0 else { continue }
            if lastReadId > 0 && list[i].id > lastReadId { continue }
            if !list[i].readByPeer || list[i].status != 2 {
                list[i].readByPeer = true
                list[i].status = 2
                changed = true
            }
        }
        if changed {
            messagesByPeer[readerId] = list
            MessageStore.save(peerId: readerId, messages: list)
        }
    }
}

// MARK: - 液态玻璃背景（跨页面共用）

/// 背景图缓存：避免每次视图刷新都从磁盘 UIImage(contentsOfFile:)
private var _bgImageCache: NSCache<NSURL, UIImage> = {
    let c = NSCache<NSURL, UIImage>()
    c.countLimit = 3
    return c
}()

/// 全页背景：若用户设置了背景图，底层放一张填满屏幕的 Image
struct ChatBackgroundImageView: View {
    let url: URL?
    var body: some View {
        if let url, let image = loadImage(url) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }

    /// 带缓存的图片加载：同一 URL 只从磁盘读一次
    private func loadImage(_ url: URL) -> UIImage? {
        if let cached = _bgImageCache.object(forKey: url as NSURL) {
            return cached
        }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        _bgImageCache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// 液态玻璃叠加层：Material + 系统底色的混合，支持透明度调节
/// - iOS 16+ 用 .ultraThinMaterial / .thinMaterial，不支持 Liquid Glass API
/// - iOS 26+ 可在外部用 .glassEffect 装饰本组件
struct LiquidGlassOverlay: View {
    let opacity: Double
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(.systemBackground)
                .opacity(opacity)
        }
        .allowsHitTesting(false)
    }
}

/// 把 List/Form 变成"透明底色 + 玻璃材质"的修饰器
/// 用法：list.liquidGlassList(opacity: store.backgroundOpacity)
/// opacity 越高 = 叠加的不透明涂层越厚 = 背景图越不容易透出来
struct LiquidGlassListModifier: ViewModifier {
    let opacity: Double
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)     // 隐藏 List 默认的整块白底
            .listRowBackground(Color.clear)       // 隐藏每一行自己的白底（关键！）
            .background(glassOverlay(opacity: opacity))
    }

    @ViewBuilder
    private func glassOverlay(opacity: Double) -> some View {
        // Material 本身就是玻璃模糊，后面叠一个可调不透明度的同色涂层
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // opacity 默认 0.55 比较通透；用户滑块范围 0.15~0.95
            Color(.systemBackground).opacity(opacity * 0.6)
        }
    }
}

extension View {
    func liquidGlassList(opacity: Double) -> some View {
        modifier(LiquidGlassListModifier(opacity: opacity))
    }
}

// MARK: - 液态玻璃栏（胶囊形，用于底部导航 / 快捷操作面板）

/// 胶囊形液态玻璃背景修饰器。
/// - iOS 26+：使用原生 `.glassEffect()` 液态玻璃效果（含系统自带的高光描边与投影）。
/// - iOS 16~25：回退到 `.ultraThinMaterial` + 系统底色叠加，保持通透观感。
///
/// 用法：`barContent.liquidGlassBar(opacity: store.backgroundOpacity)`
struct LiquidGlassBarModifier: ViewModifier {
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .background { barBackground }
    }

    @ViewBuilder
    private var barBackground: some View {
        if #available(iOS 26.0, *) {
            // 原生液态玻璃：填充胶囊底色后叠加 glassEffect，
            // 系统会自动渲染折射高光与柔和投影，无需手动加 border/shadow。
            Capsule()
                .fill(.background)
                .glassEffect()
        } else {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color(.systemBackground).opacity(opacity * 0.55))
            }
        }
    }
}

extension View {
    func liquidGlassBar(opacity: Double) -> some View {
        modifier(LiquidGlassBarModifier(opacity: opacity))
    }
}

/// 是否支持原生液态玻璃（iOS 26+）。
/// 用于在调用处决定是否还要叠加自定义描边/阴影（原生 glassEffect 已自带）。
var supportsNativeLiquidGlass: Bool {
    if #available(iOS 26.0, *) { return true }
    return false
}
