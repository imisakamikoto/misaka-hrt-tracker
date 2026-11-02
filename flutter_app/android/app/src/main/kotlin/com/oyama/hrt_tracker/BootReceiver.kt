package com.oyama.hrt_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Opens the app once after the device finishes booting, so the model can
 * rebuild its reminder schedule with the current data.
 *
 * Scheduled notifications themselves are restored by flutter_local_notifications'
 * own boot receiver, which works whether or not this one is allowed to start an
 * activity. Android 10 and later block background activity starts from
 * receivers on many devices, so a failure here is expected and harmless.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_LOCKED_BOOT_COMPLETED) {
            return
        }
        if (!BootPrefs.isEnabled(context)) return
        try {
            val launch = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(EXTRA_FROM_BOOT, true)
            }
            context.startActivity(launch)
        } catch (e: Exception) {
            Log.i(TAG, "The system did not allow starting the app at boot: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "HrtBootReceiver"
        const val EXTRA_FROM_BOOT = "hrt.startedFromBoot"
    }
}
