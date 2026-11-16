# 开发指南

## 本地检查

仓库使用 `.fvmrc` 固定 Flutter 版本。安装 [FVM](https://fvm.app/) 后执行 `fvm install`；也可以直接使用同版本的 Flutter。

以下命令在仓库根目录执行：

```bash
(cd packages/peek_desktop_connect && fvm flutter pub get && fvm flutter analyze && fvm flutter test)
(cd packages/peek_desktop_bridge && fvm flutter pub get && fvm flutter analyze && fvm flutter test)
(cd packages/peek_desktop_bridge/example && fvm flutter pub get && fvm flutter analyze)
fvm dart format --output=none --set-exit-if-changed packages
```

修改连接面板时检查中英文、取消扫码、离开页面和切换电脑。修改日志传输时检查重连、丢 ACK、队列溢出和账号上下文重置。测试和示例使用合成数据。

## 与桌面联合测试

在 [Peek Desktop](https://github.com/lx8s8/peek-desktop) 根目录初始化 `sdk` 子模块，进入两个包执行 `flutter pub get`，再运行：

```bash
cargo test --locked --manifest-path src-tauri/Cargo.toml --test sdk_interop -- --ignored --nocapture
```

测试启动临时 Rust 服务，驱动真实 `PeekRemote` 完成配对、日志确认、重连、大正文和归档恢复。凭据只保存在内存，不读取本机系统配对库。常规 Rust 测试会跳过此项，需要显式运行。

修改协议时，同步更新 SDK 和桌面的协议文档、编解码及互操作测试；测试中要包含旧端不支持扩展的情况。

## 提交与版本

提交说明使用中文，写清修改对象和结果，例如 `优化-电脑连接-缩短配对提示并统一中英文名称`。一个提交集中处理一件事，附上实际运行的检查结果。

两个包使用相同版本和 Git tag；更新公开 API 或行为时同步 `pubspec.yaml` 与 `CHANGELOG.md`。已发布 tag 保持不变，消费方使用固定 tag 并提交锁文件。

README 以安装和可用示例为主，协议限制放在对应章节。只记录实际完成的验证；手机相机、跨物理电脑及平台权限验证与本机合成测试分开说明。
