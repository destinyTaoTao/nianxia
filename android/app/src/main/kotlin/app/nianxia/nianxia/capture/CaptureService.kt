package app.nianxia.nianxia.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.app.KeyguardManager
import app.nianxia.nianxia.MainActivity
import app.nianxia.nianxia.R
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

object CaptureOwners {
    private var instance: NativeCaptureSession? = null
    val commands = Executors.newSingleThreadExecutor()
    val listeners = CopyOnWriteArrayList<(CaptureSnapshot) -> Unit>()
    @Volatile var visible = false
    private val main = Handler(Looper.getMainLooper())

    @Synchronized fun get(context: Context): NativeCaptureSession {
        return instance ?: NativeCaptureSession(
            File(context.applicationContext.filesDir.canonicalFile, "nianxia/native-captures"),
            { AndroidPcmInput(context.applicationContext) }, { SystemClock.elapsedRealtime() }
        ) { snapshot -> main.post {
            listeners.forEach { it(snapshot) }
            CaptureService.activeService?.render(snapshot)
        } }.also { instance = it }
    }
}

class CaptureService : Service() {
    private var lastNotificationSecond = -1L
    private var lastPhase: CapturePhase? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        activeService = this
        val owner = CaptureOwners.get(this)
        if (intent?.action == START) {
            val token = intent.getStringExtra("token")
            val request = token?.let { requests.remove(it) }
            if (request == null) {
                if (owner.current()?.active != true) stopSelf()
                return START_NOT_STICKY
            }
            try {
                if (!CaptureOwners.visible || !getSystemService(PowerManager::class.java).isInteractive ||
                    getSystemService(KeyguardManager::class.java).isKeyguardLocked) throw CaptureFailure("capture_not_visible")
                val notification = notification(request.first.sessionId, 0)
                if (Build.VERSION.SDK_INT >= 30) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                else startForeground(NOTIFICATION, notification)
                CaptureOwners.commands.execute {
                    try {
                        if (!CaptureOwners.visible || !getSystemService(PowerManager::class.java).isInteractive ||
                            getSystemService(KeyguardManager::class.java).isKeyguardLocked) throw CaptureFailure("capture_not_visible")
                        request.second.complete(owner.start(request.first))
                    }
                    catch (error: Exception) {
                        request.second.completeExceptionally(error)
                        Handler(Looper.getMainLooper()).post { if (owner.current()?.active != true) stopSelf() }
                    }
                }
            } catch (error: Exception) {
                request.second.completeExceptionally(error)
                if (owner.current()?.active != true) stopSelf()
            }
        } else if (intent?.action == STOP) {
            val id = intent.getStringExtra("sessionId")
            if (id != null && owner.current()?.request?.sessionId == id) {
                CaptureOwners.commands.execute { runCatching { owner.stop(id) } }
            }
        } else if (owner.current()?.active != true) stopSelf()
        return START_NOT_STICKY // A system restart must never reopen the microphone.
    }

    fun render(snapshot: CaptureSnapshot) {
        val latest = CaptureOwners.get(this).current()
        if (latest?.request?.sessionId != snapshot.request.sessionId || latest.sequence != snapshot.sequence) return
        if (!snapshot.active) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        val second = snapshot.elapsedMs / 1000
        if (second != lastNotificationSecond || snapshot.phase != lastPhase) {
            lastNotificationSecond = second
            lastPhase = snapshot.phase
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION,
                notification(snapshot.request.sessionId, snapshot.elapsedMs))
        }
    }

    private fun notification(id: String, elapsed: Long): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "录音状态", NotificationManager.IMPORTANCE_LOW))
        }
        val stop = Intent(this, CaptureService::class.java).setAction(STOP)
            .setData(Uri.parse("nianxia-internal-capture://stop/$id")).putExtra("sessionId", id)
        val pending = PendingIntent.getService(this, 1, stop, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val reopen = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder.setSmallIcon(R.drawable.shortcut_capture)
            .setContentTitle("正在录音")
            .setContentText("已录制 ${elapsed / 1000} 秒，最长 2 分钟")
            .setContentIntent(reopen).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "停止并保存", pending).build()).build()
    }

    override fun onDestroy() {
        if (activeService === this) activeService = null
        val owner = CaptureOwners.get(this)
        owner.current()?.takeIf { it.active }?.request?.sessionId?.let { id ->
            CaptureOwners.commands.execute { runCatching { owner.stop(id) } }
        }
        super.onDestroy()
    }

    companion object {
        private const val START = "app.nianxia.internal.START_CAPTURE"
        private const val STOP = "app.nianxia.internal.STOP_CAPTURE"
        private const val CHANNEL = "nianxia-recording"
        private const val NOTIFICATION = 731
        internal var activeService: CaptureService? = null
        private val requests = ConcurrentHashMap<String, Pair<CaptureRequest, CompletableFuture<CaptureSnapshot>>>()

        fun requestStart(context: Context, request: CaptureRequest): CompletableFuture<CaptureSnapshot> {
            val token = UUID.randomUUID().toString()
            val result = CompletableFuture<CaptureSnapshot>()
            requests[token] = request to result
            try {
                val intent = Intent(context, CaptureService::class.java).setAction(START).putExtra("token", token)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (error: Exception) { requests.remove(token); result.completeExceptionally(error) }
            Handler(Looper.getMainLooper()).postDelayed({
                requests.remove(token)?.second?.completeExceptionally(CaptureFailure("capture_start_timeout"))
            }, 10000)
            return result
        }
    }
}
