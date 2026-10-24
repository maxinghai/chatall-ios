//
//  ProfileView.swift
//  ChatAll
//
//  个人资料：头像、昵称、改密码、Bark 推送绑定、聊天背景、缓存。
//  主页只展示入口列表，每项功能点击后从底部弹出独立的小窗口。
//

import SwiftUI
import PhotosUI

/// 包装 UIImage 使其可作为 fullScreenCover(item:) 的标识项
private struct CropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 个人资料页的功能入口（同时决定底部弹窗的高度）
private enum ProfileSheet: String, Identifiable {
    case avatar
    case nickname
    case password
    case background
    case bark
    case cache

    var id: String { rawValue }

    var detents: Set<PresentationDetent> {
        switch self {
        case .avatar: return [.height(340)]
        // 带输入框的窗口保留 .large：键盘弹出时系统会自动把窗口抬到足够高度
        case .nickname: return [.medium, .large]
        case .password: return [.medium, .large]
        case .background: return [.medium, .large]
        case .bark: return [.medium, .large]
        case .cache: return [.height(260)]
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var store: AppStore

    @State private var nickname = ""
    @State private var avatar = ""
    @State private var barkKey = ""
    @State private var barkSaved = ""
    @State private var saving = false
    @State private var activeSheet: ProfileSheet?
    @State private var cacheSizeText = ""

    /// 聊天背景设置
    @State private var bgPickerItem: PhotosPickerItem?
    @State private var cropImage: CropItem?   // 待裁剪的原图（用 item 驱动 fullScreenCover，避免条件内容空白）

    private var displayName: String { nickname.isEmpty ? "我" : nickname }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                avatarCard

                // 功能入口：点击后从底部弹出对应窗口
                VStack(spacing: 0) {
                    entryRow(.nickname, icon: "pencil", title: "昵称",
                             detail: nickname.isEmpty ? "未设置" : nickname)
                    rowDivider
                    entryRow(.password, icon: "lock", title: "修改密码", detail: nil)
                    rowDivider
                    entryRow(.background, icon: "photo.on.rectangle", title: "聊天背景",
                             detail: store.backgroundURL == nil ? "默认背景" : "已设置")
                    rowDivider
                    entryRow(.bark, icon: "bell.badge", title: "Bark 推送绑定",
                             detail: barkSaved.isEmpty ? "未绑定" : "已绑定")
                    rowDivider
                    entryRow(.cache, icon: "trash", title: "清除缓存",
                             detail: cacheSizeText.isEmpty ? "计算中…" : cacheSizeText)
                }
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 16)

                Button {
                    store.logout()
                } label: {
                    HStack {
                        Spacer()
                        Text("退出登录").foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
                .buttonStyle(.plain)

                Text("服务器：\(AppConfig.host)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationBarTitle("个人资料", displayMode: .inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .avatar:
                    AvatarSheet(name: displayName, avatar: avatar, saving: saving) { image in
                        uploadAvatar(image)
                    }
                case .nickname:
                    NicknameSheet(nickname: $nickname) {
                        saveProfile()
                    }
                case .password:
                    PasswordSheet()
                case .background:
                    BackgroundSheet(pickerItem: $bgPickerItem,
                                    setOpacity: { store.setBackgroundOpacity($0) })
                case .bark:
                    BarkSheet(barkKey: $barkKey, saved: $barkSaved)
                case .cache:
                    CacheSheet(sizeText: cacheSizeText) {
                        clearCache()
                    }
                }
            }
            .presentationDetents(sheet.detents)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: bgPickerItem) { item in
            Task { @MainActor in
                guard let item,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    bgPickerItem = nil
                    return
                }
                // 先收起底部的背景设置窗口，再进入裁剪，避免两个转场叠加导致白屏
                bgPickerItem = nil
                activeSheet = nil
                try? await Task.sleep(for: .milliseconds(450))
                cropImage = CropItem(image: image)
            }
        }
        .fullScreenCover(item: $cropImage) { crop in
            ImageCropView(image: crop.image,
                          onCancel: {
                              cropImage = nil
                          },
                          onComplete: { cropped in
                              cropImage = nil
                              store.setBackgroundImage(cropped)
                          })
        }
        .onAppear {
            nickname = store.currentUser?.nickname ?? ""
            avatar = store.currentUser?.avatar ?? ""
            refreshCacheSize()
            Task { @MainActor in
                let saved = await store.loadBark()
                barkSaved = saved
                if barkKey.isEmpty { barkKey = saved }
            }
        }
    }

    // MARK: - 主页元素

    private var avatarCard: some View {
        Button {
            activeSheet = .avatar
        } label: {
            HStack(spacing: 14) {
                AvatarView(name: displayName, avatar: avatar, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("点击更换头像")
                        .font(.system(size: 13))
                        .foregroundColor(.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .padding(16)
            .contentShape(Rectangle())
            .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private func entryRow(_ sheet: ProfileSheet,
                          icon: String,
                          title: String,
                          detail: String?) -> some View {
        Button {
            activeSheet = sheet
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.chatGreen)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 52)
    }

    // MARK: - 缓存

    private func refreshCacheSize() {
        let bytes = ImageCache.diskUsage()
        cacheSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func clearCache() {
        ImageCache.clear()
        refreshCacheSize()
        store.toastMessage = "缓存已清除"
    }

    // MARK: - 动作

    private func saveProfile() {
        saving = true
        let n = nickname
        let a = avatar
        Task { @MainActor in
            await store.updateProfile(nickname: n, avatar: a)
            saving = false
        }
    }

    private func uploadAvatar(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let name = "avatar_\(Int(Date().timeIntervalSince1970)).jpg"
        saving = true
        Task { @MainActor in
            if let res = await store.upload(data: data, fileName: name, mimeType: "image/jpeg") {
                avatar = res.url
                await store.updateProfile(nickname: nickname, avatar: avatar)
            }
            saving = false
        }
    }
}

// MARK: - 底部弹窗通用组件

/// 弹窗统一容器：标题 + 副标题 + 可滚动内容
private struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondaryText)
                }
            }
            ScrollView(showsIndicators: false) {
                content()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 弹窗内的输入框（液态玻璃底）
private struct GlassField: View {
    @EnvironmentObject private var store: AppStore

    let placeholder: String
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
        .padding(14)
        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
    }
}

/// 弹窗内的操作按钮（filled = 绿底主按钮，否则玻璃底次按钮）
private struct SheetButton: View {
    @EnvironmentObject private var store: AppStore

    let title: String
    var filled: Bool = true
    var destructive: Bool = false
    var enabled: Bool = true
    var working: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer()
                if working {
                    ProgressView()
                        .tint(filled ? .white : .chatGreen)
                }
                Text(title)
                    .foregroundColor(filled ? .white : (destructive ? .red : .chatGreen))
                Spacer()
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .modifier(SheetButtonBackground(filled: filled, opacity: store.backgroundOpacity))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || working)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct SheetButtonBackground: ViewModifier {
    let filled: Bool
    let opacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            content
                .background(Color.chatGreen)
                .cornerRadius(14)
        } else {
            content
                .liquidGlass(opacity: opacity, cornerRadius: 14)
        }
    }
}

// MARK: - 头像

private struct AvatarSheet: View {
    let name: String
    let avatar: String
    let saving: Bool
    let onPick: (UIImage) -> Void

    @State private var showPhoto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("更换头像")
                .font(.system(size: 20, weight: .semibold))

            HStack {
                Spacer()
                AvatarView(name: name, avatar: avatar, size: 104)
                Spacer()
            }
            .padding(.vertical, 6)

            if saving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在上传…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondaryText)
                }
                .frame(maxWidth: .infinity)
            }

            SheetButton(title: "从相册选择") { showPhoto = true }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showPhoto) {
            PhotoPicker { images in
                if let image = images.first { onPick(image) }
            }
        }
    }
}

// MARK: - 昵称

private struct NicknameSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var nickname: String
    let onSave: () -> Void

    var body: some View {
        SheetScaffold(title: "修改昵称", subtitle: "昵称会展示给好友") {
            VStack(spacing: 12) {
                GlassField(placeholder: "请输入昵称", text: $nickname)
                SheetButton(title: "保存",
                            enabled: !nickname.trimmingCharacters(in: .whitespaces).isEmpty) {
                    nickname = nickname.trimmingCharacters(in: .whitespaces)
                    onSave()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 修改密码

private struct PasswordSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var confirmPwd = ""
    @State private var working = false
    @State private var tip = ""

    private var canSubmit: Bool {
        !oldPwd.isEmpty && !newPwd.isEmpty && !confirmPwd.isEmpty && !working
    }

    var body: some View {
        SheetScaffold(title: "修改密码") {
            VStack(spacing: 12) {
                GlassField(placeholder: "旧密码", text: $oldPwd, secure: true)
                GlassField(placeholder: "新密码", text: $newPwd, secure: true)
                GlassField(placeholder: "确认新密码", text: $confirmPwd, secure: true)

                if !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SheetButton(title: "确认修改", enabled: canSubmit, working: working) {
                    submit()
                }
            }
        }
    }

    private func submit() {
        guard newPwd == confirmPwd else {
            tip = "两次输入的新密码不一致"
            return
        }
        tip = ""
        working = true
        Task { @MainActor in
            let ok = await store.changePassword(old: oldPwd, new: newPwd)
            working = false
            if ok {
                oldPwd = ""
                newPwd = ""
                confirmPwd = ""
                dismiss()
            }
        }
    }
}

// MARK: - 聊天背景

private struct BackgroundSheet: View {
    @EnvironmentObject var store: AppStore

    @Binding var pickerItem: PhotosPickerItem?
    let setOpacity: (Double) -> Void

    var body: some View {
        SheetScaffold(title: "聊天背景", subtitle: "背景仅保存在本机，不会上传") {
            VStack(spacing: 12) {
                // 预览
                HStack {
                    Text("预览")
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)
                    Spacer()
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 80, height: 124)
                        .overlay {
                            ChatBackgroundImageView(fillsScreen: false)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(.separator), lineWidth: 0.5)
                                )
                        }
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                HStack {
                    PhotosPicker(selection: $pickerItem,
                                 matching: .images,
                                 label: {
                                     Text("从相册选择背景图")
                                         .font(.system(size: 15))
                                         .foregroundColor(.chatGreen)
                                 })
                    Spacer()
                    if store.backgroundURL != nil {
                        Button(role: .destructive) {
                            store.clearBackgroundImage()
                        } label: {
                            Text("恢复默认")
                                .font(.system(size: 15))
                        }
                    }
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                // 玻璃透明度
                VStack(spacing: 4) {
                    HStack {
                        Text("玻璃透明度")
                            .font(.system(size: 14))
                        Spacer()
                        Text(String(format: "%.0f%%", (1 - store.backgroundOpacity) * 100))
                            .font(.system(size: 13))
                            .foregroundColor(.secondaryText)
                    }
                    Slider(value: Binding<Double>(get: { store.backgroundOpacity },
                                                  set: { setOpacity($0) }),
                           in: 0.15...0.95,
                           step: 0.05)
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
            }
        }
    }
}

// MARK: - Bark 推送绑定

private struct BarkSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @Binding var barkKey: String
    @Binding var saved: String
    @State private var working = false

    var body: some View {
        SheetScaffold(title: "Bark 推送绑定") {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("去 Bark App 添加服务器 http://103.40.14.100:34761 取得 key 后粘贴到这里")
                        .font(.system(size: 13))
                        .foregroundColor(.secondaryText)
                    if saved.isEmpty {
                        Text("当前状态：未绑定")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                    } else {
                        Text("当前状态：已绑定（\(saved)）")
                            .font(.system(size: 13))
                            .foregroundColor(.chatGreen)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                GlassField(placeholder: "粘贴 Bark Key", text: $barkKey)

                SheetButton(title: "保存", working: working) {
                    save()
                }
            }
        }
    }

    private func save() {
        working = true
        let key = barkKey.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if await store.saveBark(key) {
                saved = key
                barkKey = key
                working = false
                dismiss()
            } else {
                working = false
            }
        }
    }
}

// MARK: - 缓存

private struct CacheSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let sizeText: String
    let onClear: () -> Void

    var body: some View {
        SheetScaffold(title: "清除缓存", subtitle: "仅清理本地图片缓存，不影响聊天记录") {
            VStack(spacing: 12) {
                HStack {
                    Text("图片缓存占用")
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)
                    Spacer()
                    Text(sizeText.isEmpty ? "计算中…" : sizeText)
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                SheetButton(title: "立即清除", filled: true) {
                    dismiss()
                    onClear()
                }
            }
        }
    }
}
