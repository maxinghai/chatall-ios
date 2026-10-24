//
//  ProfileView.swift
//  ChatAll
//
//  个人资料：改昵称、换头像（相册选图→上传）、改密码、Bark 推送绑定、聊天背景。
//

import SwiftUI
import PhotosUI

/// 包装 UIImage 使其可作为 fullScreenCover(item:) 的标识项
private struct CropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ProfileView: View {
    @EnvironmentObject var store: AppStore

    @State private var nickname = ""
    @State private var avatar = ""
    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var confirmPwd = ""
    @State private var barkKey = ""
    @State private var barkSaved = ""
    @State private var showPhoto = false
    @State private var saving = false
    @State private var changingPwd = false
    @State private var savingBark = false
    @State private var cacheSizeText = ""

    /// 聊天背景设置
    @State private var bgPickerItem: PhotosPickerItem?
    @State private var cropImage: CropItem?   // 待裁剪的原图（用 item 驱动 fullScreenCover，避免条件内容空白）
    @State private var bgOpacity: Double = AppConfig.backgroundOpacity

    var body: some View {
        // iOS 26 的 Form 每个分组自带一张白色底卡（scrollContentBackground 清不掉），
        // 改用 ScrollView 手动分组，玻璃卡才能直接浮在背景图上
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // MARK: 头像
                VStack(spacing: 12) {
                    AvatarView(name: nickname.isEmpty ? "我" : nickname, avatar: avatar, size: 88)
                    Button("更换头像") { showPhoto = true }
                        .foregroundColor(.chatGreen)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 16)

                // MARK: 昵称
                profileSection("昵称") {
                    TextField("请输入昵称", text: $nickname)
                        .padding(14)
                        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }

                // MARK: 保存资料（保持实心绿按钮）
                Button {
                    saveProfile()
                } label: {
                    HStack {
                        Spacer()
                        if saving { ProgressView() }
                        Text("保存资料").foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(Color.chatGreen)
                    .cornerRadius(14)
                }
                .disabled(saving)

                // MARK: 修改密码
                profileSection("修改密码") {
                    VStack(spacing: 10) {
                SecureField("旧密码", text: $oldPwd)
                    .padding(14)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                SecureField("新密码", text: $newPwd)
                    .padding(14)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                SecureField("确认新密码", text: $confirmPwd)
                    .padding(14)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                Button {
                    changePassword()
                } label: {
                    HStack {
                        Spacer()
                        if changingPwd { ProgressView() }
                        Text("修改密码").foregroundColor(.chatGreen)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
                        .disabled(changingPwd || oldPwd.isEmpty || newPwd.isEmpty)
                    }
                }

                // MARK: 聊天背景（本地，不上传）
                profileSection("聊天背景") {
                    VStack(spacing: 10) {
                // 预览
                HStack {
                    Text("预览")
                    Spacer()
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 90, height: 140)
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
                    PhotosPicker(selection: $bgPickerItem,
                                 matching: .images,
                                 label: { Text("选择背景图") })
                        .foregroundColor(.chatGreen)
                    Spacer()
                    if store.backgroundURL != nil {
                        Button(role: .destructive) {
                            store.clearBackgroundImage()
                        } label: { Text("清除") }
                    }
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                HStack {
                    Text("玻璃透明度")
                        .font(.system(size: 14))
                    Spacer()
                    Text(String(format: "%.0f%%", (1 - bgOpacity) * 100))
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                Slider(value: $bgOpacity, in: 0.15...0.95, step: 0.05)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                    .onChange(of: bgOpacity) { newValue in
                        store.setBackgroundOpacity(newValue)
                    }
                    }
                }

                // MARK: Bark 推送绑定
                profileSection("Bark 推送绑定") {
                    VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("去 Bark App 添加服务器 http://103.40.14.100:34761 取得 key 后粘贴到这里")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                    if barkSaved.isEmpty {
                        Text("当前状态：未绑定")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                    } else {
                        Text("当前状态：已绑定（\(barkSaved)）")
                            .font(.system(size: 13))
                            .foregroundColor(.chatGreen)
                            .lineLimit(1)
                    }
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                TextField("粘贴 Bark Key", text: $barkKey)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(14)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                Button {
                    saveBark()
                } label: {
                    HStack {
                        Spacer()
                        if savingBark { ProgressView() }
                        Text("保存").foregroundColor(.chatGreen)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
                        .disabled(savingBark)
                    }
                }

                // MARK: 缓存
                profileSection("缓存") {
                    VStack(spacing: 10) {
                HStack {
                    Text("图片缓存占用")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    Spacer()
                    Text(cacheSizeText.isEmpty ? "计算中…" : cacheSizeText)
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .padding(14)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)

                Button {
                    clearCache()
                } label: {
                    HStack {
                        Spacer()
                        Text("清除缓存").foregroundColor(.chatGreen)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
                    }
                }

                // MARK: 退出登录
                Button {
                    store.logout()
                } label: {
                    HStack {
                        Spacer()
                        Text("退出登录").foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }

                Text("服务器：\(AppConfig.host)")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationBarTitle("个人资料", displayMode: .inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPhoto) {
            PhotoPicker { images in
                // 头像只需一张，取第一张
                if let image = images.first {
                    uploadAvatar(image)
                }
            }
        }
        .onChange(of: bgPickerItem) { item in
            Task { @MainActor in
                if let item,
                   let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    // 选完图先进入裁剪，不直接保存。
                    // 延迟一下，等 PhotosPicker 的 sheet 完全收起，避免两个全屏转场冲突导致白屏。
                    try? await Task.sleep(for: .milliseconds(350))
                    cropImage = CropItem(image: image)
                }
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
            bgOpacity = store.backgroundOpacity
            refreshCacheSize()
            Task { @MainActor in
                let saved = await store.loadBark()
                barkSaved = saved
                if barkKey.isEmpty { barkKey = saved }
            }
        }
    }

    /// 分组标题 + 内容（替代 Form 的 Section，避开 iOS 26 系统自带的白底卡片）
    private func profileSection<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .padding(.leading, 4)
            content()
        }
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

    private func changePassword() {
        guard newPwd == confirmPwd else {
            store.errorMessage = "两次输入的新密码不一致"
            return
        }
        changingPwd = true
        Task { @MainActor in
            let ok = await store.changePassword(old: oldPwd, new: newPwd)
            if ok {
                oldPwd = ""
                newPwd = ""
                confirmPwd = ""
            }
            changingPwd = false
        }
    }

    private func saveBark() {
        savingBark = true
        let key = barkKey.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if await store.saveBark(key) {
                barkSaved = key
            }
            savingBark = false
        }
    }
}
