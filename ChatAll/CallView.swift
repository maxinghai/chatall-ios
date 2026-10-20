//
//  CallView.swift
//  ChatAll
//
//  通话界面：来电弹窗（接听/拒绝）、通话中（远端大画面 + 本地小窗 + 挂断/静音/切换摄像头）。
//

import SwiftUI
import WebRTC

struct CallView: View {
    @ObservedObject var call: CallManager

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
        ZStack {
            if call.isVideo {
                // 远端画面
                RTCVideoView(videoTrack: call.remoteTrack)
                    .ignoresSafeArea()
            } else {
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

            // 本地小窗
            if call.isVideo {
                VStack {
                    HStack {
                        Spacer()
                        RTCVideoView(videoTrack: call.localTrack, mirror: true)
                            .frame(width: 110, height: 160)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.3), lineWidth: 1))
                            .padding(.top, 40)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }

            // 状态（视频模式下显示在底部上方）
            if call.isVideo {
                VStack {
                    Spacer()
                    Text(call.statusText.isEmpty ? "通话中" : call.statusText)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.bottom, 130)
                }
            }

            // 控制栏
            VStack {
                Spacer()
                HStack(spacing: 44) {
                    controlButton(icon: call.muted ? "mic.slash.fill" : "mic.fill",
                                  title: call.muted ? "已静音" : "静音",
                                  background: Color.white.opacity(0.2)) {
                        call.toggleMute()
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
        .background(Color.black)
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
