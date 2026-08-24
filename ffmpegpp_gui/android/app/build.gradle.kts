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
        versionName = "5.0.0-beta2-android"
        ndk {
            // Flutter 插件在 apply 时会 clear() 并填入全部 ABI（armeabi-v7a/
            // arm64-v8a/x86_64），+= 会被其覆盖。这里必须 clear 后只保留 arm64：
            // 后端 libffmpegpp.so 与内置的 ffmpeg/ffprobe 均为 arm64，
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

    // libffmpegpp.so 是 C++ 后端动态库，需保证可被 dlopen；
    // ffmpeg/ffprobe 已改为 assets 打包（见 MainActivity.prepareBundledTool）。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // 【关键修复】ffmpeg/ffprobe 无扩展名，AAPT2 默认会 Deflate 压缩。
    // 压缩后的 asset 需要通过 ZipInflaterInputStream 解压，增加内存开销（峰值 ~40MB），
    // 且无法使用 AssetFileDescriptor 获取文件描述符。
    // 设为 noCompress 后，assets.open() 返回原始 FileInputStream，
    // 可用 assets.openFd(name).length 获取预期大小进行完整性校验。
    androidResources {
        noCompress += listOf("ffmpeg", "ffprobe")
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
