# halochat_flutter

Flutter bridge over the **HaloChat core SDK** (`halochat-android` / `halochat-ios`, 0.3.0) for
apps that draw their own chat UI. The SDKs' built-in chat screens are deliberately not wrapped.

## Install

```yaml
dependencies:
  halochat_flutter:
    git:
      url: https://github.com/andre-venturo/halochat-sdk-flutter.git
      ref: v0.1.0
```

**Android:** the SDK is on JitPack only. Add it to the app's repositories (`android/build.gradle`
`allprojects.repositories`, or `dependencyResolutionManagement` in `settings.gradle`):

```groovy
maven { url 'https://jitpack.io' }
```

**iOS (CocoaPods):** HaloChat is not on trunk yet. Declare the Core pod in `ios/Podfile`
(iOS 15+):

```ruby
pod 'HaloChat', :git => 'https://github.com/afgventura/halochat-ios.git', :tag => '0.3.0'
```

With Swift Package Manager enabled nothing extra is needed.

## Use

```dart
// After login AND on app start (the core keeps the session in memory only):
await HaloChat.setUser((forceRefresh) => myApi.mintHaloChatToken(forceRefresh: forceRefresh));
await HaloChat.registerPushToken(fcmOrHexApnsToken);

final sub = HaloChat.timeline(onError: (e) => log('$e')).listen((window) {
  // Whole live window, ascending, de-duplicated. Merge older pages yourself by id.
});
final older = await HaloChat.messagesBefore(page.oldestCursor!);

await HaloChat.send('Halo', extras: {'type': 'anamnesa'}, clientMessageId: uuidV4);
await HaloChat.sendAttachment(file.path, filename: 'ktp.jpg', mimeType: 'image/jpeg');
final url = await HaloChat.mediaUrl(message.id); // short-lived

await sub.cancel();          // leaving the chat screen
await HaloChat.signOut();    // logout
```

- `clientMessageId` must be a **UUID string**; retry a failed send with the same id.
- Errors are `HaloChatException` with a `HaloChatErrorCode`
  (`noUser`, `unauthorized`, `rateLimited`, `sendInProgress`, `rejected`, `server`,
  `invalidResponse`, `unknown`).
- Push: the server sends `type: "halochat_message"`, `roomId`, `messageId`.
  `HaloChat.isHaloChatPayload(data)` checks it; showing the notification is the app's job.
  - Android: pushes arrive over FCM; register the FCM token.
  - iOS: pushes arrive over **APNs directly**, so firebase_messaging never sees them. Register
    the hex APNs token, and forward from the AppDelegate:

    ```swift
    import halochat_flutter

    // willPresent:
    if HalochatFlutterPlugin.isHaloChatPayload(userInfo) {
      completionHandler(HalochatFlutterPlugin.suppressForegroundPush ? [] : [.banner, .sound, .badge])
      return
    }
    // didReceive:
    if HalochatFlutterPlugin.isHaloChatPayload(userInfo) {
      HalochatFlutterPlugin.handleNotificationTap(userInfo: userInfo)
      completionHandler()
      return
    }
    ```

    Then `HaloChat.setNotificationTapHandler(...)` in Dart, and
    `HaloChat.setForegroundPushSuppressed(true)` while the chat screen is open.
- One timeline subscription at a time.

## Not in the SDK (0.3.0)

Reply/quote, typing indicators, presence, client-side mark-as-read / unread count, upload
progress, more than one conversation per user. Interactive components arrive as text fallback.
