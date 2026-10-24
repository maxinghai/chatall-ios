//
//  MainView.swift
//  ChatAll
//
//  底部悬浮导航栏（会话 / 中间动态按钮 / 我）+ 右上角（加好友 / 发起群聊 / 新的朋友铃铛）
//  + 好友 contextMenu（设置备注 / 删除好友）+ 未读红点角标 + 在线小绿点。
//  中间按钮点击后全屏打开动态页（屏蔽罩，其他按钮不可点）。
//

import SwiftUI
import UIKit

struct MainView: View {
    @EnvironmentObject var store: AppStore

    @State private var tab = 0
    @State private var showSearch = false
    @State private var showCreateGroup = false
    @State private var showPending = false
    @State private var remarkTarget: FriendItem? = nil
    @State private var showMoments = false
    /// 聊天页图片预览（挂在导航栏之上，避免切换导航栏显隐导致页面重新布局抖动）
    @State private var previewItem: PreviewItem? = nil

    /// 悬浮底栏占用的高度（内容区需要留白，避免被遮挡）
    private let bottomBarSpace: CGFloat = 86

    private var tabTitle: String {
        tab == 0 ? "会话" : "我"
    }

    var body: some View {
        ZStack {
            NavigationView {
                ZStack {
                    // 底图必须放在 NavigationView 内部：
                    // 放在外层会被导航容器的不透明底色整块盖住，导致主页看不到背景图
                    ChatBackgroundImageView()

                    VStack(spacing: 0) {
                        content
                    }
                }
                .navigationBarTitle(tabTitle, displayMode: .inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .bottomBar)
                .toolbarBackground(.automatic, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        connectionBadge
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        menuButton
                    }
                }
                .overlay(alignment: .bottom) { bottomBar }
                .overlay(alignment: .top) { toastView }
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .sheet(isPresented: $showSearch) { SearchUserSheet() }
            .sheet(isPresented: $showCreateGroup) { CreateGroupSheet() }
            .sheet(isPresented: $showPending) { PendingRequestsSheet() }
            .sheet(item: $remarkTarget) { friend in
                RemarkSheet(friend: friend)
            }
            .fullScreenCover(isPresented: $showMoments) {
                // 动态页全屏覆盖：相当于屏蔽罩，打开后屏幕其他按钮均无法点击
                MomentsView()
                    .environmentObject(store)
            }
            .fullScreenCover(isPresented: $store.callUIVisible, onDismiss: {
                // 下滑返回：来电中视为拒绝；通话中则收起为悬浮小窗/悬浮电话图标，不挂断
                if store.call.state == .incoming {
                    store.call.hangup()
                } else if store.call.state != .idle {
                    store.call.minimizeUI()
                }
            }) {
                CallView(call: store.call)
            }
            .overlay {
                // 收起后悬浮在页面上的通话小窗（视频）/电话图标（语音），点击恢复通话页
                CallMiniOverlay(call: store.call) {
                    store.call.restoreUI()
                }
            }

            // 图片全屏预览：放在 NavigationView 之外，才能盖住导航栏（返回 / 通话按钮），
            // 同时不改动聊天页安全区，收起预览时页面不会重新布局、不会抖动
            if let item = previewItem {
                ImagePreviewView(urls: item.urls,
                                 currentIndex: item.index,
                                 sourceFrame: item.sourceFrame,
                                 onDismiss: { previewItem = nil })
                    .zIndex(2)
            }
        }
        .onChange(of: store.toastMessage) { value in
            guard value != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // 只清除自己弹出的那条，避免旧定时器清掉新 toast
                if store.toastMessage == value { store.toastMessage = nil }
            }
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

    // MARK: - 左上角连接状态

    private var connectionBadge: some View {
        // 导航栏左上角空间有限，iOS 26/27 的玻璃按钮会把文字截断，
        // 这里只用彩色圆点表示连接状态（绿=在线、黄=连接中、红=离线），静止不闪烁。
        // 点击圆点可手动刷新会话列表（好友 / 群组 / 未读 / 离线消息）。
        Button {
            Task { await store.reloadAll() }
        } label: {
            Circle()
                .fill(store.connectionState.color)
                .frame(width: 10, height: 10)
                .padding(6)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("连接状态：\(store.connectionState.title)，点击刷新")
    }

    // MARK: - 右上角加号菜单（添加好友 / 发起群聊 / 新的朋友）

    private var menuButton: some View {
        Menu {
            Button {
                showSearch = true
            } label: {
                Label("添加好友", systemImage: "person.badge.plus")
            }
            Button {
                showCreateGroup = true
            } label: {
                Label("发起群聊", systemImage: "person.3.fill")
            }
            Button {
                showPending = true
            } label: {
                Label("新的朋友", systemImage: "bell")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .overlay(alignment: .topTrailing) {
                    if store.totalPendingCount > 0 {
                        Text("\(min(store.totalPendingCount, 99))")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 9, y: -7)
                    }
                }
        }
        .accessibilityLabel("更多操作")
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0: conversationList
        default: ProfileView().padding(.bottom, bottomBarSpace)
        }
    }

    /// 会话行数据：朋友 / 群组统一展示，按最后消息时间倒序
    private struct ConversationRow: Identifiable, Equatable {
        let id: Int64                     // peerKey（朋友 id 或群组 id）
        let isGroup: Bool
        let name: String
        let avatar: String
        let online: Bool                  // 仅朋友有效
        let subtitle: String              // 列表预览（群显示最新消息、友显示预览）
        let lastCreatedAt: Date?          // 用于排序
        let unread: Int
    }

    private var conversations: [ConversationRow] {
        var rows: [ConversationRow] = []
        for f in store.friends {
            let peerId = f.id
            let lastDate = store.lastMessageDates[peerId]
            let preview = store.lastPreviews[peerId] ?? ""
            rows.append(ConversationRow(
                id: peerId, isGroup: false,
                name: f.displayName, avatar: f.avatar,
                online: f.online,
                subtitle: preview.isEmpty ? "暂无消息" : preview,
                lastCreatedAt: lastDate,
                unread: store.unread(peerId)
            ))
        }
        for g in store.groups {
            let peerId = g.id
            let lastDate = store.lastMessageDates[peerId]
            let preview = store.lastPreviews[peerId] ?? ""
            rows.append(ConversationRow(
                id: peerId, isGroup: true,
                name: g.displayName, avatar: g.avatar,
                online: false,
                subtitle: preview.isEmpty ? "\(g.memberCount) 人" : preview,
                lastCreatedAt: lastDate,
                unread: store.unread(peerId)
            ))
        }
        // 按最后消息时间倒序（无消息的放最后）
        rows.sort { lhs, rhs in
            switch (lhs.lastCreatedAt, rhs.lastCreatedAt) {
            case let (l?, r?): return l > r
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return rows
    }

    private var conversationList: some View {
        // iOS 26 的 List 自带一块清不掉的白色底盘，改用 ScrollView 彻底绕开系统列表样式
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(conversations) { row in
                    NavigationLink(destination: ChatView(peerId: row.id,
                                                         isGroup: row.isGroup,
                                                         title: row.name,
                                                         avatar: row.avatar,
                                                         previewItem: $previewItem)) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(name: row.name, avatar: row.avatar, size: 44)
                            if !row.isGroup && row.online {
                                Circle()
                                    .fill(Color.chatGreen)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(Color(.separator), lineWidth: 1.5))
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name)
                                .font(.system(size: 16))
                            Text(row.subtitle)
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                        rightColumn(time: store.lastTimes[row.id], unread: row.unread)
                        // List 外 NavigationLink 不再自动显示右侧箭头，手动补一个保持原样式
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(.systemGray3))
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    // 会话行不再叠加玻璃底色，直接浮在背景图上
                }
                .buttonStyle(PlainButtonStyle())
                .contextMenu {
                    if !row.isGroup, let friend = store.friends.first(where: { $0.id == row.id }) {
                        Button { remarkTarget = friend } label: {
                            Label("设置备注", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task { await store.deleteFriend(friend.id) }
                        } label: {
                            Label("删除好友", systemImage: "trash")
                        }
                    }
                }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .refreshable {
            await store.reloadAll()
        }
        .padding(.bottom, bottomBarSpace)
    }

    /// 列表行右侧的「时间 + 未读数」列
    @ViewBuilder
    private func rightColumn(time: String?, unread: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let t = time, !t.isEmpty {
                Text(t)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            if unread > 0 {
                badge(unread)
            }
        }
    }

    private func badge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, count > 9 ? 5 : 0)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.red)
            .clipShape(Capsule())
    }

    // MARK: - 悬浮底部导航栏

    private var bottomBar: some View {
        VStack(spacing: 12) {
            barContent
        }
        .padding(.bottom, 6)
    }

    private var barContent: some View {
        HStack(spacing: 0) {
            tabButton(index: 0, title: "会话",
                      icon: "bubble.left.and.bubble.right",
                      selectedIcon: "bubble.left.and.bubble.right.fill",
                      badgeCount: totalUnread)
            CenterButton(showMoments: $showMoments)
                .frame(width: 78)
            tabButton(index: 1, title: "我",
                      icon: "person",
                      selectedIcon: "person.fill",
                      badgeCount: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .liquidGlassBar(opacity: store.backgroundOpacity)
        .overlay {
            // 原生液态玻璃（iOS 26+）自带高光描边与投影，低版本才手动补
            if !supportsNativeLiquidGlass {
                Capsule().stroke(
                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8
                )
            }
        }
        .shadow(color: supportsNativeLiquidGlass ? .clear : .black.opacity(0.13),
                radius: supportsNativeLiquidGlass ? 0 : 18,
                y: supportsNativeLiquidGlass ? 0 : 6)
        .padding(.horizontal, 20)
    }

    /// 中间动态按钮：呼吸光环 + 点击打开动态页（全屏覆盖，屏蔽其他按钮）
    /// 呼吸动画状态封装在子视图内部，避免触发 MainView 整体重绘导致导航栏图标位移
    private struct CenterButton: View {
        @Binding var showMoments: Bool
        @State private var pulse = false

        var body: some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showMoments = true
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.chatGreen.opacity(0.38), lineWidth: 2)
                        .frame(width: 54, height: 54)
                        .scaleEffect(pulse ? 1.35 : 1)
                        .opacity(pulse ? 0 : 0.75)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false),
                                   value: pulse)
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color(red: 0.09, green: 0.86, blue: 0.46),
                                                    Color(red: 0.01, green: 0.62, blue: 0.33)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 54, height: 54)
                        .shadow(color: Color.chatGreen.opacity(0.45), radius: 10, y: 4)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 76, height: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .onAppear { pulse = true }
            .accessibilityLabel("动态")
        }
    }

    private var totalUnread: Int {
        store.unreadCounts.values.reduce(0, +)
    }

    private func tabButton(index: Int, title: String, icon: String,
                           selectedIcon: String, badgeCount: Int) -> some View {
        let selected = tab == index
        return Button {
            guard !selected else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.2)) { tab = index }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: selected ? selectedIcon : icon)
                        .font(.system(size: 20, weight: selected ? .semibold : .regular))
                        .frame(height: 22)
                    if badgeCount > 0 {
                        Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(.systemBackground).opacity(0.8), lineWidth: 1))
                            .offset(x: 11, y: -6)
                    }
                }
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundColor(selected ? .chatGreen : .gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.chatGreen.opacity(selected ? 0.13 : 0))
            )
            .scaleEffect(selected ? 1 : 0.96)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 顶部 toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toastMessage {
            Text(toast)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.75))
                .cornerRadius(10)
                .padding(.top, 8)
                .transition(.opacity)
        }
    }
}

// MARK: - 连接状态配色

extension ConnectionState {
    var color: Color {
        switch self {
        case .offline: return .gray
        case .connecting: return .orange
        case .online: return .chatGreen
        }
    }
}

// MARK: - 新的朋友

struct PendingRequestsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List {
                if store.pendingRequests.isEmpty {
                    Text("暂无新的好友申请")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(store.pendingRequests) { req in
                    HStack(spacing: 12) {
                        AvatarView(name: req.displayName, avatar: "", size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(req.displayName)
                                .font(.system(size: 16))
                            Text(req.msg.isEmpty ? "请求添加你为好友" : req.msg)
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("接受") {
                            Task { await store.handleRequest(req, accept: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.chatGreen)
                        Button("拒绝") {
                            Task { await store.handleRequest(req, accept: false) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
            }
            .liquidGlassList(opacity: store.backgroundOpacity)
            .navigationBarTitle("新的朋友", displayMode: .inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 搜索加好友

struct SearchUserSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) var presentationMode

    @State private var keyword = ""
    @State private var results: [UserInfo] = []
    @State private var searched = false
    @State private var messageText = "你好，我想加你为好友"

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("输入用户名/昵称搜索", text: $keyword)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("搜索") { doSearch() }
                        .foregroundColor(.chatGreen)
                }
                .padding()

                List {
                    ForEach(results) { user in
                        HStack(spacing: 12) {
                            AvatarView(name: user.displayName, avatar: user.avatar, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.system(size: 16))
                                Text("@\(user.username)").font(.system(size: 12)).foregroundColor(.gray)
                            }
                            Spacer()
                            Button("添加") {
                                Task { await store.addFriend(toId: user.id, msg: messageText) }
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.chatGreen)
                        }
                        .padding(12)
                        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                    }
                    if searched && results.isEmpty {
                        Text("没有找到用户").foregroundColor(.gray)
                    }
                }
                .liquidGlassList(opacity: store.backgroundOpacity)

                HStack {
                    Text("验证消息")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    TextField("验证消息", text: $messageText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding()
            }
            .navigationBarTitle("添加好友", displayMode: .inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func doSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        Task { @MainActor in
            results = await store.searchUser(kw)
            searched = true
        }
    }
}

// MARK: - 发起群聊

struct CreateGroupSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) var presentationMode

    @State private var name = ""
    @State private var selected: Set<Int64> = []
    @State private var creating = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    Text("群名称")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                        .frame(width: 70, alignment: .leading)
                    TextField("请输入群名称", text: $name)
                }
                .padding()

                Text("选择成员（\(selected.count)）")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                List {
                    ForEach(store.friends) { friend in
                        Button {
                            toggle(friend.id)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: friend.displayName, avatar: friend.avatar, size: 40)
                                Text(friend.displayName).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(friend.id) ? .chatGreen : .gray)
                            }
                            .padding(12)
                            .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                        }
                    }
                }
                .liquidGlassList(opacity: store.backgroundOpacity)
            }
            .navigationBarTitle("发起群聊", displayMode: .inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("创建") { create() }
                        .disabled(name.isEmpty || selected.isEmpty || creating)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func create() {
        creating = true
        let n = name
        let ids = Array(selected)
        Task { @MainActor in
            _ = await store.createGroup(name: n, memberIds: ids)
            creating = false
            presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - 设置备注

struct RemarkSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) var presentationMode

    let friend: FriendItem
    @State private var remark = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("备注名")) {
                    TextField("给 \(friend.displayName) 设置备注", text: $remark)
                        .padding(14)
                        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
                Section {
                    Text("备注仅自己可见")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .padding(14)
                        .liquidGlass(opacity: store.backgroundOpacity, cornerRadius: 14)
                }
            }
            .liquidGlassList(opacity: store.backgroundOpacity)
            .navigationBarTitle("设置备注", displayMode: .inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        let r = remark
                        Task { @MainActor in
                            await store.setRemark(friendId: friend.id, remark: r)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear { remark = friend.remark }
    }
}
