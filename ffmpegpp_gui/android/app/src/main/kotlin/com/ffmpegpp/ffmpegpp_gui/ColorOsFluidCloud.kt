package com.ffmpegpp.ffmpegpp_gui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle

/** OPPO ColorOS Fluid Cloud integration with notification fallbacks. */
object ColorOsFluidCloud {
    private const val TAG = "ColorOsFluidCloud"
    private const val CHANNEL_ID = "ffmpegpp_task_done"
    private const val CHANNEL_NAME = "任务完成"
    private const val PROVIDER_AUTHORITY = "IntelligentIntent"
    private const val PROVIDER_METHOD = "shareIntent"
    private const val EXTRA_INTENT_DATA = "intentData"
    private const val RESULT_KEY = "result"

    @Volatile private var progressCardCreated = false
    @Volatile private var lastErrorCode: String? = null
    @Volatile private var lastErrorMessage: String? = null
    @Volatile private var progressDelivery: String = "none"

    /** OPlus ROM detection is a vendor-property check, not an Android/ColorOS version gate. */
    fun colorOsVersion(): String = try {
        val clazz = Class.forName("android.os.SystemProperties")
        val method = clazz.getDeclaredMethod("get", String::class.java, String::class.java)
        arrayOf("ro.build.version.oplorom", "ro.build.version.opporom")
            .asSequence()
            .map { key -> method.invoke(null, key, "") as? String ?: "" }
            .firstOrNull { it.isNotEmpty() } ?: ""
    } catch (_: Exception) {
        ""
    }

    fun isColorOs(): Boolean = colorOsVersion().isNotEmpty()

    /** Provider visibility/reachability is only a support precheck, not a permission grant. */
    fun intentShareAvailable(context: Context): Boolean = try {
        val client = context.contentResolver
            .acquireUnstableContentProviderClient(PROVIDER_AUTHORITY)
        val available = client != null
        client?.close()
        available
    } catch (_: Exception) {
        false
    }

    private fun integrationConfig(): ColorOsIntegrationConfig? =
        ColorOsIntegrationConfig.resolve(
            debugBuild = BuildConfig.DEBUG,
            intentName = BuildConfig.OPPO_FLUID_CLOUD_INTENT_NAME,
            launcherServiceId = BuildConfig.OPPO_FLUID_CLOUD_LAUNCHER_SERVICE_ID,
            fluidCloudServiceId = BuildConfig.OPPO_FLUID_CLOUD_SERVICE_ID,
        )

    /** Stable bridge fields plus diagnostics for the Dart settings UI. */
    fun status(context: Context): Map<String, Any?> = mapOf(
        "colorOs" to isColorOs(),
        "colorOsVersion" to colorOsVersion(),
        "intentShareAvailable" to intentShareAvailable(context),
        "integrationConfigured" to ColorOsIntegrationConfig.isProductionConfigured(
            BuildConfig.DEBUG,
            BuildConfig.OPPO_FLUID_CLOUD_INTENT_NAME,
            BuildConfig.OPPO_FLUID_CLOUD_LAUNCHER_SERVICE_ID,
            BuildConfig.OPPO_FLUID_CLOUD_SERVICE_ID,
        ),
        "lastErrorCode" to lastErrorCode,
        "lastErrorMessage" to lastErrorMessage,
        "progressDelivery" to progressDelivery,
    )

    /** Complete task: use Fluid Cloud only with a configured OPlus provider; otherwise plain notification. */
    fun postTaskDone(context: Context, title: String, body: String, success: Boolean): Boolean {
        if (!HyperOsIsland.canPost(context)) return false
        val config = integrationConfig()
        val supported = isColorOs() && intentShareAvailable(context)
        if (config != null && supported &&
            shareIntent(context, ColorOsIntentPayload.buildDoneIntent(config, title, body, success))
        ) {
            return true
        }
        if (config == null) {
            recordFailure("integration_unconfigured", "OPPO production integration values are not configured")
        } else if (!supported) {
            recordFailure("provider_unavailable", "OPlus property or IntelligentIntent provider is unavailable")
        }
        return postPlainNotification(context, title, body)
    }

    /** Test notification route: a provider success is reported only after code == 0. */
    fun postTestNotification(context: Context): String {
        if (!HyperOsIsland.canPost(context)) return "no_permission"
        val config = integrationConfig()
        val supported = isColorOs() && intentShareAvailable(context)
        val sentToCloud = config != null && supported && shareIntent(
            context,
            ColorOsIntentPayload.buildDoneIntent(config, "FFmpeg++", "测试通知 · 流体云", true),
        )
        if (sentToCloud) return "fluidcloud"
        if (config == null) {
            recordFailure("integration_unconfigured", "OPPO production integration values are not configured")
        } else if (!supported) {
            recordFailure("provider_unavailable", "OPlus property or IntelligentIntent provider is unavailable")
        }
        return if (postPlainNotification(context, "FFmpeg++", "测试通知 · 系统通知")) {
            "notification"
        } else {
            "unsupported"
        }
    }

    /** Progress returns true if either Fluid Cloud or the existing ordinary notification was posted. */
    fun postProgress(context: Context, filename: String, progress: Int): Boolean {
        if (!HyperOsIsland.canPost(context)) {
            progressDelivery = "unavailable"
            return false
        }

        val config = integrationConfig()
        val supported = isColorOs() && intentShareAvailable(context)
        val shared = if (config != null && supported) {
            val action = if (progressCardCreated) 1 else 0
            shareIntent(
                context,
                ColorOsIntentPayload.buildProgressIntent(config, filename, progress, action),
            )
        } else {
            if (config == null) {
                recordFailure("integration_unconfigured", "OPPO production integration values are not configured")
            } else {
                recordFailure("provider_unavailable", "OPlus property or IntelligentIntent provider is unavailable")
            }
            false
        }

        if (shared) {
            progressCardCreated = true
            progressDelivery = "fluidcloud"
            return true
        }

        val notified = HyperOsIsland.postProgress(context, filename, progress)
        progressDelivery = if (notified) "notification" else "unavailable"
        return notified
    }

    /** End both delivery paths; cancellation is harmless when no notification/card exists. */
    fun endProgress(context: Context): Boolean {
        val notificationEnded = HyperOsIsland.endProgress(context)
        val hadFluidCard = progressCardCreated
        val fluidCardEnded = if (hadFluidCard) {
            val config = integrationConfig()
            if (config == null) {
                recordFailure("integration_unconfigured", "OPPO integration config disappeared before card end")
                false
            } else {
                shareIntent(context, ColorOsIntentPayload.buildProgressEndIntent(config))
            }
        } else {
            true
        }
        progressCardCreated = false
        return notificationEnded && fluidCardEnded
    }

    /** Execute the provider contract, retaining its result code/message for status(). */
    private fun shareIntent(context: Context, intentData: String): Boolean {
        val client = try {
            context.contentResolver.acquireUnstableContentProviderClient(PROVIDER_AUTHORITY)
        } catch (e: Exception) {
            recordFailure("provider_exception", e.message ?: "Could not acquire IntelligentIntent provider")
            return false
        } ?: run {
            recordFailure("provider_unavailable", "IntelligentIntent provider is unavailable")
            return false
        }

        try {
            val resultBundle = client.call(
                PROVIDER_METHOD,
                null,
                Bundle().apply { putString(EXTRA_INTENT_DATA, intentData) },
            ) ?: run {
                recordFailure("missing_result", "Provider returned no result bundle")
                return false
            }
            val parsed = ColorOsIntentPayload.parseShareResult(resultBundle.getString(RESULT_KEY))
            if (parsed.success) {
                lastErrorCode = null
                lastErrorMessage = null
                return true
            }
            recordFailure(parsed.code ?: "provider_error", parsed.message ?: "Provider rejected the intent")
            android.util.Log.w(TAG, "shareIntent rejected: " + parsed.code + " " + parsed.message)
            return false
        } catch (e: Exception) {
            android.util.Log.w(TAG, "shareIntent failed: " + e.message)
            recordFailure("provider_exception", e.message ?: "IntelligentIntent provider call failed")
            return false
        } finally {
            try {
                client.close()
            } catch (_: Exception) {}
        }
    }

    private fun recordFailure(code: String, message: String): Boolean {
        lastErrorCode = code.take(80)
        lastErrorMessage = message.take(256)
        return false
    }

    private fun postPlainNotification(context: Context, title: String, body: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !HyperOsIsland.canPost(context)) return false
        return try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH),
                )
            }
            val notification = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(smallIcon(context))
                .setAutoCancel(true)
                .setContentIntent(contentIntent(context))
                .build()
            nm.notify(CHANNEL_ID, 0, notification)
            true
        } catch (e: Exception) {
            android.util.Log.w(TAG, "postPlainNotification failed: " + e.message)
            false
        }
    }

    private fun smallIcon(context: Context): Int {
        val id = context.resources.getIdentifier("ic_notification", "drawable", context.packageName)
        return if (id != 0) id else android.R.drawable.ic_dialog_info
    }

    private fun contentIntent(context: Context): PendingIntent? = try {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    } catch (_: Exception) {
        null
    }
}
