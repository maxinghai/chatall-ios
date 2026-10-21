//
//  CallView.swift
//  ChatAll
//
//  通话界面：来电弹窗（接听/拒绝）、通话中（远端大画面 + 本地小窗 + 挂断/静音/切换摄像头）。
//  本地小窗可拖动、点击可切换主画面；通话页可收起为悬浮小窗（视频）或悬浮电话图标（语音）。
//

import SwiftUI
import WebRTC

struct CallView: View {
    @ObservedObject var call: CallManager

    /// true 时主画面显示自己、小窗显示对方
    @State private var selfAsMain = false
    /// 小窗中心位置（相对通话页安全区）
    @State private var pipCenter: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var pipMoved = false

    private let pipSize = CGSize(width: 110, height: 160)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if call.state == .incoming {
                incomingView
            } else {
                activeView
            }
        }
        .statusBar(hidden: true)
    }

    // MARK: - 来电

    private var incomingView: some View {
        VStack(spacing: 24) {
            Spacer()

            AvatarView(name: call.peerName, avatar: "", size: 100)

            Text(call.peerName)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white)

            Text(call.isVideo ? "邀请你进行视频通话" : "邀请你进行语音通话")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            HStack(spacing: 70) {
                VStack(spacing: 8) {
                    Button {
                        call.hangup()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.white)
                            .frame(width: 68, height: 68)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    Text("拒绝").foregroundColor(.white.opacity(0.8))
                }

                VStack(spacing: 8) {
                    Button {
                        call.acceptCall()
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.white)
                            .frame(width: 68, height: 68)
                            .background(Color.chatGreen)
                            .clipShape(Circle())
                    }
                    Text("接听").foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.bottom, 60)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - 通话中

    private var activeView: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if call.isVideo {
                    // 主画面：点击小窗后切换为自己/对方
                    RTCVideoView(videoTrack: selfAsMain ? call.localTrack : call.remoteTrack,
                                 mirror: selfAsMain)
                        .ignoresSafeArea()
                } else {
                    audioInfo
                }

                // 本地小窗：可拖动，轻点切换主画面
                if call.isVideo {
                    pipView
                        .frame(width: pipSize.width, height: pipSize.height)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                        .position(pipCenter ?? defaultPipCenter(geo.size))
                        .gesture(pipGesture(geo.size))
                }

                // 状态（视频模式下显示在控制栏上方）
                if call.isVideo {
                    VStack {
                        Spacer()
                        Text(call.statusText.isEmpty ? "通话中" : call.statusText)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.bottom, 140)
                    }
                }

                // 控制栏
                VStack {
                    Spacer()
                    HStack(spacing: 28) {
                        controlButton(icon: call.muted ? "mic.slash.fill" : "mic.fill",
                                      title: call.muted ? "已静音" : "静音",
                                      background: Color.white.opacity(0.2)) {
                            call.toggleMute()
                        }

                        controlButton(icon: "chevron.down", title: "收起",
                                      background: Color.white.opacity(0.2)) {
                            call.minimizeUI()
                        }

                        controlButton(icon: "phone.down.fill", title: "挂断", background: Color.red) {
                            call.hangup()
                        }

                        if call.isVideo {
                            controlButton(icon: "arrow.triangle.2.circlepath.camera",
                                          title: "翻转",
                                          background: Color.white.opacity(0.2)) {
                                call.switchCamera()
                            }
                        } else {
                            controlButton(icon: call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill",
                                          title: call.speakerOn ? "扬声器" : "听筒",
                                          background: Color.white.opacity(0.2)) {
                                call.toggleSpeaker()
                            }
                        }
                    }
                    .padding(.bottom, 50)
                }
            }
        }
        .background(Color.black)
    }

    private var audioInfo: some View {
        VStack(spacing: 16) {
            Spacer()
            AvatarView(name: call.peerName, avatar: "", size: 110)
            Text(call.peerName)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)
            Text(call.statusText.isEmpty ? "通话中" : call.statusText)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
        }
    }

    /// 小窗内容：主画面为自己时小窗显示对方，反之显示自己（镜像）
    private var pipView: some View {
        RTCVideoView(videoTrack: selfAsMain ? call.remoteTrack : call.localTrack,
                     mirror: !selfAsMain)
            .background(Color.black)
    }

    private func defaultPipCenter(_ bounds: CGSize) -> CGPoint {
        CGPoint(x: bounds.width - 16 - pipSize.width / 2,
                y: 40 + pipSize.height / 2)
    }

    private func clampPip(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let minX = pipSize.width / 2 + 8
        let maxX = max(minX, bounds.width - pipSize.width / 2 - 8)
        let minY = pipSize.height / 2 + 8
        let maxY = max(minY, bounds.height - pipSize.height / 2 - 80)
        return CGPoint(x: min(max(minX, point.x), maxX),
                       y: min(max(minY, point.y), maxY))
    }

    /// 小窗拖动手势：移动超过阈值算拖动，否则算点击切换画面
    private func pipGesture(_ bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? pipCenter ?? defaultPipCenter(bounds)
                if dragStart == nil { dragStart = start }
                if abs(value.translation.width) + abs(value.translation.height) > 4 {
                    pipMoved = true
                }
                pipCenter = clampPip(CGPoint(x: start.x + value.translation.width,
                                             y: start.y + value.translation.height),
                                     in: bounds)
            }
            .onEnded { _ in
                dragStart = nil
                if !pipMoved { selfAsMain.toggle() }
                pipMoved = false
            }
    }

    private func controlButton(icon: String, title: String, background: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(background)
                    .clipShape(Circle())
            }
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - 悬浮小窗（收起通话页后仍显示在页面上）

struct CallMiniOverlay: View {
    @ObservedObject var call: CallManager
    var onOpen: () -> Void

    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var moved = false

    private var miniSize: CGSize {
        call.isVideo ? CGSize(width: 112, height: 164) : CGSize(width: 62, height: 62)
    }

    var body: some View {
        GeometryReader { geo in
            if call.state != .idle && !call.showUI {
                content
                    .frame(width: miniSize.width, height: miniSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: call.isVideo ? 12 : 31))
                    .overlay(RoundedRectangle(cornerRadius: call.isVideo ? 12 : 31)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
                    .position(center ?? defaultCenter(geo.size))
                    .gesture(gesture(geo.size))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if call.isVideo {
            ZStack(alignment: .bottomLeading) {
                RTCVideoView(videoTrack: call.remoteTrack)
                Text(call.peerName)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(4)
                    .padding(6)
            }
            .background(Color.black)
        } else {
            ZStack {
                Color.chatGreen
                Image(systemName: "phone.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
            }
        }
    }

    private func defaultCenter(_ bounds: CGSize) -> CGPoint {
        if call.isVideo {
            return CGPoint(x: bounds.width - miniSize.width / 2 - 12,
                           y: 60 + miniSize.height / 2)
        }
        return CGPoint(x: bounds.width - miniSize.width / 2 - 16,
                       y: 80 + miniSize.height / 2)
    }

    private func clamp(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let minX = miniSize.width / 2 + 8
        let maxX = max(minX, bounds.width - miniSize.width / 2 - 8)
        let minY = miniSize.height / 2 + 8
        let maxY = max(minY, bounds.height - miniSize.height / 2 - 80)
        return CGPoint(x: min(max(minX, point.x), maxX),
                       y: min(max(minY, point.y), maxY))
    }

    private func gesture(_ bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? center ?? defaultCenter(bounds)
                if dragStart == nil { dragStart = start }
                if abs(value.translation.width) + abs(value.translation.height) > 4 {
                    moved = true
                }
                center = clamp(CGPoint(x: start.x + value.translation.width,
                                       y: start.y + value.translation.height),
                               in: bounds)
            }
            .onEnded { _ in
                dragStart = nil
                if !moved { onOpen() }
                moved = false
            }
    }
}
