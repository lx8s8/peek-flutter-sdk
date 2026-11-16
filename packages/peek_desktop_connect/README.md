# peek_desktop_connect

为现有 `PeekRemote 2.1.1` 增加历史桌面、Bonjour 发现、手动地址、配对链接和可注入扫码入口。网络和普通日志共用一次连接选择。此包不依赖 Talker 或日志 bridge，也不创建第二个网络客户端。

```yaml
dependencies:
  peek_desktop_connect:
    path: ../peek_desktop_connect
```

仅在宿主编译期诊断开关允许时初始化：

```dart
final memory = DesktopConnectionMemory();
final remote = peek.attach(PeekRemote(peek, memory: memory));
// 可选：remote.start() 恢复最后一台桌面；不调用则等用户手动连接。
final bridge = DesktopDiagnosticsBridge(redactor: appRedactor)
  ..attachPeekRemote(remote)
  ..attachTalker(appTalker)
  ..start();

// 放入可滚动页面；移除面板会停止发现，remote 仍由宿主拥有。
DesktopConnectionPanel(
  remote: remote,
  memory: memory, // 必须与传给 PeekRemote 的对象相同
  onScan: (context) => appScanner.scanQr(context), // 返回二维码解码文本；取消返回 null
);
```

`onScan` 由宿主已有扫码页提供；未提供时显示手动地址、链接粘贴和历史/发现入口，相机扫描与权限由宿主负责。示例工程为 macOS，演示粘贴二维码链接；移动 App 接入扫码回调后点击“扫码绑定”即可解析并发起配对。中英文文案跟随宿主 `Localizations.localeOf(context)`。

销毁顺序由宿主管理：先移除面板，再 `await bridge.dispose()`、`await remote.stop()`、`remote.dispose()`、`memory.dispose()`。`enabled: false` 的面板不读历史、不发现、不连接；正式包应从编译期跳过整个实例创建入口。

## 共享测试机

- 可分别绑定多台桌面，当前使用同一个 `PeekRemote` 每次连接一台。点历史桌面即免码连接；切换时旧连接关闭，不广播给所有配对电脑。
- 按 `serverId` 区分身份；IP/端口只是最近地址。自动发现同一身份的新地址，可直接点选连接并更新历史。地址未知时首次连接必须有四位码，避免把当前桌面的 token 发给其他手动地址。
- 官方凭据继续通过传入的 `PeekRemoteMemory` 保存。默认使用官方 shared_preferences 实现；宿主也可传入自己的适配器。新增的历史存储只含身份、名称、地址，最多 20 台，按最近使用排序，不复制 token 或配对码。列表淘汰不撤销官方授权；主动“忘记”删除该身份的凭据和历史，其他桌面不受影响。
- 老版本只保存的最后一台桌面可自动出现在历史中。历史读取/保存失败会显示说明，现有官方网络连接不因此停止；凭据保存和撤销先执行，不被历史元信息的故障阻断。
- 无 UI 的宿主可用 `memory.desktops()` 获取列表，通过 `remote.connect(desktop.endpoint, serverId: desktop.serverId, name: desktop.name)` 切换；连接成功后调用 `await memory.rememberConnected(remote)` 更新地址。面板会自动完成该更新。
- 日志队列隔离继续由 `peek_desktop_bridge` 按桌面身份处理。官方网络客户端在新目标连接成功后会同步 Peek 本地 store 的历史请求，这与诊断待发队列不同。

## 地址与扫码格式

手机使用电脑实际局域网 IP，不能填手机自己的 `127.0.0.1`，也不能填服务端监听范围 `0.0.0.0`。手动输入接受 `host[:port]`、`ws://host[:port]/` 和带方括号的 IPv6，默认端口 9741。首次配对也可粘贴桌面生成的 `peek-desktop://pair?...` 链接。

二维码链接严格校验版本、字段唯一性、地址、端口、桌面身份、四位码和过期时间，不接受 token 等额外字段。到期以电脑时间编码，App 本地先校验，服务端仍执行最终的一次性/180 秒校验；明显时钟偏差应先校准设备时间。链接只在内存中用于本次操作，错误文本不包含链接或配对码。不注册全局深链、不自动扫描剪贴板。

Bonjour 依赖宿主平台权限：iOS 需要局域网用途说明和 `_peek._tcp` 服务声明；Android/macOS 按官方 `peek_remote` 配置。组播被网络屏蔽时使用手动地址或二维码。手机相机、物理测试机与多台真实电脑仍需在宿主中验收。

```bash
flutter pub get
flutter analyze
flutter test
```
