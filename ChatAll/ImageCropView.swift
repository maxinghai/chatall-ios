//
//  ImageCropView.swift
//  ChatAll
//
//  背景图裁剪：按屏幕比例裁剪，支持双指缩放 + 拖动。
//  裁剪后的图片直接就是屏幕大小比例，作为聊天背景铺满。
//

import SwiftUI

struct ImageCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onComplete: (UIImage) -> Void

    @State private var scale: CGFloat
    @State private var translation: CGSize = .zero
    @State private var lastScale: CGFloat
    @State private var lastTranslation: CGSize = .zero

    /// 屏幕大小 = 裁剪框大小（背景图就是全屏）
    private let screenSize = UIScreen.main.bounds.size

    init(image: UIImage, onCancel: @escaping () -> Void, onComplete: @escaping (UIImage) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onComplete = onComplete
        // 初始 scale = 让图片填满屏幕（aspectFill）
        let iw = image.size.width
        let ih = image.size.height
        let base = max(screenSize.width / iw, screenSize.height / ih)
        _scale = State(initialValue: base)
        _lastScale = State(initialValue: base)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 可缩放、可拖动的图片
            Image(uiImage: image)
                .resizable()
                .frame(width: image.size.width * scale,
                       height: image.size.height * scale)
                .offset(translation)
                .clipped()

            // 底部操作栏
            VStack {
                Spacer()
                VStack(spacing: 14) {
                    Text("拖动和缩放调整图片位置")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))

                    HStack(spacing: 32) {
                        Button("取消") { onCancel() }
                            .font(.system(size: 17))
                            .foregroundColor(.white)

                        Spacer()

                        Button {
                            if let cropped = crop() { onComplete(cropped) }
                        } label: {
                            Text("完成")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.black)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .cornerRadius(18)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.55))
            }
            .ignoresSafeArea()
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
                        scale = max(lastScale * value, lastScale) // 不允许缩到比初始更小
                    }
                    .onEnded { _ in
                        lastScale = scale
                    }
            )
        )
    }

    /// 根据当前 scale + translation 计算裁剪矩形并裁剪
    private func crop() -> UIImage? {
        let iw = image.size.width
        let ih = image.size.height
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
        guard rect.width > 1, rect.height > 1 else { return image }

        // 用 UIGraphicsImageRenderer 裁剪（自动处理 imageOrientation）
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }
}
