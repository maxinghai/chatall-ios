//
//  WsClient.swift
//  ChatAll
//
//  URLSessionWebSocketTask 封装：连接、25 秒 PING、收帧循环、断线 5 秒重连、上行发送、下行回调。
//

import Foundation

final class WsClient: NSObject {

    /// 下行回调：type + data(已解析为字典，无 data 时为 nil)
    var onPacket: ((String, [String: Any]?) -> Void)?
    /// 连接状态回调（true=已连接）
    var onStateChange: ((Bool) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectItem: DispatchWorkItem?

    private var token: String = ""
    private var shouldReconnect = false
    private var connected = false
    private let pingInterval: TimeInterval = 25
    private let reconnectDelay: TimeInterval = 5

    // MARK: - 连接管理

    func connect(token: String) {
        self.token = token
        shouldReconnect = true
        openSocket()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectItem?.cancel()
        reconnectItem = nil
        stopPing()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        setConnected(false)
    }

    private func openSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        stopPing()

        guard let url = AppConfig.wsURL(token: token) else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        setConnected(true)
        startPing()
        receiveLoop()
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

    // MARK: - PING

    private func startPing() {
        stopPing()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                self?.send(type: "PING", data: nil, completion: nil)
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
            switch result {
            case .failure:
                // 断线：尝试重连
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

    private func handleDisconnect() {
        setConnected(false)
        task = nil
        stopPing()
        scheduleReconnect()
    }

    // MARK: - 上行

    /// 发送任意报文
    func send(type: String, data: [String: Any]?, completion: (() -> Void)? = nil) {
        var packet: [String: Any] = ["type": type]
        if let data = data {
            packet["data"] = data
        }
        guard let json = try? JSONSerialization.data(withJSONObject: packet),
              let text = String(data: json, encoding: .utf8) else {
            completion?()
            return
        }
        sendRaw(text, completion: completion)
    }

    /// 发送原始文本
    func sendRaw(_ text: String, completion: (() -> Void)? = nil) {
        guard let task = task else {
            completion?()
            return
        }
        task.send(.string(text)) { _ in
            DispatchQueue.main.async { completion?() }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WsClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol: String?) {
        setConnected(true)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        handleDisconnect()
    }
}
