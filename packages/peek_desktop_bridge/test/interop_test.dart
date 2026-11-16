import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_bridge/peek_desktop_bridge.dart';
import 'package:peek_desktop_connect/peek_desktop_connect.dart';
import 'package:talker/talker.dart';

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) fail('Rust interoperability timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'official PeekRemote and bridge interoperate with Rust',
    () async {
      final env = Platform.environment;
      final peek = Peek(options: const PeekOptions(name: 'Synthetic Interop'));
      final memory = DesktopConnectionMemory(
        credentials: PeekRemoteMemory.inMemory(),
        historyStore: DesktopHistoryStore.inMemory(),
      );
      final remote = PeekRemote(peek, memory: memory);
      final talker = Talker(settings: TalkerSettings(useConsoleLogs: false));
      final bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
        ..attachTalker(talker)
        ..attachPeekRemote(remote)
        ..start();
      addTearDown(() async {
        await bridge.dispose();
        await remote.stop();
        remote.dispose();
        peek.dispose();
        memory.dispose();
      });
      const id = PeekId('interop-request');
      final now = DateTime.now().toUtc();
      // The first connection must include already captured history.
      peek.report(
        PeekRequestStarted(
          id: id,
          timestamp: now,
          source: 'synthetic-interop',
          request: PeekRequest(
            method: 'GET',
            uri: Uri.parse('https://synthetic.example.test/interop'),
          ),
        ),
      );
      final endpoint = PeekRemoteEndpoint(
        '127.0.0.1',
        port: int.parse(env['PEEK_INTEROP_PORT']!),
      );
      final invitation = DesktopPairingLink.parse(
        Uri(
          scheme: 'peek-desktop',
          host: 'pair',
          queryParameters: {
            'v': '1',
            'host': endpoint.host,
            'port': '${endpoint.port}',
            'serverId': env['PEEK_INTEROP_SERVER_ID']!,
            'code': env['PEEK_INTEROP_CODE']!,
            'expiresAt':
                '${DateTime.now().add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/ 1000}',
          },
        ).toString(),
      );
      await remote.connect(
        invitation.endpoint,
        code: invitation.code,
        serverId: invitation.serverId,
      );
      await until(() => remote.state == PeekRemoteState.connected);
      peek.report(
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
      talker.info('interop-info');
      talker.warning('interop-warning');
      bridge.record(
        const DiagnosticRecord(
          level: 'error',
          message: 'interop-exception',
          tag: 'interop-review',
          relatedNetworkEntryId: 'interop-request',
          attributes: {'token': 'synthetic-secret'},
          exception: DiagnosticException(
            stackTrace: '#0 originalSyntheticFrame\n#1 syntheticMain',
          ),
        ),
      );
      await until(
        () => BigInt.parse(bridge.stats.acknowledged) >= BigInt.from(3),
      );
      await remote.stop();
      final desktop = (await memory.desktops()).single;
      expect(desktop.serverId, invitation.serverId);
      await remote.connect(desktop.endpoint, serverId: desktop.serverId);
      await until(
        () =>
            remote.state == PeekRemoteState.connected &&
            bridge.state == DiagnosticsState.ready,
      );
      talker.info('interop-after-reconnect');
      await until(
        () => BigInt.parse(bridge.stats.acknowledged) >= BigInt.from(4),
      );
      // Keep official bodyRequest handling alive until Rust verifies the remote body.
      final done = File(env['PEEK_INTEROP_DONE']!);
      await until(done.existsSync);
    },
    skip: !Platform.environment.containsKey('PEEK_INTEROP_PORT'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
