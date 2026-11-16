# peek_desktop_connect

给已有的 `PeekRemote` 增加电脑选择界面：扫码配对、粘贴链接、手动地址、历史记录和 Bonjour 发现。测试机可以保留多台电脑的配对记录，每次连接一台。

## 安装

见仓库[安装说明](../../README.md#安装)。本包依赖 `peek_remote 2.1.1`，无需接入 Talker 或日志包。

## 创建连接

在 Flutter 绑定初始化后、App 的诊断构建开关内创建对象：

```dart
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_connect/peek_desktop_connect.dart';

final memory = DesktopConnectionMemory();
final peek = Peek(options: const PeekOptions(name: 'My App'));
final remote = peek.attach(PeekRemote(peek, memory: memory));
```

App 已有 Peek 时复用原实例。调用 `remote.start()` 可尝试恢复最后连接的电脑；也可以等用户进入连接页面后手动选择。

连接页面放入滚动容器，并传入上面两个对象：

```dart
SingleChildScrollView(
  padding: const EdgeInsets.all(16),
  child: DesktopConnectionPanel(
    remote: remote,
    memory: memory,
  ),
)
```

这里的 `SingleChildScrollView`、`EdgeInsets` 来自 `package:flutter/material.dart`。面板中英文跟随 App 的 `Localizations`。

## 扫码配对

`onScan` 的类型为 `Future<String?> Function(BuildContext)`，返回二维码解码文本，取消时返回 `null`。将 App 已有扫码页面接到这个回调即可：

```dart
DesktopConnectionPanel(
  remote: remote,
  memory: memory,
  onScan: (context) => Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (context) => const MyQrScannerPage()),
  ),
)
```

`MyQrScannerPage` 是宿主的扫码页面，识别成功时用 `Navigator.pop(context, decodedText)` 返回结果；相机权限也由该页面处理。SDK 收到文本后校验链接并发起配对。没有 `onScan` 时仍可粘贴配对链接。

二维码由桌面生成，包含电脑地址、身份、四位配对码及有效期，不包含长期凭据。链接格式为：

```text
peek-desktop://pair?v=1&host=<电脑IP>&port=9741&serverId=<电脑身份>&code=<四位码>&expiresAt=<Unix秒>
```

配对码 180 秒有效，成功一次后失效。链接字段重复、版本不匹配、地址不合法或已经过期都会被拒绝；电脑与手机的时钟应保持同步。

## 历史电脑与切换

- 点击已配对的电脑可直接连接，切换时关闭旧连接
- 历史按 `serverId` 区分电脑，IP 只记录最近地址。发现同一电脑的新 IP 后，可直接选择并更新历史
- 历史最多保存 20 台，按最近使用排序。列表满后的记录淘汰只移除元信息；“忘记这台电脑”同时删除该电脑的本地凭据
- 默认凭据存储复用官方 `PeekRemoteMemory` 的 shared_preferences 实现，需要其他存储时可注入适配器
- 历史元信息只保存电脑身份、名称和地址。读取或保存失败会在面板提示，已建立的网络连接继续工作

不使用面板时，可自行读取历史并连接：

```dart
final desktops = await memory.desktops();
if (desktops.isNotEmpty) {
  final desktop = desktops.first;
  await remote.connect(
    desktop.endpoint,
    serverId: desktop.serverId,
    name: desktop.name,
  );
  await memory.rememberConnected(remote);
}
```

配合日志包使用时，切换电脑会清空旧目标的待发诊断队列。网络历史遵循官方 Peek 行为：连接成功后发送当前 Peek store 中保留的请求。

## 地址与权限

手机应填写电脑的局域网 IP，例如 `192.168.1.8:9741`。`127.0.0.1` 用于同机连接，`0.0.0.0` 只是服务端监听范围。手动地址也接受 `ws://host:port/` 和带方括号的 IPv6，端口默认 `9741`。

iOS 的诊断构建需在 Info.plist 配置 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`，服务名为 `_peek._tcp`。其余平台配置参见 [peek_remote 文档](https://pub.dev/packages/peek_remote)。公司网络禁用组播时，使用手动地址或二维码；跨网段连接还需要网络本身可达。

## 释放资源

离开连接页会停止发现，现有连接继续同步。App 销毁诊断服务时，先移除面板；若使用日志包，先释放 bridge，然后释放连接：

```dart
await remote.stop();
remote.dispose();
memory.dispose();
```

面板 `enabled: false` 时不会读取历史或开始连接。生产包仍应通过 App 的编译期开关跳过 SDK 初始化和页面入口。

本包测试覆盖链接校验、历史存储、双服务切换及页面生命周期；手机光学扫码、平台权限和跨物理电脑切换仍需在宿主 App 中验证。
