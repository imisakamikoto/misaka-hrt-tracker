package jp.misaka.hrt

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(true)
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    BootPrefs.setEnabled(this, enabled)
                    result.success(true)
                }
                "isEnabled" -> result.success(BootPrefs.isEnabled(this))
                "openAutostartSettings" -> result.success(openAutostartSettings())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Every manufacturer hides the autostart switch somewhere else. Try the
     * layouts that are known in the wild, then fall back to this app's own
     * settings page, which always exists.
     */
    private fun openAutostartSettings(): Boolean {
        val candidates = listOf(
            // Xiaomi / Redmi / POCO
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            // Huawei
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
            // Honor
            "com.hihonor.systemmanager" to "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            // OPPO / OnePlus / realme
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            // vivo / iQOO
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            // Samsung
            "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity",
            "com.samsung.android.sm" to "com.samsung.android.sm.ui.battery.BatteryActivity",
            // Meizu
            "com.meizu.safe" to "com.meizu.safe.permission.SmartBGActivity",
            // Letv
            "com.letv.android.letvsafe" to "com.letv.android.letvsafe.AutobootManageActivity",
            // Asus
            "com.asus.mobilemanager" to "com.asus.mobilemanager.autostart.AutoStartActivity",
        )
        for ((pkg, cls) in candidates) {
            val intent = Intent().apply {
                component = ComponentName(pkg, cls)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (packageManager.resolveActivity(intent, 0) == null) continue
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Try the next candidate.
            }
        }
        return try {
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(fallback)
            true
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        private const val CHANNEL = "jp.misaka.hrt/boot"
    }
}
