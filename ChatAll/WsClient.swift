//
//  WsClient.swift
//  ChatAll
//
//  URLSessionWebSocketTask 封装：连接、25 秒 PING（含 PONG 看门狗）、收帧循环、
//  断线自动重连、回前台强制重建连接、上行发送、下行回调。
//

import Foundation
import UIKit

final class WsClient: NSObject {

    /// 下行回调：type + data(已解析为字典，无 data 时为 nil)
    var onPacket: ((String, [String: Any]?) -> Void)?
    /// 连接状态回调（true=已连接）
    var onStateChange: ((Bool) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectItem: DispatchWorkItem?
    private var openTimeoutItem: DispatchWorkItem?
    private var foregroundObserver: NSObjectProtocol?

    private var token: String = ""
    private var shouldReconnect = false
    private var connected = false
    /// 最近一次收到服务端 PONG 的时间（看门狗用）
    private var lastPongAt = Date()
    private let pingInterval: TimeInterval = 25
    private let reconnectDelay: TimeInterval = 3
    private let openTimeout: TimeInterval = 15

    // MARK: - 连接管理

    func connect(token: String) {
        self.token = token
        shouldReconnect = true
        registerForeground()
        openSocket()
    }

    func disconnect() {
        shouldReconnect = false
        unregisterForeground()
        closeTransport()
        setConnected(false)
    }

    /// App 回到前台：后台期间 socket 已被系统挂断，强制重建连接
    func reconnectForForeground() {
        guard shouldReconnect else { return }
        closeTransport()
        setConnected(false)
        openSocket()
    }

    /// 收到服务端 PONG
    func notePong() {
        lastPongAt = Date()
    }

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
        openTimeoutItem?.cancel()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // 连接超时保护：15 秒仍未打开则按断线处理（重连）
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.task === task, !self.connected else { return }
            self.handleDisconnect()
        }
        openTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + openTimeout, execute: item)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            self.openSocket()
        }
        reconnectItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: item)
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.connected != value {
                self.connected = value
                self.onStateChange?(value)
            }
        }
    }

    // MARK: - 前台监听

    private func registerForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reconnectForForeground()
        }
    }

    private func unregisterForeground() {
        if let o = foregroundObserver { NotificationCenter.default.removeObserver(o) }
        foregroundObserver = nil
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
    private func handleDisconnect() {
        let staleSession = session
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.session === staleSession else { return }
            self.performDisconnect()
        }
    }

    private func performDisconnect() {
        openTimeoutItem?.cancel()
        openTimeoutItem = nil
        setConnected(false)
        stopPing()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        scheduleReconnect()
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
            self.setConnected(true)
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard session === self.session else { return }
        handleDisconnect()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard session === self.session else { return }
        if error != nil { handleDisconnect() }
    }
}
