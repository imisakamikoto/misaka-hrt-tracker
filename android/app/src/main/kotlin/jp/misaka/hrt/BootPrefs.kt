package jp.misaka.hrt

import android.content.Context
import android.content.SharedPreferences

/**
 * The one thing the boot receiver and the Flutter side both need: whether the
 * user asked the app to come back after a restart. Stored in its own
 * preferences file because the Dart side keeps everything else in SQLite.
 */
internal object BootPrefs {
    private const val FILE = "hrt_boot"
    private const val KEY_ENABLED = "boot_autostart"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }
}
