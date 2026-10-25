//
//  CallManager.swift
//  ChatAll
//
//  通话状态机与 WebRTC 信令：idle / calling / incoming / active。
//  信令时序严格与其它端一致：
//    主叫 INVITE(payload=null) → 被叫 ACCEPT → 主叫发 SDP(offer)
//    → 被叫 setRemote 后回 SDP(answer) → 两端 setLocalDescription 后逐个发 ICE。
//  收到早于 setRemoteDescription 的 SDP/ICE 会排队缓存。
//

import Foundation
import AVFoundation
import AVKit
import CoreMedia
import UIKit
import WebRTC

enum CallState: Int {
    case idle = 0
    case calling = 1
    case incoming = 2
    case active = 3
}

@MainActor
final class CallManager: NSObject, ObservableObject {

    @Published var state: CallState = .idle
    @Published var showUI = false {
        didSet {
            if oldValue != showUI { onShowUIChange?(showUI) }
        }
    }
    /// showUI 变化回调（AppStore 用它镜像到 callUIVisible 供视图订阅）
    var onShowUIChange: ((Bool) -> Void)?
    @Published var peerName = ""
    @Published var isVideo = false
    @Published var statusText = "" {
        didSet {
            if oldValue != statusText { syncLiveActivity() }
        }
    }
    @Published var muted = false
    /// 扬声器开关（音频通话用）
    @Published var speakerOn = true
    @Published var remoteTrack: RTCVideoTrack? = nil {
        didSet {
            // 远端视频轨道到来时，把 PiP 渲染器挂上去（仅视频通话）
            guard isVideo, let renderer = pipRenderer else { return }
            oldValue?.remove(renderer)
            remoteTrack?.add(renderer)
        }
    }
    @Published var localTrack: RTCVideoTrack? = nil

    weak var store: AppStore?

    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?

    // MARK: - 画中画（PiP）
    /// 把 WebRTC 远端视频帧喂给系统 PiP 窗口的渲染器
    private var pipRenderer: PiPVideoRenderer?
    /// 系统画中画控制器（仅视频通话使用）
    private var pipController: AVPictureInPictureController?
    /// App 进入后台 / 回到前台的通知监听
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private var callId = ""
    private var peerId: Int64 = 0
    private var mode = "AUDIO"
    private var isCaller = false
    private var isAccepted = false
    private var usingFrontCamera = true
    /// 通话接通的时刻，未接通为 nil（用于结束时统计通话时长）
    private var activeSince: Date?

    private var hasRemoteDescription = false
    private var pendingCandidates: [RTCIceCandidate] = []

    // MARK: - 对外动作

    /// 发起通话
    func startCall(peerId: Int64, mode: String) {
        guard state == .idle else { return }
        Task { @MainActor in
            let ok = await requestPermissions(video: mode == "VIDEO")
            guard ok else {
                self.store?.errorMessage = "缺少麦克风或摄像头权限"
                return
            }
            self.beginCall(peerId: peerId, mode: mode)
        }
    }

    /// 接听来电
    func acceptCall() {
        guard state == .incoming else { return }
        Task { @MainActor in
            let ok = await self.requestPermissions(video: self.isVideo)
            guard ok else {
                self.store?.errorMessage = "缺少麦克风或摄像头权限"
                return
            }
            self.answerIncoming()
        }
    }

    /// 挂断 / 拒绝 / 取消
    func hangup() {
        guard state != .idle else {
            teardown()
            return
        }
        if state == .incoming {
            sendSignal(action: "REJECT", payload: nil)
        } else if state == .calling && !isAccepted {
            sendSignal(action: "CANCEL", payload: nil)
        } else {
            sendSignal(action: "HANGUP", payload: nil)
        }
        teardown()
    }

    /// 全部清理（登出时调用）
    func reset() {
        teardown()
    }

    /// 收起通话页（不挂断）：视频转悬浮小窗，语音转悬浮电话图标
    func minimizeUI() {
        guard state == .active || state == .calling else { return }
        if showUI { showUI = false }
    }

    /// 从悬浮小窗恢复通话页
    func restoreUI() {
        guard state != .idle else { return }
        if !showUI { showUI = true }
    }

    /// 静音切换
    func toggleMute() {
        muted.toggle()
        localAudioTrack?.isEnabled = !muted
        syncLiveActivity()
    }

    /// 扬声器 / 听筒切换
    func toggleSpeaker() {
        speakerOn.toggle()
        configureAudioSession()
    }

    /// 前后摄像头切换
    func switchCamera() {
        guard isVideo, let source = videoSource else { return }
        usingFrontCamera.toggle()
        capturer?.stopCapture()
        startCapture(source)
    }

    // MARK: - 画中画（PiP）

    /// 创建 PiP 渲染器与控制器。远端轨道尚未到来时先占位，轨道就绪后由 didSet 自动挂载。
    private func setupPictureInPicture() {
        guard pipRenderer == nil else { return }
        let renderer = PiPVideoRenderer()
        self.pipRenderer = renderer
        // 如果远端轨道已经就绪，立即挂载
        remoteTrack?.add(renderer)

        let layer = renderer.displayLayer
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
        layer.videoGravity = .resizeAspectFill

        let contentSource = AVPictureInPictureController
            .ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: renderer)
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        self.pipController = controller
    }

    /// App 进入后台时：若正在视频通话，自动弹出系统画中画
    private func startPictureInPictureIfNeeded() {
        guard state == .active, isVideo,
              let pip = pipController,
              pip.isPictureInPicturePossible,
              !pip.isPictureInPictureActive else { return }
        pip.startPictureInPicture()
    }

    /// 停止画中画（回到前台或通话结束时调用）
    private func stopPictureInPicture() {
        guard let pip = pipController, pip.isPictureInPictureActive else { return }
        pip.stopPictureInPicture()
    }

    /// 监听前后台切换：后台自动开 PiP，前台自动关 PiP
    private func startLifecycleObservation() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.startPictureInPictureIfNeeded()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.stopPictureInPicture()
            }
        }
    }

    private func stopLifecycleObservation() {
        if let obs = backgroundObserver {
            NotificationCenter.default.removeObserver(obs)
            backgroundObserver = nil
        }
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
    }

    // MARK: - 内部流程

    private func beginCall(peerId: Int64, mode: String) {
        self.callId = UUID().uuidString
        self.peerId = peerId
        self.mode = mode
        self.isVideo = (mode == "VIDEO")
        self.isCaller = true
        self.isAccepted = false
        self.activeSince = nil
        self.peerName = store?.friendName(peerId) ?? "对方"
        self.statusText = "正在呼叫…"

        teardownConnection()
        preparePeerConnection()

        self.state = .calling
        self.showUI = true
        configureAudioSession()

        // 主叫先发 INVITE（payload 为 null）
        sendSignal(action: "INVITE", payload: nil)
    }

    private func answerIncoming() {
        // 被叫：建立连接后回 ACCEPT
        teardownConnection()
        preparePeerConnection()
        configureAudioSession()
        self.isAccepted = true
        self.state = .active
        if activeSince == nil { activeSince = Date() }
        self.statusText = "已接通"
        sendSignal(action: "ACCEPT", payload: nil)
        // 语音通话接通后进入灵动岛 / 锁屏实时活动
        syncLiveActivity()
    }

    // MARK: - 信令处理

    func handleSignal(_ data: [String: Any]) {
        let incomingCallId = data["callId"] as? String ?? ""
        let fromId = int64Value(data["fromId"]) ?? int64Value(data["toId"]) ?? 0
        let incomingMode = data["mode"] as? String ?? "AUDIO"
        let action = data["action"] as? String ?? ""
        let payload = data["payload"] as? String

        switch action {
        case "INVITE":
            // 已在通话中 → 忙线
            if state != .idle {
                store?.sendCallSignal(callId: incomingCallId, toId: fromId,
                                      mode: incomingMode, action: "REJECT", payload: "busy")
                return
            }
            self.callId = incomingCallId
            self.peerId = fromId
            self.mode = incomingMode
            self.isVideo = (incomingMode == "VIDEO")
            self.isCaller = false
            self.isAccepted = false
            self.activeSince = nil
            self.peerName = store?.friendName(fromId) ?? "来电"
            self.statusText = self.isVideo ? "视频通话邀请" : "语音通话邀请"
            self.state = .incoming
            self.showUI = true

        case "ACCEPT":
            guard incomingCallId == callId else { return }
            isAccepted = true
            statusText = "已接通"
            state = .active
            if activeSince == nil { activeSince = Date() }
            // 语音通话接通后进入灵动岛 / 锁屏实时活动
            syncLiveActivity()
            // 主叫收到 ACCEPT 后创建 offer
            if isCaller { createOffer() }

        case "SDP":
            guard let payload = payload,
                  let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sdp = obj["sdp"] as? String else { return }
            let type = obj["type"] as? String ?? "offer"
            if type == "offer" {
                setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] in
                    self?.createAnswer()
                }
            } else {
                setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp), completion: nil)
            }

        case "ICE":
            guard let payload = payload,
                  let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sdp = obj["sdp"] as? String else { return }
            let mid = obj["sdpMid"] as? String ?? "0"
            let index = Int32(int64Value(obj["sdpMLineIndex"]) ?? 0)
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
            addCandidate(candidate)

        case "HANGUP", "CANCEL", "REJECT":
            if state != .idle {
                teardown()
                store?.toastMessage = "通话已结束"
            }

        default:
            break
        }
    }

    // MARK: - PeerConnection

    private func ensureFactory() -> RTCPeerConnectionFactory {
        if let f = factory { return f }
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                         decoderFactory: RTCDefaultVideoDecoderFactory())
        factory = f
        return f
    }

    private func preparePeerConnection() {
        let f = ensureFactory()

        let config = RTCConfiguration()
        var iceServers: [RTCIceServer] = []
        if !AppConfig.stunURLs.isEmpty {
            iceServers.append(RTCIceServer(urlStrings: AppConfig.stunURLs))
        }
        if !AppConfig.turnURL.isEmpty,
           !AppConfig.turnUsername.isEmpty,
           !AppConfig.turnCredential.isEmpty {
            // WebRTC 不允许 TURN 凭证为空；匿名 coturn 也需在客户端填任意非空值
            iceServers.append(RTCIceServer(urlStrings: [AppConfig.turnURL],
                                           username: AppConfig.turnUsername,
                                           credential: AppConfig.turnCredential))
        }
        config.iceServers = iceServers
        // 预收集候选，缩短建立通话的等待时间
        config.iceCandidatePoolSize = 2
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = f.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return
        }
        self.pc = pc

        // 音频轨道
        let audioSource = f.audioSource(with: constraints)
        let audioTrack = f.audioTrack(with: audioSource, trackId: "audio0")
        self.localAudioTrack = audioTrack
        pc.add(audioTrack, streamIds: ["stream0"])

        // 视频轨道（仅视频通话）
        if isVideo {
            let source = f.videoSource()
            self.videoSource = source
            let videoTrack = f.videoTrack(with: source, trackId: "video0")
            self.localVideoTrack = videoTrack
            self.localTrack = videoTrack
            pc.add(videoTrack, streamIds: ["stream0"])
            startCapture(source)
            // 准备画中画：创建渲染器 + PiP 控制器，等远端轨道到来后自动挂载
            setupPictureInPicture()
            startLifecycleObservation()
        }

        hasRemoteDescription = false
        pendingCandidates.removeAll()
    }

    private func teardownConnection() {
        // 把 PiP 渲染器从远端轨道上摘掉（避免野指针回调）
        if let renderer = pipRenderer {
            remoteTrack?.remove(renderer)
        }
        capturer?.stopCapture()
        capturer = nil
        pc?.close()
        pc = nil
        videoSource = nil
        localVideoTrack = nil
        localAudioTrack = nil
        remoteTrack = nil
        localTrack = nil
        hasRemoteDescription = false
        pendingCandidates.removeAll()
    }

    /// 主叫在通话接通后写一条通话记录消息：[[call:voice|video:秒数]]
    private func recordCallIfNeeded() {
        guard isCaller, let started = activeSince, peerId != 0 else { return }
        activeSince = nil
        let seconds = max(1, Int(Date().timeIntervalSince(started).rounded()))
        let content = "[[call:\(isVideo ? "video" : "voice"):\(seconds)]]"
        store?.sendMessage(to: peerId, isGroup: false, contentType: "TEXT", content: content)
    }

    private func teardown() {
        // 先写通话记录（内部依赖 peerId / isCaller，需在状态清空前调用）
        recordCallIfNeeded()
        // 先关闭灵动岛实时活动，再清理通话状态
        CallLiveActivityController.shared.end()
        // 停止画中画并释放相关资源
        stopPictureInPicture()
        pipController = nil
        pipRenderer = nil
        stopLifecycleObservation()
        teardownConnection()
        state = .idle
        showUI = false
        peerName = ""
        statusText = ""
        isVideo = false
        muted = false
        speakerOn = true
        isCaller = false
        isAccepted = false
        activeSince = nil
        callId = ""
        peerId = 0
        try? RTCAudioSession.sharedInstance().setActive(false)
    }

    /// 语音通话实时活动：接通后开启/更新，视频通话不进入灵动岛
    private func syncLiveActivity() {
        guard !isVideo, state == .active else { return }
        let live = CallLiveActivityController.shared
        if live.isActive {
            live.update(status: statusText, muted: muted)
        } else {
            live.start(peerName: peerName, status: statusText, muted: muted)
        }
    }

    // MARK: - SDP / ICE

    private func mediaConstraints() -> RTCMediaConstraints {
        let mandatory: [String: String] = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": isVideo ? "true" : "false"
        ]
        return RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
    }

    private func createOffer() {
        guard let pcRef = pc else { return }
        pcRef.offer(for: mediaConstraints()) { [weak self] sdp, error in
            guard let self = self, error == nil, let sdp = sdp else { return }
            self.pc?.setLocalDescription(sdp) { error in
                DispatchQueue.main.async {
                    if error == nil { self.sendSdpDescription(sdp, type: "offer") }
                }
            }
        }
    }

    private func createAnswer() {
        guard let pcRef = pc else { return }
        pcRef.answer(for: mediaConstraints()) { [weak self] sdp, error in
            guard let self = self, error == nil, let sdp = sdp else { return }
            self.pc?.setLocalDescription(sdp) { error in
                DispatchQueue.main.async {
                    if error == nil { self.sendSdpDescription(sdp, type: "answer") }
                }
            }
        }
    }

    private func setRemoteDescription(_ desc: RTCSessionDescription, completion: (() -> Void)?) {
        guard let pcRef = pc else { return }
        pcRef.setRemoteDescription(desc) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error == nil {
                    self.hasRemoteDescription = true
                    self.flushPendingCandidates()
                    completion?()
                }
            }
        }
    }

    private func addCandidate(_ candidate: RTCIceCandidate) {
        guard hasRemoteDescription, let pcRef = pc else {
            pendingCandidates.append(candidate)
            return
        }
        pcRef.add(candidate)
    }

    private func flushPendingCandidates() {
        guard let pcRef = pc, hasRemoteDescription else { return }
        for candidate in pendingCandidates {
            pcRef.add(candidate)
        }
        pendingCandidates.removeAll()
    }

    private func sendSdpDescription(_ sdp: RTCSessionDescription, type: String) {
        let dict: [String: Any] = ["type": type, "sdp": sdp.sdp]
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: d, encoding: .utf8) else { return }
        sendSignal(action: "SDP", payload: text)
    }

    private func sendIceCandidate(_ candidate: RTCIceCandidate) {
        let dict: [String: Any] = [
            "sdpMid": candidate.sdpMid ?? "0",
            "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            "sdp": candidate.sdp
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: d, encoding: .utf8) else { return }
        sendSignal(action: "ICE", payload: text)
    }

    private func sendSignal(action: String, payload: String?) {
        guard !callId.isEmpty, peerId != 0 else { return }
        store?.sendCallSignal(callId: callId, toId: peerId,
                              mode: mode, action: action, payload: payload)
    }

    // MARK: - 采集 & 音频

    private func startCapture(_ source: RTCVideoSource) {
        let cam = RTCCameraVideoCapturer(delegate: source)
        self.capturer = cam
        let devices = RTCCameraVideoCapturer.captureDevices()
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
            return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // 选最接近 1280x720 的格式：原来取 formats.last（常见 4K/1080p60），
        // 采集与编码开销过大会导致画面卡顿、首帧延迟。
        var best: AVCaptureDevice.Format?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for f in formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard let range = f.videoSupportedFrameRateRanges.first, range.maxFrameRate >= 24 else { continue }
            let score = abs(CGFloat(dims.width) - 1280) + abs(CGFloat(dims.height) - 720)
            if score < bestScore {
                bestScore = score
                best = f
            }
        }
        guard let format = best ?? formats.last else { return }
        let maxFps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        let fps = min(maxFps, 30)
        cam.startCapture(with: device, format: format, fps: Int(fps))
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            if speakerOn {
                try session.setCategory(.playAndRecord, with: [.defaultToSpeaker, .allowBluetooth])
            } else {
                try session.setCategory(.playAndRecord, with: [.allowBluetooth])
            }
        } catch { }
        try? session.setActive(true)
        session.unlockForConfiguration()
    }

    private func requestPermissions(video: Bool) async -> Bool {
        let audioOK = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard video else { return audioOK }
        let videoOK = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        return audioOK && videoOK
    }

    // MARK: - 工具

    private func int64Value(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension CallManager: @preconcurrency RTCPeerConnectionDelegate {

    // 协议要求但业务上不需要的方法，缺任意一个都会导致 "does not conform" 编译错误
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let track = stream.videoTracks.first {
                self.remoteTrack = track
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch newState {
            case .connected, .completed:
                self.statusText = "通话中"
            case .failed:
                self.statusText = "连接失败"
                self.hangup()
            case .disconnected:
                self.statusText = "连接中断"
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            self?.sendIceCandidate(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let track = rtpReceiver.track as? RTCVideoTrack {
                self.remoteTrack = track
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension CallManager: AVPictureInPictureControllerDelegate {

    /// 用户点击 PiP 窗口的「返回」按钮，回到 App —— 恢复通话页
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoreUI()
        completionHandler(true)
    }

    /// 用户手动关闭 PiP（点 X）：通话不挂断，保持音频继续，等待用户回到 App
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    }

    /// PiP 启动失败（通常是系统资源不足或用户关闭了多任务），不影响通话本身
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
    }
}

// MARK: - PiP 视频渲染器

/// 把 WebRTC 远端视频帧逐帧喂给 AVSampleBufferDisplayLayer，
/// 再由 AVPictureInPictureController 把这个 layer 渲染到系统画中画窗口。
///
/// 帧来源有两种：
///   - RTCCVPixelBuffer：VideoToolbox 解码后的 CVPixelBuffer，直接用
///   - RTCI420Buffer：兜底用 vImage 转成 32BGRA 的 CVPixelBuffer
final class PiPVideoRenderer: NSObject, RTCVideoRenderer {

    /// 交给 AVPictureInPictureController 的显示层
    let displayLayer = AVSampleBufferDisplayLayer()

    /// 逐帧递增的展示时间戳（PiP 需要每帧有不同的 PTS，否则会丢帧）
    private var lastPts: CMTime = .zero

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
    }

    // MARK: - RTCVideoRenderer

    func setSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.frame = CGRect(origin: .zero, size: size)
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame,
              let pixelBuffer = Self.pixelBuffer(from: frame.buffer) else { return }

        // 用递增的 PTS 构造 sample buffer（30fps 步进）
        lastPts = CMTimeAdd(lastPts, CMTime(value: 1, timescale: 30))
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: lastPts,
            decodeTimeStamp: .invalid
        )

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return }

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sb = sampleBuffer else { return }

        // enqueue 必须在主线程
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.enqueue(sb)
        }
    }

    // MARK: - 帧缓冲转换

    private static func pixelBuffer(from buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let cv = buffer as? RTCCVPixelBuffer {
            return cv.pixelBuffer
        }
        // 兜底：I420 → 32BGRA
        return convertI420ToPixelBuffer(buffer.toI420())
    }

    /// 用手写整数运算把 I420 转为 32BGRA 的 CVPixelBuffer。
    /// PiP 窗口尺寸小，逐像素转换的性能够用，且不依赖 Accelerate/vImage 的复杂签名。
    private static func convertI420ToPixelBuffer(_ i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
        ) == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        let yBase = i420.dataY
        let uBase = i420.dataU
        let vBase = i420.dataV
        let strideY = Int(i420.strideY)
        let strideU = Int(i420.strideU)
        let strideV = Int(i420.strideV)

        let dstBytes = dst.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let yRow = yBase + y * strideY
            let uRow = uBase + (y / 2) * strideU
            let vRow = vBase + (y / 2) * strideV
            let outRow = dstBytes + y * dstBytesPerRow

            for x in 0..<width {
                let yVal = Int(yRow[x])
                let uVal = Int(uRow[x / 2]) - 128
                let vVal = Int(vRow[x / 2]) - 128

                // BT.601 整数系数（×256 避免浮点）
                var r = (256 * yVal + 359 * vVal) >> 8
                var g = (256 * yVal - 88 * uVal - 183 * vVal) >> 8
                var b = (256 * yVal + 454 * uVal) >> 8

                r = max(0, min(255, r))
                g = max(0, min(255, g))
                b = max(0, min(255, b))

                // 32BGRA 内存布局：B, G, R, A
                let px = x * 4
                outRow[px]     = UInt8(b)
                outRow[px + 1] = UInt8(g)
                outRow[px + 2] = UInt8(r)
                outRow[px + 3] = 255
            }
        }
        return pb
    }
}

// MARK: - PiP 播放代理

/// 实时通话画面没有播放/暂停/进度概念：时间范围声明为无限、始终保持播放，
/// 系统就不会在画中画窗口里显示进度条和暂停控件。
extension PiPVideoRenderer: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        // 直播流：忽略播放/暂停请求
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
