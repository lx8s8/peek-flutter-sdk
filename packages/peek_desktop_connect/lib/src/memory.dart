import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:peek_remote/peek_remote.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pairing_link.dart';

/// Stores display metadata only. Credential storage remains with PeekRemoteMemory.
abstract interface class DesktopHistoryStore {
  factory DesktopHistoryStore.sharedPreferences() = _PreferencesHistory;
  factory DesktopHistoryStore.inMemory() = _MemoryHistory;
  Future<String?> read();
  Future<void> write(String value);
}

final class _PreferencesHistory implements DesktopHistoryStore {
  late final _preferences = SharedPreferencesAsync();
  static const _key = 'peek_desktop_connect.history.v1';
  @override
  Future<String?> read() => _preferences.getString(_key);
  @override
  Future<void> write(String value) => _preferences.setString(_key, value);
}

final class _MemoryHistory implements DesktopHistoryStore {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async => _value = value;
}

/// Pass this SAME object to PeekRemote(memory: ...) and the picker.
/// Only successful official-client admissions create/update history entries.
class DesktopConnectionMemory extends ChangeNotifier
    implements PeekRemoteMemory {
  DesktopConnectionMemory({
    PeekRemoteMemory? credentials,
    DesktopHistoryStore? historyStore,
    this.limit = 20,
  }) : _credentials = credentials ?? PeekRemoteMemory.sharedPreferences(),
       _store = historyStore ?? DesktopHistoryStore.sharedPreferences() {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
  }

  final PeekRemoteMemory _credentials;
  final DesktopHistoryStore _store;
  final int limit;
  List<PeekRemoteDesktop>? _history;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<PeekRemoteDesktop>> _load() async {
    if (_history != null) return _history!;
    final entries = <PeekRemoteDesktop>[];
    final text = await _store.read();
    if (text != null && text.length <= 128 * 1024) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) {
          final seen = <String>{};
          for (final item in decoded.take(100)) {
            if (item is! Map<String, dynamic>) continue;
            final id = item['serverId'],
                host = item['host'],
                port = item['port'],
                name = item['name'];
            if (id is! String ||
                id.isEmpty ||
                id.length > 200 ||
                host is! String ||
                port is! int ||
                !seen.add(id))
              continue;
            try {
              final endpoint = parseDesktopAddress(
                '${host.contains(':') ? '[$host]' : host}:$port',
              );
              entries.add(
                PeekRemoteDesktop(
                  serverId: id,
                  endpoint: endpoint,
                  name: name is String ? name : null,
                ),
              );
            } on FormatException {
              /* Skip invalid display metadata. */
            }
          }
        }
      } on FormatException {
        /* Official credentials remain usable. */
      }
    }
    // Migrate the official client's last desktop without reading/copying a token.
    final last = await _credentials.lastDesktop();
    if (last != null) {
      entries.removeWhere((entry) => entry.serverId == last.serverId);
      entries.insert(0, last);
    }
    return _history = entries.take(limit).toList();
  }

  Future<List<PeekRemoteDesktop>> desktops() =>
      _serial(() async => List.unmodifiable(await _load()));

  /// Refreshes a successfully admitted desktop's display address. The official
  /// client may skip remember() when recalling a known identity at a new IP.
  Future<void> rememberConnected(PeekRemote remote) async {
    final desktop = remote.desktop;
    if (remote.state == PeekRemoteState.connected &&
        remote.deviceToken != null &&
        desktop != null) {
      await remember(desktop);
    }
  }

  Future<void> _save(List<PeekRemoteDesktop> entries) async {
    await _store.write(
      jsonEncode([
        for (final desktop in entries)
          {
            'serverId': desktop.serverId,
            'host': desktop.endpoint.host,
            'port': desktop.endpoint.port,
            if (desktop.name != null) 'name': desktop.name,
          },
      ]),
    );
    _history = entries;
    if (!_disposed) notifyListeners();
  }

  @override
  Future<PeekRemoteDesktop?> lastDesktop() => _serial(_credentials.lastDesktop);
  @override
  Future<String?> token(String serverId) =>
      _serial(() => _credentials.token(serverId));

  @override
  Future<void> remember(PeekRemoteDesktop desktop, {String? token}) =>
      _serial(() async {
        await _credentials.remember(desktop, token: token);
        final entries = List<PeekRemoteDesktop>.of(await _load());
        entries.removeWhere((entry) => entry.serverId == desktop.serverId);
        entries.insert(0, desktop);
        await _save(entries.take(limit).toList());
      });

  @override
  Future<void> forget(String serverId) => _serial(() async {
    await _credentials.forget(serverId);
    final entries = List<PeekRemoteDesktop>.of(await _load());
    entries.removeWhere((entry) => entry.serverId == serverId);
    await _save(entries);
  });

  @override
  Future<void> forgetAll() => _serial(() async {
    await _credentials.forgetAll();
    await _save([]);
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
