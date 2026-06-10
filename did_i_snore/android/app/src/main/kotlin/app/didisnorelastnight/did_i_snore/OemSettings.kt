package app.didisnorelastnight.did_i_snore

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/**
 * OEM autostart / battery deep-links for the Phase 10.1 onboarding flow.
 *
 * Kept in its own file (and on its own MethodChannel,
 * `app.didisnorelastnight/oem`) so it stays separate from the recorder
 * control channel in [MainActivity].
 *
 * Contract with the Dart side (`lib/ui/setup/oem_channel.dart`):
 *   method  "openOemSettings", arg { "brand": <settingsKey> }
 *   returns the name of the screen we actually opened
 *           ("oem" | "app-details" | "battery-settings"), so the UI can
 *           tell the user whether they landed on the vendor screen or the
 *           generic fallback.
 *
 * Hard rule: **never crash if an intent doesn't resolve.** Each vendor
 * ComponentName is attempted inside try/catch and we always fall back to
 * this app's app-details screen (and, if even that fails, the global
 * battery-optimization settings list). An OEM that has renamed or removed
 * its autostart activity must degrade to "we opened *a* settings screen",
 * not an ActivityNotFoundException that takes down the onboarding screen.
 *
 * The battery-optimization *whitelist request* itself is NOT here — it goes
 * through `permission_handler` on the Dart side
 * (`Permission.ignoreBatteryOptimizations`), which pops the system "allow
 * unrestricted background activity?" dialog. This file only handles the
 * vendor autostart screens, which have no permission_handler equivalent.
 */
object OemSettings {

    /** Channel name — must match `lib/ui/setup/oem_channel.dart`. */
    const val CHANNEL = "app.didisnorelastnight/oem"

    /**
     * Candidate vendor activities per [settingsKey] (the OemStep.settingsKey
     * from oem_steps.dart). Listed most-specific first; we open the first
     * one that resolves. Several vendors ship more than one activity name
     * across ROM versions, hence the lists.
     */
    private val vendorComponents: Map<String, List<ComponentName>> = mapOf(
        // Xiaomi MIUI / HyperOS autostart manager.
        "xiaomi" to listOf(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.permissions.PermissionsEditorActivity",
            ),
        ),
        // Oppo / Realme ColorOS startup manager (security center).
        "oppo" to listOf(
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.startupapp.StartupAppListActivity",
            ),
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            ),
            ComponentName(
                "com.oppo.safe",
                "com.oppo.safe.permission.startup.StartupAppListActivity",
            ),
        ),
        // Vivo iManager background / autostart.
        "vivo" to listOf(
            ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            ),
            ComponentName(
                "com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
            ),
        ),
        // Huawei / Honor EMUI startup manager.
        "huawei" to listOf(
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.optimize.process.ProtectActivity",
            ),
        ),
        // Samsung — One UI has no public never-sleeping-apps activity that
        // resolves reliably across versions; fall through to app-details,
        // which lands on the page that links to battery usage. Listed here
        // (empty) for documentation; the fallback handles it.
        "samsung" to emptyList(),
        // OnePlus OxygenOS — newer builds route through standard app-details
        // + battery; no stable dedicated activity. Fall back.
        "oneplus" to emptyList(),
        // Nothing OS — stock-adjacent; app-details is the right landing.
        "nothing" to emptyList(),
    )

    /**
     * Tries to open the best settings screen for [settingsKey].
     * Returns which screen was opened via [result]. Never throws.
     */
    fun open(context: Context, settingsKey: String?, result: MethodChannel.Result) {
        val key = settingsKey?.lowercase().orEmpty()

        // 1. Try the vendor-specific activity/activities.
        for (component in vendorComponents[key].orEmpty()) {
            if (tryStart(context, Intent().apply { setComponent(component) })) {
                result.success("oem")
                return
            }
        }

        // 2. Fall back to this app's app-details page — always available,
        //    and on every OEM it links onward to battery + permissions.
        val appDetails = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        )
        if (tryStart(context, appDetails)) {
            result.success("app-details")
            return
        }

        // 3. Last resort: the global battery-optimization list.
        if (tryStart(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))) {
            result.success("battery-settings")
            return
        }

        // Even the global settings didn't resolve — extraordinarily unlikely,
        // but report it instead of throwing so the UI can fall back to its
        // on-screen written steps.
        result.success("none")
    }

    /** Adds NEW_TASK (required to start an Activity from a non-Activity
     *  context) and returns true iff the intent resolved and launched. */
    private fun tryStart(context: Context, intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            // Some OEM activities exist but reject external launches.
            false
        } catch (_: Exception) {
            false
        }
    }
}
