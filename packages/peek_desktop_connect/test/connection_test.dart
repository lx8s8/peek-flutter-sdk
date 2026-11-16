import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_connect/peek_desktop_connect.dart';

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) fail('Connection did not converge');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class DesktopServer {
  DesktopServer(this.http, this.id);
  final HttpServer http;
  final String id;
  final hellos = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  PeekRemoteEndpoint get endpoint =>
      PeekRemoteEndpoint('127.0.0.1', port: http.port);
  static Future<DesktopServer> start(String id) async {
    final server = DesktopServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      id,
    );
    server.http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      server.sockets.add(socket);
      socket.listen((dynamic text) {
        final frame = jsonDecode(text as String) as Map<String, dynamic>;
        if (frame['type'] == 'hello') {
          server.hellos.add(frame);
          if (frame['code'] == '1234' ||
              frame['token'] == '${server.id}-token') {
            socket.add(
              jsonEncode({
                'type': 'welcome',
                'protocolVersion': 1,
                'server': {'id': server.id},
                if (frame['code'] != null) 'deviceToken': '${server.id}-token',
              }),
            );
          } else {
            socket.add(
              jsonEncode({
                'type': 'denied',
                'reason': 'code',
                'message': 'Synthetic denial',
              }),
            );
          }
        } else if (frame['type'] == 'ping') {
          socket.add(jsonEncode({'type': 'pong'}));
        }
      });
    });
    return server;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await http.close(force: true);
  }
}

class FailedHistory implements DesktopHistoryStore {
  @override
  Future<String?> read() async => throw StateError('Synthetic history failure');
  @override
  Future<void> write(String value) async =>
      throw StateError('Synthetic history failure');
}

void main() {
  test(
    'history storage failures cannot prevent official credential save or revocation',
    () async {
      final credentials = PeekRemoteMemory.inMemory();
      final memory = DesktopConnectionMemory(
        credentials: credentials,
        historyStore: FailedHistory(),
      );
      const desktop = PeekRemoteDesktop(
        serverId: 'a',
        endpoint: PeekRemoteEndpoint('192.168.1.8'),
      );
      await expectLater(
        memory.remember(desktop, token: 'a-token'),
        throwsStateError,
      );
      expect(await memory.token('a'), 'a-token');
      expect(await memory.lastDesktop(), desktop);
      await expectLater(memory.forget('a'), throwsStateError);
      expect(await memory.token('a'), isNull);
      expect(await memory.lastDesktop(), isNull);
      memory.dispose();
    },
  );
  test(
    'desktop QR schema parses exact identity, code and expiry without exposing code in toString',
    () {
      final link = DesktopPairingLink.parse(
        'peek-desktop://pair?v=1&host=192.168.1.8&port=9741&serverId=desktop-a&code=0123&expiresAt=1924992180',
        now: DateTime.utc(2031),
      );
      expect(link.endpoint, const PeekRemoteEndpoint('192.168.1.8'));
      expect(link.code, '0123');
      expect(link.serverId, 'desktop-a');
      expect(link.toString(), isNot(contains('0123')));
      expect(link.expiresAt.millisecondsSinceEpoch, 1924992180000);
    },
  );

  test('rejects expired, ambiguous, foreign and token-bearing pairing links', () {
    const valid =
        'peek-desktop://pair?v=1&host=192.168.1.8&port=9741&serverId=a&code=1234&expiresAt=1924992180';
    for (final text in [
      valid.replaceFirst('v=1', 'v=2'),
      valid.replaceFirst('host=192.168.1.8', 'host=0.0.0.0'),
      valid.replaceFirst('port=9741', 'port=65536'),
      valid.replaceFirst('code=1234', 'code=123'),
      valid.replaceFirst('host=192.168.1.8', 'host=foo%40bar'),
      '$valid&code=5678',
      '$valid&token=secret',
      '$valid#fragment',
      valid.replaceFirst('peek-desktop:', 'https:'),
      valid.replaceFirst('://pair?', '://pair/other?'),
    ]) {
      expect(
        () => DesktopPairingLink.parse(text, now: DateTime.utc(2031)),
        throwsFormatException,
        reason: text,
      );
    }
    expect(
      () => DesktopPairingLink.parse(valid, now: DateTime.utc(2032)),
      throwsFormatException,
    );
  });

  test(
    'manual endpoints support URLs, DNS and IPv6 but reject credentials and paths',
    () {
      expect(parseDesktopAddress('ws://192.168.1.8:9741/').host, '192.168.1.8');
      expect(parseDesktopAddress('dev-mac.local').port, 9741);
      expect(parseDesktopAddress('[2001:db8::1]:9841').host, '2001:db8::1');
      for (final value in [
        '',
        '0.0.0.0:9741',
        '[::]:9741',
        'a:0',
        'a:65536',
        'a:-1',
        'a:abc',
        'https://a:9741',
        'ws://user:secret@a:9741/',
        'a:9741/path',
        'a:9741?token=secret',
      ]) {
        expect(
          () => parseDesktopAddress(value),
          throwsFormatException,
          reason: value,
        );
      }
    },
  );

  test(
    'history survives reconstruction, updates by identity and contains no credentials',
    () async {
      final credentials = PeekRemoteMemory.inMemory(),
          store = DesktopHistoryStore.inMemory();
      final memory = DesktopConnectionMemory(
        credentials: credentials,
        historyStore: store,
      );
      const a = PeekRemoteDesktop(
        serverId: 'a',
        endpoint: PeekRemoteEndpoint('192.168.1.8'),
        name: 'Alice',
      );
      const b = PeekRemoteDesktop(
        serverId: 'b',
        endpoint: PeekRemoteEndpoint('192.168.1.9'),
        name: 'Bob',
      );
      await Future.wait([
        memory.remember(a, token: 'secret-a'),
        memory.remember(b, token: 'secret-b'),
      ]);
      await memory.remember(a.at(const PeekRemoteEndpoint('10.0.1.8')));
      final restored = DesktopConnectionMemory(
        credentials: credentials,
        historyStore: store,
      );
      expect((await restored.desktops()).map((desktop) => desktop.serverId), [
        'a',
        'b',
      ]);
      expect((await restored.desktops()).first.endpoint.host, '10.0.1.8');
      expect(await restored.token('a'), 'secret-a');
      expect(await restored.token('b'), 'secret-b');
      expect(await store.read(), isNot(contains('secret-')));
      await restored.forget('a');
      expect((await restored.desktops()).single, b);
      expect(await restored.token('a'), isNull);
      expect(await restored.token('b'), 'secret-b');
      await restored.forgetAll();
      expect(await restored.desktops(), isEmpty);
      expect(await restored.token('b'), isNull);
      memory.dispose();
      restored.dispose();
    },
  );

  test(
    'migrates official last desktop despite corrupt history and bounds history metadata',
    () async {
      final credentials = PeekRemoteMemory.inMemory(),
          store = DesktopHistoryStore.inMemory();
      const legacy = PeekRemoteDesktop(
        serverId: 'legacy',
        endpoint: PeekRemoteEndpoint('192.168.1.2'),
      );
      await credentials.remember(legacy, token: 'legacy-token');
      await store.write('{broken');
      final memory = DesktopConnectionMemory(
        credentials: credentials,
        historyStore: store,
        limit: 2,
      );
      expect(await memory.desktops(), [legacy]);
      await memory.remember(
        const PeekRemoteDesktop(
          serverId: 'a',
          endpoint: PeekRemoteEndpoint('a.local'),
        ),
      );
      await memory.remember(
        const PeekRemoteDesktop(
          serverId: 'b',
          endpoint: PeekRemoteEndpoint('b.local'),
        ),
      );
      expect((await memory.desktops()).map((desktop) => desktop.serverId), [
        'b',
        'a',
      ]);
      expect(await memory.token('legacy'), 'legacy-token');
      memory.dispose();
    },
  );

  test(
    'one official client pairs A/B, recalls the correct tokens, and follows changed IP/port',
    () async {
      final a = await DesktopServer.start('a'),
          b = await DesktopServer.start('b');
      final aMoved = await DesktopServer.start('a');
      final memory = DesktopConnectionMemory(
        credentials: PeekRemoteMemory.inMemory(),
        historyStore: DesktopHistoryStore.inMemory(),
      );
      final peek = Peek();
      final remote = PeekRemote(peek, memory: memory);
      addTearDown(() async {
        await remote.stop();
        remote.dispose();
        peek.dispose();
        memory.dispose();
        await a.close();
        await b.close();
        await aMoved.close();
      });
      await remote.connect(
        a.endpoint,
        code: '1234',
        serverId: 'a',
        name: 'Alice',
      );
      await until(() => remote.state == PeekRemoteState.connected);
      await remote.connect(
        b.endpoint,
        code: '1234',
        serverId: 'b',
        name: 'Bob',
      );
      await until(
        () =>
            remote.state == PeekRemoteState.connected && remote.serverId == 'b',
      );
      final history = await memory.desktops();
      expect(history.map((desktop) => desktop.serverId), ['b', 'a']);
      await remote.connect(aMoved.endpoint, serverId: 'a', name: 'Alice');
      await until(
        () =>
            remote.state == PeekRemoteState.connected && remote.serverId == 'a',
      );
      expect(aMoved.hellos.single['token'], 'a-token');
      expect(aMoved.hellos.single['code'], isNull);
      expect(aMoved.hellos.single['token'], isNot('b-token'));
      await memory.rememberConnected(remote);
      expect((await memory.desktops()).first.endpoint, aMoved.endpoint);
      // Forget an inactive computer without disturbing the active one.
      await memory.forget('b');
      expect(remote.state, PeekRemoteState.connected);
      expect(await memory.token('b'), isNull);
      expect(await memory.token('a'), 'a-token');
      await remote.forget();
      expect(await memory.desktops(), isEmpty);
      expect(await memory.token('a'), isNull);
    },
  );
}
