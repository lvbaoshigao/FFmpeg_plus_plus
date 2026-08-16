plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ffmpegpp.ffmpegpp_gui"
    compileSdk = flutter.compileSdkVersion
    // 与 Flutter 插件要求的 NDK 版本一致（本机 SDK 已安装）。
    // 原生库（libffmpegpp.so/ffmpeg/ffprobe）为预编译产物（jniLibs），
    // Gradle 只做打包，不重新编译。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.ffmpegpp.ffmpegpp_gui"
        // Android 8.0+；ffmpeg/ffprobe 以 arm64 静态可执行文件内置
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = "5.0.0-beta1-android"
        ndk {
            // Flutter 插件在 apply 时会 clear() 并填入全部 ABI（armeabi-v7a/
            // arm64-v8a/x86_64），+= 会被其覆盖。这里必须 clear 后只保留 arm64：
            // 内置的 libffmpeg.so/libffprobe.so 是 arm64 静态可执行文件，
            // 其它 ABI 装了也无法使用，且会白白增加 APK 体积。
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // 关键：以 legacy 方式解压 native 库（libffmpeg.so / libffprobe.so 是
    // 静态可执行文件，需要被解压到 nativeLibraryDir 并保留可执行权限，
    // 供 C++ 后端以子进程方式调用）。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
