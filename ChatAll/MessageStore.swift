//
//  MessageStore.swift
//  ChatAll
//
//  本地消息持久化：每个会话一个 JSON 文件，存于 Application Support/messages/。
//  打开会话时优先读本地（瞬间显示），再后台拉网络刷新并回写本地。
//

import Foundation

enum MessageStore {

    /// 本地消息目录：Application Support/messages/
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let d = base.appendingPathComponent("messages", isDirectory: true)
        try? FileManager.default.createDirectory(at: d,
                                                 withIntermediateDirectories: true)
        return d
    }()

    private static func file(for peerId: Int64) -> URL {
        dir.appendingPathComponent("\(peerId).json")
    }

    /// 读取某会话的本地消息（无则返回空数组）
    static func load(peerId: Int64) -> [ChatMessage] {
        let url = file(for: peerId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    /// 保存某会话的全部消息（覆盖写）
    static func save(peerId: Int64, messages: [ChatMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: file(for: peerId), options: .atomic)
    }

    /// 删除某会话消息（删除好友时）
    static func remove(peerId: Int64) {
        try? FileManager.default.removeItem(at: file(for: peerId))
    }

    /// 清空所有本地消息（登出时）
    static func clearAll() {
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
