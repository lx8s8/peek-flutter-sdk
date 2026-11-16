import 'package:peek_remote/peek_remote.dart';

/// Accepts host[:port] and ws://host[:port]/, including bracketed IPv6.
/// Wildcard listener addresses cannot be used as connection destinations.
PeekRemoteEndpoint parseDesktopAddress(String address) {
  final text = address.trim();
  if (text.isEmpty || text.length > 512 || RegExp(r'\s').hasMatch(text)) {
    throw const FormatException('Invalid desktop address');
  }
  final uri = Uri.parse(text.contains('://') ? text : 'ws://$text');
  final host = uri.host;
  // Dart normalizes an explicit :0 to the scheme's default port; reject it too.
  final authority = (text.contains('://') ? text.split('://').last : text)
      .split(RegExp(r'[/#?]'))
      .first;
  final portText = authority.startsWith('[')
      ? authority.substring(authority.indexOf(']') + 1)
      : authority.contains(':')
      ? authority.substring(authority.lastIndexOf(':'))
      : '';
  if (portText.isNotEmpty && !RegExp(r'^:\d+$').hasMatch(portText)) {
    throw const FormatException('Invalid desktop port');
  }
  final port = portText.isEmpty ? 9741 : int.parse(portText.substring(1));
  if (uri.scheme != 'ws' ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      host.isEmpty ||
      host == '0.0.0.0' ||
      host == '::' ||
      port < 1 ||
      port > 65535) {
    throw const FormatException('Invalid desktop address');
  }
  return PeekRemoteEndpoint(host, port: port);
}

/// A short-lived invitation, never a stored device token.
final class DesktopPairingLink {
  DesktopPairingLink._(this.endpoint, this.serverId, this.code, this.expiresAt);

  factory DesktopPairingLink.parse(String text, {DateTime? now}) {
    if (text.length > 2048) throw const FormatException('Invalid pairing link');
    final uri = Uri.parse(text.trim());
    const keys = {'v', 'host', 'port', 'serverId', 'code', 'expiresAt'};
    final parameters = uri.queryParametersAll;
    if (uri.scheme != 'peek-desktop' ||
        uri.authority != 'pair' ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        parameters.length != keys.length ||
        !keys.every((key) => parameters[key]?.length == 1)) {
      throw const FormatException('Invalid pairing link');
    }
    final values = uri.queryParameters;
    final host = values['host']!;
    final port = int.tryParse(values['port']!);
    final expires = int.tryParse(values['expiresAt']!);
    if (values['v'] != '1' ||
        !RegExp(r'^\d{4}$').hasMatch(values['code']!) ||
        !RegExp(r'^[a-zA-Z0-9._:-]{1,200}$').hasMatch(values['serverId']!) ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        expires == null ||
        expires < 1 ||
        expires > 8640000000000 ||
        host.contains(RegExp(r'[/@?#\s]'))) {
      throw const FormatException('Invalid pairing link');
    }
    final endpoint = parseDesktopAddress(
      '${host.contains(':') ? '[$host]' : host}:$port',
    );
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expires * 1000,
      isUtc: true,
    );
    if (!expiresAt.isAfter(now ?? DateTime.now())) {
      throw const FormatException('Pairing link expired');
    }
    return DesktopPairingLink._(
      endpoint,
      values['serverId']!,
      values['code']!,
      expiresAt,
    );
  }

  final PeekRemoteEndpoint endpoint;
  final String serverId;
  final String code;
  final DateTime expiresAt;

  @override
  String toString() => 'DesktopPairingLink($endpoint)';
}
