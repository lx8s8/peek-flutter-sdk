import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:peek_remote/peek_remote.dart';
import 'package:talker/talker.dart';
import 'coordinator.dart';
import 'model.dart';

enum DiagnosticsState {
  stopped,
  waitingForNetwork,
  connecting,
  ready,
  unsupported,
  denied,
}

class BridgeStats {
  const BridgeStats(
    this.queued,
    this.queuedBytes,
    this.dropped,
    this.conversionErrors,
    this.retries,
    this.acknowledged,
  );
  final int queued, queuedBytes, dropped, conversionErrors, retries;
  final String acknowledged;
}

class _Queued {
  _Queued(this.sequence, this.json, this.bytes, this.important);
  final BigInt sequence;
  final Map<String, Object?> json;
  final int bytes;
  final bool important;
}

class _Flight {
  _Flight(this.to, this.sentAt);
  final BigInt to;
  final int sentAt;
}

/// Explicit lifecycle. Guard construction with the app's compile-time debug policy.
class DesktopDiagnosticsBridge {
  DesktopDiagnosticsBridge({
    required this.redactor,
    this.enabled = true,
    this.maxEvents = 2000,
    this.maxBytes = 4 * 1024 * 1024,
    this.onDiagnostic,
    this.emitterId = 'main',
  }) {
    if (maxEvents < 1 ||
        maxEvents > 2000 ||
        maxBytes < 1 ||
        maxBytes > 4 * 1024 * 1024 ||
        emitterId.isEmpty ||
        emitterId.length > 100)
      throw ArgumentError('Invalid diagnostic limits');
  }
  final DiagnosticRedactor redactor;
  final bool enabled;
  final int maxEvents, maxBytes;
  final String emitterId;

  /// Independent local callback; do not route it into the same Talker.
  final void Function(String code)? onDiagnostic;
  final List<_Queued> _queue = [];
  final Stopwatch _clock = Stopwatch();
  final Expando<bool> _seen = Expando<bool>();
  Talker? _talker;
  TalkerDiagnosticConverter _converter = defaultTalkerConverter;
  StreamSubscription<TalkerData>? _logs;
  PeekRemote? _remote;
  DesktopConnectionCoordinator? _coordinator;
  StreamSubscription<dynamic>? _messages;
  WebSocket? _socket;
  HttpClient? _probe;
  Timer? _timer, _retry, _helloTimeout;
  bool _running = false,
      _disposed = false,
      _connecting = false,
      _recording = false;
  String? _runId, _targetKey, _serverId;
  int _generation = 0,
      _context = 0,
      _bytes = 0,
      _dropped = 0,
      _conversionErrors = 0,
      _retries = 0,
      _attempts = 0,
      _lastReport = -10000;
  BigInt _next = BigInt.one, _accepted = BigInt.zero;
  _Flight? _flight;
  DiagnosticsState _state = DiagnosticsState.stopped;
  DiagnosticsState get state => _state;
  String? get runId => _runId;
  String get _emitter => '$emitterId/$_context';
  BridgeStats get stats => BridgeStats(
    _queue.length,
    _bytes,
    _dropped,
    _conversionErrors,
    _retries,
    _accepted.toString(),
  );
  static String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void attachTalker(Talker talker, {TalkerDiagnosticConverter? converter}) {
    if (_disposed || !enabled) return;
    _converter = converter ?? defaultTalkerConverter;
    if (identical(_talker, talker)) return;
    unawaited(_logs?.cancel());
    _logs = null;
    _talker = talker;
    if (_running) _subscribeTalker();
  }

  void _subscribeTalker() {
    final talker = _talker;
    if (talker == null || _logs != null) return;
    void capture(TalkerData data) {
      if (!_running || !identical(_talker, talker) || _seen[data] == true)
        return;
      _seen[data] = true;
      try {
        final record = _converter(data);
        if (record != null) this.record(record);
      } on Object {
        _conversionErrors++;
        _report('converterFailed');
      }
    }

    _logs = talker.stream.listen(
      capture,
      onError: (Object _) => _report('talkerStreamFailed'),
    );
    final history = talker.history;
    for (final data in history.skip(max(0, history.length - maxEvents))) {
      capture(data);
    }
  }

  void attachPeekRemote(PeekRemote remote) {
    if (_disposed || !enabled || identical(_remote, remote)) return;
    unawaited(_coordinator?.dispose());
    _disconnect();
    _targetKey = null;
    _remote = remote;
    _coordinator = DesktopConnectionCoordinator(remote, () {
      if (identical(_remote, remote)) _coordinate();
    });
    if (_running) _coordinator!.start();
  }

  void start() {
    if (_disposed || _running || !enabled) return;
    _running = true;
    _runId ??= _id();
    _clock.start();
    _subscribeTalker();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _pump());
    _state = DiagnosticsState.waitingForNetwork;
    _coordinator?.start();
  }

  bool record(DiagnosticRecord record) {
    if (!_running || _disposed || !enabled || _recording) return false;
    _recording = true;
    try {
      final cleaned = redactor(normalizeEvent(record.toJson()));
      if (cleaned == null) return false;
      final event = normalizeEvent(cleaned);
      if (event['message'] is! String ||
          event['source'] is! String ||
          !const [
            'verbose',
            'debug',
            'info',
            'warning',
            'error',
            'critical',
          ].contains(event['level']))
        throw const FormatException('Invalid record');
      final sequence = _next;
      if (sequence > BigInt.parse('18446744073709551615'))
        throw const FormatException('Sequence exhausted');
      event.addAll({
        'eventId': '$_runId/$_emitter/$sequence',
        'runId': _runId,
        'emitterId': _emitter,
        'sequence': sequence.toString(),
        'monotonicMicros': _clock.elapsedMicroseconds.toString(),
      });
      final size = utf8.encode(jsonEncode(event)).length;
      if (size > 128 * 1024) {
        _conversionErrors++;
        _report('eventTooLarge');
        return false;
      }
      _next += BigInt.one;
      _queue.add(
        _Queued(
          sequence,
          event,
          size,
          const ['warning', 'error', 'critical'].contains(event['level']),
        ),
      );
      _bytes += size;
      while (_queue.length > maxEvents || _bytes > maxBytes) {
        final low = _queue.indexWhere((e) => !e.important);
        final old = _queue.removeAt(low < 0 ? 0 : low);
        _bytes -= old.bytes;
        _dropped++;
      }
      if (_queue.length >= 64) _pump();
      return true;
    } on Object {
      _conversionErrors++;
      _report('recordFailed');
      return false;
    } finally {
      _recording = false;
    }
  }

  void resetContext() {
    if (!enabled || _disposed) return;
    _queue.clear();
    _bytes = 0;
    _next = BigInt.one;
    _accepted = BigInt.zero;
    _context++;
    for (final data in _talker?.history ?? const <TalkerData>[]) {
      _seen[data] = true;
    }
    _targetKey = null;
    _disconnect();
    if (_running) _coordinate();
  }

  /// Explicit retry after a diagnostic-only permission change.
  void reconnect() {
    if (_running) {
      _targetKey = null;
      _disconnect();
      _coordinate();
    }
  }

  void _coordinate() {
    if (!_running) return;
    final remote = _remote;
    if (remote == null ||
        remote.state != PeekRemoteState.connected ||
        remote.endpoint == null ||
        remote.deviceToken == null ||
        remote.serverId == null) {
      _targetKey = null;
      _disconnect();
      _state = DiagnosticsState.waitingForNetwork;
      if (remote?.state == PeekRemoteState.denied ||
          remote?.state == PeekRemoteState.unpaired) {
        _queue.clear();
        _bytes = 0;
      }
      return;
    }
    final key =
        '${remote.serverId}|${remote.endpoint}|${remote.sessionId}|${remote.deviceToken}';
    if (_targetKey == key) return;
    if (_serverId != null && _serverId != remote.serverId) {
      _queue.clear();
      _bytes = 0;
      _context++;
      _next = BigInt.one;
      _accepted = BigInt.zero;
    }
    _serverId = remote.serverId;
    _targetKey = key;
    _disconnect();
    _attempts = 0;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (!_running || _connecting || _targetKey == null) return;
    final remote = _remote;
    if (remote == null || remote.state != PeekRemoteState.connected) return;
    final endpoint = remote.endpoint!;
    final token = remote.deviceToken;
    final server = remote.serverId;
    if (token == null || server == null) return;
    _connecting = true;
    _state = DiagnosticsState.connecting;
    final generation = _generation;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      _probe = client;
      bool supported;
      try {
        final request = await client
            .getUrl(
              Uri(
                scheme: 'http',
                host: endpoint.host,
                port: endpoint.port,
                path: '/diagnostics/v1/capabilities',
              ),
            )
            .timeout(const Duration(seconds: 3));
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        if (response.statusCode != 200) {
          supported = false;
        } else {
          final bytes = <int>[];
          await for (final chunk in response.timeout(
            const Duration(seconds: 3),
          )) {
            if (bytes.length + chunk.length > 8192)
              throw const FormatException('Capabilities too large');
            bytes.addAll(chunk);
          }
          final decoded = jsonDecode(utf8.decode(bytes));
          supported =
              decoded is Map &&
              decoded['protocol'] == 'peek-desktop-diagnostics' &&
              decoded['version'] == 1 &&
              decoded['serverId'] == server;
        }
      } on Object {
        supported = false;
      } finally {
        client.close(force: true);
        if (identical(_probe, client)) _probe = null;
      }
      if (!_current(generation)) return;
      if (!supported) {
        _state = DiagnosticsState.unsupported;
        return;
      }
      final socket = await WebSocket.connect(
        Uri(
          scheme: 'ws',
          host: endpoint.host,
          port: endpoint.port,
          path: '/diagnostics/v1',
        ).toString(),
      ).timeout(const Duration(seconds: 5));
      if (!_current(generation)) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      _messages = socket.listen(
        (dynamic data) => _message(generation, data),
        onDone: () => _lost(generation),
        onError: (Object _) => _lost(generation),
        cancelOnError: true,
      );
      socket.add(
        jsonEncode({
          'type': 'diagnostics.hello',
          'protocol': 'peek-desktop-diagnostics',
          'version': 1,
          'serverId': server,
          'deviceToken': token,
          'runId': _runId,
          'networkSessionId': remote.sessionId,
        }),
      );
      _helloTimeout = Timer(
        const Duration(seconds: 5),
        () => _lost(generation),
      );
    } on Object {
      if (_current(generation)) _lost(generation);
    } finally {
      if (generation == _generation) _connecting = false;
    }
  }

  bool _current(int generation) =>
      _running && !_disposed && generation == _generation && _targetKey != null;
  BigInt _sequence(Object? value) {
    if (value is! String || !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value))
      throw const FormatException('Invalid sequence');
    final result = BigInt.parse(value);
    if (result > BigInt.parse('18446744073709551615'))
      throw const FormatException('Invalid sequence');
    return result;
  }

  void _message(int generation, dynamic data) {
    if (!_current(generation) || data is! String) return;
    try {
      if (data.length > 256 * 1024)
        throw const FormatException('Oversized frame');
      final value = jsonDecode(data);
      if (value is! Map) return;
      switch (value['type']) {
        case 'diagnostics.welcome':
          if (_state != DiagnosticsState.connecting ||
              value['protocol'] != 'peek-desktop-diagnostics' ||
              value['version'] != 1 ||
              value['runId'] != _runId)
            throw const FormatException('Invalid welcome');
          final ranges = value['accepted'];
          if (ranges is! Map || ranges.length > 16)
            throw const FormatException('Invalid accepted ranges');
          final sequence = _sequence(ranges[_emitter] ?? '0');
          if (sequence >= _next)
            throw const FormatException('Sequence out of range');
          _accepted = sequence;
          _removeAccepted();
          _flight = null;
          _attempts = 0;
          _helloTimeout?.cancel();
          _state = DiagnosticsState.ready;
          _pump();
        case 'diagnostics.ack':
          if (value['emitterId'] != _emitter || _flight == null) return;
          final sequence = _sequence(value['sequence']);
          if (sequence != _flight!.to)
            throw const FormatException('ACK out of range');
          _accepted = sequence;
          _removeAccepted();
          _flight = null;
          _pump();
        case 'diagnostics.ping':
          _socket?.add(jsonEncode({'type': 'diagnostics.pong'}));
        case 'diagnostics.denied':
          _disconnect();
          _state = DiagnosticsState.denied;
          _report('diagnosticsDenied');
        case 'diagnostics.error':
          _disconnect();
          _state = DiagnosticsState.denied;
          _report('diagnosticsProtocolError');
      }
    } on Object {
      _disconnect();
      _state = DiagnosticsState.denied;
      _report('invalidDiagnosticsFrame');
    }
  }

  void _removeAccepted() {
    _queue.removeWhere((event) {
      if (event.sequence <= _accepted) {
        _bytes -= event.bytes;
        return true;
      }
      return false;
    });
  }

  void _pump() {
    try {
      _pumpUnsafe();
    } on Object {
      _lost(_generation);
    }
  }

  void _pumpUnsafe() {
    if (!_running || _state != DiagnosticsState.ready || _socket == null)
      return;
    if (_flight != null) {
      if (_clock.elapsedMilliseconds - _flight!.sentAt > 8000)
        _lost(_generation);
      return;
    }
    final next = _accepted + BigInt.one;
    final available = _queue.where((e) => e.sequence >= next).toList();
    if (available.isEmpty && next >= _next) return;
    final first = available.isEmpty ? _next : available.first.sequence;
    if (first > next) {
      final to = first - BigInt.one;
      _flight = _Flight(to, _clock.elapsedMilliseconds);
      _socket!.add(
        jsonEncode({
          'type': 'diagnostics.gap',
          'emitterId': _emitter,
          'fromSequence': next.toString(),
          'toSequence': to.toString(),
          'reason': 'notRetained',
        }),
      );
      return;
    }
    final events = <Map<String, Object?>>[];
    var bytes = 128;
    var expected = next;
    for (final event in available) {
      if (event.sequence != expected ||
          events.length == 64 ||
          bytes + event.bytes > 240 * 1024)
        break;
      events.add(event.json);
      bytes += event.bytes;
      expected += BigInt.one;
    }
    if (events.isEmpty) return;
    _flight = _Flight(expected - BigInt.one, _clock.elapsedMilliseconds);
    try {
      _socket!.add(
        jsonEncode({
          'type': 'diagnostics.batch',
          'emitterId': _emitter,
          'events': events,
        }),
      );
    } on Object {
      _lost(_generation);
    }
  }

  void _lost(int generation) {
    if (!_current(generation)) return;
    _disconnect();
    _state = DiagnosticsState.waitingForNetwork;
    _retries++;
    _attempts++;
    if (_targetKey != null && _remote?.state == PeekRemoteState.connected) {
      final ceiling = min(30000, 500 * (1 << min(6, _attempts - 1)));
      _retry = Timer(
        Duration(
          milliseconds: ceiling ~/ 2 + Random().nextInt(max(1, ceiling ~/ 2)),
        ),
        () => unawaited(_connect()),
      );
    }
  }

  void _disconnect() {
    _generation++;
    _connecting = false;
    _flight = null;
    _helloTimeout?.cancel();
    _retry?.cancel();
    _probe?.close(force: true);
    _probe = null;
    unawaited(_messages?.cancel());
    _messages = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close().catchError((Object _) {}));
  }

  void _report(String code) {
    if (_clock.elapsedMilliseconds - _lastReport < 5000) return;
    _lastReport = _clock.elapsedMilliseconds;
    try {
      onDiagnostic?.call(code);
    } on Object {}
  }

  Future<void> stop() async {
    _running = false;
    _targetKey = null;
    _disconnect();
    _timer?.cancel();
    _timer = null;
    await _logs?.cancel();
    _logs = null;
    await _coordinator?.stop();
    _state = DiagnosticsState.stopped;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    _queue.clear();
    _bytes = 0;
    _talker = null;
    _remote = null;
  }
}
