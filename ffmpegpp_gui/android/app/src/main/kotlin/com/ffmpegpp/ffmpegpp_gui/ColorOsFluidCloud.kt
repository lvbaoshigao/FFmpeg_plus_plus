package com.ffmpegpp.ffmpegpp_gui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * OPPO ColorOS「流体云」接入：任务完成通知 + 转码进度卡。
 *
 * 文档：
 *  - 流体云模板：<https://open.oppomobile.com/documentation/page/info?id=12658>
 *  - 意图共享(端侧)：<https://open.oppomobile.com/documentation/page/info?id=13558>
 *  - 意图共享数据结构（进度可视化模板）：<https://open.oppomobile.com/documentation/page/info?id=13567>
 *
 * 接入方式不是独立 SDK：应用进程活跃时，通过 `ContentProviderClient` 直接调用
 * 系统的 IntelligentIntentProvider（authority = "IntelligentIntent"），把一条
 * `IntelligentIntent` JSON 塞进 `shareIntent`，即可在端侧创建/更新/结束流体云
 * 实例（actionStatus 0=创卡 / 1=刷新 / 2=销卡）。ColorOS 14（API2.0）起支持。
 * 文档另注明：actionStatus 传 0/1 时若未创卡则会创卡，否则刷新；销卡（2）立刻生效。
 *
 * ⚠️ 联调约束（与 HyperOsIsland.kt 的「模板库另册」同款情形）：
 *  - serviceId：调测环境用固定值 {"launcher":"999800001","fluidCloud":"999900001"}；
 *    正式环境的 serviceId 需在与 OPPO 联调过程中由其提供后替换。
 *  - milestone.code 的取值表见文档「垂域里程碑」章节，此处按通用语义占位
 *    （完成=100/失败=101、进行中=0），联调时按 TASK 场景的里程碑表校准。
 *  - 创卡是否成功还取决于应用的意图共享权限（错误码 10101001）与系统开关
 *    （10103003），我们无法在端侧预判 —— 所以失败一律静默退化为普通通知/
 *    静默放弃，保证任何 ROM 上都不会 crash。
 *
 * 之所以判定与 JSON 组装都做在 Kotlin 侧：ColorOS 版本号依赖隐藏系统属性
 * （SystemProperties 反射），Dart 层拿不到；且 JSON 紧贴 Provider 调用，留在
 * 原生侧可以少一次跨语言往返 —— 与 HyperOsIsland.kt 同一套理由。
 */
object ColorOsFluidCloud {

    private const val TAG = "ColorOsFluidCloud"
    private const val CHANNEL_ID = "ffmpegpp_task_done"
    private const val CHANNEL_NAME = "任务完成"

    /** 意图共享 Provider 的 authority（文档「意图共享(端侧)」原文）。 */
    private const val PROVIDER_AUTHORITY = "IntelligentIntent"
    private const val PROVIDER_METHOD = "shareIntent"
    private const val EXTRA_INTENT_DATA = "intentData"
    private const val RESULT_KEY = "result"

    /** 调测环境固定 serviceId；正式环境由 OPPO 联调提供后替换（见类注释 ⚠️）。 */
    private const val SERVICE_ID_LAUNCHER = "999800001"
    private const val SERVICE_ID_FLUID_CLOUD = "999900001"

    /** 「任务完成」通知卡的实体固定 ID：同 id 创卡=刷新，只保留最新一条。 */
    private const val DONE_ENTITY_ID = "ffmpegpp_task_done"

    /** 进度卡的实体固定 ID：全应用只维护一张进度卡（并发任务时显示最近更新的）。 */
    private const val PROGRESS_ENTITY_ID = "ffmpegpp_progress"

    /** 本应用在流体云上的强调色（朱砂，与主题点缀色 / 超级岛一致）。 */
    private const val HIGHLIGHT = "#FF6B4A"

    /** 进度卡是否处于「已创卡未销卡」状态（进程内状态即可：销卡自然随进程消亡）。 */
    @Volatile
    private var progressCardCreated = false

    // ────────────────────────────── 能力查询 ──────────────────────────────

    /**
     * ColorOS 版本号（如 "V14.0.1" / "6.0"），非 ColorOS 返回空串。
     * oplus 系 ROM（OPPO / OnePlus / realme 国行）暴露
     * `ro.build.version.oplorom`（新版）或 `ro.build.version.opporom`（旧版）。
     */
    fun colorOsVersion(): String = try {
        val clazz = Class.forName("android.os.SystemProperties")
        val method = clazz.getDeclaredMethod(
            "get", String::class.java, String::class.java
        )
        for (key in arrayOf("ro.build.version.oplorom", "ro.build.version.opporom")) {
            val v = method.invoke(null, key, "") as? String ?: ""
            if (v.isNotEmpty()) return v
        }
        ""
    } catch (e: Exception) {
        ""
    }

    /** 是否 ColorOS（含 oplus 系三品牌）。 */
    fun isColorOs(): Boolean = colorOsVersion().isNotEmpty()

    /**
     * 意图共享 Provider 是否可达：Android 11+ 包可见性过滤下，若 Manifest 未在
     * `<queries>` 声明该 authority，这里会直接返回 null —— 可达 ≠ 有权限
     * （权限校验在系统侧，错误码 10101001），只作为「值得去试」的预判。
     */
    fun intentShareAvailable(context: Context): Boolean = try {
        val client = context.contentResolver
            .acquireUnstableContentProviderClient(PROVIDER_AUTHORITY)
        val ok = client != null
        client?.close()
        ok
    } catch (e: Exception) {
        false
    }

    /** 汇总状态，供 Dart 侧做「是否已接入流体云」的展示（method: fluidCloudStatus）。 */
    fun status(context: Context): Map<String, Any?> = mapOf(
        "colorOs" to isColorOs(),
        "colorOsVersion" to colorOsVersion(),
        "intentShareAvailable" to intentShareAvailable(context),
    )

    // ────────────────────────────── 任务完成通知 ──────────────────────────

    /**
     * 发送「任务完成」通知。ColorOS 上优先创流体云卡（胶囊/通知中心多入口呈现），
     * 创卡失败（无权限 / 开关关闭 / Provider 不可达 / 任何异常）静默退化为
     * 普通系统通知 —— 与 HyperOsIsland 同款「不抛异常、必有兜底」策略。
     *
     * @return true 表示通知已交给系统（普通通知路径），或流体云创卡被系统接受。
     */
    fun postTaskDone(
        context: Context,
        title: String,
        body: String,
        success: Boolean
    ): Boolean {
        // 流体云：创卡成功即收工（卡片本身会在通知中心呈现，不再补发普通通知，
        // 避免同一条「任务完成」在通知中心出现两份）。
        if (shareIntent(context, buildDoneIntent(title, body, success))) return true
        // 兜底：普通通知（兜底通知的返回值决定整体成败）。
        return postPlainNotification(context, title, body)
    }

    /**
     * 测试通知：按当前系统决定走哪条路，返回结果：
     *  * `fluidcloud`   —— ColorOS，已走流体云
     *  * `notification` —— 创卡失败退化，走普通系统通知
     *  * `unsupported`  —— 系统太旧，或通知被系统拒绝
     *
     * 与 [HyperOsIsland.postTestNotification] 同契约：返回值只说明「走了哪条路」，
     * 不保证真显示出来 —— 调用方据此给白名单引导文案。
     */
    fun postTestNotification(context: Context): String {
        val shared = shareIntent(context, buildDoneIntent("FFmpeg++", "测试通知 · 流体云", true))
        if (shared) return "fluidcloud"
        val ok = postPlainNotification(context, "FFmpeg++", "测试通知 · 系统通知")
        return if (ok) "notification" else "unsupported"
    }

    /**
     * 组装「任务完成」的 `IntelligentIntent` JSON（结构见文档 id=13567）。
     *
     * ⚠️ milestone.code 以文档「垂域里程碑」为准（TASK 场景另册），此处按通用
     *    完成语义占位（100=完成 / 101=失败），联调时校准。系统侧拒绝时调用方
     *    自然落到普通通知兜底。
     */
    private fun buildDoneIntent(title: String, body: String, success: Boolean): String {
        val entity = baseEntity(DONE_ENTITY_ID)
            .put("milestone",
                JSONObject().put("code", if (success) 100 else 101)
                    .put("text", if (success) "done" else "failed"))
            .put("capsule", capsuleJson("FFmpeg++ ", if (success) "已完成" else "失败"))
            .put("primary", primaryJson(title, body))

        return baseIntent(actionStatus = 0).put("intentEntity", entity).toString()
    }

    // ────────────────────────────── 进度卡 ────────────────────────────────

    /**
     * 创建/刷新转码进度卡（method: fluidCloudProgress，由 Dart 侧
     * `FluidCloudProgress` 服务节流后调用）。
     *
     * 首次创卡（actionStatus=0），之后刷新（actionStatus=1）。entityId 固定：
     * 并发多任务时最新一条更新会覆盖卡片内容，不会累积出多张卡
     * （实体数量超限 = 错误码 10103004）。
     *
     * @return 系统是否接受该次创卡/刷新（false 只代表没显示，不影响任务）。
     */
    fun postProgress(context: Context, filename: String, progress: Int): Boolean = try {
        val action = if (progressCardCreated) 1 else 0
        val ok = shareIntent(context, buildProgressIntent(filename, progress, action))
        if (ok) progressCardCreated = true
        ok
    } catch (e: Exception) {
        android.util.Log.w(TAG, "postProgress failed: " + e.message)
        false
    }

    /**
     * 销毁进度卡（method: fluidCloudEnd，队列空闲时由 Dart 侧调用）。
     * 无论销卡成败都复位 [progressCardCreated]：销卡失败时，下一次创卡
     * （actionStatus=0 未创卡则创卡）会让卡片状态自愈。
     */
    fun endProgress(context: Context): Boolean {
        if (!progressCardCreated) return true
        val ok = try {
            shareIntent(context, buildProgressEndIntent())
        } catch (e: Exception) {
            android.util.Log.w(TAG, "endProgress failed: " + e.message)
            false
        }
        progressCardCreated = false
        return ok
    }

    /**
     * 进度卡 `IntelligentIntent`：进度可视化模板（secondaryData type=PROGRESS）。
     * 文案保持 ROM 语言中性（品牌名 + 数字百分比 + 文件名），不在原生侧做本地化。
     *
     * ⚠️ milestone 进行中状态码（code=0 "processing"）为占位，联调时按
     *    「垂域里程碑」校准。
     */
    private fun buildProgressIntent(filename: String, progress: Int, actionStatus: Int): String {
        val entity = baseEntity(PROGRESS_ENTITY_ID)
            .put("milestone", JSONObject().put("code", 0).put("text", "processing"))
            .put("capsule", capsuleJson("FFmpeg++ ", "$progress%"))
            .put("primary", primaryJson("FFmpeg++", filename))
            .put(
                "secondaryData",
                JSONObject().put("type", "PROGRESS").put("progress", progress)
            )

        return baseIntent(actionStatus).put("intentEntity", entity).toString()
    }

    /** 销卡 `IntelligentIntent`：actionStatus=2，只需身份字段（结构同创卡）。 */
    private fun buildProgressEndIntent(): String {
        val entity = baseEntity(PROGRESS_ENTITY_ID)
        return baseIntent(actionStatus = 2).put("intentEntity", entity).toString()
    }

    // ────────────────────────────── JSON 组装 ─────────────────────────────

    /** `IntelligentIntent` 公共骨架：identifier/timestamp/serviceId/intentAction。 */
    private fun baseIntent(actionStatus: Int): JSONObject = JSONObject()
        .put("intentName", "FFmpegpp.Task")
        .put("identifier", UUID.randomUUID().toString()) // 单次共享唯一标识
        .put("timestamp", System.currentTimeMillis())
        .put(
            "serviceId",
            JSONObject()
                .put("launcher", SERVICE_ID_LAUNCHER)
                .put("fluidCloud", SERVICE_ID_FLUID_CLOUD)
        )
        .put("intentAction", JSONObject().put("actionStatus", actionStatus))

    /** `intentEntity` 公共骨架：TASK 场景 + 固定 entityId（intentAction 只在顶层）。 */
    private fun baseEntity(entityId: String): JSONObject = JSONObject()
        .put("entityName", "TASK")
        .put("entityId", entityId)

    /**
     * 胶囊信息：文档要求「单侧图标和文本至少传一个」，本应用没有远程图床，
     * 全部走文本，颜色跟随系统亮暗模式给两份（color/darkColor）。
     */
    private fun capsuleJson(leftText: String, rightText: String): JSONObject = JSONObject()
        .put(
            "leftText",
            JSONArray().put(
                JSONObject()
                    .put("text", leftText)
                    .put("color", HIGHLIGHT)
                    .put("darkColor", HIGHLIGHT)
            )
        )
        .put("rightText", rightText)

    /** 卡片核心信息：标题（单元素数组，带亮暗两份颜色）+ 正文。 */
    private fun primaryJson(title: String, content: String): JSONObject = JSONObject()
        .put(
            "title",
            JSONArray().put(
                JSONObject()
                    .put("text", title)
                    .put("color", HIGHLIGHT)
                    .put("darkColor", HIGHLIGHT)
            )
        )
        .put("content", content)

    // ────────────────────────────── Provider 调用 ─────────────────────────

    /**
     * 端侧意图共享：调 IntelligentIntentProvider.shareIntent，解析 ShareResult。
     * @return code == 0（成功）。
     */
    private fun shareIntent(context: Context, intentData: String): Boolean = try {
        val client = context.contentResolver
            .acquireUnstableContentProviderClient(PROVIDER_AUTHORITY)
            ?: return false
        try {
            val bundle = Bundle().apply {
                putString(EXTRA_INTENT_DATA, intentData)
            }
            val resultBundle = client.call(PROVIDER_METHOD, null, bundle)
                ?: return false
            val resultJson = resultBundle.getString(RESULT_KEY) ?: return false
            // ShareResult: { code: Int(0=成功), message: String, data?: String }
            JSONObject(resultJson).optInt("code", -1) == 0
        } finally {
            client.close()
        }
    } catch (e: Exception) {
        // 典型失败：SecurityException（无权限）、IllegalState（Provider 异常）。
        android.util.Log.w(TAG, "shareIntent failed: " + e.message)
        false
    }

    // ────────────────────────────── 普通通知兜底 ──────────────────────────

    /** 普通系统通知兜底：与 HyperOsIsland.postTaskDone 的非岛路径同款实现。 */
    private fun postPlainNotification(
        context: Context,
        title: String,
        body: String
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT
                )
            )
            val notification = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(context.applicationInfo.icon)
                .setAutoCancel(true)
                .build()
            // id 固定 0：同一时刻只保留最新一条「任务完成」，避免刷屏。
            nm.notify(CHANNEL_ID, 0, notification)
            true
        } catch (e: Exception) {
            false
        }
    }
}
