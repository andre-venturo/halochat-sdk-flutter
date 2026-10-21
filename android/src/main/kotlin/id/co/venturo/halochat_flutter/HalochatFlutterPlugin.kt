// Decision log
// - Why: Android side of the halochat_flutter bridge. Wraps the HaloChat core `HaloChatClient`
//   (no halochat-ui) so the Flutter app can draw its own chat screen.
// - Owns: the single client for the signed-in user, the timeline EventChannel subscription, the
//   native -> Dart `token` callback, and Map <-> model/JSON conversion.
// - Left out: notifications (core has none; the app shows them) and session persistence (the
//   core keeps tokens in memory only, so Dart calls setUser again on app start).

package id.co.venturo.halochat_flutter

import id.co.haloai.halochat.HaloChatClient
import id.co.haloai.halochat.HaloChatConfig
import id.co.haloai.halochat.HaloChatConversation
import id.co.haloai.halochat.HaloChatException
import id.co.haloai.halochat.HaloChatMessage
import id.co.haloai.halochat.HaloChatMessagePage
import id.co.haloai.halochat.HaloChatTokenProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class HalochatFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: HaloChatClient? = null
    private var timelineJob: Job? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "halochat_flutter")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "halochat_flutter/timeline")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // iOS-only push helpers: on Android HaloChat pushes come through FCM, which Dart already sees.
        if (call.method == "listenNotificationTaps" || call.method == "setForegroundPushSuppressed") {
            result.success(null)
            return
        }
        if (call.method == "setUser") {
            val defaults = HaloChatConfig()
            val config = HaloChatConfig(
                baseUrl = call.argument<String>("baseUrl") ?: defaults.baseUrl,
                realtimeUrl = call.argument<String>("realtimeUrl") ?: defaults.realtimeUrl,
            )
            timelineJob?.cancel()
            client = HaloChatClient(config = config, tokenProvider = HaloChatTokenProvider { force -> requestToken(force) })
            result.success(null)
            return
        }
        val c = client ?: return result.error("NO_USER", "Call setUser first", null)
        scope.launch {
            try {
                val value: Any? = when (call.method) {
                    "signOut" -> try {
                        c.signOut(); null
                    } finally {
                        // Drop the client even if the server call failed: the user is gone locally.
                        timelineJob?.cancel()
                        client = null
                    }
                    "conversation" -> c.conversation().toMap()
                    "latestMessages" -> c.latestMessages(call.argument<Int>("limit") ?: 50).toMap()
                    "messagesBefore" ->
                        c.messagesBefore(call.argument<String>("cursor")!!, call.argument<Int>("limit") ?: 50).toMap()
                    "messagesAfter" ->
                        c.messagesAfter(call.argument<String>("cursor")!!, call.argument<Int>("limit") ?: 100).toMap()
                    "send" -> {
                        val text = call.argument<String>("text")!!
                        val id = call.argument<String>("clientMessageId") ?: UUID.randomUUID().toString()
                        val extras = call.argument<Map<String, Any?>>("extras")
                        val sent = if (extras == null) c.send(text, id) else c.send(text, extras.toJson(), id)
                        sent.toMap()
                    }
                    "sendAttachment" -> {
                        val bytes = withContext(Dispatchers.IO) { File(call.argument<String>("path")!!).readBytes() }
                        c.sendAttachment(
                            bytes = bytes,
                            filename = call.argument<String>("filename")!!,
                            mimeType = call.argument<String>("mimeType")!!,
                            caption = call.argument<String>("caption"),
                            clientMessageId = call.argument<String>("clientMessageId") ?: UUID.randomUUID().toString(),
                        ).toMap()
                    }
                    "mediaUrl" -> c.mediaUrl(call.argument<String>("messageId")!!)
                    "registerPushToken" -> { c.registerPushToken(call.argument<String>("token")!!); null }
                    "unregisterPushToken" -> { c.unregisterPushToken(call.argument<String>("token")!!); null }
                    else -> return@launch result.notImplemented()
                }
                result.success(value)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                result.error(e.errorCode(), e.message, e.errorDetails())
            }
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        val c = client ?: return sink.error("NO_USER", "Call setUser first", null)
        val initialLimit = (arguments as? Map<*, *>)?.get("initialLimit") as? Int ?: 50
        timelineJob?.cancel()
        timelineJob = scope.launch {
            c.timeline(initialLimit, onError = { e ->
                // onError can fire off the main thread; EventSink must be used on it.
                scope.launch { sink.error(e.errorCode(), e.message, e.errorDetails()) }
            }).collect { messages -> sink.success(messages.map { it.toMap() }) }
        }
    }

    override fun onCancel(arguments: Any?) {
        timelineJob?.cancel()
        timelineJob = null
    }

    /** Asks Dart for a token; the app mints it through its own backend. */
    private suspend fun requestToken(forceRefresh: Boolean): String = withContext(Dispatchers.Main) {
        suspendCancellableCoroutine { cont ->
            channel.invokeMethod("token", mapOf("forceRefresh" to forceRefresh), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (!cont.isActive) return
                    if (result is String && result.isNotEmpty()) cont.resume(result)
                    else cont.resumeWithException(IllegalStateException("Token provider returned no token"))
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    if (cont.isActive) cont.resumeWithException(IllegalStateException("$errorCode: $errorMessage"))
                }

                override fun notImplemented() {
                    if (cont.isActive) cont.resumeWithException(IllegalStateException("No token provider in Dart"))
                }
            })
        }
    }
}

private fun Throwable.errorCode(): String = when (this) {
    is HaloChatException.Unauthorized -> "UNAUTHORIZED"
    is HaloChatException.RateLimited -> "RATE_LIMITED"
    is HaloChatException.SendInProgress -> "SEND_IN_PROGRESS"
    is HaloChatException.Rejected -> "REJECTED"
    is HaloChatException.Server -> "SERVER"
    is HaloChatException.InvalidResponse -> "INVALID_RESPONSE"
    else -> "UNKNOWN"
}

private fun Throwable.errorDetails(): Map<String, Any?>? = when (this) {
    is HaloChatException.RateLimited -> mapOf("retryAfterSeconds" to retryAfterSeconds)
    is HaloChatException.Rejected -> mapOf("status" to status, "code" to code)
    is HaloChatException.Server -> mapOf("status" to status)
    else -> null
}

private fun HaloChatMessage.toMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "text" to text,
    "sender" to sender.name.lowercase(),
    "senderKind" to senderKind.name.lowercase(),
    "hasMedia" to hasMedia,
    "mediaType" to mediaType,
    "mediaFilename" to mediaFilename,
    "createdAt" to createdAt,
    "status" to status?.name?.lowercase(),
    "extras" to extras?.toAny(),
)

private fun HaloChatMessagePage.toMap(): Map<String, Any?> = mapOf(
    "messages" to messages.map { it.toMap() },
    "newestCursor" to newestCursor,
    "oldestCursor" to oldestCursor,
)

private fun HaloChatConversation.toMap(): Map<String, Any?> = mapOf("roomId" to roomId, "title" to title)

private fun Map<String, Any?>.toJson(): JsonObject = JsonObject(mapValues { it.value.toJsonElement() })

private fun Any?.toJsonElement(): JsonElement = when (this) {
    null -> JsonNull
    is Map<*, *> -> JsonObject(entries.associate { it.key.toString() to it.value.toJsonElement() })
    is List<*> -> JsonArray(map { it.toJsonElement() })
    is Boolean -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    else -> JsonPrimitive(toString())
}

private fun JsonElement.toAny(): Any? = when (this) {
    is JsonNull -> null
    is JsonObject -> mapValues { it.value.toAny() }
    is JsonArray -> map { it.toAny() }
    is JsonPrimitive -> if (isString) content else booleanOrNull ?: longOrNull ?: doubleOrNull ?: content
}
