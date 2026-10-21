//
//  WsClient.swift
//  ChatAll
//
//  URLSessionWebSocketTask 封装：连接、25 秒 PING（含 PONG 看门狗）、收帧循环、
//  断线自动重连、回前台强制重建连接、上行发送、下行回调。
//

import Foundation
import UIKit

/// WebSocket 连接状态
enum WsStatus: Equatable {
    /// 未连接（已退出登录或未登录）
    case offline
    /// 正在建立连接 / 断线自动重连中
    case connecting
    /// 已连接
    case online
}

final class WsClient: NSObject {

    /// 下行回调：type + data(已解析为字典，无 data 时为 nil)
    var onPacket: ((String, [String: Any]?) -> Void)?
    /// 连接状态回调
    var onStatusChange: ((WsStatus) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectItem: DispatchWorkItem?
    private var openTimeoutItem: DispatchWorkItem?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var token: String = ""
    private var shouldReconnect = false
    private var status: WsStatus = .offline
    /// 是否经历过一次后台（回前台时无论本地状态如何都强制重建，避免系统挂断后的"假在线"）
    private var enteredBackground = false
    /// 最近一次收到服务端 PONG 的时间（看门狗用）
    private var lastPongAt = Date()
    private let pingInterval: TimeInterval = 25
    private let reconnectDelay: TimeInterval = 3
    private let openTimeout: TimeInterval = 15

    // MARK: - 连接管理

    /// 建立连接（幂等：已在连接或已连接时直接返回）。
    /// - Parameter force: true 时丢弃当前连接强制重建（回前台用）
    func connect(token: String, force: Bool = false) {
        self.token = token
        shouldReconnect = true
        registerLifecycle()
        if !force && (task != nil || status == .online) { return }
        closeTransport()
        openSocket()
    }

    func disconnect() {
        shouldReconnect = false
        enteredBackground = false
        unregisterLifecycle()
        closeTransport()
        setStatus(.offline)
    }

    /// App 回到前台：后台期间 socket 已被系统挂断，本地状态可能仍是"在线"，
    /// 因此必须强制重建，否则会一直处于收不到消息的假在线状态。
    func reconnectForForeground() {
        guard shouldReconnect else { return }
        closeTransport()
        openSocket()
    }

    /// 收到服务端 PONG
    func notePong() {
        lastPongAt = Date()
    }

    /// 当前是否已连接（前台自检用）
    var isConnected: Bool { status == .online }

    /// 关闭当前传输（定时器 + task + session），不动重连计划
    private func closeTransport() {
        reconnectItem?.cancel()
        reconnectItem = nil
        openTimeoutItem?.cancel()
        openTimeoutItem = nil
        stopPing()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func openSocket() {
        guard shouldReconnect, let url = AppConfig.wsURL(token: token) else { return }
        stopPing()
        reconnectItem?.cancel()
        reconnectItem = nil
        openTimeoutItem?.cancel()
        openTimeoutItem = nil

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        setStatus(.connecting)
        task.resume()

        // 连接超时保护：15 秒仍未打开则按断线处理（重连）
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.task === task, self.status != .online else { return }
            self.handleDisconnect()
        }
        openTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + openTimeout, execute: item)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectItem?.cancel()
        // 自动重连期间对外显示"连接中"
        setStatus(.connecting)
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            self.openSocket()
        }
        reconnectItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: item)
    }

    private func setStatus(_ value: WsStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.status != value {
                self.status = value
                self.onStatusChange?(value)
            }
        }
    }

    // MARK: - App 生命周期监听

    private func registerLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.enteredBackground = true
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleBecameActive()
        })
    }

    private func unregisterLifecycle() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    private func handleBecameActive() {
        guard shouldReconnect else { return }
        if enteredBackground {
            // 从后台回来：系统多半已挂断 socket，无条件重建
            enteredBackground = false
            reconnectForForeground()
        } else if task == nil {
            // 冷启动前注册竞态 / 连接被系统清理，补一次连接
            openSocket()
        }
    }

    // MARK: - PING

    private func startPing() {
        stopPing()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // 看门狗：超过两个周期没收到 PONG，视为假在线，强制重连
                if Date().timeIntervalSince(self.lastPongAt) > self.pingInterval * 2 + 5 {
                    self.handleDisconnect()
                    return
                }
                self.send(type: "PING", data: nil) { [weak self] error in
                    if error != nil { self?.handleDisconnect() }
                }
            }
        }
    }

    private func stopPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }

    // MARK: - 收帧

    private func receiveLoop() {
        guard let task = task else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            // 旧连接的迟到回调直接丢弃，避免误杀新连接
            guard self.task === task else { return }
            switch result {
            case .failure:
                self.handleDisconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleText(text)
                    }
                @unknown default:
                    break
                }
                // 继续接收下一帧
                self.receiveLoop()
            }
        }
    }

    /// 处理一条下行文本（URLSessionWebSocketTask 已保证帧完整性）
    private func handleText(_ text: String) {
        guard !text.isEmpty else { return }
        guard let data = text.data(using: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let type = obj["type"] as? String else { return }
        let payload = obj["data"] as? [String: Any]
        DispatchQueue.main.async { [weak self] in
            self?.onPacket?(type, payload)
        }
    }

    /// 断线处理：统一投递到主线程，并校验 session 未被替换，
    /// 避免旧连接的迟到回调误杀新连接。
    /// - Parameter trigger: 触发本次断线的 session（delegate 回调传入；
    ///   看门狗/发送失败等无上下文场景不传，默认取当前 session）
    private func handleDisconnect(trigger: URLSession? = nil) {
        let triggerSession = trigger ?? session
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.session === triggerSession,
                  self.session != nil else { return }
            self.performDisconnect()
        }
    }

    private func performDisconnect() {
        openTimeoutItem?.cancel()
        openTimeoutItem = nil
        stopPing()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if shouldReconnect {
            scheduleReconnect()
        } else {
            setStatus(.offline)
        }
    }

    // MARK: - 上行

    /// 发送任意报文
    func send(type: String, data: [String: Any]?, completion: ((Error?) -> Void)? = nil) {
        var packet: [String: Any] = ["type": type]
        if let data = data {
            packet["data"] = data
        }
        guard let json = try? JSONSerialization.data(withJSONObject: packet),
              let text = String(data: json, encoding: .utf8) else {
            completion?(NSError(domain: "WsClient", code: -1))
            return
        }
        sendRaw(text, completion: completion)
    }

    /// 发送原始文本
    func sendRaw(_ text: String, completion: ((Error?) -> Void)? = nil) {
        guard let task = task else {
            completion?(NSError(domain: "WsClient", code: -2))
            return
        }
        task.send(.string(text)) { error in
            DispatchQueue.main.async { completion?(error) }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WsClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol: String?) {
        DispatchQueue.main.async { [weak self] in
            // 旧连接的迟到回调直接丢弃
            guard let self = self, session === self.session else { return }
            self.lastPongAt = Date()
            self.openTimeoutItem?.cancel()
            self.openTimeoutItem = nil
            self.setStatus(.online)
            // 连接成功后启动收帧循环与心跳（09e4427 重构时遗漏，导致收不到消息）
            self.startPing()
            self.receiveLoop()
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard session === self.session else { return }
        handleDisconnect(trigger: session)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard session === self.session else { return }
        if error != nil { handleDisconnect(trigger: session) }
    }
}
