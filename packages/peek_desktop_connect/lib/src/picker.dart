import 'dart:async';
import 'package:flutter/material.dart';
import 'package:peek_remote/peek_remote.dart';
import 'memory.dart';
import 'pairing_link.dart';

/// The host supplies its existing scanner and returns the decoded QR text.
typedef DesktopPairingScanner = Future<String?> Function(BuildContext context);

/// Reuses an existing PeekRemote. It neither starts nor disposes that client.
/// Discovery is explicit and stops when this widget is removed or disabled.
class DesktopConnectionPanel extends StatefulWidget {
  const DesktopConnectionPanel({
    super.key,
    required this.remote,
    required this.memory,
    this.onScan,
    this.enabled = true,
  });
  final PeekRemote remote;
  final DesktopConnectionMemory memory;
  final DesktopPairingScanner? onScan;
  final bool enabled;

  @override
  State<DesktopConnectionPanel> createState() => _DesktopConnectionPanelState();
}

class _DesktopConnectionPanelState extends State<DesktopConnectionPanel> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  final _link = TextEditingController();
  StreamSubscription<PeekRemoteState>? _states;
  StreamSubscription<List<PeekRemoteDiscovered>>? _discovery;
  List<PeekRemoteDesktop> _history = [];
  List<PeekRemoteDiscovered> _found = [];
  String? _serverId, _name, _error;
  bool _busy = false, _discovering = false;
  int _generation = 0, _historyRevision = 0, _discoveryRevision = 0;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    if (!widget.enabled) return;
    final generation = _generation;
    widget.memory.addListener(_reloadHistory);
    _states = widget.remote.stateChanges.listen((_) {
      if (mounted && generation == _generation) {
        setState(() {});
        _rememberConnected();
      }
    });
    final current = widget.remote.desktop;
    if (current != null)
      _select(current.endpoint, current.serverId, current.name);
    _reloadHistory();
    _rememberConnected();
  }

  void _rememberConnected() {
    final generation = _generation;
    unawaited(
      widget.memory.rememberConnected(widget.remote).catchError((Object _) {
        if (mounted && generation == _generation)
          setState(
            () => _error = _text(
              '连接已建立，历史记录保存失败。',
              'Connected, but history could not be saved.',
            ),
          );
      }),
    );
  }

  void _detach(DesktopConnectionPanel owner) {
    _generation++;
    _historyRevision++;
    _discoveryRevision++;
    owner.memory.removeListener(_reloadHistory);
    unawaited(_states?.cancel());
    unawaited(_discovery?.cancel());
    _states = null;
    _discovery = null;
    _found = [];
    _history = [];
    _discovering = false;
    _busy = false;
    _error = null;
    _serverId = null;
    _name = null;
    _address.clear();
    _code.clear();
    _link.clear();
  }

  @override
  void didUpdateWidget(covariant DesktopConnectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remote != widget.remote ||
        oldWidget.memory != widget.memory ||
        oldWidget.enabled != widget.enabled) {
      _detach(oldWidget);
      _attach();
    }
  }

  void _reloadHistory() {
    final revision = ++_historyRevision;
    unawaited(
      widget.memory
          .desktops()
          .then((entries) {
            if (mounted && revision == _historyRevision)
              setState(() => _history = entries);
          })
          .catchError((Object _) {
            if (mounted && revision == _historyRevision)
              setState(
                () => _error = _text(
                  '历史记录读取失败，可手动连接。',
                  'History unavailable. Enter an address manually.',
                ),
              );
          }),
    );
  }

  void _select(PeekRemoteEndpoint endpoint, String? id, String? name) {
    _address.text = endpoint.uri.authority;
    _serverId = id;
    _name = name;
    _code.clear();
    _link.clear();
    _error = null;
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy || !widget.enabled) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FormatException {
      if (mounted && generation == _generation)
        setState(
          () => _error = _text(
            '地址或配对链接无效、已到期，请重新生成。首次连接需输入四位配对码。',
            'Invalid or expired address/pairing link. Generate a new one. A first connection needs a four-digit code.',
          ),
        );
    } on Object {
      if (mounted && generation == _generation)
        setState(
          () => _error = _text(
            '连接操作失败，请检查网络后重试。',
            'Connection action failed. Check the network and retry.',
          ),
        );
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final generation = _generation;
    final endpoint = parseDesktopAddress(_address.text);
    final code = _code.text.trim();
    if (code.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(code))
      throw const FormatException();
    var id = _serverId;
    // An unknown manually entered address must never receive the active desktop's token.
    for (final desktop in _history) {
      if (desktop.endpoint == endpoint) id ??= desktop.serverId;
    }
    if (id == null && widget.remote.endpoint == endpoint)
      id = widget.remote.serverId;
    if (code.isEmpty && id == null) throw const FormatException();
    await widget.remote.connect(
      endpoint,
      code: code.isEmpty ? null : code,
      serverId: id,
      name: _name,
    );
    if (mounted && generation == _generation) {
      _code.clear();
      _link.clear();
    }
  }

  Future<void> _pair(String text) async {
    final invitation = DesktopPairingLink.parse(text);
    _select(invitation.endpoint, invitation.serverId, null);
    _code.text = invitation.code;
    await _connect();
  }

  void _discover() {
    final generation = _generation;
    final revision = ++_discoveryRevision;
    unawaited(_discovery?.cancel());
    setState(() {
      _discovering = true;
      _error = null;
    });
    _discovery = widget.remote.discover().listen(
      (found) {
        if (mounted &&
            generation == _generation &&
            revision == _discoveryRevision)
          setState(() => _found = found);
      },
      onError: (Object _) {
        if (mounted &&
            generation == _generation &&
            revision == _discoveryRevision)
          setState(() {
            _discovering = false;
            _error = _text(
              '自动发现不可用，可从历史选择或手动输入地址。',
              'Discovery unavailable. Use history or enter an address.',
            );
          });
      },
    );
  }

  String _stateLabel(PeekRemoteState state) => switch (state) {
    PeekRemoteState.connected => _text('已连接', 'Connected'),
    PeekRemoteState.connecting => _text('连接中', 'Connecting'),
    PeekRemoteState.waiting => _text('等待重连', 'Waiting to reconnect'),
    PeekRemoteState.denied => _text(
      '授权被拒绝，请生成新配对码',
      'Access denied. Generate a new code',
    ),
    PeekRemoteState.unpaired => _text('未配对', 'Unpaired'),
    PeekRemoteState.stopped => _text('已断开', 'Disconnected'),
  };

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final remote = widget.remote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _text('桌面连接', 'Desktop connection'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          _text(
            '可记住多台电脑，每次连接一台。手机填写电脑的局域网 IP；127.0.0.1 仅适合同机。',
            'Remember multiple computers and connect to one at a time. On a phone, use the computer’s LAN IP. 127.0.0.1 is for the same computer.',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_stateLabel(remote.state)}${remote.endpoint == null ? '' : ' · ${remote.endpoint!.uri.authority}'}',
        ),
        TextField(
          controller: _address,
          enabled: !_busy,
          autocorrect: false,
          onChanged: (_) => setState(() {
            _serverId = null;
            _name = null;
          }),
          decoration: InputDecoration(
            labelText: _text('桌面地址（host:port）', 'Desktop address (host:port)'),
          ),
        ),
        TextField(
          controller: _code,
          enabled: !_busy,
          maxLength: 4,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _text(
              '一次性配对码（已配对可留空）',
              'One-time code (optional when paired)',
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_act(_connect)),
              child: Text(_text('连接 / 配对', 'Connect / pair')),
            ),
            OutlinedButton(
              onPressed: _busy ? null : () => unawaited(_act(remote.stop)),
              child: Text(_text('断开', 'Disconnect')),
            ),
            if (widget.onScan != null)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _act(() async {
                          final generation = _generation;
                          final value = await widget.onScan!(context);
                          if (value != null &&
                              mounted &&
                              generation == _generation)
                            await _pair(value);
                        }),
                      ),
                child: Text(_text('扫码绑定', 'Scan to pair')),
              ),
          ],
        ),
        TextField(
          controller: _link,
          enabled: !_busy,
          autocorrect: false,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: _text('粘贴桌面配对链接', 'Paste desktop pairing link'),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => unawaited(_act(() => _pair(_link.text))),
          child: Text(_text('使用链接绑定', 'Pair using link')),
        ),
        const SizedBox(height: 8),
        Text(
          _text('历史桌面', 'Desktop history'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (_history.isEmpty)
          Text(_text('成功配对后保存在这里。', 'Paired desktops appear here.')),
        for (final desktop in _history)
          ListTile(
            contentPadding: EdgeInsets.zero,
            selected:
                remote.state == PeekRemoteState.connected &&
                remote.serverId == desktop.serverId,
            title: Text(desktop.name ?? desktop.endpoint.host),
            subtitle: Text(
              '${desktop.endpoint.uri.authority} · ${desktop.serverId}',
            ),
            onTap: _busy
                ? null
                : () {
                    setState(
                      () => _select(
                        desktop.endpoint,
                        desktop.serverId,
                        desktop.name,
                      ),
                    );
                    unawaited(_act(_connect));
                  },
            trailing: IconButton(
              tooltip: _text('忘记这台桌面', 'Forget this desktop'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _act(() async {
                        if (remote.serverId == desktop.serverId) {
                          await remote.forget();
                        } else {
                          await widget.memory.forget(desktop.serverId);
                        }
                        if (mounted && _serverId == desktop.serverId)
                          setState(() {
                            _serverId = null;
                            _name = null;
                          });
                      }),
                    ),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _discover,
              child: Text(_text('发现局域网桌面', 'Discover LAN desktops')),
            ),
            if (_discovering)
              TextButton(
                onPressed: () {
                  _discoveryRevision++;
                  unawaited(_discovery?.cancel());
                  _discovery = null;
                  setState(() {
                    _discovering = false;
                    _found = [];
                  });
                },
                child: Text(_text('停止发现', 'Stop discovery')),
              ),
          ],
        ),
        if (_discovering && _found.isEmpty)
          Text(
            _text(
              '正在发现；无结果时可手动输入 IP。',
              'Discovering. Enter an IP manually if no results appear.',
            ),
          ),
        for (final desktop in _found)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(desktop.name),
            subtitle: Text(
              '${desktop.endpoint.uri.authority} · ${!desktop.isCompatible
                  ? _text('协议不兼容', 'Incompatible protocol')
                  : _history.any((known) => known.serverId == desktop.serverId)
                  ? _text('已配对，可直接连接', 'Paired, tap to connect')
                  : _text('首次连接需配对码', 'Pairing code required')}',
            ),
            enabled: !_busy && desktop.isCompatible,
            onTap: () {
              final paired = _history.any(
                (known) => known.serverId == desktop.serverId,
              );
              setState(
                () => _select(desktop.endpoint, desktop.serverId, desktop.name),
              );
              if (paired) unawaited(_act(_connect));
            },
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _detach(widget);
    _address.dispose();
    _code.dispose();
    _link.dispose();
    super.dispose();
  }
}
