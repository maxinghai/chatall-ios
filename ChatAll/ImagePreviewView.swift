//
//  ImagePreviewView.swift
//  ChatAll
//
//  全屏图片预览（仿微信）：
//  - 展开：hero 层从气泡 frame 平滑放大到全屏 fit（固定时长，避免 spring 时序错位）
//  - 关闭：支持任意方向拖拽 / 双指捏合缩小 / 点击返回，缩回气泡或淡出
//  - 左右翻页、双指缩放、双击 2x 放大到点击位置、放大后拖动
//  - 顶部栏：返回 / 页码 / 更多（保存图片）
//

import SwiftUI
import UIKit

struct ImagePreviewView: View {
    let urls: [URL]
    let currentIndex: Int
    let sourceFrame: CGRect?
    let onDismiss: () -> Void

    @State private var index: Int
    @State private var bgOpacity: Double = 0
    @State private var chromeVisible = true
    @State private var isDismissing = false

    /// hero 过渡阶段
    private enum HeroPhase { case idle, expanding, showing, closing }
    @State private var heroPhase: HeroPhase = .idle
    @State private var heroFrame: CGRect = .zero
    @State private var heroImage: UIImage?
    @State private var heroCornerRadius: CGFloat = 10

    // 缩放 & 平移（当前页）
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStartScale: CGFloat = 1
    @State private var panStartOffset: CGSize = .zero
    @State private var isPinching = false

    // 手势轴
    @State private var dragAxis: DragAxis?
    @State private var pageDrag: CGFloat = 0
    /// 拖拽关闭时的 2D 位移（任意方向）
    @State private var dismissOffset: CGSize = .zero
    @State private var lastTapTime = Date.distantPast
    @State private var pendingChromeWork: DispatchWorkItem?

    @State private var viewSize: CGSize = .zero
    @State private var imageSizes: [URL: CGSize] = [:]

    @State private var showActionSheet = false
    @State private var toast: String?

    private let maxScale: CGFloat = 4
    private let doubleTapScale: CGFloat = 2
    private let enterDuration: Double = 0.32
    private let exitDuration: Double = 0.26

    private enum DragAxis {
        case horizontal
        case dismiss
        case pan
    }

    init(urls: [URL],
         currentIndex: Int,
         sourceFrame: CGRect?,
         onDismiss: @escaping () -> Void) {
        self.urls = urls
        let start = urls.isEmpty ? 0 : max(0, min(currentIndex, urls.count - 1))
        self.currentIndex = start
        self.sourceFrame = sourceFrame
        self.onDismiss = onDismiss
        _index = State(initialValue: start)
    }

    var body: some View {
        GeometryReader { geo in
            let screenRect = CGRect(origin: .zero, size: geo.size)

            ZStack {
                // 蒙板（整层忽略安全区，使本地坐标 == .global，与气泡 sourceFrame 对齐）
                Color.black.opacity(bgOpacity)

                // pager 内容
                pager(size: geo.size)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: geo.size))
                    .simultaneousGesture(magnifyGesture(in: geo.size))
                    .simultaneousGesture(tapGesture(in: geo.size))
                    .offset(x: dismissOffset.width, y: dismissOffset.height)
                    .scaleEffect(dismissScale)
                    .opacity(heroPhase == .showing ? 1 : 0)
                    .allowsHitTesting(heroPhase == .showing)
                    .onChange(of: geo.size) { viewSize = $0 }

                // hero 过渡层
                heroLayer

                chrome
                    .padding(.top, safeAreaTop)
                    .opacity(chromeOpacity)
                    .allowsHitTesting(heroPhase == .showing && !isDismissing)
            }
            .ignoresSafeArea()
            .statusBar(hidden: true)
            .onAppear {
                viewSize = geo.size
                playEnterAnimation(in: screenRect)
            }
            .onChange(of: index) { _ in resetZoom() }
            .confirmationDialog("操作", isPresented: $showActionSheet, titleVisibility: .hidden) {
                Button("保存图片") { saveCurrentImage() }
                Button("取消", role: .cancel) {}
            }
            .overlay(alignment: .center) {
                if let toast = toast {
                    Text(toast)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - hero 过渡层

    @ViewBuilder
    private var heroLayer: some View {
        if let image = heroImage, (heroPhase == .expanding || heroPhase == .closing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: heroFrame.width, height: heroFrame.height)
                .position(x: heroFrame.midX, y: heroFrame.midY)
                .cornerRadius(heroCornerRadius)
                .clipped()
        }
    }

    // MARK: - 展开 / 关闭动画

    private func playEnterAnimation(in screenRect: CGRect) {
        guard let source = sourceFrame else {
            withAnimation(.easeOut(duration: enterDuration)) {
                bgOpacity = 1
            }
            heroPhase = .showing
            return
        }

        heroPhase = .expanding
        heroFrame = source
        heroCornerRadius = 10
        heroImage = nil

        Task { @MainActor in
            let img = await ImageCache.image(for: urls[index])
            heroImage = img
            let target = fitFrame(for: img?.size ?? .zero, in: screenRect)
            // 固定时长 easeOut，结束时与 pager 对齐，避免 spring 时序错位
            withAnimation(.easeOut(duration: enterDuration)) {
                heroFrame = target
                heroCornerRadius = 0
                bgOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + enterDuration) {
                heroPhase = .showing
            }
        }
    }

    private func fitFrame(for naturalSize: CGSize, in screen: CGRect) -> CGRect {
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return screen
        }
        let ratio = min(screen.width / naturalSize.width, screen.height / naturalSize.height)
        let w = naturalSize.width * ratio
        let h = naturalSize.height * ratio
        return CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }

    private func playExitAnimation(in screenRect: CGRect) {
        heroPhase = .closing

        // 源图不可见或无 source：直接淡出
        guard let source = sourceFrame, isSourceVisible(source) else {
            withAnimation(.easeOut(duration: exitDuration)) {
                bgOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration) { onDismiss() }
            return
        }

        Task { @MainActor in
            let img = await ImageCache.image(for: urls[index])
            heroImage = img
            let fit = fitFrame(for: img?.size ?? .zero, in: screenRect)
            // 从当前拖拽/缩放后的实际位置开始，避免从屏幕中心跳变
            let combinedScale = dismissScale * scale
            let startFrame = CGRect(
                x: fit.midX + dismissOffset.width + offset.width - fit.width * combinedScale / 2,
                y: fit.midY + dismissOffset.height + offset.height - fit.height * combinedScale / 2,
                width: fit.width * combinedScale,
                height: fit.height * combinedScale
            )
            heroFrame = startFrame
            heroCornerRadius = 0
            withAnimation(.easeOut(duration: exitDuration)) {
                heroFrame = source
                heroCornerRadius = 10
                bgOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration) { onDismiss() }
        }
    }

    /// 源缩略图是否仍在屏幕内（滚出屏幕则改用淡出，避免图片飞回不可见区域）
    private func isSourceVisible(_ source: CGRect) -> Bool {
        let screen = CGRect(origin: .zero, size: viewSize)
        return screen.intersects(source.insetBy(dx: -20, dy: -20))
    }

    private func triggerDismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        playExitAnimation(in: CGRect(origin: .zero, size: viewSize))
    }

    // MARK: - 分页容器

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

    // MARK: - 顶部栏（微信风格：返回 / 页码 / 更多）

    private var chrome: some View {
        VStack {
            ZStack {
                HStack {
                    Button { triggerDismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()

                    Button { showActionSheet = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if urls.count > 1 {
                    Text("\(index + 1) / \(urls.count)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()
        }
        .opacity(chromeOpacity)
        .allowsHitTesting(chromeVisible && !isDismissing)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
    }

    private var chromeOpacity: Double {
        guard chromeVisible else { return 0 }
        let dist = hypot(dismissOffset.width, dismissOffset.height)
        return max(0, 1 - Double(dist / 200))
    }

    private var dismissScale: CGFloat {
        let dist = hypot(dismissOffset.width, dismissOffset.height)
        guard viewSize.height > 0, dist > 0 else { return 1 }
        return max(0.5, 1 - dist / (viewSize.height * 0.9))
    }

    /// 顶部安全区高度（用于把顶部栏推到刘海/状态栏下方；App 只支持竖屏，读一次即可）
    private var safeAreaTop: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 0
    }

    // MARK: - 拖动：翻页 / 拖拽关闭 / 放大后平移

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isDismissing, !isPinching, heroPhase == .showing else { return }

                // 放大后：平移图片
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

                // 首次判定手势方向
                if dragAxis == nil {
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard max(abs(dx), abs(dy)) > 8 else { return }
                    dragAxis = abs(dx) >= abs(dy) ? .horizontal : .dismiss
                }

                switch dragAxis {
                case .horizontal:
                    pageDrag = pageDragValue(for: value.translation.width, in: size)
                    dismissOffset = .zero
                case .dismiss:
                    // 任意方向拖拽：图片跟随手指 1:1，轻微缩放 + 背景渐变
                    dismissOffset = value.translation
                    let dist = hypot(dismissOffset.width, dismissOffset.height)
                    bgOpacity = max(0, 1 - Double(dist / 420))
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
                case .horizontal:
                    finishPageDrag(value, in: size)
                case .dismiss:
                    finishDismissDrag(value)
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
        return max(-size.width * 0.85, min(size.width * 0.85, dx))
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

        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88)) {
            if target != index { index = target }
            pageDrag = 0
        }
    }

    private func finishDismissDrag(_ value: DragGesture.Value) {
        let dist = hypot(value.translation.width, value.translation.height)
        let predictedDist = hypot(value.predictedEndTranslation.width,
                                  value.predictedEndTranslation.height)
        if dist > 120 || predictedDist > 300 {
            triggerDismiss()
        } else {
            withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                dismissOffset = .zero
                bgOpacity = 1
            }
        }
    }

    // MARK: - 双指缩放（含捏合缩小关闭）

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !isDismissing, heroPhase == .showing else { return }
                if !isPinching {
                    isPinching = true
                    dragAxis = nil
                    pageDrag = 0
                    dismissOffset = .zero
                    pinchStartScale = scale
                    panStartOffset = offset
                }
                let newScale = min(maxScale, pinchStartScale * value)
                scale = newScale
                if scale < 1 {
                    // 缩小：背景随缩放淡出
                    bgOpacity = Double(max(0, scale))
                } else {
                    offset = clampOffset(offset, scale: newScale, in: size)
                }
            }
            .onEnded { _ in
                isPinching = false
                if scale < 0.85 {
                    // 捏合缩小到一定程度：关闭
                    triggerDismiss()
                } else if scale < 1 {
                    withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                        scale = 1
                        bgOpacity = 1
                    }
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 280, damping: 28)) {
                        offset = clampOffset(offset, scale: scale, in: size)
                    }
                }
            }
    }

    // MARK: - 单击 / 双击

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !isDismissing, heroPhase == .showing else { return }
                let now = Date()
                if now.timeIntervalSince(lastTapTime) < 0.3 {
                    lastTapTime = .distantPast
                    pendingChromeWork?.cancel()
                    pendingChromeWork = nil
                    toggleZoom(at: value.location, in: size)
                } else {
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
                offset = clampOffset(CGSize(width: -p.x * (doubleTapScale - 1),
                                            height: -p.y * (doubleTapScale - 1)),
                                     scale: doubleTapScale,
                                     in: size)
            }
        }
    }

    // MARK: - 缩放边界

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
        dismissOffset = .zero
    }

    // MARK: - 保存图片

    private func saveCurrentImage() {
        Task { @MainActor in
            guard let img = await ImageCache.image(for: urls[index]) else {
                showToast("图片加载失败")
                return
            }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            showToast("已保存到相册")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { toast = nil }
        }
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
