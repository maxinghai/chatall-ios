//
//  MainView.swift
//  ChatAll
//
//  底部三标签（聊天 / 群组 / 我）+ 右上角铃铛（新的朋友）与"+"菜单
//  + 好友 contextMenu（设置备注 / 删除好友）+ 未读红点角标 + 在线小绿点。
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: AppStore

    @State private var tab = 0
    @State private var showSearch = false
    @State private var showCreateGroup = false
    @State private var showPending = false
    @State private var remarkTarget: FriendItem? = nil

    private var tabTitle: String {
        switch tab {
        case 0: return "聊天"
        case 1: return "群组"
        default: return "我"
        }
    }

    var body: some View {
        ZStack {
            // 底图：所有页面共用同一张
            ChatBackgroundImageView(url: store.backgroundURL)

            NavigationView {
                VStack(spacing: 0) {
                    content
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
                        pendingButton
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        plusMenu
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
        // 这里只用彩色圆点表示连接状态（绿=在线、黄=连接中、红=离线）。
        Circle()
            .fill(store.connectionState.color)
            .frame(width: 10, height: 10)
            .padding(6)
            .animation(.easeInOut(duration: 0.2), value: store.connectionState)
            .accessibilityLabel("连接状态：\(store.connectionState.title)")
    }

    // MARK: - 右上角铃铛（新的朋友）

    private var pendingButton: some View {
        Button {
            showPending = true
        } label: {
            Image(systemName: "bell")
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
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 右上角 "+" 菜单

    private var plusMenu: some View {
        Menu {
            Button {
                showSearch = true
            } label: {
                Label("搜索加好友", systemImage: "person.badge.plus")
            }
            Button {
                showCreateGroup = true
            } label: {
                Label("发起群聊", systemImage: "person.3")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0: friendList
        case 1: groupList
        default: ProfileView().padding(.bottom, 56)
        }
    }

    private var friendList: some View {
        List {
            ForEach(store.friends) { friend in
                NavigationLink(destination: ChatView(peerId: friend.id,
                                                     isGroup: false,
                                                     title: friend.displayName,
                                                     avatar: friend.avatar)) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(name: friend.displayName, avatar: friend.avatar, size: 44)
                            if friend.online {
                                Circle()
                                    .fill(Color.chatGreen)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(Color(.separator), lineWidth: 1.5))
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(friend.displayName)
                                .font(.system(size: 16))
                            if let preview = store.lastPreviews[friend.id], !preview.isEmpty {
                                Text(preview)
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        rightColumn(time: store.lastTimes[friend.id],
                                    unread: store.unread(friend.id))
                    }
                }
                .contextMenu {
                    Button {
                        remarkTarget = friend
                    } label: {
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
        .listStyle(PlainListStyle())
        .liquidGlassList(opacity: store.backgroundOpacity)
        .padding(.bottom, 56)
    }

    private var groupList: some View {
        List {
            ForEach(store.groups) { group in
                NavigationLink(destination: ChatView(peerId: group.id,
                                                     isGroup: true,
                                                     title: group.displayName,
                                                     avatar: group.avatar)) {
                    HStack(spacing: 12) {
                        AvatarView(name: group.displayName, avatar: group.avatar, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName)
                                .font(.system(size: 16))
                            Text("\(group.memberCount) 人")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        rightColumn(time: store.lastTimes[group.id],
                                    unread: store.unread(group.id))
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
        .liquidGlassList(opacity: store.backgroundOpacity)
        .padding(.bottom, 56)
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

    // MARK: - 底部标签栏

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(index: 0, title: "聊天", icon: "message", badgeCount: totalFriendUnread)
            tabButton(index: 1, title: "群组", icon: "person.3", badgeCount: totalGroupUnread)
            tabButton(index: 2, title: "我", icon: "person", badgeCount: 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(.systemBackground).opacity(store.backgroundOpacity)
            }
        )
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var totalFriendUnread: Int {
        store.friends.reduce(0) { $0 + store.unread($1.id) }
    }

    private var totalGroupUnread: Int {
        store.groups.reduce(0) { $0 + store.unread($1.id) }
    }

    private func tabButton(index: Int, title: String, icon: String, badgeCount: Int) -> some View {
        Button {
            tab = index
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                    if badgeCount > 0 {
                        Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 12, y: -8)
                    }
                }
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(tab == index ? .chatGreen : .gray)
            .frame(maxWidth: .infinity)
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
                    .padding(.vertical, 4)
                }
            }
            .listStyle(PlainListStyle())
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
                    }
                    if searched && results.isEmpty {
                        Text("没有找到用户").foregroundColor(.gray)
                    }
                }
                .listStyle(PlainListStyle())
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
                        }
                    }
                }
                .listStyle(PlainListStyle())
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
                }
                Section {
                    Text("备注仅自己可见")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
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
