package com.ffmpegpp.ffmpegpp_gui

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ColorOsIntegrationConfigTest {
    @Test fun debugBuildUsesDocumentedDebugTemplate() {
        val config = ColorOsIntegrationConfig.resolve(
            debugBuild = true,
            intentName = null,
            launcherServiceId = null,
            fluidCloudServiceId = null,
        )

        assertNotNull(config)
        assertTrue(config!!.isDebugTemplate)
        val payload = JSONObject(
            ColorOsIntentPayload.buildProgressIntent(config, "sample.mp4", 42, 0)
        )
        assertEquals("Example.Progress", payload.getString("intentName"))
        assertEquals("999800001", payload.getJSONObject("serviceId").getString("launcher"))
        assertEquals("999900001", payload.getJSONObject("serviceId").getString("fluidCloud"))
    }

    @Test fun releaseWithoutOfficialIntegrationFailsClosed() {
        assertNull(ColorOsIntegrationConfig.resolve(
            debugBuild = false,
            intentName = null,
            launcherServiceId = null,
            fluidCloudServiceId = null,
        ))
    }

    @Test fun releaseRequiresAllOfficialValues() {
        assertNull(ColorOsIntegrationConfig.resolve(
            debugBuild = false,
            intentName = "com.example.progress",
            launcherServiceId = "launcher-id",
            fluidCloudServiceId = null,
        ))
    }

    @Test fun releasePayloadUsesConfiguredValuesAndPreservesProgress() {
        val config = ColorOsIntegrationConfig.resolve(
            debugBuild = false,
            intentName = "official.progress",
            launcherServiceId = "launcher-prod",
            fluidCloudServiceId = "fluid-prod",
        )!!
        val payload = JSONObject(
            ColorOsIntentPayload.buildProgressIntent(config, "movie.mp4", 200, 0)
        )

        assertFalse(config.isDebugTemplate)
        assertEquals("official.progress", payload.getString("intentName"))
        assertEquals("fluid-prod", payload.getJSONObject("serviceId").getString("fluidCloud"))
        val entity = payload.getJSONObject("intentEntity")
        assertEquals(100, entity.getJSONObject("secondaryData").getInt("progress"))
        assertEquals("100%", entity.getJSONObject("capsule").getString("rightText"))
    }


    @Test fun debugTemplateDoesNotCountAsProductionConfiguration() {
        assertFalse(ColorOsIntegrationConfig.isProductionConfigured(
            debugBuild = true,
            intentName = null,
            launcherServiceId = null,
            fluidCloudServiceId = null,
        ))
    }

    @Test fun completeReleaseValuesAreReportedAsConfigured() {
        assertTrue(ColorOsIntegrationConfig.isProductionConfigured(
            debugBuild = false,
            intentName = "official.progress",
            launcherServiceId = "launcher-prod",
            fluidCloudServiceId = "fluid-prod",
        ))
        assertFalse(ColorOsIntegrationConfig.isProductionConfigured(
            debugBuild = false,
            intentName = "official.progress",
            launcherServiceId = "launcher-prod",
            fluidCloudServiceId = " ",
        ))
    }

    @Test fun providerErrorCodeAndMessageAreRetained() {
        val result = ColorOsIntentPayload.parseShareResult(
            "{\"code\":10101001,\"message\":\"permission denied\"}"
        )
        assertFalse(result.success)
        assertEquals("10101001", result.code)
        assertEquals("permission denied", result.message)
    }

    @Test fun malformedProviderResultIsNotReportedAsSuccess() {
        val result = ColorOsIntentPayload.parseShareResult("not-json")
        assertFalse(result.success)
        assertEquals("invalid_response", result.code)
        assertNotNull(result.message)
    }
}

