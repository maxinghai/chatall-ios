# ChatAll iOS 补充说明

本文件是 ChatAll iOS 端的补充 README，覆盖功能清单、目录结构、通信协议、本地存储、构建配置与双端功能对照。
Android 端（`../chat-android`）以本文件描述的行为为对齐基准。

## 1. 项目简介与技术栈

ChatAll 是一个自建的即时通讯客户端，支持单聊、群聊、图片/文件/语音消息、WebRTC 音视频通话、动态（朋友圈）、Bark 推送与灵动岛通话卡片。

| 项目 | 说明 |
| --- | --- |
| 语言 | Swift 5.9 |
| UI | SwiftUI，iOS 16.1+ |
| 最低系统 | iOS 16.1 |
| 版本 | 1.0.3（Build 4），Bundle ID `com.chat.chatall` |
| 工程生成 | XcodeGen（`project.yml`） |
| 实时通话 | stasel/WebRTC 155.0.0 |
| 画中画 | `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` |
| 灵动岛 / 锁屏 | WidgetKit Live Activity（`ChatAllWidget`） |
| 网络 | `URLSession` + async/await；`URLSessionWebSocketTask` |

## 2. 目录结构

```
chatall-ios/
├── project.yml                     # XcodeGen 工程定义（target、Info.plist、权限、URL Scheme）
├── ChatAll/
│   ├── ChatAllApp.swift            # App 入口，注入 AppStore / CallManager
│   ├── Models.swift                # REST/WS 数据模型
│   ├── ApiClient.swift             # 全部 REST 接口封装
│   ├── AppConfig.swift             # 服务器、TURN/STUN、token、背景图、时间格式化、演示模式
│   ├── WsClient.swift              # WebSocket：心跳、看门狗、重连、前后台重建
│   ├── AppStore.swift              # 全局状态与业务逻辑（消息/未读/好友/群/动态/撤回）
│   ├── MessageStore.swift          # 本地消息持久化
│   ├── ImageCache.swift            # 头像与图片内存/磁盘缓存
│   ├── AvatarView.swift            # 首字彩色圆形头像
│   ├── LoginView.swift             # 登录/注册、高级设置、演示模式
│   ├── MainView.swift              # 会话列表、底部导航、好友/群入口、toast
│   ├── ChatView.swift              # 聊天页、输入栏、消息气泡、时间分隔线、长按菜单
│   ├── MomentsView.swift           # 动态列表、发布、点赞、评论、删除、九宫格
│   ├── ProfileView.swift           # 我：资料、密码、背景、Bark、缓存、退出
│   ├── CallManager.swift           # WebRTC 通话信令与状态机
│   ├── CallView.swift              # 通话界面
│   ├── CallActivityAttributes.swift# Live Activity 数据模型（与 Widget 共享）
│   ├── CallLiveActivityController.swift # 灵动岛/锁屏通话卡片控制
│   ├── RTCVideoView.swift          # WebRTC 视频渲染视图
│   ├── VoiceRecorder.swift         # 语音录制（WAV）
│   ├── ImagePreviewView.swift       # 图片全屏预览
│   ├── ImageCropView.swift         # 头像裁剪
│   └── Assets.xcassets             # AppIcon
└── ChatAllWidget/
    └── CallLiveActivityWidget.swift# 灵动岛 / 锁屏 Live Activity UI
```

## 3. 功能清单

### 3.1 账号

- 登录 / 注册切换；注册需昵称。
- 服务器地址放在折叠的“高级设置”中，默认 `43.248.188.28:18422`。
- 演示模式：本地 mock 数据，不访问服务端。

### 3.2 好友与群组

- 搜索用户并发送好友申请；新的朋友列表（同意/拒绝，带角标）。
- 好友备注、删除好友。
- 发起群聊（选成员）、群成员列表、群邀请。

### 3.3 会话列表

- 单聊 + 群聊合并，按最后消息时间倒序。
- 在线好友显示绿点；无消息时单聊显示“暂无消息”、群聊显示“N 人”。
- 每行显示最后消息预览（`我: ` 前缀）、时间、未读数。
- 下拉刷新；连接状态圆点可点击刷新。
- 底部导航：会话 / 动态（中间呼吸按钮）/ 我，会话项显示未读总数角标。

### 3.4 消息

- 文本、图片（多选、发送前压缩：最长边 1600 / JPEG 0.7）、文件、语音（WAV）。
- 送达/已读状态；发送中状态；`READ` 上报与 `READ_RECEIPT` 同步。
- 长按消息：复制、撤回（2 分钟内）、删除（本地）。
- 撤回后显示“你撤回了一条消息”，会话列表预览自动跳过撤回消息。
- 时间分隔线：首条或间隔超过 5 分钟/跨天时显示。
- 图片全屏预览、保存到相册、文件分享。
- 通话记录以消息形式写入，格式 `[[call:voice|video:秒数]]`。

### 3.5 音视频通话

- WebRTC 语音/视频通话，信令走 WS `CALL` / `CALL_SIGNAL`（INVITE / ACCEPT / REJECT / CANCEL / HANGUP / SDP / ICE）。
- 静音、扬声器、前后摄像头切换。
- 画中画（PiP）；语音通话支持后台音频；灵动岛/锁屏 Live Activity 显示通话状态。

### 3.6 动态（朋友圈）

- 列表：头像、昵称、正文、九宫格图片、点赞数、评论区。
- 发布：文字 + 最多 9 张图（JPEG 0.8 上传）。
- 点赞 / 取消点赞、评论、删除自己的动态。
- 空态文案：“还没有动态，点击右上角发布第一条吧”。

### 3.7 我

- 个人资料（头像上传、昵称）、修改密码。
- 聊天背景：从相册选择、恢复默认、玻璃透明度滑块 0.15–0.95（显示不透明度百分比）。
- Bark 推送绑定（提示地址 `http://103.40.14.100:34761`）。
- 清除缓存、退出登录、服务器地址查看。

## 4. 通信协议

### 4.1 REST

- Base URL：`http://{host}`。
- 统一响应：`{ "code": 0, "msg": "ok", "data": ... }`，`code != 0` 视为失败并抛错。
- 鉴权：`Authorization: Bearer {token}`。

主要接口：

| 方法与路径 | 说明 |
| --- | --- |
| `POST /api/auth/login` | 登录 |
| `POST /api/auth/register` | 注册 |
| `GET /api/friend/list` | 好友列表 |
| `GET /api/friend/request/pending` | 待处理好友申请 |
| `POST /api/friend/request` | 发送好友申请 |
| `POST /api/friend/request/handle` | 处理好友申请 |
| `DELETE /api/friend/{id}` | 删除好友 |
| `POST /api/friend/{id}/remark` | 设置备注 |
| `GET /api/user/search?kw=` | 搜索用户 |
| `GET /api/user/{id}` | 用户资料 |
| `PUT /api/user/profile` | 修改昵称/头像 |
| `PUT /api/user/password` | 修改密码 |
| `GET /api/user/bark` / `POST /api/user/bark` | 查询/绑定 Bark |
| `POST /api/user/xiaomi-token` | 上报推送 token |
| `GET /api/group/my` | 我的群 |
| `POST /api/group/create` | 创建群 |
| `POST /api/group/{id}/invite` | 邀请入群 |
| `GET /api/message/offline` | 离线消息 |
| `GET /api/message/unread` | 单聊未读统计 |
| `GET /api/message/history/single` | 单聊历史（`peerId`、`limit`） |
| `GET /api/message/history/group` | 群历史（`groupId`、`limit`） |
| `GET /api/moment/feed` | 动态列表 |
| `POST /api/moment/create` | 发布动态，`images` 为 JSON 字符串数组 |
| `POST /api/moment/{id}/like` | 点赞/取消，返回布尔 |
| `POST /api/moment/{id}/comment` | 评论 |
| `DELETE /api/moment/{id}` | 删除动态 |
| `POST /api/file/upload` | multipart 上传，返回 `{url,name,size}` |

### 4.2 WebSocket

- 地址：`ws://{host}/ws?token={token}`。
- 报文：`{ "type": "...", "data": {...} }`。
- 类型：

| type | 方向 | 说明 |
| --- | --- | --- |
| `PING` / `PONG` | 双向 | 25s 心跳，PONG 看门狗 |
| `MESSAGE` | 服务端 → 客户端 | 新消息 |
| `ACK` | 服务端 → 客户端 | 发送确认（回填 id/status） |
| `READ` | 客户端 → 服务端 | 上报已读 |
| `READ_RECEIPT` | 服务端 → 客户端 | 对方已读回执（`readerId`、`lastReadId`） |
| `CALL` / `CALL_SIGNAL` | 双向 | 通话信令 |
| `FRIEND_REQUEST` | 服务端 → 客户端 | 新好友申请 |
| `ONLINE_STATUS` | 服务端 → 客户端 | 好友在线状态 |

### 4.3 连接策略

- 发送 PING：25s；15s 内未 open 视为失败；3s 重连；PING 后 10s 无 PONG 主动重连。
- App 进入后台时保留语音通话所需音频；回到前台重建 WS。

## 5. 本地存储

| 内容 | 位置 |
| --- | --- |
| token / 当前用户 | `UserDefaults` |
| 全局聊天背景 | `Application Support/backgrounds/bg.jpg`（JPEG 85%，最长边=屏幕尺寸） |
| 背景透明度 | `UserDefaults`，默认 0.55 |
| 消息 | `MessageStore` 本地持久化（按会话） |
| 图片缓存 | `Caches`（`ImageCache`） |
| 演示模式开关 | `UserDefaults` |

## 6. 构建与运行

```bash
cd chatall-ios
xcodegen generate
open chatall-ios.xcodeproj
```

- Xcode 中选择 `ChatAll` scheme，配置开发团队后运行到真机或模拟器。
- `ChatAllWidget` 为 Live Activity 扩展，Bundle ID `com.chat.chatall.widget`，随主 App 一起签名安装。
- 服务器为 HTTP 明文，`Info.plist` 已设置 `NSAllowsArbitraryLoads = true`。
- URL Scheme：`chatall`（用于 Bark 通知点击跳回 App）。

## 7. 配置

| 项 | 默认值 |
| --- | --- |
| 服务器 | `43.248.188.28:18422` |
| HTTP | `http://{host}` |
| WebSocket | `ws://{host}/ws?token={token}` |
| TURN | `turn:103.40.14.100:34761?transport=udp` |
| STUN | `stun:stun.l.google.com:19302` 等公共 STUN |
| Bark 服务提示 | `http://103.40.14.100:34761` |

## 8. 权限与 Info.plist

| Key | 文案 |
| --- | --- |
| `NSCameraUsageDescription` | 用于视频通话时采集画面 |
| `NSMicrophoneUsageDescription` | 用于发送语音消息和语音通话 |
| `NSPhotoLibraryUsageDescription` | 用于发送图片和设置头像 |
| `NSPhotoLibraryAddUsageDescription` | 用于保存预览图片到相册 |
| `NSLocalNetworkUsageDescription` | 用于连接聊天服务器 |
| `UIBackgroundModes` | `audio`（通话最小化后继续收音放音） |
| `NSSupportsLiveActivities` | `true` |

## 9. 与 Android 的功能对照

| 能力 | iOS | Android |
| --- | --- | --- |
| 单聊/群聊/图片/文件/语音 | 有 | 有 |
| WebRTC 音视频 + 画中画 | 有 | 有 |
| 通话记录消息 | 有 | 有 |
| 长按复制/撤回/删除 | 有 | 有（本次对齐） |
| `READ_RECEIPT` / 未读校准 | 有 | 有（本次对齐） |
| 动态（朋友圈） | 有 | 有（本次对齐） |
| 全局背景 + 透明度 | 有 | 有（本次对齐） |
| Bark 绑定 | 有 | 有（本次对齐） |
| 演示模式 | 有 | 有（本次对齐） |
| 图片多选 / 压缩 / 保存相册 | 有 | 有（本次对齐） |
| 聊天时间分隔线 | 有 | 有（本次对齐） |
| 灵动岛 / Live Activity | 有 | 不适用（Android 以画中画实现通话悬浮） |
| 每会话聊天背景 | 无 | 有（Android 额外能力，保留） |
| 文件下载到 Downloads | 无（分享面板） | 有（Android 额外能力，保留） |

## 10. 已知限制

- 撤回与删除均为本地行为：服务端没有撤回/删除消息接口，iOS 也只修改本地状态并持久化。
- 演示模式数据完全由本地 mock，不同步服务端。
- 会话历史默认一次加载最近 100 条，更早消息需服务端支持分页。
- `logs_*.zip` 为历史日志包，不参与构建。
