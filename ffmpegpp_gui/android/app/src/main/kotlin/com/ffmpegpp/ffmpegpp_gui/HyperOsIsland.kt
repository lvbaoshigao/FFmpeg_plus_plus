package com.ffmpegpp.ffmpegpp_gui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

/**
 * 小米澎湃 OS「小米超级岛」接入。
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
 * 之所以判定要做在 Kotlin 侧：前两条依赖隐藏 API（SystemProperties 反射）与
 * MIUI 私有 Settings 键，Dart 层拿不到；而且 JSON 组装紧贴通知构建，留在原生
 * 侧可以少一次跨语言往返。
 */
object HyperOsIsland {

    private const val TAG = "HyperOsIsland"
    private const val CHANNEL_ID = "ffmpegpp_task_done"
    private const val CHANNEL_NAME = "任务完成"

    /** 本应用在超级岛上的强调色（朱砂，与主题点缀色一致）。 */
    private const val HIGHLIGHT = "#FF6B4A"

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
        val extras = android.os.Bundle().apply {
            putString("package", context.packageName)
        }
        val bundle = context.contentResolver.call(uri, "canShowFocus", null, extras)
        bundle?.getBoolean("canShowFocus", false) ?: false
    } catch (e: Exception) {
        false
    }

    /** 三件套汇总，供 Dart 侧做「是否已接入超级岛」的状态展示。 */
    fun status(context: Context): Map<String, Any?> = mapOf(
        "islandSupported" to isIslandSupported(),
        "focusProtocolVersion" to focusProtocolVersion(context),
        "hasFocusPermission" to hasFocusPermission(context),
    )

    /**
     * 测试通知：按当前系统决定走哪条路，返回结果：
     *  * `island`       —— 澎湃 OS，已走小米超级岛
     *  * `notification` —— 其它 ROM，走普通系统通知
     *  * `unsupported`  —— 系统太旧，或通知被系统拒绝
     *
     * 返回值只说明「走了哪条路」，不保证真显示出来：应用若没进通知/自启动
     * 白名单，MIUI 会静默丢弃 —— 调用方据此给出引导文案。
     */
    fun postTestNotification(context: Context): String {
        val island = isIslandSupported() &&
            focusProtocolVersion(context) >= 3 &&
            hasFocusPermission(context)
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
     * @return true 表示通知已交给系统（不代表一定显示在岛上——权限关闭时退化）。
     */
    fun postTaskDone(
        context: Context,
        title: String,
        body: String,
        success: Boolean
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // 复用同一条通道：岛通知走的就是普通通知流程。
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT
                )
            )

            val builder = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(context.applicationInfo.icon)
                .setAutoCancel(true)

            // 只有「真的有岛」才加扩展参数：不支持的设备加了也是白加，
            // 但 JSON 组装成本极低，这里不做强分支，保留一份实现即可。
            if (isIslandSupported() && focusProtocolVersion(context) >= 3) {
                builder.extras.putString(
                    "miui.focus.param",
                    buildIslandParam(title, body, success)
                )
            }

            // id 用固定值：同一时刻只保留最新一条「任务完成」，避免队列刷屏
            // 把岛挤掉（岛一次只显示一条焦点通知）。
            nm.notify(CHANNEL_ID, 0, builder.build())
            true
        } catch (e: Exception) {
            false
        }
    }

    // ────────────────────────────── 进度通知 ──────────────────────────────

    /** 进度通知通道与固定 id：同一时刻只保留最新一张进度卡。 */
    private const val PROGRESS_CHANNEL_ID = "ffmpegpp_island_progress"
    private const val PROGRESS_CHANNEL_NAME = "转码进度"
    private const val PROGRESS_NOTIFY_ID = 1

    /**
     * 转码进度通知：支持岛的设备带 `miui.focus.param` 上岛（进度卡），
     * 不支持的设备退化为一条不断刷新的普通通知。
     *
     * @return true 表示通知已交给系统（不代表一定显示在岛上——权限关闭时退化）。
     */
    fun postProgress(context: Context, filename: String, progress: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // 低重要性 + onlyAlertOnce：秒级刷新的进度通知不得反复出声/横幅。
            nm.createNotificationChannel(
                NotificationChannel(
                    PROGRESS_CHANNEL_ID, PROGRESS_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                )
            )

            val pct = progress.coerceIn(0, 100)
            val builder = Notification.Builder(context, PROGRESS_CHANNEL_ID)
                .setContentTitle(filename)
                .setContentText("转码进度 $pct%")
                .setSmallIcon(context.applicationInfo.icon)
                .setOnlyAlertOnce(true)

            if (isIslandSupported() && focusProtocolVersion(context) >= 3) {
                builder.extras.putString(
                    "miui.focus.param",
                    buildIslandProgressParam(filename, pct)
                )
            }

            nm.notify(PROGRESS_CHANNEL_ID, PROGRESS_NOTIFY_ID, builder.build())
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 队列空闲时销掉进度通知（没发过卡时 cancel 也无害）。
     * 进度通知不设 ongoing：中途被用户划掉后，下一次进度心跳会自动重建。
     */
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

    /**
     * 组装进度卡的 `miui.focus.param` JSON（结构同 [buildIslandParam]，
     * 差异：business 区分、进度卡不自动收走、后续更新不抢焦点）。
     *
     * ⚠️ 进度专用模板字段以《小米超级岛模板库》另册为准，这里先用通用
     * 「文本 + 图标」结构占位（内容即百分比），换模板只替换 area 字段。
     */
    private fun buildIslandProgressParam(filename: String, progress: Int): String {
        val content = "转码进度 $progress%"

        val small = JSONObject()
            .put("pic", "miui.focus.pic_ok")
            .put("title", filename)
            .put("content", content)

        val big = JSONObject()
            .put("pic", "miui.focus.pic_ok")
            .put("title", filename)
            .put("content", content)

        val island = JSONObject()
            .put("islandProperty", 1) // 1=信息展示为主
            .put("islandTimeout", 60) // 60s 无更新回落（进度心跳会持续续期）
            .put("dismissIsland", false) // 进度卡不自动收走，等 endProgress 销卡
            .put("highlightColor", HIGHLIGHT)
            .put("bigIslandArea", big)
            .put("smallIslandArea", small)

        val v2 = JSONObject()
            .put("business", "ffmpegpp_island_progress")
            .put("islandFirstFloat", true) // 首次直接展开态
            .put("enableFloat", false) // 更新时不再抢焦点
            .put("timeout", 5) // 5 分钟无更新时普通通知自动消失（兜底）
            .put("param_island", island)
            .put("aodTitle", filename)
            .put("ticker", content)

        return JSONObject().put("param_v2", v2).toString()
    }

    /**
     * 组装 `miui.focus.param` JSON。
     *
     * ⚠️ 具体模板字段以《小米超级岛模板库》为准（文档第三章另册）。
     * 这里用的是通用「文本 + 图标」结构（`bigIslandArea` / `smallIslandArea`
     * 的 title/content/pic），若换模板只需替换这两个对象的字段，判定与通道
     * 部分不用动。
     */
    private fun buildIslandParam(title: String, body: String, success: Boolean): String {
        val iconKey = if (success) "miui.focus.pic_ok" else "miui.focus.pic_err"

        val small = JSONObject()
            .put("pic", iconKey)
            .put("title", title)
            .put("content", body)

        val big = JSONObject()
            .put("pic", iconKey)
            .put("title", title)
            .put("content", body)

        val island = JSONObject()
            .put("islandProperty", 1) // 1=信息展示为主
            .put("islandTimeout", 60) // 岛停留 60s 后自动消失
            .put("dismissIsland", true) // 用完即走
            .put("highlightColor", HIGHLIGHT)
            .put("bigIslandArea", big)
            .put("smallIslandArea", small)

        val v2 = JSONObject()
            .put("business", "ffmpegpp_task_done")
            .put("islandFirstFloat", true) // 首次直接展开态
            .put("enableFloat", false) // 更新时不再抢焦点
            .put("timeout", 5) // 5 分钟后普通通知自动消失
            .put("param_island", island)
            .put("aodTitle", title)
            .put("ticker", title)

        return JSONObject().put("param_v2", v2).toString()
    }
}
