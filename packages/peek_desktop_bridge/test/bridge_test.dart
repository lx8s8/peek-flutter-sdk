import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_bridge/peek_desktop_bridge.dart';
import 'package:talker/talker.dart';

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) fail('state did not converge');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Fixture {
  Fixture(
    this.server, {
    this.supported = true,
    this.serverId = 'synthetic-server',
  });
  final HttpServer server;
  final bool supported;
  final String serverId;
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> events = [];
  final List<Map<String, dynamic>> gaps = [];
  final Map<String, Map<String, String>> accepted = {};
  int probes = 0, diagnosticConnections = 0;
  bool loseAckOnce = false;
  static Future<Fixture> start({
    bool supported = true,
    String serverId = 'synthetic-server',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = Fixture(server, supported: supported, serverId: serverId);
    server.listen((request) => unawaited(fixture.handle(request)));
    return fixture;
  }

  Future<void> handle(HttpRequest request) async {
    if (request.uri.path == '/diagnostics/v1/capabilities') {
      probes++;
      request.response.statusCode = supported ? 200 : 404;
      request.response.write(
        jsonEncode({
          'protocol': 'peek-desktop-diagnostics',
          'version': 1,
          'serverId': serverId,
          'capabilities': ['logs', 'ack', 'gaps'],
        }),
      );
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    final diagnostic = request.uri.path == '/diagnostics/v1';
    if (diagnostic) diagnosticConnections++;
    String? run;
    socket.listen((dynamic text) {
      final value = jsonDecode(text as String) as Map<String, dynamic>;
      switch (value['type']) {
        case 'hello':
          socket.add(
            jsonEncode({
              'type': 'welcome',
              'protocolVersion': 1,
              'deviceToken': 'synthetic-token-$serverId',
              'server': {'id': serverId},
            }),
          );
        case 'diagnostics.hello':
          run = value['runId'] as String;
          socket.add(
            jsonEncode({
              'type': 'diagnostics.welcome',
              'protocol': 'peek-desktop-diagnostics',
              'version': 1,
              'runId': run,
              'accepted': accepted[run] ?? <String, String>{},
            }),
          );
        case 'diagnostics.batch':
          final incoming = (value['events'] as List)
              .cast<Map<String, dynamic>>();
          events.addAll(incoming);
          final emitter = value['emitterId'] as String;
          final sequence = incoming.last['sequence'] as String;
          (accepted[run!] ??= <String, String>{})[emitter] = sequence;
          if (loseAckOnce) {
            loseAckOnce = false;
            unawaited(socket.close());
          } else {
            socket.add(
              jsonEncode({
                'type': 'diagnostics.ack',
                'emitterId': emitter,
                'sequence': sequence,
              }),
            );
          }
        case 'diagnostics.gap':
          gaps.add(value);
          final emitter = value['emitterId'] as String;
          final sequence = value['toSequence'] as String;
          (accepted[run!] ??= <String, String>{})[emitter] = sequence;
          socket.add(
            jsonEncode({
              'type': 'diagnostics.ack',
              'emitterId': emitter,
              'sequence': sequence,
            }),
          );
        case 'ping':
          socket.add(jsonEncode({'type': 'pong'}));
      }
    }, onError: (Object _) {});
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }

  Future<PeekRemote> remote(Peek peek) async {
    final remote = PeekRemote(peek, memory: PeekRemoteMemory.inMemory());
    await remote.connect(
      PeekRemoteEndpoint('127.0.0.1', port: server.port),
      code: 'synthetic-code',
    );
    await until(() => remote.state == PeekRemoteState.connected);
    return remote;
  }
}

void main() {
  test('disabled bridge does not initialize, capture or subscribe', () async {
    final talker = Talker(settings: TalkerSettings(useConsoleLogs: false));
    final bridge = DesktopDiagnosticsBridge(
      redactor: redactSensitiveFields,
      enabled: false,
    );
    bridge.attachTalker(talker);
    bridge.start();
    talker.info('ignored');
    expect(bridge.record(const DiagnosticRecord(message: 'ignored')), false);
    expect(bridge.runId, isNull);
    expect(bridge.stats.queued, 0);
    await bridge.dispose();
  });
  test(
    'history and stream boundary is deduplicated, repeated initialization is safe',
    () async {
      final talker = Talker(settings: TalkerSettings(useConsoleLogs: false));
      talker.info('history');
      final bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields);
      bridge.attachTalker(talker);
      bridge.attachTalker(talker);
      bridge.start();
      bridge.start();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.stats.queued, 1);
      talker.warning('live');
      await Future<void>.delayed(Duration.zero);
      expect(bridge.stats.queued, 2);
      await bridge.dispose();
      talker.info('after dispose');
      await Future<void>.delayed(Duration.zero);
      expect(bridge.stats.queued, 0);
    },
  );
  test(
    'normalization bounds cycles, UTF-8 and serialization before queueing',
    () async {
      final cycle = <String, Object?>{};
      cycle['self'] = cycle;
      final value = normalizeEvent(
        DiagnosticRecord(
          message: '中😀' * 40000,
          attributes: {'cycle': cycle, 'token': 'synthetic-secret'},
          exception: DiagnosticException(stackTrace: '原始栈😀' * 50000),
        ).toJson(),
      );
      expect(
        utf8.encode(jsonEncode(value)).length,
        lessThanOrEqualTo(128 * 1024),
      );
      expect(value['truncated'], true);
      expect(
        jsonEncode(redactSensitiveFields(value)),
        isNot(contains('synthetic-secret')),
      );
      expect(
        (redactSensitiveFields({
              'attributes': <String, Object?>{'token': 'synthetic-secret'},
            })['attributes']
            as Map)['token'],
        '[REDACTED]',
      );
      final bridge = DesktopDiagnosticsBridge(
        redactor: (_) => throw StateError('synthetic'),
        maxEvents: 2,
      )..start();
      expect(bridge.record(const DiagnosticRecord(message: 'business')), false);
      expect(bridge.stats.conversionErrors, 1);
      await bridge.dispose();
    },
  );
  test(
    'unsupported desktop probes once while official network remains connected',
    () async {
      final fixture = await Fixture.start(supported: false);
      final peek = Peek();
      final remote = await fixture.remote(peek);
      final bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
        ..attachPeekRemote(remote)
        ..start();
      await until(() => bridge.state == DiagnosticsState.unsupported);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(fixture.probes, 1);
      expect(fixture.diagnosticConnections, 0);
      expect(remote.state, PeekRemoteState.connected);
      await bridge.dispose();
      await remote.stop();
      remote.dispose();
      peek.dispose();
      await fixture.close();
    },
  );
  test(
    'already connected official remote shares pairing and restores lost ACK',
    () async {
      final fixture = await Fixture.start();
      fixture.loseAckOnce = true;
      final peek = Peek();
      final remote = await fixture.remote(peek);
      final bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
        ..attachPeekRemote(remote)
        ..start();
      bridge.record(
        const DiagnosticRecord(
          message: 'safe',
          attributes: {'token': 'synthetic-secret'},
          exception: DiagnosticException(
            stackTrace: '#0 original\n#1 synthetic',
          ),
        ),
      );
      await until(() => bridge.stats.acknowledged == '1');
      expect(fixture.events.length, 1);
      expect(fixture.diagnosticConnections, greaterThanOrEqualTo(2));
      expect(
        (fixture.events.single['attributes'] as Map)['token'],
        '[REDACTED]',
      );
      expect(
        (fixture.events.single['exception'] as Map)['stackTrace'],
        '#0 original\n#1 synthetic',
      );
      expect(remote.state, PeekRemoteState.connected);
      expect(bridge.stats.queued, 0);
      await bridge.dispose();
      await remote.stop();
      remote.dispose();
      peek.dispose();
      await fixture.close();
    },
  );
  test(
    'overflow sends explicit gaps and context reset cannot carry old queue',
    () async {
      final fixture = await Fixture.start();
      final peek = Peek();
      final remote = await fixture.remote(peek);
      final bridge = DesktopDiagnosticsBridge(
        redactor: redactSensitiveFields,
        maxEvents: 2,
      )..start();
      for (var i = 0; i < 5; i++) {
        bridge.record(DiagnosticRecord(message: 'old $i'));
      }
      expect(bridge.stats.dropped, 3);
      bridge.resetContext();
      bridge.record(const DiagnosticRecord(message: 'new context'));
      for (var i = 0; i < 3; i++) {
        bridge.record(DiagnosticRecord(message: 'new $i'));
      }
      bridge.attachPeekRemote(remote);
      await until(() => bridge.stats.acknowledged == '4');
      expect(fixture.gaps.isNotEmpty, true);
      expect(
        fixture.events.every(
          (e) => !(e['message'] as String).startsWith('old'),
        ),
        true,
      );
      expect(bridge.stats.queued, 0);
      await bridge.dispose();
      await remote.stop();
      remote.dispose();
      peek.dispose();
      await fixture.close();
    },
  );
  test(
    'switching one official client isolates each desktop diagnostic queue',
    () async {
      final a = await Fixture.start(serverId: 'desktop-a');
      final b = await Fixture.start(serverId: 'desktop-b');
      final peek = Peek();
      final remote = await a.remote(peek);
      final bridge = DesktopDiagnosticsBridge(redactor: redactSensitiveFields)
        ..attachPeekRemote(remote)
        ..start();
      addTearDown(() async {
        await bridge.dispose();
        await remote.stop();
        remote.dispose();
        peek.dispose();
        await a.close();
        await b.close();
      });
      await until(() => bridge.state == DiagnosticsState.ready);
      bridge.record(const DiagnosticRecord(message: 'a-live'));
      await until(() => bridge.stats.acknowledged == '1');
      await remote.stop();
      await until(() => bridge.state == DiagnosticsState.waitingForNetwork);
      bridge.record(
        const DiagnosticRecord(message: 'a-offline-must-not-reach-b'),
      );
      expect(bridge.stats.queued, 1);
      await remote.connect(
        PeekRemoteEndpoint('127.0.0.1', port: b.server.port),
        code: 'synthetic-code',
        serverId: 'desktop-b',
      );
      await until(
        () =>
            bridge.state == DiagnosticsState.ready &&
            remote.serverId == 'desktop-b',
      );
      expect(bridge.stats.queued, 0);
      bridge.record(const DiagnosticRecord(message: 'b-live'));
      await until(() => bridge.stats.acknowledged == '1');
      expect(b.events.map((event) => event['message']), ['b-live']);
      expect(a.events.map((event) => event['message']), ['a-live']);
      await remote.connect(
        PeekRemoteEndpoint('127.0.0.1', port: a.server.port),
        serverId: 'desktop-a',
      );
      await until(
        () =>
            bridge.state == DiagnosticsState.ready &&
            remote.serverId == 'desktop-a',
      );
      bridge.record(const DiagnosticRecord(message: 'a-return'));
      await until(() => bridge.stats.acknowledged == '1');
      expect(a.events.map((event) => event['message']), ['a-live', 'a-return']);
      expect(b.events.map((event) => event['message']), ['b-live']);
    },
  );
  test('default Talker adapter leaves network logs with Peek', () {
    expect(
      defaultTalkerConverter(TalkerData('network', key: TalkerKey.httpRequest)),
      isNull,
    );
  });
}
