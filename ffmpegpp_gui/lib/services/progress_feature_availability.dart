// Platform capability checks shared by notification settings and their tests.

/// Show the Fluid Cloud entry only when the ROM and provider are available.
bool shouldShowFluidCloudProgressSetting(Map<String, Object?>? status) =>
    status?['colorOs'] == true && status?['intentShareAvailable'] == true;

/// Release builds need the identifiers approved for this integration.
bool isFluidCloudIntegrationConfigured(Map<String, Object?>? status) =>
    status?['integrationConfigured'] == true;

/// Super Island controls are relevant only on a ROM that advertises the island.
/// Protocol/permission problems remain visible on supported devices so the
/// settings page can explain how to enable the feature.
bool shouldShowSuperIslandProgressSetting(Map<String, Object?>? status) =>
    status?['islandSupported'] == true;
