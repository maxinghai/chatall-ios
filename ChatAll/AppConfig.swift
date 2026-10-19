//
//  AppConfig.swift
//  ChatAll
//
//  服务器地址读写、http/ws 基址拼接、文件 URL 拼接、时间串格式化。
//

import Foundation
import SwiftUI

/// 全局配置（服务器地址存 UserDefaults）
enum AppConfig {

    /// 默认服务器地址
    static let defaultHost = "43.248.188.28:18422"

    private static let hostKey = "chatall.serverHost"
    private static let tokenKey = "chatall.token"
    private static let userKey = "chatall.user"

    // MARK: 服务器地址

    /// 当前服务器地址（host:port）
    static var host: String {
        get {
            let v = UserDefaults.standard.string(forKey: hostKey)
            if let v = v, !v.isEmpty { return v }
            return defaultHost
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hostKey)
        }
    }

    /// HTTP 基址，形如 http://43.248.188.28:18422
    static var httpBase: String {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("http://") || h.hasPrefix("https://") {
            return h.hasSuffix("/") ? String(h.dropLast()) : h
        }
        return "http://\(h)"
    }

    /// WebSocket 基址，形如 ws://43.248.188.28:18422/ws?token=xxx
    static func wsURL(token: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        var base: String
        if h.hasPrefix("http://") {
            base = "ws://" + h.dropFirst("http://".count)
        } else if h.hasPrefix("https://") {
            base = "wss://" + h.dropFirst("https://".count)
        } else if h.hasPrefix("ws://") || h.hasPrefix("wss://") {
            base = h
        } else {
            base = "ws://\(h)"
        }
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return URL(string: "\(base)/ws?token=\(encoded)")
    }

    // MARK: 文件 URL
    /// 把服务端返回的相对路径拼成完整 URL
    static func fileURL(_ path: String?) -> URL? {
        guard let path = path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        if path.hasPrefix("/") {
            return URL(string: httpBase + path)
        }
        return URL(string: httpBase + "/" + path)
    }

    // MARK: 登录信息持久化

    static var token: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    static var user: UserInfo? {
        get {
            guard let data = UserDefaults.standard.data(forKey: userKey) else { return nil }
            return try? JSONDecoder().decode(UserInfo.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(data, forKey: userKey)
            } else {
                UserDefaults.standard.removeObject(forKey: userKey)
            }
        }
    }

    static func clearAuth() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
    }

    // MARK: 时间格式化

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// 解析服务端本地时间串，失败返回 nil（不崩）
    static func parseDate(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        return formatter.date(from: s)
    }

    /// 显示时间：今天显示 HH:mm，否则显示 MM-dd HH:mm
    static func displayTime(_ s: String?) -> String {
        guard let s = s, !s.isEmpty else { return "" }
        guard let date = formatter.date(from: s) else {
            // 解析失败直接显示原串
            return s
        }
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            df.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            df.dateFormat = "'昨天' HH:mm"
        } else {
            df.dateFormat = "MM-dd HH:mm"
        }
        return df.string(from: date)
    }

    /// 生成当前时间串（本地上传用）
    static func nowString() -> String {
        return displayFormatter.string(from: Date())
    }

    /// 格式化时长（秒 → m:ss）
    static func durationText(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "0:00" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 主题色
extension Color {
    /// 微信绿 #07c160
    static let chatGreen = Color(red: 0.027, green: 0.757, blue: 0.376)
    /// 消息气泡灰色
    static let bubbleGray = Color(red: 0.92, green: 0.92, blue: 0.92)
}
