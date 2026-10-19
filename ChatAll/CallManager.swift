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
    @Published var showUI = false
    @Published var peerName = ""
    @Published var isVideo = false
    @Published var statusText = ""
    @Published var muted = false
    @Published var remoteTrack: RTCVideoTrack? = nil
    @Published var localTrack: RTCVideoTrack? = nil

    weak var store: AppStore?

    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?

    private var callId = ""
    private var peerId: Int64 = 0
    private var mode = "AUDIO"
    private var isCaller = false
    private var isAccepted = false
    private var usingFrontCamera = true

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

    /// 静音切换
    func toggleMute() {
        muted.toggle()
        localAudioTrack?.isEnabled = !muted
    }

    /// 前后摄像头切换
    func switchCamera() {
        guard isVideo, let source = videoSource else { return }
        usingFrontCamera.toggle()
        capturer?.stopCapture()
        startCapture(source)
    }

    // MARK: - 内部流程

    private func beginCall(peerId: Int64, mode: String) {
        self.callId = UUID().uuidString
        self.peerId = peerId
        self.mode = mode
        self.isVideo = (mode == "VIDEO")
        self.isCaller = true
        self.isAccepted = false
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
        self.statusText = "已接通"
        sendSignal(action: "ACCEPT", payload: nil)
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
            self.peerName = store?.friendName(fromId) ?? "来电"
            self.statusText = self.isVideo ? "视频通话邀请" : "语音通话邀请"
            self.state = .incoming
            self.showUI = true

        case "ACCEPT":
            guard incomingCallId == callId else { return }
            isAccepted = true
            statusText = "已接通"
            state = .active
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
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
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
        }

        hasRemoteDescription = false
        pendingCandidates.removeAll()
    }

    private func teardownConnection() {
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

    private func teardown() {
        teardownConnection()
        state = .idle
        showUI = false
        peerName = ""
        statusText = ""
        isVideo = false
        muted = false
        isCaller = false
        isAccepted = false
        callId = ""
        peerId = 0
        try? RTCAudioSession.sharedInstance().setActive(false)
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
        guard let format = formats.last else { return }
        let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        cam.startCapture(with: device, format: format, fps: Int(fps))
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, with: [.defaultToSpeaker, .allowBluetooth])
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
