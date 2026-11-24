pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 必须 ≥ Flutter 的最低支持版本：9.1.0 会直接抛
    // "Android Gradle Plugin version 9.1.0 is lower than Flutter's minimum
    //  supported version of 9.1.1"，导致 flutter build apk 失败。
    id("com.android.application") version "9.1.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
