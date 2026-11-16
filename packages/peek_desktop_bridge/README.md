# peek_desktop_bridge

把 Talker 日志和原始异常堆栈发送到 Peek Desktop。它复用 App 已有 `PeekRemote` 的配对结果，通过独立 WebSocket 传输诊断事件。

## 接入

按[安装说明](../../README.md#安装)加入依赖，在 App 的诊断构建开关内初始化。这里的 `talker` 和 `remote` 分别是 App 已有的 Talker、PeekRemote 实例：

```dart
import 'package:peek_desktop_bridge/peek_desktop_bridge.dart';

final bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
  ..attachTalker(talker)
  ..attachPeekRemote(remote)
  ..start();
```

首次在桌面配对时允许“诊断同步”。网络客户端连接成功后，bridge 自动建立日志连接，不需要再次输入配对码。完整初始化见[仓库示例](../../README.md#接入顺序)，可运行工程见 [example](example/README.md)。

网络请求继续由 Peek 拦截器采集。默认 converter 跳过 Talker 中已知的 HTTP/gRPC 网络日志，避免重复展示。

## 脱敏与自定义日志

`redactor` 必须提供，返回 `null` 可以丢弃整个事件。`redactSensitiveFields` 是结构化敏感字段的清理工具；自由文本、异常消息和堆栈需按业务补充规则。转换、脱敏和裁剪在进入发送队列前完成，不会修改原有 Talker 记录。

不通过 Talker 的日志可直接写入：

```dart
bridge.record(
  const DiagnosticRecord(
    message: '本地缓存读取完成',
    source: 'cache',
    tag: 'startup',
    attributes: {'items': 12},
  ),
);
```

级别使用 `verbose`、`debug`、`info`、`warning`、`error`、`critical`。需要准确跳转网络请求时，传入该请求的 `relatedNetworkEntryId`；没有 ID 的日志只参与时间线展示。

自定义 Talker 类型可通过 `attachTalker(talker, converter: ...)` 转换为 `DiagnosticRecord`。如果宿主把原始堆栈保存在自定义字段中，取出后传给 `defaultTalkerConverter(data, originalStackTrace: originalStack, tag: tag)`，避免发送 UI 简化后的堆栈。

## 生命周期

| 操作 | 行为 |
| --- | --- |
| `start()` | 订阅 Talker，并检查当前网络连接；重复调用不会重复订阅 |
| `reconnect()` | 重试诊断连接，例如桌面重新允许诊断同步后 |
| `resetContext()` | 清空待发日志并更换发送上下文，适合退出账号时调用 |
| `dispose()` | 释放订阅、定时器和诊断连接，需 `await` |

bridge 不销毁传入的 `PeekRemote`。整个诊断服务关闭时，先释放 bridge，再停止和释放 remote。它也不安装全局异常处理器，App 继续使用原有 FlutterError、Zone 或崩溃上报配置。

[连接包](../peek_desktop_connect/README.md)负责历史电脑、发现和扫码入口。两个包共用一个 remote，每次同步到当前所选电脑；切换电脑身份时会清空旧目标的待发诊断队列。

## 状态与排查

| 状态 | 含义及处理 |
| --- | --- |
| `waitingForNetwork` | 等待官方网络连接成功，先检查地址和配对结果 |
| `connecting` | 正在探测或连接诊断通道 |
| `ready` | 可以发送日志，`stats.queued` 在收到确认后减少 |
| `unsupported` | 对端没有兼容的诊断能力；标准网络连接仍可使用 |
| `denied` | 桌面未允许诊断，授权后调用 `reconnect()` |
| `stopped` | 尚未启动或已经停止 |

`onDiagnostic` 返回不含凭据的低频错误码，用于宿主的独立诊断输出。不要将其写回正在订阅的同一个 Talker，以免形成循环。

## 缓冲与确认

| 项目 | 默认上限或间隔 |
| --- | --- |
| 待发队列 | 2,000 条 / 4 MiB，优先淘汰低级别日志 |
| 发送时机 | 每 50 ms 或累计 64 条 |
| 单批 | 最多 64 条 / 240 KiB，一个在途批次 |
| ACK 超时 | 8 秒，之后重连并恢复未确认队列 |
| 单事件 | 128 KiB |
| 结构化属性 | 深度 8、总遍历节点 512、每个容器 64 项 |

裁剪后事件带 `truncated` / `truncatedFields`。异常和高等级日志也受容量限制。被队列淘汰的序号通过 gap 告知桌面，重放已确认的序号不会重复展示。

ACK 表示桌面已接纳到内存。SDK 不另存已经确认的历史；桌面丢失内存后，超出 SDK 队列的记录无法重放，会显示缺口。桌面的归档与恢复快照是另外的磁盘保存功能。

协议字段及服务端限制见[诊断协议 v1](../../docs/诊断协议v1.md)。本包使用 Dart IO，暂不支持 Web。生产包应在构造 bridge 前通过编译期开关禁用诊断。

## 开发

```bash
flutter pub get
flutter analyze
flutter test
```

Rust 与真实 Dart 客户端的联合测试见[开发指南](../../CONTRIBUTING.md#与桌面联合测试)。
