//
//  Models.swift
//  ChatAll
//
//  所有与后端交互的数据模型（REST 返回值与 WebSocket 下行共用）。
//  注意：id 一律使用 Int64，避免服务端 BIGINT 溢出。
//  所有非可选字段都用 decodeIfPresent + 默认值解码，服务端返回 null / 缺字段时不崩溃。
//

import Foundation

/// 后端统一响应包装：{"code":Int,"msg":String,"data":T}
struct ApiResponse<T: Codable>: Codable {
    var code: Int = -1
    var msg: String = ""
    var data: T? = nil

    enum CodingKeys: String, CodingKey {
        case code, msg, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decode(Int.self, forKey: .code)) ?? -1
        msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
        data = try? c.decodeIfPresent(T.self, forKey: .data)
    }

    init() {}
}

/// 用户信息
struct UserInfo: Codable, Identifiable, Equatable {
    var id: Int64 = 0
    var username: String = ""
    var nickname: String = ""
    var avatar: String = ""

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, avatar
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? ""
    }

    /// 显示名：优先昵称，其次用户名
    var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !username.isEmpty { return username }
        return "用户"
    }
}

/// 登录 / 注册返回：{token, user}
struct AuthResult: Codable {
    var token: String = ""
    var user: UserInfo = UserInfo()

    enum CodingKeys: String, CodingKey {
        case token, user
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = (try? c.decode(String.self, forKey: .token)) ?? ""
        user = (try? c.decode(UserInfo.self, forKey: .user)) ?? UserInfo()
    }
}

/// 好友列表项
struct FriendItem: Codable, Identifiable, Equatable {
    var id: Int64 = 0
    var username: String = ""
    var nickname: String = ""
    var avatar: String = ""
    var remark: String = ""
    var online: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, avatar, remark, online
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? ""
        remark = (try? c.decode(String.self, forKey: .remark)) ?? ""
        online = (try? c.decode(Bool.self, forKey: .online)) ?? false
    }

    /// 列表显示名：优先备注，其次昵称，其次用户名
    var displayName: String {
        if !remark.isEmpty { return remark }
        if !nickname.isEmpty { return nickname }
        if !username.isEmpty { return username }
        return "好友"
    }
}

/// 群组列表项
struct GroupItem: Codable, Identifiable, Equatable {
    var id: Int64 = 0
    var name: String = ""
    var avatar: String = ""
    var ownerId: Int64 = 0
    var memberCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, ownerId, memberCount
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? ""
        ownerId = (try? c.decode(Int64.self, forKey: .ownerId)) ?? 0
        memberCount = (try? c.decode(Int.self, forKey: .memberCount)) ?? 0
    }

    var displayName: String { name.isEmpty ? "群聊" : name }
}

/// 群成员
struct GroupMember: Codable, Identifiable, Equatable {
    var id: Int64 = 0
    var username: String = ""
    var nickname: String = ""
    var avatar: String = ""
    var role: String = ""

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, avatar, role
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? ""
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
    }

    var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !username.isEmpty { return username }
        return "成员"
    }
}

/// 好友申请（待处理）
struct PendingRequest: Codable, Identifiable, Equatable {
    var requestId: Int64 = 0
    var fromId: Int64 = 0
    var fromNickname: String = ""
    var fromUsername: String = ""
    var msg: String = ""

    enum CodingKeys: String, CodingKey {
        case requestId, fromId, fromNickname, fromUsername, msg
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = (try? c.decode(Int64.self, forKey: .requestId)) ?? 0
        fromId = (try? c.decode(Int64.self, forKey: .fromId)) ?? 0
        fromNickname = (try? c.decode(String.self, forKey: .fromNickname)) ?? ""
        fromUsername = (try? c.decode(String.self, forKey: .fromUsername)) ?? ""
        msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
    }

    var id: Int64 { requestId }

    var displayName: String {
        if !fromNickname.isEmpty { return fromNickname }
        if !fromUsername.isEmpty { return fromUsername }
        return "用户"
    }
}

/// 消息：REST 返回值与 WS 下行共用
struct ChatMessage: Codable, Identifiable, Equatable {
    var id: Int64 = 0
    var msgId: String = ""
    var fromId: Int64 = 0
    var toId: Int64? = nil
    var groupId: Int64? = nil
    /// 1 单聊 / 2 群聊
    var chatType: Int = 1
    /// TEXT / IMAGE / FILE / VOICE
    var contentType: String = "TEXT"
    var content: String? = nil
    var fileUrl: String? = nil
    var fileName: String? = nil
    var fileSize: Int64? = nil
    var duration: Int? = nil
    /// 服务端状态：0未送达 1已送达 2已读（单聊）
    var status: Int? = nil
    var createdAt: String? = nil

    /// 本地发送态：0=发送中 1=已发送（ACK 后置 1） 2=发送失败
    var localState: Int = 1

    /// 本地撤回标记：自己在 2 分钟内撤回的消息，仍然留在列表中但显示为灰色提示
    var recalled: Bool = false

    /// 对方已读：只以服务端 status=2（已读回执）为准，不再本地推断
    var readByPeer: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, msgId, fromId, toId, groupId, chatType, contentType
        case content, fileUrl, fileName, fileSize, duration, status, createdAt
        case localState, recalled, readByPeer
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        msgId = (try? c.decode(String.self, forKey: .msgId)) ?? ""
        fromId = (try? c.decode(Int64.self, forKey: .fromId)) ?? 0
        toId = try? c.decodeIfPresent(Int64.self, forKey: .toId)
        groupId = try? c.decodeIfPresent(Int64.self, forKey: .groupId)
        chatType = (try? c.decode(Int.self, forKey: .chatType)) ?? 1
        contentType = (try? c.decode(String.self, forKey: .contentType)) ?? "TEXT"
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        fileUrl = try? c.decodeIfPresent(String.self, forKey: .fileUrl)
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
        fileSize = try? c.decodeIfPresent(Int64.self, forKey: .fileSize)
        duration = try? c.decodeIfPresent(Int.self, forKey: .duration)
        let st = (try? c.decodeIfPresent(Int.self, forKey: .status)) ?? 0
        status = st
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        // 服务端消息默认已发送；本地存储读出的发送态需要保留
        localState = (try? c.decode(Int.self, forKey: .localState)) ?? 1
        // 本地字段：旧文件没有该 key 时默认 false，兼容冷启动读取旧 JSON
        recalled = (try? c.decode(Bool.self, forKey: .recalled)) ?? false
        // 已读状态以服务端 status 为准（2=已读）：
        // 旧版本"打开自己的会话即推断对方已读"把 readByPeer 写成了 true，这里不再采用本地值，
        // 避免历史脏数据继续显示"已读"。
        readByPeer = st >= 2
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(msgId, forKey: .msgId)
        try c.encode(fromId, forKey: .fromId)
        try c.encodeIfPresent(toId, forKey: .toId)
        try c.encodeIfPresent(groupId, forKey: .groupId)
        try c.encode(chatType, forKey: .chatType)
        try c.encode(contentType, forKey: .contentType)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(fileUrl, forKey: .fileUrl)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encodeIfPresent(fileSize, forKey: .fileSize)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(localState, forKey: .localState)
        try c.encode(recalled, forKey: .recalled)
        try c.encode(readByPeer, forKey: .readByPeer)
    }

    /// 会话标识：单聊用对方 id，群聊用群 id
    var peerKey: Int64 {
        if chatType == 2 { return groupId ?? 0 }
        return toId ?? 0
    }
}

/// 单聊未读统计（服务端返回 [{peerId, count}]）
struct UnreadCountItem: Codable {
    var peerId: Int64 = 0
    var count: Int = 0

    enum CodingKeys: String, CodingKey {
        case peerId, count
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peerId = (try? c.decode(Int64.self, forKey: .peerId)) ?? 0
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

/// 文件上传返回
struct UploadResult: Codable {
    var url: String = ""
    var name: String = ""
    var size: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case url, name, size
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
    }
}

/// Bark 绑定信息
struct BarkInfo: Codable {
    var barkKey: String = ""

    enum CodingKeys: String, CodingKey {
        case barkKey
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        barkKey = (try? c.decode(String.self, forKey: .barkKey)) ?? ""
    }
}
