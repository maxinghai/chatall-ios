//
//  ChatView.swift
//  ChatAll
//
//  会话界面：消息列表（自动滚到底）、气泡、发送中转圈、输入栏（文本/相册/文件/按住录音）、
//  图片全屏预览、文件下载后系统分享、语音播放。
//

import SwiftUI
import UIKit
import QuartzCore
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
    @Binding var previewItem: PreviewItem?
    @State private var shareItem: ShareItem? = nil
    @State private var sending = false
    @StateObject private var recorder = VoiceRecorder()
    @State private var inputFocused = false
    /// 键盘升降期间逐帧贴底的驱动器（见 followKeyboard）
    @State private var keyboardFollow: KeyboardBottomFollower?
    /// 用户是否仍按住录音键（用于解决异步 start 与同步 end 的竞态：
    /// 快速点击时 onEnded 先于 recorder.start() 执行，isRecording 仍为 false，
    /// endRecord 会提前 return，导致录音启动后永远无法停止。）
    @State private var isPressing = false

    /// 每个图片 URL 对应气泡在屏幕上的 frame（用于展开过渡）
    @State private var imageFrames: [URL: CGRect] = [:]

    var body: some View {
        ZStack {
            // 聊天页也铺同一张背景图
            ChatBackgroundImageView()

            // 输入栏用 safeAreaInset 挂在消息列表底部：
            // 键盘升降完全交给系统驱动（与键盘同一动画），输入栏始终贴合键盘顶边，
            // 不再手动计算 padding，避免出现输入栏与键盘不同步、收起时页面回跳。
            messageArea
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        inputBar
                    }
                }
                .navigationBarTitle(title, displayMode: .inline)
                .toolbarBackground(.hidden, for: .navigationBar)
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
                    keyboardFollow?.stop()
                    keyboardFollow = nil
                    // 离开页面时若还在录音，立即停止并丢弃（不发送）
                    if recorder.isRecording {
                        isPressing = false
                        _ = recorder.stop()
                    }
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

            // 图片预览由 MainView 在导航栏之上统一承载（避免切换导航栏显隐导致页面重新布局）

            // 录音中 overlay：屏幕中间显示读秒 + 波形动画
            if recorder.isRecording {
                RecordingOverlayView(seconds: recorder.seconds, power: recorder.power)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .transition(.opacity)
            }
        }
    }

    /// 预先计算每条消息是否需要显示时间分隔线
    private func computeSeparatorFlags(messages: [ChatMessage]) -> [Bool] {
        guard !messages.isEmpty else { return [] }
        var flags = [Bool](repeating: false, count: messages.count)
        flags[0] = true // 第一条始终显示
        for i in 1..<messages.count {
            flags[i] = AppConfig.shouldShowSeparator(
                previous: messages[i - 1].createdAt,
                current: messages[i].createdAt
            )
        }
        return flags
    }

    // MARK: - 消息列表（续）

    private var messages: [ChatMessage] {
        store.messages(for: peerId)
    }

    /// 列表底部固定锚点：消息行的 id 会在服务端 ACK 后变化（本地负数 → 真实 id），
    /// 用它滚动会因目标瞬时消失而失效，故始终滚到这个不变的空视图。
    private let bottomAnchor = "chat_bottom_anchor"

    private var messageArea: some View {
        // 预先算出每条消息是否需要显示时间分隔线（避免在 ViewBuilder 里写复杂 if 导致编译器超时）
        let separatorFlags = computeSeparatorFlags(messages: messages)
        let enumerated = Array(messages.enumerated())

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(enumerated, id: \.element.id) { idx, msg in
                        if separatorFlags[idx] {
                            timeSeparator(for: msg.createdAt, topPad: idx == 0 ? 4 : 6)
                        }
                        MessageRow(message: msg,
                                   isSelf: msg.fromId == (store.currentUser?.id ?? 0),
                                   showSender: isGroup,
                                   senderName: senderName(msg),
                                   senderAvatar: senderAvatar(msg),
                                   store: store,
                                   peerId: peerId,
                                   recordFrame: { url, frame in imageFrames[url] = frame },
                                   onTapImage: { url in openImagePreview(url: url) },
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
            .modifier(ScrollDismissesKeyboardCompat())
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
                for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                followKeyboard(proxy, note: note)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { note in
                // 部分收起路径只发 WillHide，这里兜底走同一套跟随逻辑
                followKeyboard(proxy, note: note)
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

    // MARK: - 键盘跟随

    /// 键盘升降期间逐帧把消息列表贴到底部。
    /// 系统的键盘避让动画每一帧都会改变列表可视区高度，只在开始/结束时各滚一次，
    /// 会出现「消息先被输入栏挡住、最后再跳一下」的错位感；
    /// 这里在整个键盘动画期间跟随每个刷新帧重新贴底，列表底部始终贴着输入栏顶边，
    /// 弹出与收回都与键盘同步。
    private func followKeyboard(_ proxy: ScrollViewProxy, note: Notification) {
        guard !messages.isEmpty else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let scroll = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        keyboardFollow?.stop()
        keyboardFollow = nil
        guard duration > 0.01 else {
            // 无动画的键盘变化（例如切换输入法高度）：直接贴底即可
            scroll()
            return
        }
        let follower = KeyboardBottomFollower(duration: duration + 0.08, onTick: scroll)
        follower.start()
        keyboardFollow = follower
    }

    private func senderName(_ msg: ChatMessage) -> String {
        if msg.fromId == (store.currentUser?.id ?? 0) { return store.currentUserName() }
        return store.friendName(msg.fromId) ?? "用户\(msg.fromId)"
    }

    private func senderAvatar(_ msg: ChatMessage) -> String {
        if msg.fromId == (store.currentUser?.id ?? 0) { return store.currentUser?.avatar ?? "" }
        return store.friends.first(where: { $0.id == msg.fromId })?.avatar ?? ""
    }

    /// 时间分隔线（微信风格：居中灰色小圆角玻璃标签）
    private func timeSeparator(for createdAt: String?, topPad: CGFloat = 4) -> some View {
        let text = AppConfig.chatTimeString(createdAt)
        let content = text.isEmpty ? AppConfig.listTimeString(createdAt) : text
        return Text(content.isEmpty ? "—" : content)
            .font(.system(size: 11))
            .foregroundColor(.gray)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .padding(.top, topPad)
            .background(Rectangle().fill(.ultraThinMaterial))
            .cornerRadius(4)
            .frame(maxWidth: .infinity)
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

            ChatInputField(text: $inputText,
                           isFocused: $inputFocused,
                           onSend: sendText)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 10)

            if inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                // 按住录音
                ZStack {
                    Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(recorder.isRecording ? .white : .gray)
                        .frame(width: 40, height: 34)
                }
                .liquidGlass(opacity: recorder.isRecording ? 0.9 : store.backgroundOpacity, cornerRadius: 8)
                .overlay {
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.35))
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
                        .overlay {
                            if #available(iOS 26.0, *) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.clear)
                                    .glassEffect()
                            }
                        }
                }
                .disabled(sending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 12)
    }

    // MARK: - 发送

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.sendMessage(to: peerId, isGroup: isGroup,
                          contentType: "TEXT", content: text)
        // 只清空文字，不动焦点：UIKit 输入框在发送键回调里已拒绝 resign，
        // 键盘不会收起，也就不存在重新聚焦造成的回弹闪烁。
        inputText = ""
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
        isPressing = true
        Task { @MainActor in
            let ok = await recorder.requestPermission()
            guard ok else {
                store.errorMessage = "没有麦克风权限"
                isPressing = false
                return
            }
            do {
                try recorder.start()
                // 权限申请 + start 是异步的，用户可能在它完成前就已松手。
                // 若已松手，立刻收尾（时长不足 1 秒会被丢弃，不会误发）。
                if !isPressing {
                    finishRecording()
                }
            } catch {
                store.errorMessage = "录音失败"
                isPressing = false
            }
        }
    }

    private func endRecord() {
        isPressing = false
        // 若录音尚未真正启动（异步权限/start 未完成），这里直接返回；
        // beginRecord 的 Task 在 start 完成后会通过 isPressing == false 触发 finishRecording。
        guard recorder.isRecording else { return }
        finishRecording()
    }

    /// 停止录音并发送（时长不足 1 秒则丢弃）
    private func finishRecording() {
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

    /// 收集当前会话所有图片 URL，打开预览并定位到当前点击的图片
    private func openImagePreview(url: URL) {
        let imageURLs = messages.compactMap { msg -> URL? in
            guard msg.contentType == "IMAGE" else { return nil }
            return AppConfig.fileURL(msg.fileUrl)
        }
        let frame = imageFrames[url]
        if let idx = imageURLs.firstIndex(of: url) {
            previewItem = PreviewItem(urls: imageURLs, index: idx, sourceFrame: frame)
        } else {
            previewItem = PreviewItem(urls: [url], index: 0, sourceFrame: frame)
        }
    }
}

/// iOS 16+ 把列表拖动收起键盘改为「立即整体收起」：
/// 交互式逐帧拖拽与手动键盘跟随无法逐帧同步，且是半截键盘残留的常见诱因。
private struct ScrollDismissesKeyboardCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.immediately)
        } else {
            content
        }
    }
}

// MARK: - 键盘跟随器

/// 在键盘动画期间按屏幕刷新帧回调，让消息列表逐帧贴底。
/// 系统键盘避让是逐帧改变列表可视区高度的，只有跟随每一帧重新贴底，
/// 列表才能与键盘/输入栏完全同步（既不提前，也不在动画结束后补跳）。
private final class KeyboardBottomFollower: NSObject {
    private var link: CADisplayLink?
    private var endTime: CFTimeInterval = 0
    private let duration: Double
    private let onTick: () -> Void

    init(duration: Double, onTick: @escaping () -> Void) {
        self.duration = duration
        self.onTick = onTick
    }

    func start() {
        stop()
        endTime = CACurrentMediaTime() + duration
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard CACurrentMediaTime() < endTime else {
            stop()
            return
        }
        onTick()
    }
}

// MARK: - 聊天输入框

/// SwiftUI 的 TextField 按下键盘「发送」键（onSubmit）后会主动 resignFirstResponder，
/// 键盘必然收起；再靠延时重新聚焦就会看到键盘回弹闪烁。
/// 这里用 UITextField 代理拦截回车：发送后返回 false，不释放第一响应者，
/// 键盘全程不关闭，输入框焦点也不丢失。
private struct ChatInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSend: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 17)
        field.placeholder = "输入消息"
        field.returnKeyType = .send
        field.text = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 垂直方向固定按内容高度，避免 SwiftUI 把输入框拉满剩余空间
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.textChanged(_:)),
                        for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // 拼音等输入法正在组合输入（markedTextRange 非空）时不覆盖文本，避免打断联想
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChatInputField

        init(_ parent: ChatInputField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// 返回 false：键盘的「发送」键只触发发送，不让输入框退出第一响应者。
        /// 键盘因此不会收起，也不会出现重新弹出的回弹动画。
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSend()
            return false
        }

        /// 部分第三方输入法的「发送」键是插入换行而非触发 return，这里同样拦截，
        /// 避免换行被吞掉或输入框因此失焦。
        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            if string == "\n" {
                parent.onSend()
                return false
            }
            return true
        }
    }
}

// MARK: - 单条消息气泡

struct MessageRow: View {
    let message: ChatMessage
    let isSelf: Bool
    let showSender: Bool
    let senderName: String
    let senderAvatar: String
    let store: AppStore
    let peerId: Int64
    let recordFrame: (URL, CGRect) -> Void
    let onTapImage: (URL) -> Void
    let onTapFile: (ChatMessage) -> Void
    let onTapVoice: (ChatMessage) -> Void
    let isPlaying: Bool

    var body: some View {
        if message.recalled {
            recalledMessage
        } else {
            normalRow
        }
    }

    /// 撤回消息：居中灰色提示（微信风格）
    private var recalledMessage: some View {
        Text(isSelf ? "你撤回了一条消息" : "\(senderName) 撤回了一条消息")
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity)
            .contextMenu {
                Button(role: .destructive) {
                    store.deleteMessage(peerId: peerId, msgId: message.msgId)
                } label: { Label("删除", systemImage: "trash") }
            }
    }

    /// 普通消息行
    private var normalRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelf {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 2) {
                    bubble
                        .contextMenu { contextMenuActions }
                    readStatus
                }
                statusIndicator
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
                        .contextMenu { contextMenuActions }
                }
                Spacer(minLength: 40)
            }
        }
        .textSelection(.disabled)   // 整行禁用文本选择，彻底屏蔽英文系统 edit menu
    }

    /// 长按气泡弹出的菜单项（全部中文，覆盖系统英文菜单）
    @ViewBuilder
    private var contextMenuActions: some View {
        // 文本消息 → 可复制
        if message.contentType == "TEXT",
           let content = message.content, !content.isEmpty {
            Button {
                UIPasteboard.general.string = content
            } label: { Label("复制", systemImage: "doc.on.doc") }
        }
        if isSelf && store.canRecall(message) {
            Button {
                store.recallMessage(peerId: peerId, msgId: message.msgId)
            } label: { Label("撤回", systemImage: "arrow.uturn.left") }
        }
        Button(role: .destructive) {
            store.deleteMessage(peerId: peerId, msgId: message.msgId)
        } label: { Label("删除", systemImage: "trash") }
    }

    /// 自己发的 ACK 消息下方显示"已读 / 未读"（仅单聊，群聊无意义）
    @ViewBuilder
    private var readStatus: some View {
        if isSelf && message.localState == 1 && !showSender {
            Text(message.readByPeer ? "已读" : "未读")
                .font(.system(size: 10))
                .foregroundColor(.gray)
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
        if let call = callRecord {
            callRecordBubble(call.isVideo, call.seconds)
        } else {
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
    }

    /// 通话记录（普通文本消息，内容形如 [[call:voice:83]]）
    private var callRecord: (isVideo: Bool, seconds: Int)? {
        guard message.contentType == "TEXT" else { return nil }
        let text = (message.content ?? "").trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("[[call:"), text.hasSuffix("]]") else { return nil }
        let body = text.dropFirst("[[call:".count).dropLast(2)
        let parts = body.split(separator: ":")
        guard parts.count == 2,
              parts[0] == "voice" || parts[0] == "video",
              let seconds = Int(parts[1]) else { return nil }
        return (parts[0] == "video", seconds)
    }

    /// 通话记录气泡：图标 + 语音/视频通话 + 时长
    private func callRecordBubble(_ video: Bool, _ seconds: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: video ? "video.fill" : "phone.fill")
                .font(.system(size: 14))
            Text((video ? "视频通话 " : "语音通话 ") + Self.durationText(seconds))
                .font(.system(size: 15))
        }
        .foregroundColor(isSelf ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelf ? Color.chatGreen : Color.bubbleGray)
        .cornerRadius(14)
    }

    private static func durationText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private var textBubble: some View {
        Text(message.content ?? "")
            .font(.system(size: 16))
            .foregroundColor(isSelf ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelf ? Color.chatGreen : Color.bubbleGray)
            .cornerRadius(14)
            .textSelection(.disabled)   // 禁用系统英文选择菜单，统一用我们自己的 contextMenu
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
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        if let url = AppConfig.fileURL(message.fileUrl) {
                            let frame = geo.frame(in: .global)
                            recordFrame(url, frame)
                        }
                    }
                    .onChange(of: geo.frame(in: .global)) { new in
                        if let url = AppConfig.fileURL(message.fileUrl) {
                            recordFrame(url, new)
                        }
                    }
            }
        )
        .onTapGesture {
            if let url = AppConfig.fileURL(message.fileUrl) { onTapImage(url) }
        }
    }

    private var fileBubble: some View {
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
        .onTapGesture { onTapFile(message) }
    }

    private var fileSizeText: String {
        let size = message.fileSize ?? 0
        if size <= 0 { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }

    private var voiceBubble: some View {
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
        .onTapGesture { onTapVoice(message) }
    }
}

// MARK: - 辅助类型

/// 图片预览项：所有图片 URL + 当前索引 + 源气泡 frame（用于展开过渡）
struct PreviewItem: Identifiable {
    let id = UUID()
    let urls: [URL]
    let index: Int
    let sourceFrame: CGRect?
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

// MARK: - 录音中全屏提示

/// 长按录音时屏幕中间的覆盖层：麦克风图标 + 读秒 + 波形条 + 底部提示
private struct RecordingOverlayView: View {
    let seconds: Int
    let power: Float

    /// 6 根波形条，颜色从左到右渐变
    private let barCount = 6
    private let barColors: [Color] = [
        Color.red.opacity(0.9), Color.orange.opacity(0.9),
        Color.yellow.opacity(0.9), Color.green.opacity(0.9),
        Color.blue.opacity(0.9), Color.purple.opacity(0.9)
    ]

    // 为每根条一个"相位"，让波形自然抖动
    @State private var phases: [CGFloat] = (0..<6).map { _ in CGFloat.random(in: 0...1) }

    var body: some View {
        ZStack {
            // 半透明背景遮罩
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            // 中间卡片
            VStack(spacing: 18) {
                // 麦克风 icon + 外圈脉冲
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.15 + Double(power) * 0.4))
                        .frame(width: 96, height: 96)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.red))
                }

                // 读秒
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white)

                // 波形条
                HStack(alignment: .center, spacing: 4) {
                    ForEach(0..<barCount, id: \.self) { i in
                        bar(index: i)
                    }
                }
                .frame(height: 40)
                .padding(.horizontal, 8)

                // 底部提示
                Text("松开发送")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 8)
            .onAppear { tickPhase() }
            .onChange(of: power) { _ in tickPhase() }
        }
    }

    private func bar(index: Int) -> some View {
        // 基础高度由 power 决定，再叠加该条自己的相位抖动，让波形有"律动"
        let base = CGFloat(power) * 34 + 4
        let jitter = phases[index] * CGFloat(power) * 14
        let h = min(40, max(4, base + jitter))
        return RoundedRectangle(cornerRadius: 2)
            .fill(barColors[index])
            .frame(width: 5, height: h)
            .animation(.linear(duration: 0.12), value: h)
    }

    private func tickPhase() {
        // 每次 tick 让 6 根条各自一个新的随机相位
        phases = phases.map { _ in CGFloat.random(in: 0...1) }
    }
}
