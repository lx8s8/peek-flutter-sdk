# Peek Flutter SDK

Peek Desktop 的 Flutter SDK，统一维护连接入口和日志同步两个包，采用 [MIT 许可证](LICENSE)。主分支为 `main`，通过 Git tag/commit 固定依赖，当前不发布到 pub.dev。

| 包 | 职责 |
| --- | --- |
| `peek_desktop_connect` | 电脑历史、Bonjour 发现、手动地址、配对链接及宿主扫码回调 |
| `peek_desktop_bridge` | Talker 普通日志和原始异常堆栈、脱敏、队列、重连与累计确认 |

两个包复用宿主的同一个官方 `PeekRemote 2.1.1`。共享测试机可保留多台电脑配对，每次选择一台；扫码相机和权限由宿主提供。

## App 引用

公开后可通过 HTTPS 引用，无需为 SDK 配置私有仓库凭据。两个包固定到同一 tag，`pubspec.lock` 一并提交：

```yaml
dependencies:
  peek_desktop_connect:
    git:
      url: https://github.com/lx8s8/peek-flutter-sdk.git
      ref: v0.1.1
      path: packages/peek_desktop_connect
  peek_desktop_bridge:
    git:
      url: https://github.com/lx8s8/peek-flutter-sdk.git
      ref: v0.1.1
      path: packages/peek_desktop_bridge
```

接入顺序：在宿主编译期诊断开关之后创建 `DesktopConnectionMemory`，传给共享 `PeekRemote`；bridge 绑定已有 Talker 和该 remote；连接页面使用同一个 memory/remote 并传入 `onScan`。生产渠道 Release/Profile 直接跳过构造、订阅、历史读取和发现入口。扫码链接只返回解码文本，不写入日志；SDK 不安装全局异常处理器。

详见 [连接包](packages/peek_desktop_connect/README.md)、[日志包](packages/peek_desktop_bridge/README.md) 与 [诊断协议](docs/诊断协议v1.md)。bridge 示例中的 macOS 工程用于合成数据；手机相机和局域网权限需由宿主真机验收。

## 本地验证

使用 `.fvmrc` 固定的 Flutter，在两个包分别执行 `fvm flutter pub get`、`fvm flutter analyze` 和 `fvm flutter test`。示例目录也可执行静态分析和 macOS debug 构建。

跨语言回归由 [Peek Desktop](https://github.com/lx8s8/peek-desktop) 的 `sdk_interop` 驱动，默认不读取系统配对库；协议变化时需与桌面一起验证。

## 来源与版本

初始代码从 `peek-desktop` 的 `a7a9f03b34f3bbdb1ad3e03b5db0f5c5cfa1f90a` 提取，原提交历史保留在桌面仓库。后续 SDK 改动仅在本仓库维护，桌面通过固定子模块版本参与联合测试。

## 开源边界

本仓库只包含可复用 SDK、协议、合成测试与演示工程。宿主的业务配置、生产诊断开关、业务脱敏规则和用户日志由宿主维护。配对授权仍由桌面执行，源码公开不改变一次性配对和设备授权要求。
