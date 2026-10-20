//
//  ImagePreviewView.swift
//  ChatAll
//
//  全屏图片预览：点击关闭，支持捏合缩放与拖动。
//

import SwiftUI

struct ImagePreviewView: View {
    let url: URL

    @Environment(\.presentationMode) var presentationMode
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CachedImage(url: url,
                        contentMode: .fit,
                        placeholder: { ProgressView().tint(.white) },
                        failure: {
                            VStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("图片加载失败")
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(5.0, lastScale * value))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.0 {
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )

            // 关闭按钮
            VStack {
                HStack {
                    Spacer()
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            presentationMode.wrappedValue.dismiss()
        }
        .statusBar(hidden: true)
    }
}
