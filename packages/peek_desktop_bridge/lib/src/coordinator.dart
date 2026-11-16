import 'dart:async';
import 'package:peek_remote/peek_remote.dart';

/// Observes only public APIs; it never creates another network client or stores a token.
class DesktopConnectionCoordinator {
  DesktopConnectionCoordinator(this.remote, this.onChange);
  final PeekRemote remote;
  final void Function() onChange;
  // The subscription is cancelled by stop/dispose after clearing the owned slot.
  // ignore: cancel_subscriptions
  StreamSubscription<PeekRemoteState>? _subscription;
  void start() {
    if (_subscription != null) return;
    _subscription = remote.stateChanges.listen((_) => onChange());
    onChange(); // Covers an already connected remote.
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> dispose() => stop();
}
