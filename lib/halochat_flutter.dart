// Decision log
// - Why: Flutter bridge over the HaloChat *core* SDKs (Android `halochat`, iOS `HaloChat` Core,
//   0.3.0) so an app can drive its own chat UI from Dart. The SDKs' own chat screens are not
//   wrapped on purpose: this plugin is core-only.
// - Owns: one MethodChannel for calls, one EventChannel for the live timeline, and the
//   native -> Dart `token` callback so token minting stays in the app's own HTTP stack.
// - Left out: a platform-interface layer (one implementation only), recognising push payloads
//   beyond `type == "halochat_message"`, and showing notifications (the app owns that).

import 'dart:async';

import 'package:flutter/services.dart';

import 'src/models.dart';

export 'src/models.dart';

/// Mints a HaloChat client token (`hct_…`) through YOUR backend. [forceRefresh] is true after
/// HaloAI refused the last token: mint a new one instead of returning a cached value.
typedef HaloChatTokenProvider = Future<String> Function(bool forceRefresh);

class HaloChat {
  HaloChat._();

  static const MethodChannel _channel = MethodChannel('halochat_flutter');
  static const EventChannel _timelineChannel = EventChannel('halochat_flutter/timeline');

  static HaloChatTokenProvider? _tokenProvider;

  /// Push payload `type` the HaloChat server sends (`data.type` on FCM, `userInfo.type` on APNs).
  static const pushType = 'halochat_message';

  /// True when [data] is a HaloChat push payload. The core SDKs have no helper for this.
  static bool isHaloChatPayload(Map<dynamic, dynamic>? data) => data?['type'] == pushType;

  /// Creates the native client for the signed-in user. Call after every login AND on app start
  /// when a session is restored: the core SDKs keep the session in memory only.
  ///
  /// [baseUrl] / [realtimeUrl] default to HaloAI production when null.
  static Future<void> setUser(
    HaloChatTokenProvider tokenProvider, {
    String? baseUrl,
    String? realtimeUrl,
  }) {
    _tokenProvider = tokenProvider;
    _channel.setMethodCallHandler(_handleNativeCall);
    return _invoke<void>('setUser', {'baseUrl': baseUrl, 'realtimeUrl': realtimeUrl});
  }

  /// Unregisters this device's push token, expires the HaloChat session and drops the client.
  static Future<void> signOut() async {
    await _invoke<void>('signOut');
    _tokenProvider = null;
  }

  static Future<HaloChatConversation> conversation() async =>
      HaloChatConversation.fromMap((await _invoke<Map>('conversation'))!);

  static Future<HaloChatMessagePage> latestMessages({int limit = 50}) =>
      _page('latestMessages', {'limit': limit});

  /// Older page; pass [HaloChatMessagePage.oldestCursor] verbatim.
  static Future<HaloChatMessagePage> messagesBefore(String cursor, {int limit = 50}) =>
      _page('messagesBefore', {'cursor': cursor, 'limit': limit});

  /// Newer page; the server may resend some overlap, so merge by id.
  static Future<HaloChatMessagePage> messagesAfter(String cursor, {int limit = 100}) =>
      _page('messagesAfter', {'cursor': cursor, 'limit': limit});

  /// Live window: backfill, then realtime socket with polling fallback. Ascending and
  /// de-duplicated; each event is the whole window, not a delta. Older pages from
  /// [messagesBefore] are NOT included: keep them yourself and merge by id.
  ///
  /// Errors (offline, rate limited) go to [onError] and the stream keeps going: the SDK retries
  /// by itself. [HaloChatErrorCode.unauthorized] means the token provider can no longer mint.
  ///
  /// ponytail: one native subscription at a time (single EventChannel); a second concurrent
  /// listener with a different [initialLimit] shares the first one's window.
  static Stream<List<HaloChatMessage>> timeline({
    int initialLimit = 50,
    void Function(HaloChatException error)? onError,
  }) =>
      _timelineChannel
          .receiveBroadcastStream({'initialLimit': initialLimit})
          .transform(StreamTransformer<dynamic, List<HaloChatMessage>>.fromHandlers(
            handleData: (data, sink) => sink.add(
              (data as List).map((m) => HaloChatMessage.fromMap(m as Map)).toList(),
            ),
            handleError: (error, stack, sink) {
              if (error is PlatformException) {
                onError?.call(HaloChatException.fromPlatform(error));
              } else {
                sink.addError(error, stack);
              }
            },
          ));

  /// Sends text, optionally with [extras] (JSON object, at most 16 KB, needs a server with
  /// extras support). Keep [clientMessageId] until the send succeeds and retry with the SAME id:
  /// the server never creates a second message for it.
  static Future<HaloChatMessage> send(
    String text, {
    Map<String, dynamic>? extras,
    String? clientMessageId,
  }) async =>
      HaloChatMessage.fromMap((await _invoke<Map>('send', {
        'text': text,
        'extras': extras,
        'clientMessageId': clientMessageId,
      }))!);

  /// Uploads the file at [path] and sends it, optionally with a [caption].
  static Future<HaloChatMessage> sendAttachment(
    String path, {
    required String filename,
    required String mimeType,
    String? caption,
    String? clientMessageId,
  }) async =>
      HaloChatMessage.fromMap((await _invoke<Map>('sendAttachment', {
        'path': path,
        'filename': filename,
        'mimeType': mimeType,
        'caption': caption,
        'clientMessageId': clientMessageId,
      }))!);

  /// Short-lived download URL for a media message. Fetch again when it expires.
  static Future<String> mediaUrl(String messageId) async =>
      (await _invoke<String>('mediaUrl', {'messageId': messageId}))!;

  /// FCM token on Android, hex APNs token on iOS. Call after every [setUser].
  static Future<void> registerPushToken(String token) =>
      _invoke<void>('registerPushToken', {'token': token});

  static Future<void> unregisterPushToken(String token) =>
      _invoke<void>('unregisterPushToken', {'token': token});

  /// iOS only: HaloChat pushes arrive over APNs, not FCM, so firebase_messaging never reports
  /// their taps. Forward them from the AppDelegate with
  /// `HalochatFlutterPlugin.handleNotificationTap(userInfo:)` and receive them here. A tap that
  /// cold-started the app is delivered right after this call. No-op on Android (taps arrive
  /// through FCM there).
  static Future<void> setNotificationTapHandler(void Function(Map<String, dynamic> payload) handler) async {
    _onNotificationTap = handler;
    _channel.setMethodCallHandler(_handleNativeCall);
    final pending = await _invoke<Map>('listenNotificationTaps');
    if (pending != null) handler(pending.map((k, v) => MapEntry(k.toString(), v)));
  }

  static void Function(Map<String, dynamic> payload)? _onNotificationTap;

  /// iOS only: while true, the AppDelegate should not present HaloChat pushes in the foreground
  /// (read `HalochatFlutterPlugin.suppressForegroundPush`). Set it while the chat screen is open.
  static Future<void> setForegroundPushSuppressed(bool suppressed) =>
      _invoke<void>('setForegroundPushSuppressed', {'suppressed': suppressed});

  static Future<HaloChatMessagePage> _page(String method, Map<String, Object?> args) async =>
      HaloChatMessagePage.fromMap((await _invoke<Map>(method, args))!);

  static Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw HaloChatException.fromPlatform(e);
    }
  }

  static Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'notificationTap') {
      final payload = (call.arguments as Map?) ?? const {};
      _onNotificationTap?.call(payload.map((k, v) => MapEntry(k.toString(), v)));
      return null;
    }
    if (call.method != 'token') throw MissingPluginException(call.method);
    final provider = _tokenProvider;
    if (provider == null) {
      throw PlatformException(code: 'NO_USER', message: 'No token provider set');
    }
    return provider((call.arguments as Map?)?['forceRefresh'] == true);
  }
}
