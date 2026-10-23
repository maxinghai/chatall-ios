//
//  ImageCropView.swift
//  ChatAll
//
//  背景图裁剪：保持图片原始比例，按屏幕比例裁剪，支持双指缩放 + 拖动。
//

import SwiftUI

struct ImageCropView: View {
    /// 缩小后的图片（保持原始比例，最大边不超过 2000px，避免大图卡顿）
    private let displayImage: UIImage
    let onCancel: () -> Void
    let onComplete: (UIImage) -> Void

    /// 让图片刚好填满屏幕的初始缩放（aspectFill）
    private let baseScale: CGFloat
    @State private var scale: CGFloat
    @State private var translation: CGSize = .zero
    @State private var lastScale: CGFloat
    @State private var lastTranslation: CGSize = .zero

    /// 屏幕大小 = 裁剪框大小（背景图就是全屏）
    private let screenSize = UIScreen.main.bounds.size

    init(image: UIImage, onCancel: @escaping () -> Void, onComplete: @escaping (UIImage) -> Void) {
        // 只缩小、不裁剪，保持原始比例
        self.displayImage = ImageCropView.downscale(image, maxEdge: 2000)
        self.onCancel = onCancel
        self.onComplete = onComplete
        let iw = self.displayImage.size.width
        let ih = self.displayImage.size.height
        let sw = UIScreen.main.bounds.width
        let sh = UIScreen.main.bounds.height
        self.baseScale = max(sw / iw, sh / ih)
        _scale = State(initialValue: self.baseScale)
        _lastScale = State(initialValue: self.baseScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图片裁剪区域（占满上方所有空间）
            ZStack {
                Color.black
                Image(uiImage: displayImage)
                    .resizable()
                    .frame(width: displayImage.size.width * scale,
                           height: displayImage.size.height * scale)
                    .offset(translation)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            // 不允许缩到比 baseScale 更小，保证始终填满屏幕
                            scale = max(lastScale * value, baseScale)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
            )

            // 底部操作栏（VStack 内，安全区内，一定可见）
            VStack(spacing: 12) {
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
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .cornerRadius(22)
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.85))
        }
        .ignoresSafeArea()
    }

    /// 根据当前 scale + translation 计算裁剪矩形并裁剪
    private func crop() -> UIImage? {
        let iw = displayImage.size.width
        let ih = displayImage.size.height
        let cw = screenSize.width
        let ch = screenSize.height

        // 图片左上角在屏幕坐标系中的位置 = 屏幕中心 + translation - 图片显示尺寸/2
        // 屏幕左上角 (0,0) 在图片坐标系中的位置 =
        //   (iw*scale/2 - cw/2 - tx, ih*scale/2 - ch/2 - ty)
        let cropX = iw / 2 - cw / (2 * scale) - translation.width / scale
        let cropY = ih / 2 - ch / (2 * scale) - translation.height / scale
        let cropW = cw / scale
        let cropH = ch / scale

        var rect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        guard rect.width > 1, rect.height > 1 else { return displayImage }

        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            displayImage.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }

    // MARK: - 图片缩小（保持原始比例，不裁剪）

    /// 把图片缩小到最大边不超过 maxEdge，保持原始比例
    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return image }
        let longest = max(iw, ih)
        guard longest > maxEdge else { return image }

        let ratio = maxEdge / longest
        let targetSize = CGSize(width: iw * ratio, height: ih * ratio)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
