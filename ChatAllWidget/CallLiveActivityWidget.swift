//
//  CallLiveActivityWidget.swift
//  ChatAllWidget
//
//  语音通话实时活动：灵动岛紧凑/展开视图 + 锁屏卡片。
//  点击“打开”回到 App 通话页；点击“挂断”回到 App 并结束通话。
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ChatAllWidgetBundle: WidgetBundle {
    var body: some Widget {
        CallLiveActivityWidget()
    }
}

struct CallLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            LockScreenCallView(context: context)
                .widgetURL(URL(string: "chatall://open-call"))
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ZStack {
                        Circle()
                            .fill(Color.callGreen)
                            .frame(width: 36, height: 36)
                        Image(systemName: "phone.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                    }
                    .padding(.leading, 8)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.peerName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(statusText(context))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    timerText(context)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: 72)
                        .padding(.trailing, 8)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Link(destination: URL(string: "chatall://open-call")!) {
                            Label("打开", systemImage: "phone.arrow.up.right.fill")
                                .font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Link(destination: URL(string: "chatall://hangup")!) {
                            Label("挂断", systemImage: "phone.down.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: "phone.fill")
                    .foregroundColor(.callGreen)
            } compactTrailing: {
                timerText(context)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "phone.fill")
                    .foregroundColor(.callGreen)
            }
            .keylineTint(.callGreen)
        }
    }

    /// 状态文案：静音时追加“已静音”
    private func statusText(_ context: ActivityViewContext<CallActivityAttributes>) -> String {
        let status = context.state.status.isEmpty ? "通话中" : context.state.status
        return context.state.muted ? "\(status) · 已静音" : status
    }

    /// 通话计时（由系统按开始时间自动走时）
    private func timerText(_ context: ActivityViewContext<CallActivityAttributes>) -> Text {
        Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
             countsDown: false)
            .monospacedDigit()
    }
}

/// 锁屏 / 通知中心卡片
private struct LockScreenCallView: View {
    let context: ActivityViewContext<CallActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.callGreen)
                    .frame(width: 44, height: 44)
                Image(systemName: "phone.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.peerName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
                 countsDown: false)
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.white)
        }
        .padding(12)
    }

    private var statusText: String {
        let status = context.state.status.isEmpty ? "通话中" : context.state.status
        return context.state.muted ? "\(status) · 已静音" : status
    }
}

extension Color {
    /// 与 App 内品牌绿一致的 #07C160
    static let callGreen = Color(red: 0.027, green: 0.757, blue: 0.376)
}
