import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_bridge/peek_desktop_bridge.dart';
import 'package:peek_desktop_connect/peek_desktop_connect.dart';
import 'package:talker/talker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: [Locale('zh'), Locale('en')],
      home: Demo(),
    ),
  );
}

class Demo extends StatefulWidget {
  const Demo({super.key});
  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  static const enabled =
      kDebugMode && bool.fromEnvironment('PEEK_DESKTOP_DIAGNOSTICS');
  final talker = Talker(settings: TalkerSettings(useConsoleLogs: false));
  Peek? peek;
  PeekRemote? remote;
  DesktopDiagnosticsBridge? bridge;
  Timer? refresh;
  DesktopConnectionMemory? connectionMemory;
  bool emitting = false;
  @override
  void initState() {
    super.initState();
    if (enabled) {
      peek = Peek(options: const PeekOptions(name: 'Peek Bridge Demo'));
      connectionMemory = DesktopConnectionMemory();
      remote = peek!.attach(PeekRemote(peek!, memory: connectionMemory!));
      bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
        ..attachTalker(talker)
        ..attachPeekRemote(remote!)
        ..start();
      remote!.start();
      refresh = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void network() {
    final id = PeekId.generate();
    final now = DateTime.now().toUtc();
    peek!.report(
      PeekRequestStarted(
        id: id,
        timestamp: now,
        request: PeekRequest(
          method: 'GET',
          uri: Uri.parse('https://synthetic.example.test/demo/${id.value}'),
        ),
        source: 'synthetic-demo',
      ),
    );
    peek!.report(
      PeekResponseReceived(
        id: id,
        timestamp: now.add(const Duration(milliseconds: 42)),
        response: PeekResponse(
          statusCode: 200,
          body: PeekBody.text(
            '{"id":900719925474099312345,"amount":0.12345678901234567890,"padding":"${'x' * 6000}"}',
            contentType: PeekMediaType.tryParse('application/json'),
          ),
        ),
      ),
    );
    bridge!.record(
      DiagnosticRecord(
        message: '合成请求完成 · 显式关联',
        source: 'synthetic-demo',
        tag: 'request',
        relatedNetworkEntryId: id.value,
        attributes: const {'durationMs': 42, 'status': 200},
      ),
    );
  }

  void reviewSamples() {
    for (var i = 0; i < 3; i++) {
      bridge!.record(
        const DiagnosticRecord(
          message: '重复异常 · 合成数据',
          level: 'error',
          source: 'synthetic-review',
          tag: 'retry',
          exception: DiagnosticException(
            type: 'SyntheticError',
            message: '固定异常用于验证指纹分组',
            stackTrace:
                '#0 syntheticOperation (synthetic.dart:10:3)\n'
                '#1 syntheticCaller (synthetic.dart:20:5)',
          ),
        ),
      );
    }
    bridge!.record(
      const DiagnosticRecord(
        message: '空堆栈异常 · 合成数据',
        level: 'error',
        source: 'synthetic-review',
        tag: 'empty-stack',
        exception: DiagnosticException(type: 'SyntheticEmpty', stackTrace: ''),
      ),
    );
    bridge!.record(
      DiagnosticRecord(
        message: '截断属性 · 合成数据',
        source: 'synthetic-review',
        tag: 'truncated',
        attributes: {'oversized': 'x' * 40000},
        relatedNetworkEntryId: 'synthetic-missing-request',
      ),
    );
  }

  Future<void> burst() async {
    if (emitting) return;
    setState(() => emitting = true);
    for (var i = 1; i <= 120 && mounted; i++) {
      bridge!.record(
        DiagnosticRecord(
          message: '跟随测试 $i / 120 · 合成数据',
          source: 'synthetic-burst',
          tag: i.isEven ? 'even' : 'odd',
          level: i % 10 == 0 ? 'warning' : 'info',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (mounted) setState(() => emitting = false);
  }

  @override
  void dispose() {
    refresh?.cancel();
    unawaited(bridge?.dispose());
    remote?.dispose();
    peek?.dispose();
    connectionMemory?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Peek Bridge Demo')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          if (!enabled)
            const Text(
              '诊断未初始化。请用 debug 模式并传入 --dart-define=PEEK_DESKTOP_DIAGNOSTICS=true 启动。',
            )
          else ...[
            DesktopConnectionPanel(remote: remote!, memory: connectionMemory!),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('macOS 示例支持粘贴配对链接；手机 App 可通过 onScan 接入现有扫码页。'),
            ),
            const SizedBox(height: 16),
            Text('网络：${remote!.state.name} · 日志：${bridge!.state.name}'),
            Text(
              '待发 ${bridge!.stats.queued} 条 · 淘汰 ${bridge!.stats.dropped} · 已确认 ${bridge!.stats.acknowledged}',
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: network, child: const Text('生成合成请求')),
                OutlinedButton(
                  onPressed: reviewSamples,
                  child: const Text('P2 分组 / 空堆栈 / 截断'),
                ),
                OutlinedButton(
                  onPressed: emitting ? null : () => unawaited(burst()),
                  child: Text(emitting ? '正在发送合成日志…' : '连续 120 条日志'),
                ),
                OutlinedButton(
                  onPressed: () => talker.info('普通业务日志 · 合成数据'),
                  child: const Text('INFO 日志'),
                ),
                OutlinedButton(
                  onPressed: () => talker.warning('业务警告 · 合成数据'),
                  child: const Text('WARN 日志'),
                ),
                OutlinedButton(
                  onPressed: () => talker.handle(
                    StateError('合成异常'),
                    StackTrace.current,
                    '原始堆栈演示',
                  ),
                  child: const Text('异常与堆栈'),
                ),
                OutlinedButton(
                  onPressed: () => bridge!.record(
                    const DiagnosticRecord(
                      message: '结构化合成事件',
                      attributes: {
                        'operation': 'demo',
                        'token': 'synthetic-secret',
                      },
                    ),
                  ),
                  child: const Text('脱敏属性'),
                ),
                OutlinedButton(
                  onPressed: () => bridge!.resetContext(),
                  child: const Text('重置上下文'),
                ),
                OutlinedButton(
                  onPressed: () => bridge!.reconnect(),
                  child: const Text('重试日志连接'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('此示例只生成合成记录，不访问业务接口。生产应用需使用自身编译期诊断开关，不自动覆盖全局异常处理器。'),
          ],
        ],
      ),
    ),
  );
}
