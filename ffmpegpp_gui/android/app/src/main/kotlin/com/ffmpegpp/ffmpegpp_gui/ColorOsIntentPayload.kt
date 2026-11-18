package com.ffmpegpp.ffmpegpp_gui

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal object ColorOsIntentPayload {
    private const val PROGRESS_ENTITY_ID="ffmpegpp_progress"
    private const val SERVICE_ID_LAUNCHER="999800001"
    private const val SERVICE_ID_FLUID_CLOUD="999900001"
    private const val HIGHLIGHT="#FF6B4A"
    fun buildProgressIntent(filename: String, progress: Int, actionStatus: Int): String {
        val pct = progress.coerceIn(0, 100)
        val entity = baseEntity(PROGRESS_ENTITY_ID)
            .put("milestone", JSONObject().put("code", 0).put("text", "processing"))
            .put("capsule", capsuleJson("FFmpeg++ ", "$pct%"))
            .put("primary", primaryJson("FFmpeg++", filename))
            .put(
                "secondaryData",
                JSONObject().put("type", "PROGRESS").put("progress", pct)
            )

        return baseIntent(actionStatus).put("intentEntity", entity).toString()
    }

    /** 销卡 `IntelligentIntent`：actionStatus=2，只需身份字段（结构同创卡）。 */
    fun buildProgressEndIntent(): String {
        val entity = baseEntity(PROGRESS_ENTITY_ID)
        return baseIntent(actionStatus = 2).put("intentEntity", entity).toString()
    }

    // ────────────────────────────── JSON 组装 ─────────────────────────────

    /** `IntelligentIntent` 公共骨架：identifier/timestamp/serviceId/intentAction。 */
    // OPPO doc 13567: debug IDs require Example.Progress. Production intentName,
    // serviceId and TASK milestones must be supplied/approved during OPPO integration.
    fun baseIntent(actionStatus: Int): JSONObject = JSONObject()
        .put("intentName", "Example.Progress")
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

}
