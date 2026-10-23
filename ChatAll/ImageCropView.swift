//
//  ImageCropView.swift
//  ChatAll
//
//  背景图裁剪：按屏幕比例裁剪，支持双指缩放 + 拖动。
//  裁剪后的图片直接就是屏幕大小比例，作为聊天背景铺满。
//

import SwiftUI

struct ImageCropView: View {
    /// 已经缩放到屏幕尺寸的图片（避免直接渲染 4000×3000 原图导致卡顿）
    private let displayImage: UIImage
    let onCancel: () -> Void
    let onComplete: (UIImage) -> Void

    @State private var scale: CGFloat = 1.0
    @State private var translation: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastTranslation: CGSize = .zero

    /// 屏幕大小 = 裁剪框大小（背景图就是全屏）
    private let screenSize = UIScreen.main.bounds.size

    init(image: UIImage, onCancel: @escaping () -> Void, onComplete: @escaping (UIImage) -> Void) {
        // 进入裁剪页前先把图片缩放到屏幕尺寸（保持比例填满），避免大图渲染卡顿
        self.displayImage = ImageCropView.prepareImage(image, screenSize: UIScreen.main.bounds.size)
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 可缩放、可拖动的图片（displayImage 已铺满屏幕，scale 从 1 开始放大）
            Image(uiImage: displayImage)
                .resizable()
                .frame(width: displayImage.size.width * scale,
                       height: displayImage.size.height * scale)
                .offset(translation)
                .clipped()

            // 底部操作栏（不 extends 到安全区外，按钮一定可见）
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 14) {
                    Text("拖动和缩放调整图片位置")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))

                    HStack(spacing: 24) {
                        Button("取消") { onCancel() }
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .frame(minWidth: 64)

                        Spacer()

                        Button {
                            if let cropped = crop() { onComplete(cropped) }
                        } label: {
                            Text("完成")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(minWidth: 80)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 9)
                                .background(Color.white)
                                .cornerRadius(20)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .padding(.top, 14)
                .padding(.bottom, 20)   // 留给 Home indicator 的空间
                .background(Color.black.opacity(0.7))
            }
        }
        .gesture(
            SimultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        translation = CGSize(
                            width: lastTranslation.width + value.translation.width,
                            height: lastTranslation.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastTranslation = translation
                    },
                MagnificationGesture()
                    .onChanged { value in
                        // 不允许缩到比初始（1.0）更小，保证始终填满屏幕
                        scale = max(lastScale * value, 1.0)
                    }
                    .onEnded { _ in
                        lastScale = scale
                    }
            )
        )
    }

    /// 根据当前 scale + translation 计算裁剪矩形并裁剪
    private func crop() -> UIImage? {
        let iw = displayImage.size.width
        let ih = displayImage.size.height
        let cw = screenSize.width
        let ch = screenSize.height

        // 图片左上角在屏幕坐标系中的位置 = 屏幕中心 + translation - 图片显示尺寸/2
        // 反推：屏幕左上角 (0,0) 在图片坐标系中的位置 =
        //   (iw*scale/2 - cw/2 - tx, ih*scale/2 - ch/2 - ty)
        // 再除以 scale 得到原图坐标系
        let cropX = iw / 2 - cw / (2 * scale) - translation.width / scale
        let cropY = ih / 2 - ch / (2 * scale) - translation.height / scale
        let cropW = cw / scale
        let cropH = ch / scale

        var rect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        // Clamp 到图片范围内
        rect = rect.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        guard rect.width > 1, rect.height > 1 else { return displayImage }

        // 用 UIGraphicsImageRenderer 裁剪（自动处理 imageOrientation）
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            displayImage.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }

    // MARK: - 图片预处理

    /// 把原图缩放到"刚好填满屏幕"的尺寸，避免大图渲染卡顿
    /// 返回的图片比例 = 屏幕比例（aspectFill 裁剪后）
    private static func prepareImage(_ image: UIImage, screenSize: CGSize) -> UIImage {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return image }

        // 以屏幕比例 aspectFill 裁剪，裁出中间区域
        let screenRatio = screenSize.width / screenSize.height
        let imgRatio = iw / ih
        let drawRect: CGRect
        if imgRatio > screenRatio {
            // 图片更宽，裁掉左右
            let w = ih * screenRatio
            drawRect = CGRect(x: (iw - w) / 2, y: 0, width: w, height: ih)
        } else {
            // 图片更高，裁掉上下
            let h = iw / screenRatio
            drawRect = CGRect(x: 0, y: (ih - h) / 2, width: iw, height: h)
        }

        // 渲染到屏幕像素尺寸（@2x/@3x 清晰）
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: screenSize.width * scale,
                                height: screenSize.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize),
                       from: drawRect,
                       fraction: 1.0)
        }
    }
}
