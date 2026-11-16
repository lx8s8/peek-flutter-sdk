import 'dart:convert';
import 'package:talker/talker.dart';

typedef DiagnosticRedactor =
    Map<String, Object?>? Function(Map<String, Object?> event);
typedef TalkerDiagnosticConverter = DiagnosticRecord? Function(TalkerData data);

class DiagnosticException {
  const DiagnosticException({
    required this.stackTrace,
    this.type,
    this.message,
    this.stackFormat = 'dart',
  });
  final String stackTrace;
  final String? type;
  final String? message;
  final String stackFormat;
  Map<String, Object?> toJson() => {
    'stackTrace': stackTrace,
    'type': ?type,
    'message': ?message,
    'stackFormat': stackFormat,
  };
}

class DiagnosticRecord {
  const DiagnosticRecord({
    required this.message,
    this.level = 'info',
    this.source = 'app',
    this.tag,
    this.attributes = const {},
    this.exception,
    this.occurredAt,
    this.relatedNetworkEntryId,
    this.traceId,
  });
  final String message;
  final String level;
  final String source;
  final String? tag;
  final Map<String, Object?> attributes;
  final DiagnosticException? exception;
  final DateTime? occurredAt;
  final String? relatedNetworkEntryId;
  final String? traceId;
  Map<String, Object?> toJson() => {
    'kind': exception == null ? 'log' : 'exception',
    'level': level,
    'source': source,
    'message': message,
    'occurredAt': (occurredAt ?? DateTime.now()).toUtc().toIso8601String(),
    'tag': ?tag,
    'attributes': attributes,
    if (exception != null) 'exception': exception!.toJson(),
    'relatedNetworkEntryId': ?relatedNetworkEntryId,
    'traceId': ?traceId,
  };
}

DiagnosticRecord? defaultTalkerConverter(
  TalkerData data, {
  String? originalStackTrace,
  String? tag,
}) {
  if ([
    TalkerKey.httpRequest,
    TalkerKey.httpResponse,
    TalkerKey.httpError,
    TalkerKey.grpcRequest,
    TalkerKey.grpcResponse,
    TalkerKey.grpcError,
  ].contains(data.key))
    return null;
  final error = data.error ?? data.exception;
  return DiagnosticRecord(
    message: data.message ?? _safeString(error),
    level: data.logLevel?.name ?? (error != null ? 'error' : 'info'),
    source: 'talker',
    tag: tag ?? data.key,
    occurredAt: data.time,
    exception: error == null
        ? null
        : DiagnosticException(
            type: error.runtimeType.toString(),
            message: _safeString(error),
            stackTrace: originalStackTrace ?? data.stackTrace?.toString() ?? '',
          ),
  );
}

String _safeString(Object? value) {
  try {
    return value?.toString() ?? '';
  } on Object {
    return '[unprintable]';
  }
}

String _clip(String text, int limit) {
  if (text.length <= limit) return text;
  var end = limit;
  if (end > 0 &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff)
    end--;
  return text.substring(0, end);
}

/// Bounds arbitrary attributes before calling user redaction and again afterwards.
Map<String, Object?> normalizeEvent(Map<String, Object?> input) {
  final truncated = <String>{};
  var nodes = 0;
  void mark(String path) {
    if (truncated.length < 64) truncated.add(path);
  }

  Object? normalize(Object? value, String path, int depth) {
    if (++nodes > 512 || depth > 8) {
      mark(path);
      return '[depth limit]';
    }
    if (value == null || value is bool || value is int) return value;
    if (value is double) return value.isFinite ? value : value.toString();
    if (value is String) {
      final max = path == 'exception.stackTrace'
          ? 65536
          : path == 'message'
          ? 16384
          : 2048;
      final text = _clip(value, max);
      if (text != value) mark(path);
      return text;
    }
    if (value is Map) {
      final result = <String, Object?>{};
      var count = 0;
      for (final entry in value.entries) {
        if (++count > 64) {
          mark(path);
          break;
        }
        final key = _clip(_safeString(entry.key), 128);
        result[key] = normalize(
          entry.value,
          path.isEmpty ? key : '$path.$key',
          depth + 1,
        );
      }
      return result;
    }
    if (value is Iterable) {
      final result = <Object?>[];
      for (final item in value) {
        if (result.length == 64) {
          mark(path);
          break;
        }
        result.add(normalize(item, '$path[]', depth + 1));
      }
      return result;
    }
    return _clip(_safeString(value), 512);
  }

  const keys = {
    'kind',
    'level',
    'source',
    'message',
    'occurredAt',
    'tag',
    'attributes',
    'exception',
    'relatedNetworkEntryId',
    'traceId',
    'truncated',
    'truncatedFields',
  };
  final ordered = <String, Object?>{
    for (final entry in input.entries)
      if (keys.contains(entry.key) && entry.key != 'attributes')
        entry.key: entry.value,
  };
  if (ordered['exception'] is Map) {
    final exception = ordered['exception']! as Map;
    ordered['exception'] = <String, Object?>{
      for (final key in ['type', 'message', 'stackTrace', 'stackFormat'])
        if (exception.containsKey(key)) key: exception[key],
    };
  }
  final result = normalize(ordered, '', 0)! as Map<String, Object?>;
  result['attributes'] = normalize(
    input['attributes'] ?? <String, Object?>{},
    'attributes',
    0,
  );
  result.removeWhere((key, _) => !keys.contains(key));
  for (final key in ['source', 'tag', 'relatedNetworkEntryId', 'traceId']) {
    if (result[key] is String && (result[key]! as String).length > 256) {
      result[key] = _clip(result[key]! as String, 256);
      truncated.add(key);
    }
  }
  for (final key in ['kind', 'level', 'occurredAt']) {
    if (result[key] is String) result[key] = _clip(result[key]! as String, 64);
  }

  if (truncated.isNotEmpty) {
    result['truncated'] = true;
    result['truncatedFields'] = truncated.toList();
  }
  while (utf8.encode(jsonEncode(result)).length > 120 * 1024) {
    // Prefer preserving identity and a useful original stack over unbounded attributes.
    if (result['attributes'] is Map &&
        (result['attributes']! as Map).isNotEmpty) {
      result['attributes'] = <String, Object?>{};
      truncated.add('attributes');
    } else {
      for (final key in ['message', 'exception']) {
        if (key == 'message' && result[key] is String)
          result[key] = _clip(
            result[key]! as String,
            (result[key]! as String).length ~/ 2,
          );
        if (key == 'exception' && result[key] is Map<String, Object?>) {
          final exception = result[key]! as Map<String, Object?>;
          for (final field in ['stackTrace', 'message']) {
            if (exception[field] is String)
              exception[field] = _clip(
                exception[field]! as String,
                (exception[field]! as String).length ~/ 2,
              );
          }
        }
      }
      truncated.add('message');
      truncated.add('exception');
    }
    result['truncated'] = true;
    result['truncatedFields'] = truncated.toList();
  }
  return result;
}

/// Conservative structured-field helper; apps still supply their own free-text policy.
Map<String, Object?> redactSensitiveFields(Map<String, Object?> event) {
  final sensitive = RegExp(
    r'^(authorization|cookie|set-cookie|password|passwd|token|deviceToken|secret|otp|verificationCode|accessToken|refreshToken)$',
    caseSensitive: false,
  );
  Object? clean(Object? value) {
    if (value is Map<String, Object?>)
      return value.map(
        (key, item) =>
            MapEntry(key, sensitive.hasMatch(key) ? '[REDACTED]' : clean(item)),
      );
    if (value is List) return value.map(clean).toList();
    return value;
  }

  return clean(event)! as Map<String, Object?>;
}
