//
//  ImagePreviewView.swift
//  ChatAll
//
//  全屏图片预览：左右滑动切换图片、上下滑动关闭、双指缩放 + 放大拖动、缩小回弹。
//

import SwiftUI
import UIKit

struct ImagePreviewView: View {
    let urls: [URL]
    let currentIndex: Int

    @Environment(\.presentationMode) var presentationMode
    @State private var index: Int
    @State private var bgOpacity: Double = 1.0
    @State private var dragCloseOffset: CGFloat = 0
    @State private var isAnyZoomed: Bool = false

    init(urls: [URL], currentIndex: Int) {
        self.urls = urls
        self.currentIndex = currentIndex
        _index = State(initialValue: currentIndex)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(bgOpacity)
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    ZoomableImageView(url: url,
                                      isZoomedChanged: { zoomed in
                                          DispatchQueue.main.async {
                                              isAnyZoomed = zoomed
                                          }
                                      })
                    .tag(i)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragCloseOffset)
            .scaleEffect(1.0 - abs(dragCloseOffset) / 1200)
            // 未放大时，外层处理垂直向下关闭
            .simultaneousGesture(closeDragGesture)

            VStack {
                HStack {
                    Spacer()
                    if urls.count > 1 {
                        Text("\(index + 1) / \(urls.count)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(12)
                            .padding(.trailing, 8)
                    }
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
        .statusBar(hidden: true)
        .animation(.interpolatingSpring(stiffness: 300, damping: 30), value: dragCloseOffset)
    }

    // MARK: - 垂直向下关闭手势

    private var closeDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isAnyZoomed else { return }
                // 只响应向下滑动
                let dy = max(0, value.translation.height)
                dragCloseOffset = dy
                bgOpacity = max(0.3, 1.0 - dy / 400)
            }
            .onEnded { value in
                guard !isAnyZoomed else { return }
                let dy = max(0, value.translation.height)
                if dy > 120 {
                    withAnimation(.easeOut(duration: 0.25)) {
                        dragCloseOffset = dy + 200
                        bgOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        presentationMode.wrappedValue.dismiss()
                    }
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) {
                        dragCloseOffset = 0
                        bgOpacity = 1.0
                    }
                }
            }
    }
}

// MARK: - 单张可缩放图片

struct ZoomableImageView: View {
    let url: URL
    let isZoomedChanged: (Bool) -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var imageSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
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
                .background(
                    GeometryReader { imgGeo in
                        Color.clear
                            .onAppear { imageSize = imgGeo.size }
                            .onChange(of: imgGeo.size) { new in imageSize = new }
                    }
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnificationGesture)
                .simultaneousGesture(dragGesture(in: geo.size))
        }
        .clipped()
    }

    // MARK: - 双指缩放

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = max(1.0, min(5.0, lastScale * value))
                scale = newScale
            }
            .onEnded { value in
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 25)) {
                    if scale < 1.0 {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
                lastScale = scale
                isZoomedChanged(scale > 1.0)
            }
    }

    // MARK: - 放大后的拖动（边界约束；未放大时不处理，让 TabView 自由滑动）

    private func dragGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard scale > 1.0 else { return }

                let scaledW = max(imageSize.width * scale, viewSize.width)
                let scaledH = max(imageSize.height * scale, viewSize.height)
                let maxX = max(0, (scaledW - viewSize.width) / 2)
                let maxY = max(0, (scaledH - viewSize.height) / 2)

                var newX = lastOffset.width + value.translation.width
                var newY = lastOffset.height + value.translation.height
                newX = min(maxX, max(-maxX, newX))
                newY = min(maxY, max(-maxY, newY))
                offset = CGSize(width: newX, height: newY)
            }
            .onEnded { _ in
                lastOffset = offset
                if scale <= 1.0 {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 25)) {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }
}
