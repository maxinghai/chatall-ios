//
//  CallLiveActivityController.swift
//  ChatAll
//
//  语音通话实时活动的开关与状态更新：接通时在灵动岛/锁屏展示，挂断或结束时关闭。
//

import ActivityKit
import Foundation

@MainActor
final class CallLiveActivityController {

    static let shared = CallLiveActivityController()

    private var activity: Activity<CallActivityAttributes>?
    private var starting = false
    /// 结束/重新开始时的世代号，避免异步启动在挂断后又把活动建回来
    private var generation = 0

    var isActive: Bool { activity != nil }

    /// 开始实时活动（需在 App 前台调用）
    func start(peerName: String, status: String, muted: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !starting, activity == nil else { return }
        starting = true
        generation += 1
        let gen = generation
        let attributes = CallActivityAttributes(peerName: peerName, startedAt: Date())
        let state = CallActivityAttributes.ContentState(status: status, muted: muted)
        Task { @MainActor in
            // 清掉上一次进程残留的活动，避免多条通话同时挂在灵动岛
            for stale in Activity<CallActivityAttributes>.activities {
                await stale.end(using: nil, dismissalPolicy: .immediate)
            }
            guard gen == self.generation else {
                self.starting = false
                return
            }
            do {
                self.activity = try Activity.request(attributes: attributes,
                                                     contentState: state,
                                                     pushType: nil)
            } catch {
                self.activity = nil
            }
            self.starting = false
        }
    }

    /// 更新状态（例如“通话中”“已静音”）
    func update(status: String, muted: Bool) {
        guard let activity else { return }
        let state = CallActivityAttributes.ContentState(status: status, muted: muted)
        Task { await activity.update(using: state) }
    }

    /// 结束并立即移除（含异常残留的活动）
    func end() {
        generation += 1
        starting = false
        activity = nil
        for item in Activity<CallActivityAttributes>.activities {
            Task { await item.end(using: nil, dismissalPolicy: .immediate) }
        }
    }
}
