## 0.1.1

- `HaloChat.refresh()`: restarts the live timeline (backfill + fresh socket) at once. A running
  timeline whose socket dropped waits the SDK poll interval (5s) before it asks the server again;
  call this on app resume or on a push for the open chat. No native SDK change.

## 0.1.0

- Core-only bridge: setUser (Dart token provider), signOut, conversation, latestMessages,
  messagesBefore/After, timeline stream, send (+extras), sendAttachment, mediaUrl, push tokens.
