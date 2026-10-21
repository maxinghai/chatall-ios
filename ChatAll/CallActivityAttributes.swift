//
//  CallActivityAttributes.swift
//  ChatAll
//
//  语音通话实时活动（Live Activity / 灵动岛）的数据模型。
//  该文件同时被主 App 与 ChatAllWidget 扩展编译，两端类型定义必须保持一致。
//

import ActivityKit
import Foundation

struct CallActivityAttributes: ActivityAttributes {

    /// 动态内容：通话状态与静音状态
    struct ContentState: Codable, Hashable {
        var status: String
        var muted: Bool
    }

    /// 固定内容：对方昵称与通话开始时间（用于灵动岛计时）
    var peerName: String
    var startedAt: Date
}
