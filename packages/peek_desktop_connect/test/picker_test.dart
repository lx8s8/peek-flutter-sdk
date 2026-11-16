import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peek/core.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:peek_desktop_connect/peek_desktop_connect.dart';

class HistoryStore implements DesktopHistoryStore {
  int reads = 0;
  String? value;
  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String text) async {
    value = text;
  }
}

class Discovery implements PeekRemoteDiscovery {
  // Test fixtures close this controller after unmounting the picker.
  // ignore: close_sinks
  final stream = StreamController<List<PeekRemoteDiscovered>>.broadcast();
  int watches = 0;
  @override
  Stream<List<PeekRemoteDiscovered>> watch() {
    watches++;
    return stream.stream;
  }
}

class Wire implements PeekRemoteConnection {
  final messagesController = StreamController<String>.broadcast();
  final hellos = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<String> get messages => messagesController.stream;
  @override
  void send(String text) {
    final frame = jsonDecode(text) as Map<String, dynamic>;
    if (frame['type'] == 'hello') {
      hellos.add(frame);
      messagesController.add(
        jsonEncode({
          'type': 'welcome',
          'protocolVersion': 1,
          'server': {'id': 'a'},
          if (frame['code'] != null) 'deviceToken': 'a-token',
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await messagesController.close();
  }
}

class Transport implements PeekRemoteTransport {
  final wires = <Wire>[];
  final addresses = <Uri>[];
  @override
  Future<PeekRemoteConnection> connect(Uri uri) async {
    addresses.add(uri);
    final wire = Wire();
    wires.add(wire);
    return wire;
  }
}

void main() {
  testWidgets('late scanner result cannot connect after the picker is removed', (
    tester,
  ) async {
    final scanned = Completer<String?>();
    final transport = Transport();
    final memory = DesktopConnectionMemory(
      credentials: PeekRemoteMemory.inMemory(),
      historyStore: DesktopHistoryStore.inMemory(),
    );
    final peek = Peek();
    final remote = PeekRemote(peek, memory: memory, transport: transport);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DesktopConnectionPanel(
              remote: remote,
              memory: memory,
              onScan: (_) => scanned.future,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan to pair'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    scanned.complete(
      'peek-desktop://pair?v=1&host=192.168.1.8&port=9741&serverId=a&code=1234&expiresAt=2000000000',
    );
    await tester.pumpAndSettle();
    expect(transport.wires, isEmpty);
    expect(tester.takeException(), isNull);
    remote.dispose();
    peek.dispose();
    memory.dispose();
  });
  testWidgets(
    'disabled picker does not read credentials/history or start discovery/network',
    (tester) async {
      final store = HistoryStore(),
          discovery = Discovery(),
          transport = Transport();
      final memory = DesktopConnectionMemory(
        credentials: PeekRemoteMemory.inMemory(),
        historyStore: store,
      );
      final peek = Peek();
      final remote = PeekRemote(
        peek,
        memory: memory,
        discovery: discovery,
        transport: transport,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopConnectionPanel(
            remote: remote,
            memory: memory,
            enabled: false,
          ),
        ),
      );
      await tester.pump();
      expect(store.reads, 0);
      expect(discovery.watches, 0);
      expect(transport.wires, isEmpty);
      await tester.pumpWidget(const SizedBox());
      remote.dispose();
      peek.dispose();
      memory.dispose();
      await discovery.stream.close();
    },
  );

  testWidgets(
    'scanner binds once, history reconnects without code, unknown manual address cannot leak token',
    (tester) async {
      final store = HistoryStore(),
          discovery = Discovery(),
          transport = Transport();
      final memory = DesktopConnectionMemory(
        credentials: PeekRemoteMemory.inMemory(),
        historyStore: store,
      );
      final peek = Peek();
      final remote = PeekRemote(
        peek,
        memory: memory,
        discovery: discovery,
        transport: transport,
      );
      var scans = 0;
      Future<String?> scan(BuildContext _) async {
        scans++;
        return 'peek-desktop://pair?v=1&host=192.168.1.8&port=9741&serverId=a&code=1234&expiresAt=${DateTime.now().add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/ 1000}';
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DesktopConnectionPanel(
                remote: remote,
                memory: memory,
                onScan: scan,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(discovery.watches, 0);
      await tester.tap(find.text('Scan to pair'));
      await tester.pumpAndSettle();
      expect(scans, 1);
      expect(remote.state, PeekRemoteState.connected);
      expect(transport.wires.single.hellos.single['code'], '1234');
      expect(transport.wires.single.hellos.single['token'], isNull);
      final historyTile = find.widgetWithText(ListTile, '192.168.1.8');
      await tester.ensureVisible(historyTile);
      await tester.pumpAndSettle();
      await tester.tap(historyTile);
      await tester.pumpAndSettle();
      expect(transport.wires.last.hellos.single['token'], 'a-token');
      expect(transport.wires.last.hellos.single['code'], isNull);
      expect(transport.wires.first.closed, true);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))
            .onPressed,
        isNotNull,
        reason: 'reconnect action should finish',
      );
      // A typo/new address without a pairing code must leave the current client untouched.
      final field = find.widgetWithText(
        TextField,
        'Computer address (host:port)',
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, '192.168.1.99:9741');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        '192.168.1.99:9741',
      );
      await tester.ensureVisible(find.text('Connect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(transport.wires.length, 2);
      expect(
        find.textContaining('Check the address and four-digit code'),
        findsOneWidget,
      );
      // Discovery does not start until requested, and cancellation leaves the shared remote running.
      await tester.ensureVisible(find.text('Find nearby computers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find nearby computers'));
      await tester.pump();
      expect(discovery.watches, 1);
      expect(discovery.stream.hasListener, true);
      discovery.stream.add([
        const PeekRemoteDiscovered(
          name: 'New IP',
          endpoint: PeekRemoteEndpoint('192.168.1.18'),
          serverId: 'a',
          protocolVersion: 1,
        ),
      ]);
      await tester.pump();
      await tester.ensureVisible(find.text('New IP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New IP'));
      await tester.pumpAndSettle();
      expect(transport.addresses.last.host, '192.168.1.18');
      expect(transport.wires.last.hellos.single['token'], 'a-token');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(discovery.stream.hasListener, false);
      expect(remote.state, PeekRemoteState.connected);
      await remote.stop();
      remote.dispose();
      peek.dispose();
      memory.dispose();
      await discovery.stream.close();
    },
  );

  testWidgets(
    'expired scan leaves the active destination unchanged and shows no secret',
    (tester) async {
      final transport = Transport(),
          memory = DesktopConnectionMemory(
            credentials: PeekRemoteMemory.inMemory(),
            historyStore: DesktopHistoryStore.inMemory(),
          );
      final peek = Peek();
      final remote = PeekRemote(peek, memory: memory, transport: transport);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DesktopConnectionPanel(
                remote: remote,
                memory: memory,
                onScan: (_) async =>
                    'peek-desktop://pair?v=1&host=192.168.1.8&port=9741&serverId=a&code=6789&expiresAt=1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan to pair'));
      await tester.pumpAndSettle();
      expect(transport.wires, isEmpty);
      expect(
        find.textContaining('Check the address and four-digit code'),
        findsOneWidget,
      );
      expect(find.textContaining('6789'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      remote.dispose();
      peek.dispose();
      memory.dispose();
    },
  );
}
