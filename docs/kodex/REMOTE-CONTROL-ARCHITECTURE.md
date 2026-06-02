# Codex Remote Control 架构详解

本文档详细解释 Codex 的 Remote Control 功能实现机制，包含源码引用以便对照阅读。

---

## 目录

1. [概述](#概述)
2. [整体架构](#整体架构)
3. [核心组件](#核心组件)
4. [连接生命周期](#连接生命周期)
5. [消息协议](#消息协议)
6. [认证与注册](#认证与注册)
7. [Pairing 配对流程](#pairing-配对流程)
8. [大消息分片传输](#大消息分片传输)
9. [客户端追踪与生命周期](#客户端追踪与生命周期)
10. [Exec Server Remote（远程执行环境）](#exec-server-remote)
11. [TUI Remote 连接模式](#tui-remote-连接模式)
12. [Windows 兼容性](#windows-兼容性)

---

## 概述

Codex 的 "Remote Control" 允许远程客户端（如 ChatGPT Web 界面）通过 OpenAI 中继服务连接并控制本地运行的 Codex app-server。

整个系统由三层组成：

```
┌──────────────┐         ┌──────────────────┐         ┌──────────────┐
│  Remote UI   │◄──────► │  OpenAI 中继服务 │◄──────► │  本地 Codex  │
│ (ChatGPT等)  │  HTTPS  │ (chatgpt.com)    │   WSS   │  app-server  │
└──────────────┘         └──────────────────┘         └──────────────┘
```

关键约束：Remote Control 只接受来自 `chatgpt.com` 或 `chatgpt-staging.com` 域名的 HTTPS 连接，或者 localhost（用于开发测试）。

---

## 整体架构

### 入口点

- **CLI 命令**: `codex remote-control [start|stop]`
  - 源码: `codex-rs/cli/src/remote_control_cmd.rs:31-57`
  - `RemoteControlCommand` 结构体定义了 `start` 和 `stop` 子命令

- **App Server 启动时自动启用**: 当 app-server 启动时，如果配置了 remote control URL，会自动启动 remote control 任务
  - 源码: `codex-rs/app-server-transport/src/transport/remote_control/mod.rs:394-515`
  - `start_remote_control()` 函数是启动入口

### 模块结构

```
codex-rs/app-server-transport/src/transport/remote_control/
├── mod.rs              # 公共接口、Handle、启动逻辑
├── protocol.rs         # 消息类型定义、URL 规范化
├── enroll.rs           # 服务器注册、token 刷新、配对请求
├── websocket.rs        # WebSocket 连接管理、读写循环
├── client_tracker.rs   # 远程客户端连接跟踪
└── segment.rs          # 大消息分片/重组
```

---

## 核心组件

### RemoteControlHandle

`codex-rs/app-server-transport/src/transport/remote_control/mod.rs:56-62`

```rust
pub struct RemoteControlHandle {
    enabled_tx: Arc<watch::Sender<bool>>,
    status_tx: Arc<watch::Sender<RemoteControlStatusChangedNotification>>,
    state_db_available: bool,
    current_enrollment: CurrentRemoteControlEnrollment,
    auth_manager: Arc<AuthManager>,
}
```

这是外部代码控制 remote control 的手柄。支持：
- `enable()` — 启用远程控制（需要 SQLite state DB）
- `disable()` — 禁用远程控制
- `status()` — 查询当前状态（Disabled/Connecting/Connected/Errored）
- `start_pairing()` — 发起配对请求

### RemoteControlWebsocket

`codex-rs/app-server-transport/src/transport/remote_control/websocket.rs:243-261`

核心运行时状态机，负责：
- 等待启用信号
- 建立/重连 WebSocket 连接
- 运行读写 worker
- 处理认证恢复

### ClientTracker

`codex-rs/app-server-transport/src/transport/remote_control/client_tracker.rs:45-52`

```rust
pub(crate) struct ClientTracker {
    clients: HashMap<(ClientId, StreamId), ClientState>,
    legacy_stream_ids: HashMap<ClientId, StreamId>,
    join_set: JoinSet<(ClientId, StreamId)>,
    server_event_tx: mpsc::Sender<QueuedServerEnvelope>,
    transport_event_tx: mpsc::Sender<TransportEvent>,
    shutdown_token: CancellationToken,
}
```

跟踪所有通过中继 WebSocket 连接的远程客户端，将它们映射为 app-server 内部的 `TransportEvent`（与本地 WebSocket 连接等效）。

---

## 连接生命周期

### 启动流程

`websocket.rs:430-520` 中的 `run()` 方法定义了主循环：

```
1. 等待 app_server_client_name（由父进程提供）
2. loop {
     等待 enabled=true
     connect() → 建立 WebSocket 连接
     run_connection() → 运行读写循环直到断开
   }
3. shutdown client_tracker
```

### 连接建立（connect）

`websocket.rs:547-702` 中的 `connect()` 方法：

```
1. 发布状态 = Connecting
2. 解析 remote_control_url → RemoteControlTarget
3. loop {
     加载认证信息
     尝试 enroll/refresh server token
     构建 WebSocket 请求（带认证头）
     连接 WebSocket
     成功 → 返回 Connected
     失败 → 指数退避重试（上限 30s）
   }
```

### WebSocket 连接运行

`websocket.rs:704-747` 中的 `run_connection()` 并行启动两个 worker：

- **Server Writer** (`run_server_writer`): 从 `server_event_rx` 接收本地事件，序列化后写入 WebSocket
- **Websocket Reader** (`run_websocket_reader`): 从 WebSocket 读取远程客户端消息，通过 `ClientTracker` 转发给 app-server

连接结束原因：
- `Shutdown` — 收到关闭信号
- `Disabled` — 用户禁用了 remote control
- `ConnectionWorkerStopped` — 读/写 worker 停止（网络断开等）

### 重连策略

`websocket.rs:1220-1229`:

```rust
fn next_reconnect_delay(reconnect_attempt: &mut u64) -> (Duration, bool) {
    let reconnect_delay = backoff(*reconnect_attempt).min(REMOTE_CONTROL_RECONNECT_BACKOFF_CAP);
    // 达到 30s 上限后重置计数器，重新开始指数退避
}
```

使用指数退避，上限 30 秒。达到上限后重置计数器重新开始。

---

## 消息协议

### URL 端点

`protocol.rs:177-230` 中的 `normalize_remote_control_url()` 生成四个端点：

| 端点 | 路径 | 用途 |
|------|------|------|
| `websocket_url` | `/wham/remote/control/server` | WebSocket 长连接 |
| `enroll_url` | `/wham/remote/control/server/enroll` | 服务器注册 |
| `refresh_url` | `/wham/remote/control/server/refresh` | Token 刷新 |
| `pair_url` | `/wham/remote/control/server/pair` | 配对请求 |

### 域名白名单

`protocol.rs:158-175`:

```rust
fn is_allowed_remote_control_chatgpt_host(host: &Option<Host<&str>>) -> bool {
    host == "chatgpt.com"
        || host == "chatgpt-staging.com"
        || host.ends_with(".chatgpt.com")
        || host.ends_with(".chatgpt-staging.com")
}
```

只允许 chatgpt.com 系列域名（HTTPS）或 localhost（HTTP/HTTPS）。

### 客户端→服务端消息（ClientEvent）

`protocol.rs:70-91`:

```rust
pub enum ClientEvent {
    ClientMessage { message: JSONRPCMessage },       // 完整 JSON-RPC 消息
    ClientMessageChunk { ... },                      // 分片消息
    Ack { segment_id: Option<usize> },              // 确认收到
    Ping,                                            // 心跳
    ClientClosed,                                    // 客户端断开
}
```

### 服务端→客户端消息（ServerEvent）

`protocol.rs:117-134`:

```rust
pub enum ServerEvent {
    ServerMessage { message: Box<OutgoingMessage> }, // 完整 JSON-RPC 响应
    ServerMessageChunk { ... },                      // 分片响应
    Ack,                                             // 确认收到
    Pong { status: PongStatus },                    // 心跳响应
}
```

### 信封格式

每条消息都包裹在信封（Envelope）中：

```rust
// 客户端信封 (protocol.rs:93-108)
struct ClientEnvelope {
    event: ClientEvent,
    client_id: ClientId,      // 标识哪个远程客户端
    stream_id: Option<StreamId>,  // 标识客户端内的连接流
    seq_id: Option<u64>,      // 用于去重和确认
    cursor: Option<String>,   // 用于断线重连时恢复位置
}

// 服务端信封 (protocol.rs:145-156)
struct ServerEnvelope {
    event: ServerEvent,
    client_id: ClientId,
    stream_id: StreamId,
    seq_id: u64,
}
```

### 协议版本

`websocket.rs:60`:
```rust
pub(super) const REMOTE_CONTROL_PROTOCOL_VERSION: &str = "3";
```

---

## 认证与注册

### 认证要求

`websocket.rs:1175-1218` 中的 `load_remote_control_auth()`：

Remote Control 要求 **ChatGPT 认证**（非 API key）：
- 需要有效的 ChatGPT session token
- 需要 account_id（用于标识用户）
- API key 认证不被支持

### Server Enrollment（注册）

`enroll.rs:339-378` 中的 `enroll_remote_control_server()`:

注册请求包含：

```rust
struct EnrollRemoteServerRequest {
    name: String,              // 服务器名（主机名）
    os: &'static str,         // 操作系统
    arch: &'static str,       // CPU 架构
    app_server_version: &'static str,  // 版本号
    installation_id: String,   // 安装标识
}
```

注册响应：

```rust
struct EnrollRemoteServerResponse {
    server_id: String,               // 分配的服务器 ID
    environment_id: String,          // 环境 ID
    remote_control_token: String,    // WebSocket 认证 token
    expires_at: String,              // Token 过期时间
}
```

### Token 刷新

`enroll.rs:380-417` 中的 `refresh_remote_control_server()`:

Token 在过期前 30 秒开始刷新：

```rust
const REMOTE_CONTROL_SERVER_TOKEN_REFRESH_SKEW_SECS: i64 = 30;

fn should_refresh_server_token(&self) -> bool {
    self.remote_control_token.is_none()
        || self.expires_at.is_none_or(|expires_at| {
            expires_at.unix_timestamp()
                <= now().unix_timestamp() + 30
        })
}
```

### Enrollment 持久化

`enroll.rs:159-285`: Enrollment 信息存储在 SQLite state DB 中，键为 `(websocket_url, account_id, app_server_client_name)`。这样重启后可以复用已有的 server_id/environment_id，避免重复注册。

`codex-rs/state/src/runtime/remote_control.rs:28-80` 定义了数据库操作。

### 认证恢复

`websocket.rs:1551-1581` 中的 `recover_remote_control_auth()`:

当收到 401/403 时，系统尝试：
1. 从文件重新加载 auth token
2. 如果 token 已更新，重试连接
3. 如果恢复失败，报错

---

## Pairing 配对流程

### 概述

Pairing 是让新的远程客户端通过一次性配对码建立连接的机制（类似 Bluetooth pairing）。

### 实现

`mod.rs:142-215` 中的 `start_pairing()`:

```
1. 检查 remote control 是否已启用
2. 加载当前认证
3. 获取当前 enrollment（必须已完成注册）
4. 如果 server token 快过期，先刷新
5. 调用 /pair 端点发起配对请求
6. 处理各种错误：
   - 403: 清除 server token，重新刷新后重试
   - 404: 清除 enrollment（服务器端已不存在）
7. 最终确认账户没有变更后，返回配对响应
```

### 配对请求/响应

`protocol.rs:42-53`:

```rust
// 请求
struct StartRemoteControlPairingRequest {
    manual_code: bool,   // 是否请求人类可读的配对码
}

// 响应
struct StartRemoteControlPairingResponse {
    pairing_code: String,           // 配对码
    manual_pairing_code: Option<String>,  // 人类可读版本（如 "ABCD-EFGH"）
    server_id: String,
    environment_id: String,
    expires_at: String,             // 配对码有效期
}
```

---

## 大消息分片传输

### 设计目标

远程控制消息可能很大（如长代码输出），需要分片传输以避免单条 WebSocket 消息过大。

### 参数

`segment.rs:17-21`:

```rust
const REMOTE_CONTROL_SEGMENT_TARGET_BYTES: usize = 100 * 1024;     // 目标分片大小 100KB
const REMOTE_CONTROL_SEGMENT_MAX_BYTES: usize = 150 * 1024;        // 单片最大 150KB
const REMOTE_CONTROL_REASSEMBLED_MAX_BYTES: usize = 100 * 1024 * 1024;  // 重组上限 100MB
const REMOTE_CONTROL_SEGMENT_COUNT_MAX: usize = 1024;              // 最多 1024 片
const REMOTE_CONTROL_SEGMENT_ASSEMBLY_MAX_COUNT: usize = 128;      // 同时组装上限 128 条
```

### 分片格式

```rust
ClientMessageChunk {
    segment_id: usize,           // 当前片序号
    segment_count: usize,        // 总片数
    message_size_bytes: usize,   // 原始消息字节数
    message_chunk_base64: String, // Base64 编码的分片内容
}
```

### 重组逻辑

`segment.rs` 中的 `ClientSegmentReassembler`：
- 按 `(client_id, stream_id)` 维护组装缓冲区
- 收到所有分片后合并，返回完整的 `ClientEnvelope`
- 超时或超尺寸的组装会被丢弃

### 发送端分片

`segment.rs` 中的 `split_server_envelope_for_transport()`:
- 如果 `ServerEnvelope` 序列化后超过 `SEGMENT_TARGET_BYTES`，自动分片
- 每片加上 `segment_id` 和 `segment_count` 元数据

---

## 客户端追踪与生命周期

### 客户端识别

每个远程客户端由 `(ClientId, StreamId)` 唯一标识：
- `ClientId`: 标识远程用户/浏览器
- `StreamId`: 标识同一客户端内的独立会话流

### 连接初始化

`client_tracker.rs:94-217` 中的 `handle_message()`:

当收到 `ClientEvent::ClientMessage` 且 method 为 `"initialize"` 时：
1. 分配新的 `connection_id`
2. 创建 `writer_tx/writer_rx` 通道
3. 发送 `TransportEvent::ConnectionOpened` 给 app-server
4. 启动 `run_client_outbound` 任务处理向该客户端的响应

### 空闲超时

`client_tracker.rs:27-28`:

```rust
const REMOTE_CONTROL_CLIENT_IDLE_TIMEOUT: Duration = Duration::from_secs(10 * 60);  // 10 分钟
const REMOTE_CONTROL_IDLE_SWEEP_INTERVAL: Duration = Duration::from_secs(30);       // 每 30s 检查
```

超过 10 分钟无活动的客户端连接会被自动关闭。

### Ping/Pong 机制

- 服务端每 10 秒发送 WebSocket Ping（`websocket.rs:63-64`）
- 如果 60 秒内没收到 Pong，断开连接（`websocket.rs:65-66`）
- 协议层面也有 `ClientEvent::Ping` / `ServerEvent::Pong`，用于客户端级别的存活检测

### 连接关闭

客户端断开时：
1. 收到 `ClientEvent::ClientClosed`
2. `ClientTracker` 取消该客户端的 disconnect_token
3. 发送 `TransportEvent::ConnectionClosed` 给 app-server
4. 清理分片重组缓冲区

---

## Exec Server Remote

这是另一个独立的 remote 机制，用于云端执行环境。

### 入口

`codex-rs/exec-server/src/remote.rs:128-158`

```rust
pub async fn run_remote_environment(
    config: RemoteEnvironmentConfig,
    runtime_paths: ExecServerRuntimePaths,
) -> Result<(), ExecServerError> {
    // 1. 向 environment registry 注册
    // 2. 获取 WebSocket URL
    // 3. 连接 WebSocket
    // 4. 循环处理远程请求（断线重连，指数退避）
}
```

### 与 Remote Control 的区别

| | Remote Control | Exec Server Remote |
|---|---|---|
| 用途 | 远程控制 TUI/app-server | 远程执行命令 |
| 注册目标 | chatgpt.com 中继 | Environment Registry |
| 消息协议 | JSON-RPC over WebSocket | 复用的 WebSocket 连接 |
| 认证 | ChatGPT session token | SharedAuthProvider |
| 数据流 | 双向消息 | 命令执行请求/响应 |

### 相关文件

- `codex-rs/exec-server/src/remote.rs` — 远程环境注册和 WebSocket 连接
- `codex-rs/exec-server/src/remote_process.rs` — 远程进程管理
- `codex-rs/exec-server/src/remote_file_system.rs` — 远程文件系统操作

---

## TUI Remote 连接模式

### CLI 参数

`codex-rs/cli/src/main.rs:827-838`:

```rust
struct InteractiveRemoteOptions {
    /// 连接到远程 app server
    /// 支持: ws://host:port, wss://host:port, unix://, unix://PATH
    #[arg(long = "remote", value_name = "ADDR")]
    remote: Option<String>,

    /// 远程认证 token 的环境变量名
    #[arg(long = "remote-auth-token-env", value_name = "ENV_VAR")]
    remote_auth_token_env: Option<String>,
}
```

使用方式：
```bash
codex --remote ws://192.168.1.100:8080
codex --remote wss://my-server.com:443 --remote-auth-token-env MY_TOKEN
```

这让 TUI 直接连接到已运行的远程 app-server，而不是启动本地 app-server。

### TUI 状态显示

`codex-rs/tui/src/status/remote_connection.rs` — 在 TUI 中显示远程连接状态。

---

## Windows 兼容性

### 无平台门控

Remote Control 功能 **没有** `#[cfg(windows)]` 或 `#[cfg(not(windows))]` 条件编译。所有平台（macOS、Linux、Windows）都编译和运行相同的代码。

### Windows 特殊处理

唯一的 Windows 特殊处理在测试中：

`websocket.rs:1655-1658`:
```rust
// Windows Bazel CI can take longer than a few seconds for the websocket
// client connection attempt to reach the local test listener.
#[cfg(windows)]
const TEST_HTTP_ACCEPT_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(not(windows))]
const TEST_HTTP_ACCEPT_TIMEOUT: Duration = Duration::from_secs(5);
```

### 依赖兼容性

Remote Control 依赖的关键 crate 都支持 Windows：
- `tokio-tungstenite` — 跨平台 WebSocket
- `reqwest` — 跨平台 HTTP 客户端
- `codex-utils-rustls-provider` — 使用 rustls（纯 Rust TLS），无需 OpenSSL

---

## 数据流图

### 远程客户端发送消息到 app-server

```
远程客户端 (ChatGPT Web)
    │
    ▼ [HTTPS/WSS]
OpenAI 中继服务 (chatgpt.com/backend-api/wham/remote/control/server)
    │
    ▼ [WebSocket Text Frame]
┌───────────────────────────────────────────────────────────┐
│ RemoteControlWebsocket::run_websocket_reader()            │
│   ├─ 反序列化 ClientEnvelope                              │
│   ├─ 分片重组 (ClientSegmentReassembler)                  │
│   └─ 传给 ClientTracker                                  │
│                                                           │
│ ClientTracker::handle_message()                          │
│   ├─ initialize → 创建新连接 (TransportEvent::ConnectionOpened) │
│   ├─ message → 转发 (TransportEvent::IncomingMessage)    │
│   ├─ ping → 回复 Pong                                    │
│   └─ closed → 关闭连接 (TransportEvent::ConnectionClosed) │
└───────────────────────────────────────────────────────────┘
    │
    ▼ [mpsc channel: TransportEvent]
App Server 消息处理器 (与本地 WebSocket 连接处理相同)
```

### App-server 发送响应到远程客户端

```
App Server 消息处理器
    │
    ▼ [mpsc channel: QueuedOutgoingMessage]
ClientTracker::run_client_outbound()
    │
    ▼ [mpsc channel: QueuedServerEnvelope]
┌───────────────────────────────────────────────────────────┐
│ RemoteControlWebsocket::run_server_writer()               │
│   ├─ 分配 seq_id                                         │
│   ├─ 分片 (split_server_envelope_for_transport)          │
│   ├─ 缓存到 BoundedOutboundBuffer（支持断线重发）         │
│   └─ 序列化 + 写入 WebSocket                             │
└───────────────────────────────────────────────────────────┘
    │
    ▼ [WebSocket Text Frame]
OpenAI 中继服务
    │
    ▼ [HTTPS/WSS]
远程客户端
```

---

## WebSocket 连接请求头

`websocket.rs:1125-1173` 中 `build_remote_control_websocket_request()`:

| Header | 值 | 用途 |
|--------|------|------|
| `x-codex-server-id` | server_id | 标识此服务器 |
| `x-codex-name` | Base64(server_name) | 人类可读名称 |
| `x-codex-protocol-version` | "3" | 协议版本号 |
| `authorization` | Bearer {token} | 服务器认证 |
| `x-codex-installation-id` | installation_id | 安装标识 |
| `x-codex-subscribe-cursor` | cursor | 断线重连恢复点 |

---

## 可靠性机制

### 断线重连

- WebSocket 断开后自动重连（指数退避，上限 30s）
- 重连时携带 `subscribe_cursor`，中继服务可以重发缺失的消息

### 消息确认（ACK）

- `BoundedOutboundBuffer`（`websocket.rs:76-135`）缓存已发送但未确认的消息
- 收到 `ClientEvent::Ack` 后清除对应缓存
- 重连后重发所有未确认的消息

### 去重

- 客户端消息携带 `seq_id`
- `ClientTracker` 记录 `last_inbound_seq_id`，丢弃重复消息
- 分片消息通过 `last_completed_client_chunk_seq_id_by_stream` 去重

### 流量控制

- `BoundedOutboundBuffer` 限制未确认消息数量为 `CHANNEL_CAPACITY`
- 达到上限时暂停从 `server_event_rx` 接收新消息

---

## 状态持久化

Enrollment 信息存储在 SQLite（codex state DB）中：

表：`remote_control_enrollments`
- `websocket_url` — 目标 URL
- `account_id` — 用户账户 ID
- `app_server_client_name` — 客户端名称（可选）
- `server_id` — 注册分配的服务器 ID
- `environment_id` — 环境 ID
- `server_name` — 本机名称
- `updated_at` — 更新时间

这确保重启后可以复用已有注册，避免每次都重新 enroll。

---

## 关键常量

| 常量 | 值 | 位置 |
|------|------|------|
| 协议版本 | 3 | `websocket.rs:60` |
| WebSocket Ping 间隔 | 10s | `websocket.rs:63` |
| Pong 超时 | 60s | `websocket.rs:65` |
| 重连退避上限 | 30s | `websocket.rs:69` |
| 连接超时 | 30s | `websocket.rs:71` |
| 注册/配对请求超时 | 30s | `enroll.rs:23-24` |
| Token 提前刷新 | 30s | `enroll.rs:26` |
| 分片目标大小 | 100KB | `segment.rs:17` |
| 分片最大大小 | 150KB | `segment.rs:18` |
| 重组上限 | 100MB | `segment.rs:19` |
| 客户端空闲超时 | 10min | `client_tracker.rs:27` |
| 空闲检查间隔 | 30s | `client_tracker.rs:28` |
