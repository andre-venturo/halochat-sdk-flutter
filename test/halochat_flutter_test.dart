import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halochat_flutter/halochat_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('halochat_flutter');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final messageMap = {
    'id': 'm1',
    'text': 'Halo',
    'sender': 'me',
    'senderKind': 'customer',
    'hasMedia': false,
    'mediaType': null,
    'mediaFilename': null,
    'createdAt': '2026-10-21T03:04:05.123Z',
    'status': 'read',
    'extras': {
      'type': 'anamnesa',
      'metadata': {
        'photos': ['a.jpg'],
      },
    },
  };

  group('HaloChatMessage.fromMap', () {
    test('parses every field', () {
      final m = HaloChatMessage.fromMap(messageMap);
      expect(m.id, 'm1');
      expect(m.isMine, isTrue);
      expect(m.senderKind, HaloChatSenderKind.customer);
      expect(m.status, HaloChatStatus.read);
      expect(m.createdAt, DateTime.utc(2026, 10, 21, 3, 4, 5, 123));
      expect(m.extras!['metadata']['photos'], ['a.jpg']);
    });

    test('unknown enums fall back like the native SDKs, nulls stay null', () {
      final m = HaloChatMessage.fromMap({
        'id': 7,
        'sender': 'bot',
        'senderKind': 'robot',
        'status': 'seen',
        'createdAt': 'not a date',
      });
      expect(m.id, '7');
      expect(m.sender, HaloChatSender.agent);
      expect(m.senderKind, HaloChatSenderKind.system);
      expect(m.status, isNull);
      expect(m.text, isNull);
      expect(m.extras, isNull);
      expect(m.hasMedia, isFalse);
      expect(m.createdAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    });

    test('extras with non-string keys from the codec become string-keyed', () {
      final m = HaloChatMessage.fromMap({
        ...messageMap,
        'extras': <Object?, Object?>{
          'nested': <Object?, Object?>{1: 'x'},
        },
      });
      expect(m.extras!['nested'], {'1': 'x'});
    });
  });

  test('HaloChatMessagePage.fromMap keeps cursors and tolerates missing messages', () {
    final page = HaloChatMessagePage.fromMap({
      'messages': [messageMap],
      'oldestCursor': 'c1',
    });
    expect(page.messages.single.id, 'm1');
    expect(page.oldestCursor, 'c1');
    expect(page.newestCursor, isNull);
    expect(HaloChatMessagePage.fromMap({}).messages, isEmpty);
  });

  test('isHaloChatPayload', () {
    expect(HaloChat.isHaloChatPayload({'type': 'halochat_message'}), isTrue);
    expect(HaloChat.isHaloChatPayload({'type': 'order'}), isFalse);
    expect(HaloChat.isHaloChatPayload(null), isFalse);
  });

  group('method channel', () {
    final calls = <MethodCall>[];
    tearDown(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('send passes text, extras and clientMessageId and parses the reply', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return messageMap;
      });
      final sent = await HaloChat.send('Halo', extras: {'roomtype': 'bantuan'}, clientMessageId: 'u-1');
      expect(calls.single.method, 'send');
      expect(calls.single.arguments, {
        'text': 'Halo',
        'extras': {'roomtype': 'bantuan'},
        'clientMessageId': 'u-1',
      });
      expect(sent.id, 'm1');
    });

    test('PlatformException maps to HaloChatException with details', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'RATE_LIMITED', message: 'slow', details: {'retryAfterSeconds': 9});
      });
      await expectLater(
        HaloChat.latestMessages(),
        throwsA(isA<HaloChatException>()
            .having((e) => e.code, 'code', HaloChatErrorCode.rateLimited)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 9)),
      );
    });

    test('unknown native code maps to unknown', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'WAT');
      });
      await expectLater(
        HaloChat.mediaUrl('m1'),
        throwsA(isA<HaloChatException>().having((e) => e.code, 'code', HaloChatErrorCode.unknown)),
      );
    });

    test('tap handler gets the buffered cold-start tap, then live taps', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'listenNotificationTaps' ? {'type': 'halochat_message', 'roomId': 'r1'} : null;
      });
      final taps = <Map<String, dynamic>>[];
      await HaloChat.setNotificationTapHandler(taps.add);
      expect(taps.single['roomId'], 'r1');

      await messenger.handlePlatformMessage(
        'halochat_flutter',
        channel.codec.encodeMethodCall(const MethodCall('notificationTap', {'messageId': 'm9'})),
        (_) {},
      );
      expect(taps.last['messageId'], 'm9');
    });

    test('native token request is answered by the provider set in setUser', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final forced = <bool>[];
      await HaloChat.setUser((force) async {
        forced.add(force);
        return 'hct_abc';
      });

      final reply = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        'halochat_flutter',
        channel.codec.encodeMethodCall(const MethodCall('token', {'forceRefresh': true})),
        reply.complete,
      );
      expect(channel.codec.decodeEnvelope((await reply.future)!), 'hct_abc');
      expect(forced, [true]);
    });
  });
}
