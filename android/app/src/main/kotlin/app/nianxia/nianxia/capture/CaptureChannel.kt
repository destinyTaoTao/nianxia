package app.nianxia.nianxia.capture

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Engine-scoped transport only. Detaching never disposes the process owner. */
class CaptureChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "app.nianxia/capture")
    private val events = EventChannel(messenger, "app.nianxia/capture_events")
    private var sink: EventChannel.EventSink? = null
    private val listener: (CaptureSnapshot) -> Unit = { sink?.success(it.wire()) }

    init {
        CaptureOwners.listeners.add(listener)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        methods.setMethodCallHandler { call, reply ->
            if (call.method == "setValidationWorkspace" || call.method == "endValidationWorkspace") {
                CaptureOwners.commands.execute {
                    try {
                        val args = call.arguments as? Map<*, *> ?: throw CaptureFailure("capture_validation")
                        CaptureOwners.validationWorkspace(activity, args["runId"] as? String
                            ?: throw CaptureFailure("capture_validation"), call.method == "endValidationWorkspace")
                        main.post { reply.success(null) }
                    } catch (error: Exception) { main.post { fail(reply, error) } }
                }
                return@setMethodCallHandler
            }
            val owner = CaptureOwners.get(activity)
            if (call.method == "start") {
                try {
                    if (!CaptureOwners.visible || !activity.hasWindowFocus()) throw CaptureFailure("capture_not_visible")
                    val request = CaptureRequest.fromWire(call.arguments as Map<*, *>)
                    CaptureService.requestStart(activity, request).whenComplete { snapshot, failure ->
                        main.post {
                            if (failure == null) reply.success(snapshot.wire()) else fail(reply, failure)
                        }
                    }
                } catch (error: Exception) { fail(reply, error) }
            } else CaptureOwners.commands.execute {
                try {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    val value: Any? = when (call.method) {
                        "current" -> owner.current()?.wire()
                        "pending" -> owner.pending(args["after"] as String?, (args["limit"] as? Int) ?: 32).map { it.wire() }
                        "stop" -> owner.stop(args["sessionId"] as String).wire()
                        "cancel" -> { owner.cancel(args["sessionId"] as String); null }
                        "claim" -> owner.claim(args["sessionId"] as String).wire()
                        "acknowledge" -> {
                            owner.acknowledge(args["sessionId"] as String,
                                CaptureDisposition.valueOf(args["disposition"] as String)); null
                        }
                        else -> throw CaptureFailure("capture_method")
                    }
                    main.post { reply.success(value) }
                } catch (error: Exception) { main.post { fail(reply, error) } }
            }
        }
    }

    private fun fail(reply: MethodChannel.Result, error: Throwable) {
        val safe = (error as? CaptureFailure)?.code ?: (error.cause as? CaptureFailure)?.code ?: "capture_operation"
        reply.error(safe, "录音会话操作未完成。", null)
    }

    fun visible() { CaptureOwners.visible = true }

    fun hidden() {
        CaptureOwners.visible = false
        val owner = CaptureOwners.get(activity)
        val current = owner.current()
        if (current?.request?.mode == CaptureMode.query && current.active) {
            CaptureOwners.commands.execute { runCatching { owner.stop(current.request.sessionId) } }
        }
    }

    fun detach() {
        sink = null
        CaptureOwners.listeners.remove(listener)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
