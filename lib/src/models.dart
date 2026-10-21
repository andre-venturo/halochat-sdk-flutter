// Decision log
// - Why: Dart mirror of the native SDK models (HaloChatMessage, HaloChatMessagePage,
//   HaloChatConversation, HaloChatException/HaloChatError) so apps never touch platform maps.
// - Owns: tolerant decoding from the channel map. Unknown enum values fall back to the same
//   defaults the native SDKs use (sender -> agent, senderKind -> system), so a value added by a
//   newer server never fails a whole page.
// - Left out: equality/copyWith helpers. Add them when a caller needs them.

import 'package:flutter/services.dart';

enum HaloChatSender { me, agent }

enum HaloChatSenderKind { customer, ai, human, system }

enum HaloChatStatus { sent, delivered, read }

T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return null;
}

Map<String, dynamic>? _stringKeyed(Object? raw) =>
    raw is Map ? raw.map((k, v) => MapEntry(k.toString(), _deep(v))) : null;

Object? _deep(Object? v) {
  if (v is Map) return _stringKeyed(v);
  if (v is List) return v.map(_deep).toList();
  return v;
}

/// One message of the signed-in user's conversation.
class HaloChatMessage {
  const HaloChatMessage({
    required this.id,
    required this.createdAt,
    this.text,
    this.sender = HaloChatSender.agent,
    this.senderKind = HaloChatSenderKind.system,
    this.hasMedia = false,
    this.mediaType,
    this.mediaFilename,
    this.status,
    this.extras,
  });

  final String id;
  final String? text;
  final HaloChatSender sender;
  final HaloChatSenderKind senderKind;
  final bool hasMedia;
  final String? mediaType;
  final String? mediaFilename;
  final DateTime createdAt;
  final HaloChatStatus? status;

  /// Free-form JSON object sent with the message (like Qiscus `extras`), or null.
  final Map<String, dynamic>? extras;

  bool get isMine => sender == HaloChatSender.me;

  factory HaloChatMessage.fromMap(Map<dynamic, dynamic> map) => HaloChatMessage(
        id: map['id'].toString(),
        text: map['text'] as String?,
        sender: _enumByName(HaloChatSender.values, map['sender']) ?? HaloChatSender.agent,
        senderKind:
            _enumByName(HaloChatSenderKind.values, map['senderKind']) ?? HaloChatSenderKind.system,
        hasMedia: map['hasMedia'] == true,
        mediaType: map['mediaType'] as String?,
        mediaFilename: map['mediaFilename'] as String?,
        // Native sends ISO-8601; an unparseable value sorts as epoch instead of dropping the page.
        createdAt: DateTime.tryParse(map['createdAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        status: _enumByName(HaloChatStatus.values, map['status']),
        extras: _stringKeyed(map['extras']),
      );
}

/// One page of history, ascending by time. Cursors are opaque; pass them back verbatim.
class HaloChatMessagePage {
  const HaloChatMessagePage({required this.messages, this.newestCursor, this.oldestCursor});

  final List<HaloChatMessage> messages;
  final String? newestCursor;
  final String? oldestCursor;

  factory HaloChatMessagePage.fromMap(Map<dynamic, dynamic> map) => HaloChatMessagePage(
        messages: ((map['messages'] as List?) ?? const [])
            .map((m) => HaloChatMessage.fromMap(m as Map))
            .toList(),
        newestCursor: map['newestCursor'] as String?,
        oldestCursor: map['oldestCursor'] as String?,
      );
}

/// The user's single conversation with the business.
class HaloChatConversation {
  const HaloChatConversation({required this.roomId, this.title});

  final String roomId;
  final String? title;

  factory HaloChatConversation.fromMap(Map<dynamic, dynamic> map) =>
      HaloChatConversation(roomId: map['roomId'].toString(), title: map['title'] as String?);
}

/// Error codes the native side puts in [PlatformException.code].
enum HaloChatErrorCode {
  /// No user set: call `HaloChat.setUser` first.
  noUser,

  /// The token was refused even after one refresh through the token provider.
  unauthorized,

  /// Too many requests; see [HaloChatException.retryAfterSeconds].
  rateLimited,

  /// A send with this clientMessageId is still in flight; re-read before retrying.
  sendInProgress,

  /// The server rejected the request (4xx other than 401/409/429).
  rejected,

  /// Transient server failure (5xx).
  server,

  /// The response could not be decoded.
  invalidResponse,

  /// Anything else (network, file IO, token provider failure).
  unknown,
}

const _codeNames = {
  'NO_USER': HaloChatErrorCode.noUser,
  'UNAUTHORIZED': HaloChatErrorCode.unauthorized,
  'RATE_LIMITED': HaloChatErrorCode.rateLimited,
  'SEND_IN_PROGRESS': HaloChatErrorCode.sendInProgress,
  'REJECTED': HaloChatErrorCode.rejected,
  'SERVER': HaloChatErrorCode.server,
  'INVALID_RESPONSE': HaloChatErrorCode.invalidResponse,
};

class HaloChatException implements Exception {
  const HaloChatException(this.code, this.message, {this.status, this.retryAfterSeconds});

  final HaloChatErrorCode code;
  final String? message;

  /// HTTP status for [HaloChatErrorCode.rejected] / [HaloChatErrorCode.server].
  final int? status;
  final int? retryAfterSeconds;

  factory HaloChatException.fromPlatform(PlatformException e) {
    final details = e.details is Map ? e.details as Map : const {};
    return HaloChatException(
      _codeNames[e.code] ?? HaloChatErrorCode.unknown,
      e.message,
      status: details['status'] as int?,
      retryAfterSeconds: details['retryAfterSeconds'] as int?,
    );
  }

  @override
  String toString() => 'HaloChatException(${code.name}, $message)';
}
