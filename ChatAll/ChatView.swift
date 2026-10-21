//
//  ChatView.swift
//  ChatAll
//
//  会话界面：消息列表（自动滚到底）、气泡、发送中转圈、输入栏（文本/相册/文件/按住录音）、
//  图片全屏预览、文件下载后系统分享、语音播放。
//

import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: AppStore

    let peerId: Int64
    let isGroup: Bool
    let title: String
    let avatar: String

    @State private var inputText = ""
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var previewURL: IdentifiableURL? = nil
    @State private var shareItem: ShareItem? = nil
    @State private var sending = false
    @StateObject private var recorder = VoiceRecorder()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageArea
            Divider()
            inputBar
        }
        .navigationBarTitle(title, displayMode: .inline)
        .toolbar {
            // iOS 15 的 ToolbarContentBuilder 不支持 if（buildIf 需 iOS 16+），
            // 条件判断必须放在 ToolbarItem 内部的 ViewBuilder 里。
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isGroup {
                    HStack(spacing: 16) {
                        Button {
                            store.call.startCall(peerId: peerId, mode: "AUDIO")
                        } label: {
                            Image(systemName: "phone")
                        }
                        Button {
                            store.call.startCall(peerId: peerId, mode: "VIDEO")
                        } label: {
                            Image(systemName: "video")
                        }
                    }
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                await store.openConversation(peerId: peerId, isGroup: isGroup)
            }
        }
        .onDisappear {
            store.closeConversation(peerId: peerId)
            recorder.stopPlay()
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { images in
                sendImages(images)
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .fullScreenCover(item: $previewURL) { item in
            ImagePreviewView(url: item.url)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
        .alert(isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Alert(title: Text("提示"),
                  message: Text(store.errorMessage ?? ""),
                  dismissButton: .default(Text("知道了")))
        }
    }

    // MARK: - 消息列表

    private var messages: [ChatMessage] {
        store.messages(for: peerId)
    }

    /// 列表底部固定锚点：消息行的 id 会在服务端 ACK 后变化（本地负数 → 真实 id），
    /// 用它滚动会因目标瞬时消失而失效，故始终滚到这个不变的空视图。
    private let bottomAnchor = "chat_bottom_anchor"

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(messages) { msg in
                        MessageRow(message: msg,
                                   isSelf: msg.fromId == (store.currentUser?.id ?? 0),
                                   showSender: isGroup,
                                   senderName: senderName(msg),
                                   senderAvatar: senderAvatar(msg),
                                   onTapImage: { url in previewURL = IdentifiableURL(url: url) },
                                   onTapFile: { m in downloadAndShare(m) },
                                   onTapVoice: { m in playVoice(m) },
                                   isPlaying: recorder.playingURL == voiceURL(msg))
                        .id(msg.id)
                    }
                    Color.clear
                        .frame(height: 16)
                        .id(bottomAnchor)
                }
                .padding(.top, 12)
                .padding(.bottom, 12)
                .padding(.horizontal, 12)
            }
            .background(Color(.systemGroupedBackground))
            .contentShape(Rectangle())
            .onTapGesture { inputFocused = false }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: messages.last?.id) { _ in
                // 服务端 ACK 会替换最后一条消息的 id，行重建后需重新贴底
                scrollToBottom(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { _ in
                // 键盘弹出会压缩消息区，需重新滚到底部
                scrollToBottom(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification)) { _ in
                // 键盘动画结束后再校准一次，避免偶发遮挡最后一条
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !messages.isEmpty else { return }
        // 滚到固定锚点：LazyVStack 懒加载与 ACK 换 id 都不会让目标丢失。
        // 分三次执行，覆盖键盘压缩、行布局与行高变化的时序。
        func doScroll() {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        DispatchQueue.main.async { doScroll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { doScroll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { doScroll() }
    }

    private func senderName(_ msg: ChatMessage) -> String {
        if msg.fromId == (store.currentUser?.id ?? 0) { return store.currentUserName() }
        return store.friendName(msg.fromId) ?? "用户\(msg.fromId)"
    }

    private func senderAvatar(_ msg: ChatMessage) -> String {
        if msg.fromId == (store.currentUser?.id ?? 0) { return store.currentUser?.avatar ?? "" }
        return store.friends.first(where: { $0.id == msg.fromId })?.avatar ?? ""
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button {
                showPhotoPicker = true
            } label: {
                if sending {
                    ProgressView()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
            }
            .disabled(sending)

            Button {
                showFileImporter = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 20))
                    .foregroundColor(sending ? Color.gray.opacity(0.4) : .gray)
            }
            .disabled(sending)

            TextField("输入消息", text: $inputText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { sendText() }

            if inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                // 按住录音
                ZStack {
                    Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(recorder.isRecording ? .white : .gray)
                        .frame(width: 40, height: 34)
                        .background(recorder.isRecording ? Color.red : Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    if recorder.isRecording {
                        Text("\(recorder.seconds)s")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .offset(x: 34)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !recorder.isRecording { beginRecord() }
                        }
                        .onEnded { _ in
                            endRecord()
                        }
                )
            } else {
                Button {
                    sendText()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 34)
                        .background(Color.chatGreen)
                        .cornerRadius(8)
                }
                .disabled(sending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 发送

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.sendMessage(to: peerId, isGroup: isGroup,
                          contentType: "TEXT", content: text)
        inputText = ""
        // 发送后保持键盘弹出：列表刷新可能让输入框失焦，稍后重新拉起焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            inputFocused = true
        }
    }

    private func sendImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        sending = true
        Task { @MainActor in
            store.toastMessage = "正在发送图片…"
            var sent = 0
            for image in images {
                guard let data = Self.processedJPEG(image) else { continue }
                let name = "img_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 100...999)).jpg"
                if let res = await store.upload(data: data, fileName: name, mimeType: "image/jpeg") {
                    store.sendMessage(to: peerId, isGroup: isGroup,
                                      contentType: "IMAGE", content: "[图片]",
                                      fileUrl: res.url, fileName: res.name, fileSize: res.size)
                    sent += 1
                }
            }
            store.toastMessage = sent > 1 ? "已发送 \(sent) 张图片" : nil
            sending = false
        }
    }

    /// 大图等比压缩到最长边 1600，控制上传体积、加快发送
    private static func processedJPEG(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1600
        var target = image
        let side = max(image.size.width, image.size.height) * image.scale
        if side > maxSide {
            let ratio = maxSide / side
            let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        return target.jpegData(compressionQuality: 0.7)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 读取文件（注意安全作用域）
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                store.errorMessage = "无法读取文件"
                return
            }
            let name = url.lastPathComponent
            let mime = mimeType(for: url.pathExtension)
            sending = true
            Task { @MainActor in
                if let res = await store.upload(data: data, fileName: name, mimeType: mime) {
                    store.sendMessage(to: peerId, isGroup: isGroup,
                                      contentType: "FILE", content: "[文件]",
                                      fileUrl: res.url, fileName: res.name.isEmpty ? name : res.name,
                                      fileSize: res.size)
                }
                sending = false
            }
        case .failure:
            break
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "mp4": return "video/mp4"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    // MARK: - 录音

    private func beginRecord() {
        Task { @MainActor in
            let ok = await recorder.requestPermission()
            guard ok else {
                store.errorMessage = "没有麦克风权限"
                return
            }
            do {
                try recorder.start()
            } catch {
                store.errorMessage = "录音失败"
            }
        }
    }

    private func endRecord() {
        guard recorder.isRecording else { return }
        let duration = recorder.seconds
        guard let url = recorder.stop(), duration >= 1 else {
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        sending = true
        Task { @MainActor in
            if let res = await store.upload(data: data, fileName: "voice_\(Int(Date().timeIntervalSince1970)).wav",
                                            mimeType: "audio/wav") {
                store.sendMessage(to: peerId, isGroup: isGroup,
                                  contentType: "VOICE", content: "[语音]",
                                  fileUrl: res.url, fileName: res.name, fileSize: res.size,
                                  duration: duration)
            }
            sending = false
        }
    }

    // MARK: - 播放 / 下载

    private func voiceURL(_ msg: ChatMessage) -> URL? {
        return AppConfig.fileURL(msg.fileUrl)
    }

    private func playVoice(_ msg: ChatMessage) {
        guard let url = voiceURL(msg) else { return }
        Task { @MainActor in
            await recorder.play(url: url)
        }
    }

    private func downloadAndShare(_ msg: ChatMessage) {
        guard let url = AppConfig.fileURL(msg.fileUrl) else { return }
        let name = (msg.fileName?.isEmpty == false) ? msg.fileName! : "download"
        URLSession.shared.downloadTask(with: url) { loc, _, _ in
            guard let loc = loc else { return }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: loc, to: dest)
            DispatchQueue.main.async {
                shareItem = ShareItem(url: dest)
            }
        }.resume()
    }
}

// MARK: - 单条消息气泡

struct MessageRow: View {
    let message: ChatMessage
    let isSelf: Bool
    let showSender: Bool
    let senderName: String
    let senderAvatar: String
    let onTapImage: (URL) -> Void
    let onTapFile: (ChatMessage) -> Void
    let onTapVoice: (ChatMessage) -> Void
    let isPlaying: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelf {
                Spacer(minLength: 40)
                statusIndicator
                bubble
                AvatarView(name: senderName, avatar: senderAvatar, size: 32)
            } else {
                AvatarView(name: senderName, avatar: senderAvatar, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    if showSender {
                        Text(senderName)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    bubble
                }
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if message.localState == 0 {
            ProgressView().scaleEffect(0.6)
        } else if message.localState == 2 {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 16))
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.contentType {
        case "IMAGE":
            imageBubble
        case "FILE":
            fileBubble
        case "VOICE":
            voiceBubble
        default:
            textBubble
        }
    }

    private var textBubble: some View {
        Text(message.content ?? "")
            .font(.system(size: 16))
            .foregroundColor(isSelf ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelf ? Color.chatGreen : Color.bubbleGray)
            .cornerRadius(14)
    }

    private var imageBubble: some View {
        ZStack {
            if let url = AppConfig.fileURL(message.fileUrl) {
                CachedImage(url: url,
                            placeholder: {
                                ProgressView().frame(width: 160, height: 160)
                            },
                            failure: {
                                Image(systemName: "photo")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                                    .frame(width: 160, height: 160)
                            })
            } else {
                Color.gray.opacity(0.2).frame(width: 160, height: 160)
            }
        }
        .frame(width: 160, height: 160)
        .clipped()
        .cornerRadius(10)
        .onTapGesture {
            if let url = AppConfig.fileURL(message.fileUrl) { onTapImage(url) }
        }
    }

    private var fileBubble: some View {
        Button {
            onTapFile(message)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 26))
                    .foregroundColor(isSelf ? .white : .chatGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.fileName ?? "文件")
                        .font(.system(size: 14))
                        .foregroundColor(isSelf ? .white : .primary)
                        .lineLimit(1)
                    Text(fileSizeText)
                        .font(.system(size: 11))
                        .foregroundColor(isSelf ? Color.white.opacity(0.8) : .gray)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelf ? Color.chatGreen : Color.bubbleGray)
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var fileSizeText: String {
        let size = message.fileSize ?? 0
        if size <= 0 { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }

    private var voiceBubble: some View {
        Button {
            onTapVoice(message)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isSelf ? .white : .primary)
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundColor(isSelf ? .white : .chatGreen)
                Text(AppConfig.durationText(message.duration))
                    .font(.system(size: 13))
                    .foregroundColor(isSelf ? .white : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelf ? Color.chatGreen : Color.bubbleGray)
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 辅助类型

/// 带 id 的 URL（用于 sheet / fullScreenCover）
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// 分享项
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系统分享面板
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 相册选图（PHPicker，无需相册权限，支持最多 6 张多选）
struct PhotoPicker: UIViewControllerRepresentable {
    var maxCount: Int = 6
    var onPick: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = maxCount
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let providers = results.compactMap { $0.itemProvider }
                .filter { $0.canLoadObject(ofClass: UIImage.self) }
            guard !providers.isEmpty else { return }

            var images = [UIImage?](repeating: nil, count: providers.count)
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    images[index] = object as? UIImage
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                let picked = images.compactMap { $0 }
                if !picked.isEmpty { self.parent.onPick(picked) }
            }
        }
    }
}
