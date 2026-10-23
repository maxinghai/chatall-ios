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

    // MARK: ICE（STUN / TURN）

    /// TURN 中继（服务器部署 coturn 后填写，留空则只用 STUN）。
    /// 例：turn:43.248.188.28:3478?transport=udp
    static let turnURL = "turn:103.40.14.14:56368?transport=udp"
    static let turnUsername = "chatall"
    static let turnCredential = "chatall"

    /// 只取主机名（去掉协议前缀和端口）
    static var hostOnly: String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(of: ":") { h = String(h[..<i]) }
        return h
    }

    /// STUN 列表：自有服务器优先（部署 coturn 后可直连），
    /// 再兜底国内可达的公共 STUN——原 stun.l.google.com 在国内不可达，
    /// 会让 ICE 收集长时间等待，通话建立明显变慢。
    static var stunURLs: [String] {
        ["stun:\(hostOnly):3478",
         "stun:stun.qq.com:3478",
         "stun:stun.miwifi.com:3478",
         "stun:stun.chat.bilibili.com:3478"]
    }

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

    // MARK: Demo 模式（仅本地展示，不联网）

    private static let demoModeKey = "chatall.demoMode"
    /// Demo 模式开关：打开后跳过网络登录，直接展示 mock 数据
    static var demoMode: Bool {
        get { UserDefaults.standard.object(forKey: demoModeKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: demoModeKey) }
    }

    // MARK: 聊天背景（仅本地，不上传服务器）

    private static let bgImageKey = "chatall.backgroundFilename"
    private static let bgOpacityKey = "chatall.backgroundOpacity"

    /// 背景图存放目录：Application Support/backgrounds/
    static let backgroundsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let d = base.appendingPathComponent("backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: d,
                                                 withIntermediateDirectories: true)
        return d
    }()

    /// 当前背景图 URL（若未设置则 nil）
    static var backgroundImageURL: URL? {
        let fn = UserDefaults.standard.string(forKey: bgImageKey) ?? ""
        guard !fn.isEmpty else { return nil }
        let url = backgroundsDir.appendingPathComponent(fn)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 玻璃叠加层的不透明度：值越大底色越厚，背景图越不透。默认 0.55（比较通透）
    static var backgroundOpacity: Double {
        get { UserDefaults.standard.object(forKey: bgOpacityKey) as? Double ?? 0.55 }
        set { UserDefaults.standard.set(newValue, forKey: bgOpacityKey) }
    }

    /// 保存新背景图：压缩到屏幕分辨率 → JPEG 85% → 写到 backgroundsDir
    /// 同时删除旧图文件，避免磁盘累积
    @discardableResult
    static func saveBackgroundImage(_ image: UIImage) -> Bool {
        // 1) 缩放到屏幕尺寸，避免存 4K 照片占内存
        let screenSize = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let maxW = screenSize.width * scale
        let maxH = screenSize.height * scale
        let resized = downscale(image: image, maxPixels: CGSize(width: maxW, height: maxH))

        // 2) 旧图清理
        if let oldURL = backgroundImageURL {
            try? FileManager.default.removeItem(at: oldURL)
        }

        // 3) 新文件名固定，保证每次覆盖写
        let filename = "bg.jpg"
        let url = backgroundsDir.appendingPathComponent(filename)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.set(filename, forKey: bgImageKey)
            return true
        } catch {
            return false
        }
    }

    /// 清除背景图：删文件 + 清 UserDefaults
    static func clearBackground() {
        if let url = backgroundImageURL { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removeObject(forKey: bgImageKey)
    }

    /// 下采样（保持宽高比）
    private static func downscale(image: UIImage, maxPixels: CGSize) -> UIImage {
        let size = image.size
        let wScale = maxPixels.width / size.width
        let hScale = maxPixels.height / size.height
        let ratio = min(min(wScale, hScale), 1.0)
        guard ratio < 1 else { return image }
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: 时间格式化

    /// 服务端时间串常见格式（依次尝试）
    private static let serverFormats: [String] = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.SSS"
    ]

    private static let serverFormatters: [DateFormatter] = {
        serverFormats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = fmt
            return f
        }
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let serverFormatOutput: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// 解析服务端时间串（宽容模式：多种格式 + ISO8601 兜底），失败返回 nil
    static func parseDate(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        for fmt in serverFormatters {
            if let d = fmt.date(from: s) { return d }
        }
        return isoFormatter.date(from: s)
    }

    /// 生成当前时间串（本地上传用）
    static func nowString() -> String {
        return serverFormatOutput.string(from: Date())
    }

    // MARK: 微信风格时间格式化

    /// 聊天页时间分隔线格式（微信规则，带时分）：
    /// 今天 → HH:mm；昨天 → 昨天 HH:mm；本周非今昨 → 周X HH:mm；
    /// 当年非本周非昨 → M月D日 HH:mm；跨年 → YYYY年M月D日 HH:mm
    static func chatTimeString(_ s: String?) -> String {
        guard let date = parseDate(s) else { return "" }
        return chatTimeString(from: date)
    }

    /// 列表页右侧时间格式（微信规则，简洁版，不含时分；仅今天显示时分）：
    /// 今天 → HH:mm；昨天 → 昨天；本周非今昨 → 周X；当年 → M/D；跨年 → YYYY/M/D
    static func listTimeString(_ s: String?) -> String {
        guard let date = parseDate(s) else { return "" }
        let now = Date()
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")

        if cal.isDateInToday(date) {
            df.dateFormat = "HH:mm"
            return df.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "昨天" }

        // 本周内（周一~周日）
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        if date >= weekStart && date < now {
            let weekdayNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = cal.component(.weekday, from: date)
            return weekdayNames[weekday]
        }

        // 当年
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            df.dateFormat = "M/d"
            return df.string(from: date)
        }

        // 跨年
        df.dateFormat = "yyyy/M/d"
        return df.string(from: date)
    }

    private static func chatTimeString(from date: Date) -> String {
        let now = Date()
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")

        if cal.isDateInToday(date) {
            df.dateFormat = "HH:mm"
            return df.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            df.dateFormat = "'昨天' HH:mm"
            return df.string(from: date)
        }

        // 本周内（周一~周日）
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        if date >= weekStart {
            let weekdayNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = cal.component(.weekday, from: date)
            df.dateFormat = "HH:mm"
            return weekdayNames[weekday] + " " + df.string(from: date)
        }

        // 当年
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            df.dateFormat = "M月d日 HH:mm"
            return df.string(from: date)
        }

        // 跨年
        df.dateFormat = "yyyy年M月d日 HH:mm"
        return df.string(from: date)
    }

    /// 判断两条消息之间是否需要插入时间分隔线（微信规则）：
    /// - 两条不在同一天 → 显示
    /// - 间隔 > 5 分钟 → 显示
    /// - 任一条时间缺失 → 不显示（避免无意义分隔线）
    static func shouldShowSeparator(previous: String?, current: String?) -> Bool {
        guard let prevStr = previous, !prevStr.isEmpty,
              let curStr = current, !curStr.isEmpty else {
            return false
        }
        guard let prev = parseDate(prevStr), let cur = parseDate(curStr) else {
            return false
        }
        let cal = Calendar.current
        if !cal.isDate(prev, equalTo: cur, toGranularity: .day) { return true }
        let diff = cur.timeIntervalSince(prev)
        return diff > 300 // 5 分钟
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
