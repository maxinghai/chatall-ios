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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }

    /// 处理自定义 scheme 回调
    private func handleURL(_ url: URL) {
        guard url.scheme == "chatall" else { return }
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
        Group {
            if store.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
    }
}
