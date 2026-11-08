package app.nianxia.nianxia

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

class CaptureTileService : TileService() {
    override fun onClick() {
        super.onClick()
        // Let the system unlock first; never attempt hidden/locked recording.
        if (isLocked) unlockAndRun { launchCapture() } else launchCapture()
    }

    private fun launchCapture() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "app.nianxia.CAPTURE"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 9012, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
