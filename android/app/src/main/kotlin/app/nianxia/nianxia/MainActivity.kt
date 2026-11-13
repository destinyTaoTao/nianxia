package app.nianxia.nianxia

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.app.KeyguardManager
import android.os.Build
import android.os.PowerManager
import android.os.Bundle
import android.os.StatFs
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import app.nianxia.nianxia.capture.CaptureChannel

class MainActivity : FlutterActivity() {
    private var pendingCalendar: MethodChannel.Result? = null
    private val calendarRequest = 9011
    private var systemChannel: MethodChannel? = null
    private var launchReady = false
    private var pendingLaunch: String? = null
    private var screenReceiverRegistered = false
    private var captureChannel: CaptureChannel? = null
    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) {
                captureChannel?.hidden()
                systemChannel?.invokeMethod("screenOff", null)
            }
        }
    }

    // A single activity/engine owns SQLite and the microphone. Translucency is
    // used only by the small Flutter capsule; regular pages paint an opaque UI.
    override fun getBackgroundMode() = BackgroundMode.transparent
    override fun getInitialRoute() = "/"

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingLaunch = actionFor(intent)
        super.onCreate(savedInstanceState)
        // SCREEN_OFF is a protected system broadcast. Unlike inactive, it
        // remains unambiguous if the screen wakes before onStop is dispatched.
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(screenOffReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(screenOffReceiver, filter)
        }
        screenReceiverRegistered = true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = actionFor(intent) ?: return
        if (launchReady) systemChannel?.invokeMethod("launch", action)
        else pendingLaunch = action
    }

    private fun actionFor(intent: Intent): String? {
        val uri = intent.data
        if (uri != null) {
            // No caller-supplied content, file paths, destinations or operations.
            if (uri.scheme != "nianxia" || !uri.path.isNullOrEmpty() ||
                uri.query != null || uri.fragment != null || uri.userInfo != null || uri.port != -1) return null
            return when (uri.host) { "capture" -> "capsule"; "search" -> "search"; else -> null }
        }
        return when (intent.action) {
            "app.nianxia.CAPTURE" -> "capsule"
            Intent.ACTION_MAIN -> "home"
            else -> null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Prototype remains restricted to the disposable test application.
        if (applicationContext.packageName == "app.nianxia.nianxia.test") {
            captureChannel = CaptureChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        systemChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.nianxia/system")
        systemChannel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "validationIdentity" -> result.success(mapOf(
                        "applicationId" to applicationContext.packageName,
                        "cacheRoot" to cacheDir.canonicalPath,
                        "temporaryRoots" to listOf(cacheDir.canonicalPath, codeCacheDir.canonicalPath)
                    ))
                    "recordingScreenAvailable" -> result.success(
                        getSystemService(PowerManager::class.java).isInteractive &&
                            !getSystemService(KeyguardManager::class.java).isKeyguardLocked
                    )
                    "getLaunchAction" -> {
                        launchReady = true
                        result.success(pendingLaunch)
                        pendingLaunch = null
                    }
                    "dismissCapsule" -> { moveTaskToBack(true); result.success(null) }
                    "protectFiles" -> result.success(true) // Private storage; backup disabled in manifest/rules.
                    "availableStorageBytes" -> {
                        try {
                            result.success(StatFs(filesDir.absolutePath).availableBytes)
                        } catch (_: Exception) {
                            result.error("storage_space", "Unable to inspect private storage", null)
                        }
                    }
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
        captureChannel?.detach()
        captureChannel = null
        if (screenReceiverRegistered) {
            unregisterReceiver(screenOffReceiver)
            screenReceiverRegistered = false
        }
        pendingCalendar?.success("unknown")
        pendingCalendar = null
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        captureChannel?.visible()
    }

    override fun onStop() {
        captureChannel?.hidden()
        super.onStop()
    }
}
