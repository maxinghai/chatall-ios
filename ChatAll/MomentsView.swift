//
//  MomentsView.swift
//  ChatAll
//
//  动态（朋友圈）页面：查看好友 + 自己的动态、发布动态（文字+图片）、
//  点赞、评论、删除自己的动态。
//

import SwiftUI
import UIKit

struct MomentsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var showCreate = false
    @State private var commentingMomentId: Int64? = nil
    @State private var commentText = ""
    @State private var previewItem: PreviewItem? = nil

    var body: some View {
        ZStack {
            NavigationView {
                ZStack {
                    // 底图放在 NavigationView 内部，否则会被导航容器的不透明底色盖住
                    ChatBackgroundImageView()

                    // iOS 26 的 List 自带白色底盘清不掉，改用 ScrollView 让玻璃卡直接浮在背景图上
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(store.moments) { moment in
                                momentRow(moment)
                            }
                            if store.moments.isEmpty {
                                Text("还没有动态，点击右上角发布第一条吧")
                                    .foregroundColor(.gray)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 60)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                    .refreshable {
                        await store.refreshMoments()
                    }
                }
                .navigationBarTitle("动态", displayMode: .inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showCreate = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .sheet(isPresented: $showCreate) {
                CreateMomentSheet()
            }
            .task {
                await store.refreshMoments()
            }

            // 全屏图片预览（仿微信：点击九宫格展开，拖拽/捏合收起）
            if let item = previewItem {
                ImagePreviewView(urls: item.urls,
                                 currentIndex: item.index,
                                 sourceFrame: item.sourceFrame,
                                 onDismiss: { previewItem = nil })
                    .zIndex(1)
            }
        }
    }

    // MARK: - 单条动态

    private func momentRow(_ moment: MomentItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：头像 + 昵称 + 时间
            HStack(spacing: 10) {
                AvatarView(name: moment.displayName, avatar: moment.avatar, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(moment.displayName)
                        .font(.system(size: 15, weight: .medium))
                    Text(AppConfig.listTimeString(moment.createdAt))
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
                if moment.userId == store.currentUser?.id {
                    Menu {
                        Button(role: .destructive) {
                            Task { await store.deleteMoment(momentId: moment.id) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.gray)
                            .padding(8)
                    }
                }
            }

            // 文字内容
            if !moment.content.isEmpty {
                Text(moment.content)
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 图片九宫格
            let urls = moment.imageURLs.compactMap { AppConfig.fileURL($0) }
            if !urls.isEmpty {
                MomentImagesGrid(urls: urls) { index, frame in
                    previewItem = PreviewItem(urls: urls, index: index, sourceFrame: frame)
                }
            }

            // 操作栏：点赞 + 评论
            HStack(spacing: 24) {
                Button {
                    Task { await store.toggleMomentLike(momentId: moment.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: moment.liked ? "heart.fill" : "heart")
                            .foregroundColor(moment.liked ? .red : .gray)
                        if moment.likeCount > 0 {
                            Text("\(moment.likeCount)")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Button {
                    commentText = ""
                    commentingMomentId = moment.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.right")
                            .foregroundColor(.gray)
                        if !moment.comments.isEmpty {
                            Text("\(moment.comments.count)")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }

            // 点赞列表
            if moment.likeCount > 0 {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text(moment.likeUsers.map { $0.displayName }.joined(separator: "、"))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 6)
            }

            // 评论列表
            if !moment.comments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(moment.comments) { c in
                        HStack(alignment: .top, spacing: 6) {
                            Text(c.displayName + "：")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Text(c.content)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 6)
            }

            // 评论输入框（点击评论按钮后展开）
            if commentingMomentId == moment.id {
                HStack(spacing: 8) {
                    TextField("说点什么...", text: $commentText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                    Button("发送") {
                        let text = commentText.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        commentingMomentId = nil
                        Task { await store.addMomentComment(momentId: moment.id, content: text) }
                    }
                    .foregroundColor(.chatGreen)
                }
            }
        }
        .padding(14)
        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 16)
    }
}

/// 微信风格图片九宫格：
/// 1 张按原图比例单图展示；2、4 张两列；其余三列。
/// 单元格使用固定正方形尺寸，避免 LazyVGrid 在自适应宽高下错位。
private struct MomentImagesGrid: View {
    let urls: [URL]
    let onTap: (Int, CGRect?) -> Void

    @State private var availableWidth: CGFloat = 0
    @State private var frames: [Int: CGRect] = [:]

    private let spacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 仅用于测量行宽（0 高度，不参与布局）
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { availableWidth = geo.size.width }
                            .onChange(of: geo.size.width) { availableWidth = $0 }
                    }
                )

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if urls.count == 1 {
            let width = availableWidth > 0 ? min(max(availableWidth * 0.7, 120), 240) : 200
            MomentSingleImage(url: urls[0], maxWidth: width)
                .background(frameRecorder(0))
                .contentShape(Rectangle())
                .onTapGesture { onTap(0, frames[0]) }
        } else {
            let columns = (urls.count == 2 || urls.count == 4) ? 2 : 3
            let side = cellSide(columns: columns)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing),
                                     count: columns),
                      alignment: .leading,
                      spacing: spacing) {
                ForEach(urls.indices, id: \.self) { i in
                    gridCell(url: urls[i], index: i, side: side)
                }
            }
        }
    }

    private func cellSide(columns: Int) -> CGFloat {
        let maxSide: CGFloat = columns == 2 ? 150 : 100
        guard availableWidth > 0 else { return maxSide }
        let fit = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return max(44, min(maxSide, fit))
    }

    private func gridCell(url: URL, index: Int, side: CGFloat) -> some View {
        CachedImage(url: url,
                    placeholder: { Color.gray.opacity(0.15) },
                    failure: {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundColor(.gray)
                    })
            .frame(width: side, height: side)
            .clipped()
            .background(Color.gray.opacity(0.15))
            .contentShape(Rectangle())
            .background(frameRecorder(index))
            .onTapGesture { onTap(index, frames[index]) }
    }

    /// 记录单元格在当前屏幕上的 frame，供预览展开动画使用
    private func frameRecorder(_ key: Int) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frames[key] = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { frames[key] = $0 }
        }
    }
}

/// 单张图片：按原图比例展示（限宽限高），加载前先用正方形占位。
private struct MomentSingleImage: View {
    let url: URL
    let maxWidth: CGFloat

    @State private var ratio: CGFloat = 1

    private var size: CGSize {
        if ratio >= 1 {
            return CGSize(width: maxWidth, height: max(56, maxWidth / ratio))
        }
        let maxHeight = maxWidth * 1.3
        return CGSize(width: maxHeight * ratio, height: maxHeight)
    }

    var body: some View {
        CachedImage(url: url,
                    placeholder: { Color.gray.opacity(0.15) },
                    failure: {
                        Image(systemName: "photo")
                            .font(.system(size: 30))
                            .foregroundColor(.gray)
                    })
            .frame(width: size.width, height: size.height)
            .clipped()
            .background(Color.gray.opacity(0.15))
            .task(id: url) {
                guard let img = await ImageCache.image(for: url),
                      img.size.width > 0, img.size.height > 0 else { return }
                // 限制极端比例，避免长图占满整屏
                ratio = min(max(img.size.width / img.size.height, 0.4), 2.5)
            }
    }
}

// MARK: - 发布动态

struct CreateMomentSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var images: [UIImage] = []
    @State private var showPicker = false
    @State private var posting = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $content)
                    .frame(minHeight: 120)
                    .padding()
                    .overlay(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("分享此刻的想法...")
                                .foregroundColor(.gray)
                                .padding(.top, 24)
                                .padding(.leading, 20)
                        }
                    }

                // 已选图片预览
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(images.indices, id: \.self) { idx in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: images[idx])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipped()
                                        .cornerRadius(6)
                                    Button {
                                        images.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.black.opacity(0.6))
                                            .background(Color.white.opacity(0.8).clipShape(Circle()))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 8)
                }

                // 添加图片按钮
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                        Text("添加图片")
                    }
                    .foregroundColor(.chatGreen)
                    .padding(.vertical, 10)
                }

                Spacer()
            }
            .navigationBarTitle("发布动态", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("发布") { post() }
                        .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty
                                  && images.isEmpty || posting)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showPicker) {
            PhotoPicker(maxCount: 9) { picked in
                images.append(contentsOf: picked)
            }
        }
    }

    private func post() {
        posting = true
        let text = content.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            // 先上传图片拿到 URL 列表
            var urls: [String] = []
            for img in images {
                if let data = img.jpegData(compressionQuality: 0.8) {
                    do {
                        let res = try await ApiClient.shared.uploadFile(
                            data: data, fileName: "moment_\(UUID().uuidString).jpg", mimeType: "image/jpeg")
                        urls.append(res.url)
                    } catch {
                        store.errorMessage = "图片上传失败：\(error.localizedDescription)"
                    }
                }
            }
            let ok = await store.createMoment(content: text, images: urls)
            posting = false
            if ok { dismiss() }
        }
    }
}
