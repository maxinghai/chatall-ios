//
//  RTCVideoView.swift
//  ChatAll
//
//  UIViewRepresentable 包装 RTCMTLVideoView（WebRTC Metal 渲染视图）。
//

import SwiftUI
import WebRTC

struct RTCVideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    /// 本地预览是否水平镜像
    var mirror: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        context.coordinator.view = view
        context.coordinator.attach(videoTrack, to: view)
        applyMirror(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.view = uiView
        context.coordinator.attach(videoTrack, to: uiView)
        applyMirror(uiView)
    }

    private func applyMirror(_ view: RTCMTLVideoView) {
        view.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    final class Coordinator {
        weak var view: RTCMTLVideoView?
        private var currentTrack: RTCVideoTrack?

        func attach(_ track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            if currentTrack === track { return }
            currentTrack?.remove(view)
            currentTrack = track
            track?.add(view)
        }
    }
}
