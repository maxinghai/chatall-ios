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
                    // 回到前台：检测连接状态，未连接自动重建（后台期间 socket 常被系统掐断）
                    if phase == .active {
                        store.ensureConnected()
                    }
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
