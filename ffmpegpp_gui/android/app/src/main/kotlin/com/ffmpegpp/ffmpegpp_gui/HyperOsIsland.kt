package com.ffmpegpp.ffmpegpp_gui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.provider.Settings

/**
 * 小米澎湃 OS「小米超级岛」接入 + 应用通知基建。
 *
 * 文档：<https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2131>
 *
 * 岛通知**不是独立 SDK**：就是一条普通系统通知，额外在
 * `notification.extras` 里塞一个 key 为 `miui.focus.param` 的 JSON。
 * 支持岛的设备（HyperOS 3，`persist.sys.feature.island == true`）会按岛样式
 * 展示；不支持的设备自动退化成普通通知，所以这里对失败一律不抛异常。
 *
 * 能力判定三件套（文档「五、查询接口」）：
 *  1. `persist.sys.feature.island`            —— 是否支持岛（反射 SystemProperties）
 *  2. `Settings.System.notification_focus_protocol` —— 焦点通知协议版本
 *     1=OS1 / 2=OS2 / 3=OS3（只有 OS3 有岛）
 *  3. `content://miui.statusbar.notification.public` —— 应用是否被允许发焦点通知
 *
 * ## 2026-11-20 重写要点（「完全没有通知 / 岛上什么都没有」的根因）
 *
 * 1. **通道改为启动时预注册**（[ensureChannels]）：之前只在第一次发通知时才
 *    `createNotificationChannel`。这种「运行中新建的通道」在部分 ROM 上会被静默
 *    降级，用户在系统「通知」页也看不到分类、无法单独开启。
 * 2. **发送前预检权限**（[canPost]）：Android 13+ 的 POST_NOTIFICATIONS 被拒时
 *    `notify()` 不抛异常也不显示，旧实现直接 notify 后返回 true，UI 以为发成功。
 * 3. **岛 JSON 结构改正**：旧实现的 `bigIslandArea` / `smallIslandArea` 里直接平铺
 *    `pic` / `title` / `content`，而模板要求的是**分区对象**
 *    （`imageTextInfoLeft.picInfo` + `textInfo`；注意不是 `miui.focus.paramtextInfo`）。
 *    字段不匹配时系统的行为是**整条丢弃**而不是降级 —— 这是「开了岛也什么都不显示」
 *    的直接原因。另外补上必填的 `business`，以及更新类通知需要的 `updatable`。
 * 4. **图标走 miui.focus.pics**：`pic` 里写的 key 必须在 `miui.focus.pics` 里注册过，
 *    否则图标区域空白；这里注册应用自己的通知图标。
 */
object HyperOsIsland {


    /** 任务完成通知：高重要性，允许横幅/响铃。 */
    private const val DONE_CHANNEL_ID = "ffmpegpp_task_done"
    private const val DONE_CHANNEL_NAME = "任务完成"
    private const val DONE_NOTIFY_ID = 0

    /** 转码进度：低重要性 + onlyAlertOnce，秒级刷新不得反复出声。 */
    private const val PROGRESS_CHANNEL_ID = "ffmpegpp_island_progress"
    private const val PROGRESS_CHANNEL_NAME = "转码进度"
    private const val PROGRESS_NOTIFY_ID = 1

    /** 自定义图标的注册 key（必须与 `miui.focus.pics` Bundle 里的 key 一致）。 */
    private const val PIC_KEY = "miui.focus.pic_ffmpegpp"

    // ────────────────────────────── 能力查询 ──────────────────────────────

    /** 是否支持岛：反射读 `persist.sys.feature.island`（隐藏 API，必须反射）。 */
    fun isIslandSupported(): Boolean = try {
        val clazz = Class.forName("android.os.SystemProperties")
        val method = clazz.getDeclaredMethod(
            "getBoolean", String::class.java, Boolean::class.javaPrimitiveType
        )
        method.invoke(null, "persist.sys.feature.island", false) as? Boolean ?: false
    } catch (e: Exception) {
        false
    }

    /**
     * 焦点通知协议版本：0=不支持，1=OS1，2=OS2，3=OS3（岛）。
     * OS2 与 OS3 的模板不互通 —— 只有 3 才走岛。
     */
    fun focusProtocolVersion(context: Context): Int = try {
        Settings.System.getInt(
            context.contentResolver, "notification_focus_protocol", 0
        )
    } catch (e: Exception) {
        0
    }

    /** 应用是否开启了焦点通知权限（关闭时岛会退化成普通通知）。 */
    fun hasFocusPermission(context: Context): Boolean = try {
        val uri = android.net.Uri.parse("content://miui.statusbar.notification.public")
        val extras = Bundle().apply {
            putString("package", context.packageName)
        }
        val bundle = context.contentResolver.call(uri, "canShowFocus", null, extras)
        bundle?.getBoolean("canShowFocus", false) ?: false
    } catch (e: Exception) {
        false
    }

    /** 三件套是否齐备（支持岛 + 协议 ≥3 + 焦点通知权限）。 */
    fun isIslandAvailable(context: Context): Boolean =
        isIslandSupported() &&
            focusProtocolVersion(context) >= 3 &&
            hasFocusPermission(context)

    /**
     * 综合状态，供 Dart 侧解释「为什么没有通知 / 为什么不上岛」：
     *  * `islandSupported` / `focusProtocolVersion` / `hasFocusPermission` / `islandAvailable`
     *  * `postNotificationsGranted` —— Android 13+ 的运行时通知权限
     *  * `notificationsEnabled`    —— 系统通知总开关
     *  * `channelDoneExists` / `channelProgressExists` —— 通道是否已注册
     */
    fun status(context: Context): Map<String, Any?> = mapOf(
        "islandSupported" to isIslandSupported(),
        "focusProtocolVersion" to focusProtocolVersion(context),
        "hasFocusPermission" to hasFocusPermission(context),
        "islandAvailable" to isIslandAvailable(context),
        "postNotificationsGranted" to notificationsPermissionGranted(context),
        "notificationsEnabled" to notificationsEnabled(context),
        "channelDoneExists" to channelExists(context, true),
        "channelProgressExists" to channelExists(context, false),
    )

    // ────────────────────────────── 通知基建 ──────────────────────────────

    /**
     * 注册（或补齐）两条通知通道。**Activity 启动时调用一次**。
     *
     * 通道一旦创建，其重要性就由用户接管（再 create 同名 id 改不动重要性），
     * 所以这里只在缺失时创建，已存在则保留用户的设置。
     */
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(DONE_CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        DONE_CHANNEL_ID,
                        DONE_CHANNEL_NAME,
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = "任务完成 / 处理失败提醒"
                        enableVibration(true)
                        setShowBadge(true)
                    }
                )
            }
            if (nm.getNotificationChannel(PROGRESS_CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        PROGRESS_CHANNEL_ID,
                        PROGRESS_CHANNEL_NAME,
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "转码进度（静默、持续更新）"
                        setShowBadge(false)
                    }
                )
            }
        } catch (e: Exception) {
            // 通道注册失败不致命：发送前还会再兜底一次。
        }
    }

    /** 通道是否已注册（供设置页判断系统里能不能单独开关）。 */
    fun channelExists(context: Context, done: Boolean): Boolean = try {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            false
        } else {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            nm.getNotificationChannel(
                if (done) DONE_CHANNEL_ID else PROGRESS_CHANNEL_ID
            ) != null
        }
    } catch (e: Exception) {
        false
    }

    /** Android 13+ 的 POST_NOTIFICATIONS 运行时权限（更低版本恒为 true）。 */
    fun notificationsPermissionGranted(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            true
        } else {
            context.checkSelfPermission(
                android.Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        }
    } catch (e: Exception) {
        false
    }

    /** 系统级通知总开关（用户在系统设置里可能整体关掉）。 */
    fun notificationsEnabled(context: Context): Boolean = try {
        val nm =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.areNotificationsEnabled()
    } catch (e: Exception) {
        false
    }

    /**
     * 现在能否真正送达一条通知。
     *
     * Android 13+ 权限被拒时 `notify()` **不抛异常也不显示**，所以必须在发送前
     * 预检；否则调用方只能看到「返回 true 但什么都没出现」。
     */
    fun canPost(context: Context): Boolean =
        notificationsEnabled(context) && notificationsPermissionGranted(context)

    /** 跳到系统「应用通知」页（用户手动开权限 / 改分类的唯一入口）。 */
    fun openNotificationSettings(context: Context): Boolean = try {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        true
    } catch (e: Exception) {
        false
    }

    /**
     * 通知小图标：纯白单色 `drawable/ic_notification`。
     * 绝不能用 `applicationInfo.icon`（自适应启动图标）—— 多数 ROM（MIUI/澎湃
     * 尤甚）会以 "Bad notification posted: Couldn't create icon" 拒收，通知被
     * **静默丢弃**，是「通知完全不显示」的头号原因。
     */
    private fun smallIcon(context: Context): Int {
        val id = context.resources
            .getIdentifier("ic_notification", "drawable", context.packageName)
        return if (id != 0) id else android.R.drawable.ic_dialog_info
    }

    /**
     * 点击通知打开应用（`setAutoCancel` 也依赖它才能生效）。
     * 没有 contentIntent 时点通知**什么都不发生**（旧实现就是这样）。
     */
    private fun contentIntent(context: Context): PendingIntent? {
        return try {
            val launch =
                context.packageManager.getLaunchIntentForPackage(context.packageName)
                    ?: return null
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } catch (e: Exception) {
            null
        }
    }

    /**
     * `miui.focus.pics`：把应用通知图标注册成 [PIC_KEY]。
     *
     * 岛 JSON 里的 `pic` 只是**键名**，真正的图要在这个 extras Bundle 里给；
     * 键名没注册时图标区域空白（部分模板会因此整条不展示）。
     */
    private fun picsBundle(context: Context): Bundle {
        val extras = Bundle()
        try {
            val pics = Bundle()
            pics.putParcelable(
                PIC_KEY,
                Icon.createWithResource(context, smallIcon(context)),
            )
            extras.putBundle("miui.focus.pics", pics)
        } catch (e: Exception) {
            // 图标注册失败不影响文字内容展示。
        }
        return extras
    }

    /**
     * 测试通知：按当前系统决定走哪条路，返回结果：
     *  * `island`       —— 澎湃 OS，已走小米超级岛
     *  * `notification` —— 其它 ROM，走普通系统通知
     *  * `no_permission` —— 系统通知开关 / 运行时权限未开（通知必然不显示）
     *  * `unsupported`  —— 系统太旧，或通知被系统拒绝
     *
     * 返回值只说明「走了哪条路」，不保证真显示出来：应用若没进通知/自启动
     * 白名单，MIUI 会静默丢弃 —— 调用方据此给出引导文案。
     */
    fun postTestNotification(context: Context): String {
        ensureChannels(context)
        // 权限与总开关分开判断：前者能当场请求，后者只能跳系统设置。
        if (!notificationsPermissionGranted(context)) return "no_permission"
        if (!notificationsEnabled(context)) return "no_permission"
        val island = isIslandAvailable(context)
        val ok = postTaskDone(
            context,
            "FFmpeg++",
            if (island) "测试通知 · 小米超级岛" else "测试通知 · 系统通知",
            true
        )
        return when {
            !ok -> "unsupported"
            island -> "island"
            else -> "notification"
        }
    }

    // ────────────────────────────── 通知发送 ──────────────────────────────

    /**
     * 发送「任务完成」通知；支持岛的设备带上 `miui.focus.param` 自动上岛。
     *
     * 岛参数只在「三件套全过」时附加（含 [hasFocusPermission]）：无焦点权限时
     * 附加 `miui.focus.param` 在 HyperOS 上可能整条被丢 —— 普通通知也跟着消失，
     * 所以宁可不上岛也要保证通知可见。
     *
     * @return true 表示通知已交给系统（不代表一定显示在岛上——权限关闭时退化）。
     */
    fun postTaskDone(
        context: Context,
        title: String,
        body: String,
        success: Boolean
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!canPost(context)) return false
        return try {
            ensureChannels(context)
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val builder = Notification.Builder(context, DONE_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setSmallIcon(smallIcon(context))
                .setAutoCancel(true)
                .setContentIntent(contentIntent(context))
                .addExtras(picsBundle(context))

            if (isIslandAvailable(context)) {
                builder.extras.putString(
                    "miui.focus.param",
                    islandJson(
                        business = "ffmpegpp_task_done",
                        frontTitle = if (success) "已完成" else "处理失败",
                        title = title,
                        content = body,
                        iconKey = PIC_KEY,
                        updatable = false,
                        dismissIsland = true,
                        islandTimeoutSec = 60,
                        timeoutMin = 5,
                        // 完成类通知：首次出现直接展开（一眼看到结果），之后不再抢焦点。
                        firstFloat = true,
                    )
                )
            }

            // id 用固定值：同一时刻只保留最新一条「任务完成」，避免队列刷屏
            // 把岛挤掉（岛一次只显示一条焦点通知）。
            nm.notify(DONE_CHANNEL_ID, DONE_NOTIFY_ID, builder.build())
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 转码进度通知：支持岛的设备带 `miui.focus.param` 上岛（进度卡），
     * 不支持的设备退化为一条不断刷新的普通通知（带系统进度条）。
     *
     * @return true 表示通知已交给系统（不代表一定显示在岛上——权限关闭时退化）。
     */
    fun postProgress(context: Context, filename: String, progress: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!canPost(context)) return false
        return try {
            ensureChannels(context)
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val pct = progress.coerceIn(0, 100)
            val content = "转码进度 $pct%"
            val builder = Notification.Builder(context, PROGRESS_CHANNEL_ID)
                .setContentTitle(filename)
                .setContentText(content)
                .setSmallIcon(smallIcon(context))
                .setOnlyAlertOnce(true)
                // ongoing：进度卡不该被一划就没（旧实现没设，划掉后要等下一次心跳
                // 才重建；进程被冻结时那张卡就永远回不来了）。
                .setOngoing(true)
                .setProgress(100, pct, false)
                .setContentIntent(contentIntent(context))
                .addExtras(picsBundle(context))

            // Android 16 Live Update（实时更新 / 推广通知）：ColorOS 16+、HyperOS 3 等
            // 会把合规的推广 ongoing 通知显示到流体云 / 状态栏胶囊。无需 OPPO 私有
            // IntelligentIntent 配置，作为私有通道未配置时的标准兜底。
            // 要求：ongoing + contentTitle + 非 colorized + 无自定义 RemoteViews +
            // 渠道重要性不能是 MIN + 清单声明 POST_PROMOTED_NOTIFICATIONS。
            if (Build.VERSION.SDK_INT >= 36) {
                builder.extras.putBoolean("android.requestPromotedOngoing", true)
                try {
                    Notification.Builder::class.java
                        .getMethod("setShortCriticalText", String::class.java)
                        .invoke(builder, "$pct%")
                } catch (_: Exception) {}
            }

            if (isIslandAvailable(context)) {
                builder.extras.putString(
                    "miui.focus.param",
                    islandJson(
                        business = "ffmpegpp_island_progress",
                        frontTitle = "转码中",
                        title = "$pct%",
                        content = filename,
                        iconKey = PIC_KEY,
                        // 更新类通知必须 updatable，否则系统按「一次性通知」处理，
                        // 后续同 id 的更新会被丢弃或重新弹一次。
                        updatable = true,
                        dismissIsland = false,
                        islandTimeoutSec = 600,
                        timeoutMin = 30,
                        // ⚠️ 进度卡**不能**首次展开：旧实现设成 true，配合
                        // updatable 的持续更新，岛会一直停在展开态挡住状态栏。
                        firstFloat = false,
                        progress = pct,
                    )
                )
            }

            nm.notify(PROGRESS_CHANNEL_ID, PROGRESS_NOTIFY_ID, builder.build())
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 队列空闲时销掉进度通知（没发过卡时 cancel 也无害）。 */
    fun endProgress(context: Context): Boolean {
        return try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(PROGRESS_CHANNEL_ID, PROGRESS_NOTIFY_ID)
            true
        } catch (e: Exception) {
            false
        }
    }

    // ────────────────────────────── 岛 JSON ──────────────────────────────

    /**
     * miui.focus.param JSON: expanded progress plus big/small island components.
     * Kept Android-independent in [XiaomiIslandPayload] for JVM regression tests.
     */
    private fun islandJson(
        business: String,
        frontTitle: String,
        title: String,
        content: String,
        iconKey: String,
        updatable: Boolean,
        dismissIsland: Boolean,
        islandTimeoutSec: Int,
        timeoutMin: Int,
        firstFloat: Boolean,
        progress: Int? = null,
    ): String = XiaomiIslandPayload.build(
        business, frontTitle, title, content, iconKey, updatable, dismissIsland,
        islandTimeoutSec, timeoutMin, firstFloat, progress,
    )
}
