// Decision log
// - Why: iOS side of the halochat_flutter bridge. Wraps the HaloChat Core `HaloChatClient`
//   (not HaloChatUI) so the Flutter app can draw its own chat screen.
// - Owns: the single client for the signed-in user, the timeline EventChannel subscription, the
//   native -> Dart `token` callback, and dictionary <-> model/JSON conversion.
// - Left out: notifications (Core has none; the app shows them) and session persistence (Core
//   keeps tokens in memory only, so Dart calls setUser again on app start).

import Flutter
import Foundation
import HaloChat

public class HalochatFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let channel: FlutterMethodChannel
    private var client: HaloChatClient?
    private var timelineTask: Task<Void, Never>?

    // HaloChat pushes on iOS go straight through APNs (not FCM), so firebase_messaging never sees
    // them. The app's AppDelegate forwards them here; these statics bridge them to Dart.
    private static weak var shared: HalochatFlutterPlugin?
    private static var pendingTap: [String: Any]?
    private static var dartListensForTaps = false

    /// Set from Dart while the app's chat screen is visible.
    public private(set) static var suppressForegroundPush = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "halochat_flutter", binaryMessenger: registrar.messenger())
        let instance = HalochatFlutterPlugin(channel: channel)
        shared = instance
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "halochat_flutter/timeline", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance)
    }

    /// True for a HaloChat push payload (`type == "halochat_message"`).
    public static func isHaloChatPayload(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["type"] as? String == "halochat_message"
    }

    /// Call from `userNotificationCenter(_:didReceive:)` for a HaloChat payload. Delivered to Dart
    /// now, or buffered until Dart starts listening (cold start from a tap).
    public static func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        var payload: [String: Any] = [:]
        for (key, value) in userInfo where key is String && !(value is [AnyHashable: Any]) {
            payload[key as! String] = value
        }
        DispatchQueue.main.async {
            if dartListensForTaps, let plugin = shared {
                plugin.channel.invokeMethod("notificationTap", arguments: payload)
            } else {
                pendingTap = payload
            }
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "listenNotificationTaps":
            Self.dartListensForTaps = true
            result(Self.pendingTap)
            Self.pendingTap = nil
            return
        case "setForegroundPushSuppressed":
            Self.suppressForegroundPush = args["suppressed"] as? Bool ?? false
            result(nil)
            return
        default:
            break
        }
        if call.method == "setUser" {
            var config = HaloChatConfiguration()
            if let raw = args["baseUrl"] as? String, let url = URL(string: raw) { config.baseURL = url }
            if let raw = args["realtimeUrl"] as? String, let url = URL(string: raw) { config.realtimeURL = url }
            timelineTask?.cancel()
            client = HaloChatClient(
                configuration: config,
                tokenProvider: HaloChatClosureTokenProvider { [weak self] forceRefresh in
                    guard let self else { throw PluginError("Plugin released") }
                    return try await self.requestToken(forceRefresh: forceRefresh)
                }
            )
            result(nil)
            return
        }
        guard let client else {
            result(FlutterError(code: "NO_USER", message: "Call setUser first", details: nil))
            return
        }
        Task { @MainActor in
            do {
                result(try await self.perform(call.method, args: args, client: client))
            } catch {
                result(Self.flutterError(error))
            }
        }
    }

    @MainActor
    private func perform(_ method: String, args: [String: Any], client: HaloChatClient) async throws -> Any? {
        // Dart passes a UUID string; anything else gets a fresh id (retry is then not idempotent).
        let clientMessageId = (args["clientMessageId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        switch method {
        case "signOut":
            // Drop the client even if the server call failed: the user is gone locally.
            defer {
                timelineTask?.cancel()
                self.client = nil
            }
            try await client.signOut()
            return nil
        case "conversation":
            let c = try await client.conversation()
            return ["roomId": c.roomId, "title": c.title as Any? ?? NSNull()]
        case "latestMessages":
            return Self.map(try await client.latestMessages(limit: args["limit"] as? Int ?? 50))
        case "messagesBefore":
            let cursor = args["cursor"] as? String ?? ""
            return Self.map(try await client.messages(before: cursor, limit: args["limit"] as? Int ?? 50))
        case "messagesAfter":
            let cursor = args["cursor"] as? String ?? ""
            return Self.map(try await client.messages(after: cursor, limit: args["limit"] as? Int ?? 100))
        case "send":
            let text = args["text"] as? String ?? ""
            if let extras = args["extras"] as? [String: Any] {
                return Self.map(try await client.send(
                    text: text, extras: extras.mapValues(Self.toJSON), clientMessageId: clientMessageId))
            }
            return Self.map(try await client.send(text: text, clientMessageId: clientMessageId))
        case "sendAttachment":
            let path = args["path"] as? String ?? ""
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return Self.map(try await client.send(
                attachment: data,
                filename: args["filename"] as? String ?? URL(fileURLWithPath: path).lastPathComponent,
                mimeType: args["mimeType"] as? String ?? "application/octet-stream",
                caption: args["caption"] as? String,
                clientMessageId: clientMessageId
            ))
        case "mediaUrl":
            return try await client.mediaURL(for: args["messageId"] as? String ?? "").absoluteString
        case "registerPushToken":
            try await client.registerPushToken(args["token"] as? String ?? "")
            return nil
        case "unregisterPushToken":
            try await client.unregisterPushToken(args["token"] as? String ?? "")
            return nil
        default:
            return FlutterMethodNotImplemented
        }
    }

    // MARK: Timeline

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let client else { return FlutterError(code: "NO_USER", message: "Call setUser first", details: nil) }
        let initialLimit = (arguments as? [String: Any])?["initialLimit"] as? Int ?? 50
        timelineTask?.cancel()
        timelineTask = Task {
            let stream = client.timeline(initialLimit: initialLimit, onError: { error in
                // onError fires off the main thread; FlutterEventSink must be used on it.
                DispatchQueue.main.async { events(Self.flutterError(error)) }
            })
            // Cancelling the task ends the for-await, which stops the SDK's socket and polling.
            for await messages in stream {
                let maps = messages.map(Self.map)
                await MainActor.run { events(maps) }
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        timelineTask?.cancel()
        timelineTask = nil
        return nil
    }

    // MARK: Token

    /// Asks Dart for a token; the app mints it through its own backend.
    private func requestToken(forceRefresh: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.channel.invokeMethod("token", arguments: ["forceRefresh": forceRefresh]) { result in
                    if let token = result as? String, !token.isEmpty {
                        continuation.resume(returning: token)
                    } else if let error = result as? FlutterError {
                        continuation.resume(throwing: PluginError("\(error.code): \(error.message ?? "")"))
                    } else {
                        continuation.resume(throwing: PluginError("Token provider returned no token"))
                    }
                }
            }
        }
    }

    // MARK: Conversion

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func map(_ m: HaloChatMessage) -> [String: Any] {
        [
            "id": m.id,
            "text": m.text as Any? ?? NSNull(),
            "sender": m.sender.rawValue,
            "senderKind": m.senderKind.rawValue,
            "hasMedia": m.hasMedia,
            "mediaType": m.mediaType as Any? ?? NSNull(),
            "mediaFilename": m.mediaFilename as Any? ?? NSNull(),
            "createdAt": isoFormatter.string(from: m.createdAt),
            "status": m.status?.rawValue as Any? ?? NSNull(),
            "extras": m.extras.map { $0.mapValues(fromJSON) } as Any? ?? NSNull(),
        ]
    }

    private static func map(_ page: HaloChatMessagePage) -> [String: Any] {
        [
            "messages": page.messages.map(map),
            "newestCursor": page.newestCursor as Any? ?? NSNull(),
            "oldestCursor": page.oldestCursor as Any? ?? NSNull(),
        ]
    }

    private static func toJSON(_ value: Any) -> HaloChatJSON {
        switch value {
        case is NSNull: return .null
        case let n as NSNumber:
            // Flutter's codec boxes Dart bool as a CFBoolean NSNumber.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(toJSON))
        case let d as [String: Any]: return .object(d.mapValues(toJSON))
        default: return .string("\(value)")
        }
    }

    private static func fromJSON(_ json: HaloChatJSON) -> Any {
        switch json {
        case .null: return NSNull()
        case .bool(let b): return b
        // Integral doubles go back as Int so Dart sees the same types as on Android.
        case .number(let d): return d == d.rounded() && abs(d) < 9_007_199_254_740_992 ? Int(d) : d
        case .string(let s): return s
        case .array(let a): return a.map(fromJSON)
        case .object(let o): return o.mapValues(fromJSON)
        }
    }

    private static func flutterError(_ error: Error) -> FlutterError {
        guard let e = error as? HaloChatError else {
            return FlutterError(code: "UNKNOWN", message: "\(error)", details: nil)
        }
        switch e {
        case .unauthorized:
            return FlutterError(code: "UNAUTHORIZED", message: "HaloChat token refused", details: nil)
        case .rateLimited(let seconds):
            return FlutterError(code: "RATE_LIMITED", message: "Rate limited", details: ["retryAfterSeconds": seconds])
        case .sendInProgress:
            return FlutterError(code: "SEND_IN_PROGRESS", message: "Send already in progress", details: nil)
        case .rejected(let status, let code):
            return FlutterError(code: "REJECTED", message: "Rejected: \(status)",
                                details: ["status": status, "code": code as Any? ?? NSNull()])
        case .server(let status):
            return FlutterError(code: "SERVER", message: "Server error: \(status)", details: ["status": status])
        case .invalidResponse:
            return FlutterError(code: "INVALID_RESPONSE", message: "Invalid response", details: nil)
        }
    }
}

private struct PluginError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
