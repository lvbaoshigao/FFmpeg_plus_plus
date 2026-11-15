package com.ffmpegpp.ffmpegpp_gui

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NotificationPayloadTest {
    private fun xiaomi(progress: Int?) = JSONObject(XiaomiIslandPayload.build(
        "transcode", "FFmpeg++", "sample.mp4", "Processing", "miui.land.pic_task",
        true, false, 60, 5, false, progress,
    )).getJSONObject("param_v2")

    @Test fun expandedProgressIsPresentAndClamped() {
        for (input in listOf(-7, 0, 42, 100, 128)) {
            val v2 = xiaomi(input)
            val bar = v2.getJSONObject("progressInfo")
            assertEquals(input.coerceIn(0, 100), bar.getInt("progress"))
            assertEquals("#FF6B4A", bar.getString("colorProgress"))
            assertEquals("#FF6B4A", bar.getString("colorProgressEnd"))
        }
    }

    @Test fun collapsedAndBigIslandUseSameProgressWithoutCompetingIconComponent() {
        for (input in listOf(-1, 0, 37, 100, 101)) {
            val island = xiaomi(input).getJSONObject("param_island")
            val small = island.getJSONObject("smallIslandArea")
            assertFalse(small.has("picInfo"))
            assertEquals(1, small.length())
            val combined = small.getJSONObject("combinePicInfo")
            assertFalse(combined.has("type"))
            assertEquals(1, combined.getJSONObject("picInfo").getInt("type"))
            assertEquals("miui.land.pic_task", combined.getJSONObject("picInfo").getString("pic"))
            val ring = combined.getJSONObject("progressInfo")
            assertEquals(input.coerceIn(0, 100), ring.getInt("progress"))
            assertTrue(ring.getString("colorReach").isNotEmpty())
            assertTrue(ring.getString("colorUnReach").isNotEmpty())
            assertFalse(ring.getBoolean("isCCW"))
            assertEquals(input.coerceIn(0, 100), island.getJSONObject("bigIslandArea")
                .getJSONObject("progressTextInfo").getJSONObject("progressInfo").getInt("progress"))
        }
    }

    @Test fun nonProgressNotificationDoesNotFabricateProgress() {
        val v2 = xiaomi(null)
        assertFalse(v2.has("progressInfo"))
        val island = v2.getJSONObject("param_island")
        assertTrue(island.getJSONObject("smallIslandArea").has("picInfo"))
        assertFalse(island.getJSONObject("bigIslandArea").has("progressTextInfo"))
    }

    @Test fun oppoDebugIntentMatchesOfficialDebugServiceIds() {
        val payload = JSONObject(ColorOsIntentPayload.buildProgressIntent("sample.mp4", 42, 0))
        assertEquals("Example.Progress", payload.getString("intentName"))
        assertEquals("999900001", payload.getJSONObject("serviceId").getString("fluidCloud"))
        assertEquals("999800001", payload.getJSONObject("serviceId").getString("launcher"))
    }

    @Test fun oppoProgressAndCapsuleAlwaysAgreeAndAreClamped() {
        for (input in listOf(-4, 0, 42, 100, 200)) {
            val entity = JSONObject(ColorOsIntentPayload.buildProgressIntent("sample.mp4", input, 1))
                .getJSONObject("intentEntity")
            val secondary = entity.getJSONObject("secondaryData")
            assertEquals("PROGRESS", secondary.getString("type"))
            assertEquals(input.coerceIn(0, 100), secondary.getInt("progress"))
            assertEquals("${input.coerceIn(0, 100)}%", entity.getJSONObject("capsule").getString("rightText"))
        }
    }

    @Test fun oppoCreateRefreshAndEndKeepEntityIdentity() {
        val created = JSONObject(ColorOsIntentPayload.buildProgressIntent("first.mp4", 10, 0))
        val refreshed = JSONObject(ColorOsIntentPayload.buildProgressIntent("next.mp4", 50, 1))
        val ended = JSONObject(ColorOsIntentPayload.buildProgressEndIntent())
        for ((payload, action) in listOf(created to 0, refreshed to 1, ended to 2)) {
            assertEquals(action, payload.getJSONObject("intentAction").getInt("actionStatus"))
            assertEquals("ffmpegpp_progress", payload.getJSONObject("intentEntity").getString("entityId"))
        }
        assertFalse(ended.getJSONObject("intentEntity").has("secondaryData"))
        assertNotEquals(created.getString("identifier"), refreshed.getString("identifier"))
    }
}
