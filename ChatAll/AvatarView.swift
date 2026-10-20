//
//  AvatarView.swift
//  ChatAll
//
//  圆形头像：有 avatar 用 AsyncImage 圆形裁剪，否则显示昵称首字 + 按名字生成的固定背景色。
//

import SwiftUI

struct AvatarView: View {
    let name: String
    let avatar: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if !avatar.isEmpty, let url = AppConfig.fileURL(avatar) {
                CachedImage(url: url,
                            placeholder: { loadingPlaceholder },
                            failure: { textPlaceholder })
            } else {
                textPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var loadingPlaceholder: some View {
        ZStack {
            backgroundColor
            ProgressView().scaleEffect(0.6)
        }
    }

    private var textPlaceholder: some View {
        ZStack {
            backgroundColor
            Text(firstChar)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundColor(.white)
        }
    }

    private var firstChar: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let c = n.first { return String(c) }
        return "?"
    }

    /// 按名字生成固定背景色
    private var backgroundColor: Color {
        let palette: [Color] = [
            Color(red: 0.35, green: 0.62, blue: 0.90),
            Color(red: 0.95, green: 0.55, blue: 0.30),
            Color(red: 0.45, green: 0.75, blue: 0.50),
            Color(red: 0.80, green: 0.45, blue: 0.75),
            Color(red: 0.55, green: 0.55, blue: 0.85),
            Color(red: 0.90, green: 0.65, blue: 0.30),
            Color(red: 0.35, green: 0.70, blue: 0.70)
        ]
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        let idx = palette.isEmpty ? 0 : hash % palette.count
        return palette[idx]
    }
}
