# peek_desktop_bridge

复用官方 `peek_remote 2.1.1` 的公开配对信息，将 `talker 5.1.20` 普通日志与原始异常堆栈发送到 Peek Desktop 的独立诊断通道。固定 `talker_logger 5.1.20`，依赖锁文件用于联合开发复现。`publish_to: none`，采用 MIT 许可证，通过 Git tag 供宿主 App 引用；当前不发布到 pub.dev。

## 接入

先在 App 自己的编译期诊断开关之后创建 bridge。prod Release/Profile 应直接跳过整个初始化入口，不创建实例、不 attach、不读取凭据、不探测桌面；SDK 的 `enabled: false` 也会跳过启动与订阅，但不能代替调用方的编译期保护。

```dart
if (appDiagnosticsEnabled) {
  // remote 必须是已注册的同一个官方客户端，不能另建一个 PeekRemote。
  final bridge = DesktopDiagnosticsBridge(redactor: appDiagnosticRedactor);
  bridge.attachTalker(appTalker);
  bridge.attachPeekRemote(existingRemote);
  bridge.start();
}
```

`redactor` 为必传参数，可返回 null 丢弃事件。`redactSensitiveFields` 仅是递归敏感字段清理工具，不保证自由文本、消息和堆栈能自动识别全部隐私，App 仍须提供自己的脱敏规则。转换、清理和裁剪发生在入队前。结构化属性限制深度 8、总遍历节点 512、单容器 64 项；超限字段带截断标记，单事件序列化上限 128 KiB。

默认 Talker converter 跳过已知 HTTP/gRPC 网络日志，避免复制标准网络链路；可传 converter 适配 App 特有结构。宿主隐藏的原始堆栈（例如 `originalStackTrace`）与业务 tag 应由 App 显式提取后传给 `defaultTalkerConverter(data, originalStackTrace: ..., tag: ...)`。SDK 不引用宿主业务类型、不安装全局异常处理器，不覆盖已有 Firebase、FlutterError 或 Zone 处理。

重复 start、重复 attach 同一个 Talker/PeekRemote 不重复订阅。先订阅 stream 再读取已有历史，以弱对象身份合并回放与直播；`dispose()` 取消订阅、计时器、探测和连接。bridge 不 dispose 调用方的 PeekRemote。

## 连接与边界

- 官方连接已经 connected 时也会立即检查公开 endpoint/sessionId/deviceToken/serverId；无 deviceToken 的静态 token 连接不尝试私有诊断，不重复索取配对码。
- 能力不存在、超时或版本/server identity 不匹配时，本轮保持 unsupported，网络连接继续；不循环探测原版 Peek Pro。
- 诊断与网络使用两条 WebSocket。token 只出现在握手消息，不进入 URL、配置、日志或 callback。SDK 不复制持久化官方 token。
- 默认队列最多 2,000 条/4 MiB，优先淘汰低级别日志；WARN/ERROR/异常同样有硬上限。每 50 ms 或 64 条发送，单批最多 240 KiB，一个在途批次。只在 ACK 后释放队列；8 秒未确认重连并按 welcome 的累计确认位置恢复。
- 已不在队列的序号先发送 gap。确认代表桌面内存接纳，不是落盘；已经 ACK 的历史不额外保留，桌面重启丢失内存后会明确报告无法重放的范围。
- `resetContext()` 清空待发历史并更换 emitter 上下文，阻断旧 ACK 和旧账号日志。切换 server identity 也清理旧目标队列。每 run 最多 16 个 emitter，极长运行中需规划上下文重建。
- 诊断授权被关闭后保持 denied，不反复弹配对；授权重新开启后调用 `bridge.reconnect()` 或重连标准网络。
- `onDiagnostic` 仅返回不含凭据的低频错误码，不能重新送回同一个 Talker。

当前 IO 传输支持 Dart VM 上的 Flutter 平台；Web 不支持。网络内容仍由官方 Peek 拦截器采集，桥接失败不影响业务请求、控制台或本地日志。

共享测试机的历史 IP/桌面选择、自动发现与二维码入口由独立 [`peek_desktop_connect`](../peek_desktop_connect/README.md) 提供；把该包的 memory 同时传给现有 `PeekRemote` 和连接面板。bridge 继续复用这一个 remote，切换桌面身份会清理旧目标待发诊断队列；每次发送给当前所选一台，不同时广播。相机扫码通过宿主回调接入，日志包不增加相机权限。

## 验证与演示

```bash
flutter pub get
flutter analyze
flutter test
cd example
flutter pub get
flutter run -d macos --dart-define=PEEK_DESKTOP_DIAGNOSTICS=true
```

示例默认关闭诊断，只在 debug + 显式 dart-define 时初始化。它提供官方 Bonjour 自动发现、地址/配对码输入、合成请求、INFO/WARN/异常、结构化脱敏和上下文重置。macOS 已提供工程；如需移动端示例壳，可在 example 使用 Flutter 工具添加目标平台并验证局域网权限。

诊断线上契约见仓库 [`诊断协议 v1`](../../docs/诊断协议v1.md)。桌面互操作与已验证范围见 [Peek Desktop](https://github.com/lx8s8/peek-desktop)。

跨语言回归从 Peek Desktop 仓库根目录运行（先初始化 `sdk` 子模块并安装 SDK 依赖）：

```bash
cargo test --locked --manifest-path src-tauri/Cargo.toml --test sdk_interop -- --ignored --nocapture
```

测试启动临时 Rust 服务并使用内存凭据，驱动真实官方 PeekRemote 与本 SDK 配对、重连、传输日志及大正文。它不读取系统配对库；默认 Rust/Flutter 测试会跳过此项，需显式执行。
