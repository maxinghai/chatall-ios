//
//  ChatAllApp.swift
//  ChatAll
//
//  应用入口：注入 AppStore，根视图按登录态切换，处理 chatall:// 回调（Bark 通知返回后刷新离线消息）。
//

import SwiftUI

@main
struct ChatAllApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { url in
                    handleURL(url)
                }
                .onChange(of: scenePhase) { phase in
                    // 回到前台兜底：确保 socket 存在。
                    // 后台期间 socket 被系统挂断时，由 WsClient 监听 didBecomeActive 强制重建。
                    if phase == .active {
                        store.ensureConnected()
                    }
                }
        }
    }

    /// 处理自定义 scheme 回调
    private func handleURL(_ url: URL) {
        guard url.scheme == "chatall" else { return }
        // 灵动岛 / 锁屏实时活动：打开通话页或挂断
        switch url.host {
        case "open-call":
            Task { @MainActor in
                store.call.restoreUI()
            }
            return
        case "hangup":
            Task { @MainActor in
                store.call.hangup()
            }
            return
        default:
            break
        }
        Task { @MainActor in
            await store.loadOffline()
            await store.refreshFriends()
            await store.refreshPending()
        }
    }
}

/// 根视图：已登录 → 主界面；否则 → 登录页
struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack {
            // 全局底图：登录页 / 主界面（会话、聊天、个人资料）共用
            ChatBackgroundImageView()

            Group {
                if store.isLoggedIn {
                    MainView()
                } else {
                    LoginView()
                }
            }
        }
    }
}
