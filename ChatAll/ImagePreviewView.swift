//
//  ImagePreviewView.swift
//  ChatAll
//
//  全屏图片预览（仿微信）：
//  - 单击显示/隐藏顶部栏，双击以点击位置为中心放大/还原
//  - 双指缩放、放大后单指拖动查看，边界回弹
//  - 未放大时左右滑动切换图片、下拉关闭
//

import SwiftUI
import UIKit

struct ImagePreviewView: View {
    let urls: [URL]
    let currentIndex: Int

    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var bgOpacity: Double = 1
    @State private var chromeVisible = true
    @State private var isDismissing = false

    // 当前图片的缩放 / 位移
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStartScale: CGFloat = 1
    @State private var panStartOffset: CGSize = .zero
    @State private var isPinching = false

    // 手势状态
    @State private var dragAxis: DragAxis?
    @State private var pageDrag: CGFloat = 0
    @State private var closeDrag: CGFloat = 0
    @State private var lastTapTime = Date.distantPast
    @State private var pendingChromeWork: DispatchWorkItem?

    @State private var viewSize: CGSize = .zero
    /// 已加载图片的原始尺寸，用于计算放大后的拖动边界
    @State private var imageSizes: [URL: CGSize] = [:]

    private let maxScale: CGFloat = 4
    private let doubleTapScale: CGFloat = 2.5

    private enum DragAxis {
        case horizontal   // 左右翻页
        case vertical     // 下拉关闭
        case pan          // 放大后拖动图片
    }

    init(urls: [URL], currentIndex: Int) {
        self.urls = urls
        let start = urls.isEmpty ? 0 : max(0, min(currentIndex, urls.count - 1))
        self.currentIndex = start
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(bgOpacity)
                .ignoresSafeArea()

            GeometryReader { geo in
                let size = geo.size
                pager(size: size)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: size))
                    .simultaneousGesture(magnifyGesture(in: size))
                    .simultaneousGesture(tapGesture(in: size))
                    .offset(y: closeDrag)
                    .scaleEffect(closeScale(in: size))
                    .onAppear { viewSize = size }
                    .onChange(of: geo.size) { viewSize = $0 }
            }
            .ignoresSafeArea()

            chrome
        }
        .background(Color.black.ignoresSafeArea())
        .statusBar(hidden: true)
        .onChange(of: index) { _ in
            resetZoom()
        }
    }

    // MARK: - 分页容器

    /// 只渲染当前图片和左右相邻图片，翻页时前后图已就位
    private var visibleIndices: [Int] {
        [index - 1, index, index + 1].filter { $0 >= 0 && $0 < urls.count }
    }

    private func pager(size: CGSize) -> some View {
        ZStack {
            ForEach(visibleIndices, id: \.self) { i in
                PreviewPageView(url: urls[i],
                                isCurrent: i == index,
                                scale: scale,
                                offset: offset,
                                onLoaded: { naturalSize in
                                    imageSizes[urls[i]] = naturalSize
                                    if i == index {
                                        offset = clampOffset(offset, scale: scale, in: viewSize)
                                    }
                                })
                .frame(width: size.width, height: size.height)
                .offset(x: CGFloat(i - index) * size.width + pageDrag)
                .zIndex(i == index ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: - 顶部栏

    private var chrome: some View {
        VStack {
            ZStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    Spacer()
                }

                if urls.count > 1 {
                    Text("\(index + 1) / \(urls.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.35)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            Spacer()
        }
        .opacity(chromeOpacity)
        .allowsHitTesting(chromeVisible && !isDismissing)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
    }

    private var chromeOpacity: Double {
        guard chromeVisible else { return 0 }
        guard closeDrag > 0 else { return 1 }
        return max(0, 1 - Double(closeDrag / 200))
    }

    private func closeScale(in size: CGSize) -> CGFloat {
        guard size.height > 0 else { return 1 }
        return max(0.5, 1 - closeDrag / (size.height * 2))
    }

    // MARK: - 拖动：翻页 / 下拉关闭 / 放大后平移

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isDismissing, !isPinching else { return }

                // 放大状态：拖动查看图片
                if scale > 1.001 {
                    if dragAxis != .pan {
                        dragAxis = .pan
                        panStartOffset = offset
                    }
                    let proposed = CGSize(width: panStartOffset.width + value.translation.width,
                                          height: panStartOffset.height + value.translation.height)
                    offset = clampOffset(proposed, scale: scale, in: size)
                    return
                }

                // 首次变化时锁定方向，避免斜向拖动时同时翻页和关闭
                if dragAxis == nil {
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard max(abs(dx), abs(dy)) > 8 else { return }
                    dragAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                }

                switch dragAxis {
                case .some(.horizontal):
                    pageDrag = pageDragValue(for: value.translation.width, in: size)
                    closeDrag = 0
                case .some(.vertical):
                    let dy = max(0, value.translation.height)
                    closeDrag = dy
                    bgOpacity = max(0.3, 1 - Double(dy / 500))
                default:
                    break
                }
            }
            .onEnded { value in
                defer { dragAxis = nil }

                guard !isDismissing else { return }

                if dragAxis == .pan || scale > 1.001 {
                    withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                        offset = clampOffset(offset, scale: scale, in: size)
                    }
                    return
                }

                switch dragAxis {
                case .some(.horizontal):
                    finishPageDrag(value, in: size)
                case .some(.vertical):
                    finishCloseDrag(value, in: size)
                default:
                    break
                }
            }
    }

    private func pageDragValue(for dx: CGFloat, in size: CGSize) -> CGFloat {
        guard size.width > 0 else { return 0 }
        let atLeadingEdge = index == 0 && dx > 0
        let atTrailingEdge = index == urls.count - 1 && dx < 0
        if atLeadingEdge || atTrailingEdge {
            return dx * 0.25
        }
        return max(-size.width * 0.8, min(size.width * 0.8, dx))
    }

    private func finishPageDrag(_ value: DragGesture.Value, in size: CGSize) {
        guard size.width > 0 else { return }
        let dx = value.translation.width
        let predicted = value.predictedEndTranslation.width
        var target = index

        if abs(predicted) > size.width * 0.35 || abs(dx) > size.width * 0.18 {
            if predicted < 0 || (predicted == 0 && dx < 0) {
                target = min(urls.count - 1, index + 1)
            } else if predicted > 0 || (predicted == 0 && dx > 0) {
                target = max(0, index - 1)
            }
        }

        if target != index {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                index = target
                pageDrag = 0
            }
        } else {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                pageDrag = 0
            }
        }
    }

    private func finishCloseDrag(_ value: DragGesture.Value, in size: CGSize) {
        let dy = value.translation.height
        let predicted = value.predictedEndTranslation.height
        if dy > 120 || predicted > 300 {
            isDismissing = true
            dismiss()
        } else {
            withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                closeDrag = 0
                bgOpacity = 1
            }
        }
    }

    // MARK: - 双指缩放

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !isDismissing else { return }
                if !isPinching {
                    isPinching = true
                    dragAxis = nil
                    pageDrag = 0
                    closeDrag = 0
                    bgOpacity = 1
                    pinchStartScale = scale
                    panStartOffset = offset
                }
                let newScale = min(maxScale, max(1, pinchStartScale * value))
                scale = newScale
                offset = clampOffset(offset, scale: newScale, in: size)
            }
            .onEnded { _ in
                isPinching = false
                withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                    offset = clampOffset(offset, scale: scale, in: size)
                }
            }
    }

    // MARK: - 单击 / 双击

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !isDismissing else { return }
                let now = Date()
                if now.timeIntervalSince(lastTapTime) < 0.3 {
                    // 双击：以点击位置为中心放大 / 还原
                    lastTapTime = .distantPast
                    pendingChromeWork?.cancel()
                    pendingChromeWork = nil
                    toggleZoom(at: value.location, in: size)
                } else {
                    // 单击：等双击判定结束后再切换顶部栏
                    lastTapTime = now
                    let work = DispatchWorkItem {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            chromeVisible.toggle()
                        }
                    }
                    pendingChromeWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
            }
    }

    private func toggleZoom(at point: CGPoint, in size: CGSize) {
        if scale > 1.001 {
            withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                scale = 1
                offset = .zero
            }
        } else {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = CGPoint(x: point.x - center.x, y: point.y - center.y)
            withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                scale = doubleTapScale
                // 保持点击位置不动：O = p * (1 - S)
                offset = clampOffset(CGSize(width: -p.x * (doubleTapScale - 1),
                                            height: -p.y * (doubleTapScale - 1)),
                                     scale: doubleTapScale,
                                     in: size)
            }
        }
    }

    // MARK: - 缩放边界

    /// 图片按 aspect-fit 显示后的实际尺寸
    private func fittedSize(in size: CGSize) -> CGSize {
        guard urls.indices.contains(index) else { return size }
        let natural = imageSizes[urls[index]] ?? .zero
        guard natural.width > 0, natural.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let ratio = min(size.width / natural.width, size.height / natural.height)
        return CGSize(width: natural.width * ratio, height: natural.height * ratio)
    }

    private func clampOffset(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1.001 else { return .zero }
        let fitted = fittedSize(in: size)
        let maxX = max(0, (fitted.width * scale - size.width) / 2)
        let maxY = max(0, (fitted.height * scale - size.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
        isPinching = false
        dragAxis = nil
        pageDrag = 0
    }
}

// MARK: - 单张图片

private struct PreviewPageView: View {
    let url: URL
    let isCurrent: Bool
    let scale: CGFloat
    let offset: CGSize
    let onLoaded: (CGSize) -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(isCurrent ? scale : 1)
                        .offset(isCurrent ? offset : .zero)
                } else if failed {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.6))
                        Text("图片加载失败")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.75))
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: url) {
            failed = false
            image = nil
            if let img = await ImageCache.image(for: url) {
                image = img
                onLoaded(img.size)
            } else {
                failed = true
            }
        }
    }
}
