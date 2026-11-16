# Peek Flutter SDK

在 Flutter App 中连接 [Peek Desktop](https://github.com/lx8s8/peek-desktop)，把网络请求、Talker 日志和异常堆栈放到电脑上查看。

| 包 | 用途 | 文档 |
| --- | --- | --- |
| `peek_desktop_connect` | 扫码配对、历史电脑、局域网发现和手动连接 | [连接指南](packages/peek_desktop_connect/README.md) |
| `peek_desktop_bridge` | Talker 日志、异常堆栈和自定义诊断事件同步 | [日志接入](packages/peek_desktop_bridge/README.md) |

两个包可以分别使用。一起接入时，共用 App 中已有的 `PeekRemote`：测试机可记住多台电脑，每次连接其中一台。相机扫码使用 App 自己的扫码页面。

## 环境要求

- Dart 3.11 或更新版本，Flutter 3.41 或更新版本
- `peek_remote 2.1.1`；日志包使用 `talker` / `talker_logger 5.1.20`
- 运行于 Dart VM 的 Flutter App，暂不支持 Web

上述版本是依赖约束；本仓库使用 FVM 固定 Flutter 3.47.8 开发和测试，其他 Flutter 版本尚未逐一验证。

## 安装

在 App 的 `pubspec.yaml` 中加入需要的包，然后执行 `flutter pub get`。目前通过 Git tag 分发，尚未发布到 pub.dev。两个包使用同一 tag，并提交 App 的 `pubspec.lock`。

```yaml
dependencies:
  peek_desktop_connect:
    git:
      url: https://github.com/lx8s8/peek-flutter-sdk.git
      ref: v0.1.2
      path: packages/peek_desktop_connect
  peek_desktop_bridge:
    git:
      url: https://github.com/lx8s8/peek-flutter-sdk.git
      ref: v0.1.2
      path: packages/peek_desktop_bridge
```

下面的示例还直接使用 `peek`、`peek_remote` 和 `talker`，App 应将它们分别声明为直接依赖。

## 接入顺序

1. 在 App 的诊断构建开关之后创建连接对象
2. 将同一个 `DesktopConnectionMemory` 交给 `PeekRemote` 和连接面板
3. 日志包订阅已有的 Talker，并绑定这个 `PeekRemote`
4. 在电脑上启动监听，生成配对码；App 扫码或输入地址、配对码连接

初始化代码可以放在 App 的诊断服务中：

```dart
import 'package:flutter/foundation.dart';
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_connect/peek_desktop_connect.dart';
import 'package:peek_desktop_bridge/peek_desktop_bridge.dart';
import 'package:talker/talker.dart';

const diagnosticsEnabled =
    kDebugMode && bool.fromEnvironment('PEEK_DESKTOP_DIAGNOSTICS');

DesktopConnectionMemory? memory;
PeekRemote? remote;
DesktopDiagnosticsBridge? bridge;

void initializeDiagnostics(Peek peek, Talker talker) {
  if (!diagnosticsEnabled || remote != null) return;
  final connections = DesktopConnectionMemory();
  final client = peek.attach(PeekRemote(peek, memory: connections));
  memory = connections;
  remote = client;
  bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
    ..attachTalker(talker)
    ..attachPeekRemote(client)
    ..start();
  client.start();
}
```

示例开关只允许 Debug，并需要传入 `--dart-define=PEEK_DESKTOP_DIAGNOSTICS=true`。有 dev/preprod 渠道的 App 可使用自己的编译期策略。正式生产包应跳过对象创建、日志订阅和连接入口；`enabled: false` 只控制实例行为，不能代替整个入口的构建隔离。

`redactSensitiveFields` 会清理结构化敏感字段。业务消息和堆栈中的隐私内容仍需 App 自行处理，详见[日志接入](packages/peek_desktop_bridge/README.md#脱敏与自定义日志)。

## 运行示例

```bash
git clone https://github.com/lx8s8/peek-flutter-sdk.git
cd peek-flutter-sdk/packages/peek_desktop_bridge/example
flutter pub get
flutter run -d macos --dart-define=PEEK_DESKTOP_DIAGNOSTICS=true
```

[示例说明](packages/peek_desktop_bridge/example/README.md)包含配对步骤、测试按钮和预期结果。示例只生成测试数据，不依赖业务服务。

## 开发与协议

- [开发指南](CONTRIBUTING.md)：本地检查、跨语言测试和提交说明
- [诊断协议 v1](docs/诊断协议v1.md)：事件字段、握手、确认和容量
- [版本记录](CHANGELOG.md)
- [问题反馈](https://github.com/lx8s8/peek-flutter-sdk/issues)：请附版本和脱敏后的复现步骤，不要上传设备凭据或原始业务日志

项目采用 [MIT 许可证](LICENSE)。网络采集与配对基于 [Peek](https://github.com/artdima/peek)，日志适配基于 [Talker](https://github.com/Frezyx/talker)。
