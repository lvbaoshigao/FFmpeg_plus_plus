package com.ffmpegpp.ffmpegpp_gui

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal data class ColorOsIntegrationConfig(
    val intentName: String,
    val launcherServiceId: String,
    val fluidCloudServiceId: String,
    val isDebugTemplate: Boolean,
) {
    companion object {
        private const val DEBUG_INTENT_NAME = "Example.Progress"
        private const val DEBUG_LAUNCHER_SERVICE_ID = "999800001"
        private const val DEBUG_FLUID_CLOUD_SERVICE_ID = "999900001"

        /** Debug builds use OPPO's sample template; release requires all OPPO-issued values. */
        fun isProductionConfigured(
            debugBuild: Boolean,
            intentName: String?,
            launcherServiceId: String?,
            fluidCloudServiceId: String?,
        ): Boolean = !debugBuild &&
            !intentName.isNullOrBlank() &&
            !launcherServiceId.isNullOrBlank() &&
            !fluidCloudServiceId.isNullOrBlank()

        fun resolve(
            debugBuild: Boolean,
            intentName: String?,
            launcherServiceId: String?,
            fluidCloudServiceId: String?,
        ): ColorOsIntegrationConfig? {
            if (debugBuild) {
                return ColorOsIntegrationConfig(
                    DEBUG_INTENT_NAME,
                    DEBUG_LAUNCHER_SERVICE_ID,
                    DEBUG_FLUID_CLOUD_SERVICE_ID,
                    isDebugTemplate = true,
                )
            }
            val values = listOf(intentName, launcherServiceId, fluidCloudServiceId)
                .map { it?.trim().orEmpty() }
            if (values.any(String::isEmpty)) return null
            return ColorOsIntegrationConfig(
                values[0], values[1], values[2], isDebugTemplate = false,
            )
        }
    }
}

internal data class ColorOsShareResult(
    val success: Boolean,
    val code: String?,
    val message: String?,
)

internal object ColorOsIntentPayload {
    private const val PROGRESS_ENTITY_ID = "ffmpegpp_progress"
    private const val DONE_ENTITY_ID = "ffmpegpp_task_done"
    private const val HIGHLIGHT = "#FF6B4A"

    fun buildProgressIntent(
        config: ColorOsIntegrationConfig,
        filename: String,
        progress: Int,
        actionStatus: Int,
    ): String {
        val pct = progress.coerceIn(0, 100)
        val entity = baseEntity(PROGRESS_ENTITY_ID)
            .put("milestone", JSONObject().put("code", 0).put("text", "processing"))
            .put("capsule", capsuleJson("FFmpeg++ ", "$pct%"))
            .put("primary", primaryJson("FFmpeg++", filename))
            .put("secondaryData", JSONObject().put("type", "PROGRESS").put("progress", pct))
        return baseIntent(config, actionStatus).put("intentEntity", entity).toString()
    }

    fun buildDoneIntent(
        config: ColorOsIntegrationConfig,
        title: String,
        body: String,
        success: Boolean,
    ): String {
        val entity = baseEntity(DONE_ENTITY_ID)
            .put("milestone", JSONObject()
                .put("code", if (success) 100 else 101)
                .put("text", if (success) "done" else "failed"))
            .put("capsule", capsuleJson("FFmpeg++ ", if (success) "已完成" else "失败"))
            .put("primary", primaryJson(title, body))
        return baseIntent(config, actionStatus = 0).put("intentEntity", entity).toString()
    }

    /** Destroy progress card with the same integration identity used to create it. */
    fun buildProgressEndIntent(config: ColorOsIntegrationConfig): String =
        baseIntent(config, actionStatus = 2)
            .put("intentEntity", baseEntity(PROGRESS_ENTITY_ID))
            .toString()

    /** Parse the documented ShareResult without swallowing its error code/message. */
    fun parseShareResult(resultJson: String?): ColorOsShareResult {
        if (resultJson.isNullOrBlank()) {
            return ColorOsShareResult(false, "missing_result", "Provider returned no result")
        }
        return try {
            val result = JSONObject(resultJson)
            val code = result.optInt("code", Int.MIN_VALUE)
            if (code == Int.MIN_VALUE) {
                ColorOsShareResult(false, "missing_code", "Provider result has no integer code")
            } else {
                val message = result.optString("message", "").takeIf { it.isNotBlank() }
                ColorOsShareResult(code == 0, code.toString(), message)
            }
        } catch (e: Exception) {
            ColorOsShareResult(false, "invalid_response", e.message ?: "Invalid provider response")
        }
    }

    fun baseIntent(config: ColorOsIntegrationConfig, actionStatus: Int): JSONObject = JSONObject()
        .put("intentName", config.intentName)
        .put("identifier", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put(
            "serviceId",
            JSONObject()
                .put("launcher", config.launcherServiceId)
                .put("fluidCloud", config.fluidCloudServiceId),
        )
        .put("intentAction", JSONObject().put("actionStatus", actionStatus))

    private fun baseEntity(entityId: String): JSONObject = JSONObject()
        .put("entityName", "TASK")
        .put("entityId", entityId)

    private fun capsuleJson(leftText: String, rightText: String): JSONObject = JSONObject()
        .put(
            "leftText",
            JSONArray().put(
                JSONObject()
                    .put("text", leftText)
                    .put("color", HIGHLIGHT)
                    .put("darkColor", HIGHLIGHT),
            ),
        )
        .put("rightText", rightText)

    private fun primaryJson(title: String, content: String): JSONObject = JSONObject()
        .put(
            "title",
            JSONArray().put(
                JSONObject()
                    .put("text", title)
                    .put("color", HIGHLIGHT)
                    .put("darkColor", HIGHLIGHT),
            ),
        )
        .put("content", content)
}
