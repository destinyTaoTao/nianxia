package app.nianxia.nianxia

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingCalendar: MethodChannel.Result? = null
    private val calendarRequest = 9011

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.nianxia/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "protectFiles" -> result.success(true) // Private storage; backup disabled in manifest/rules.
                    "calendar" -> {
                        if (pendingCalendar != null) {
                            result.success("unknown")
                            return@setMethodCallHandler
                        }
                        val title = call.argument<String>("title")
                        val start = call.argument<Number>("start")?.toLong()
                        val end = call.argument<Number>("end")?.toLong()
                        if (title.isNullOrBlank() || title.length > 200 || start == null || end == null || end <= start) {
                            result.error("invalid_event", "Invalid event fields", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(Intent.ACTION_INSERT).apply {
                            data = CalendarContract.Events.CONTENT_URI
                            putExtra(CalendarContract.Events.TITLE, title)
                            putExtra(CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location") ?: "")
                            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, start)
                            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
                            // ACTION_INSERT has no standard reminder-minutes extra. The UI
                            // explicitly asks the user to verify it in their calendar app.
                        }
                        try {
                            pendingCalendar = result
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, calendarRequest)
                        } catch (_: ActivityNotFoundException) {
                            pendingCalendar = null
                            result.success("unavailable")
                        } catch (_: SecurityException) {
                            pendingCalendar = null
                            result.success("unavailable")
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Calendar intent has no reliable saved/cancelled contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == calendarRequest) {
            // RESULT_OK/RESULT_CANCELED is not proof of insertion on arbitrary OEM calendars.
            pendingCalendar?.success("unknown")
            pendingCalendar = null
        }
    }

    override fun onDestroy() {
        pendingCalendar?.success("unknown")
        pendingCalendar = null
        super.onDestroy()
    }
}
