package com.ffmpegpp.ffmpegpp_gui

import android.content.Intent
import android.net.Uri
import android.app.WallpaperManager
import android.os.Build
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 与 Dart 侧 services/android_platform.dart、services/shell_open.dart 对应：
        //  - nativeLibraryDir：APK 内置 native 库目录
        //    （libffmpegpp.so 后端动态库 + libffmpeg.so / libffprobe.so 可执行文件）
        //  - wallpaperColors：系统壁纸主色（Monet 动态取色种子）
        //  - openUrl：用系统浏览器/默认应用打开 http(s) 链接
        //  - openFile：用默认应用打开本地文件（FileProvider 生成 content:// URI）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ffmpegpp/android")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "wallpaperColors" -> result.success(wallpaperColors())
                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        if (url.isEmpty()) {
                            result.error("empty_url", "url is empty", null)
                        } else {
                            // 安全校验：仅允许 http/https scheme，防止 file:// 或 content:// 访问本地文件
                            if (!url.startsWith("http://") && !url.startsWith("https://")) {
                                result.error("invalid_scheme", "only http/https URLs are allowed", null)
                            } else {
                                try {
                                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.error("open_failed", e.message, null)
                                }
                            }
                        }
                    }
                    "openFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        if (path.isEmpty()) {
                            result.error("empty_path", "path is empty", null)
                        } else {
                            openFile(path, result)
                        }
                    }
                    // 申请必要媒体权限（读取视频/音频/图片，旧系统 READ_EXTERNAL_STORAGE）
                    "requestMediaPermissions" -> result.success(requestMediaPermissions())
                    else -> result.notImplemented()
                }
            }
    }

    /** 用默认应用打开本地文件（目录交给系统文件管理器）。 */
    private fun openFile(path: String, result: MethodChannel.Result) {
        try {
            val f = File(path)
            if (!f.exists()) {
                result.error("not_found", "file not found: " + path, null)
                return
            }
            if (f.isDirectory) {
                // 目录：用系统文件管理器打开（DocumentsUI）
                val dirIntent = Intent(Intent.ACTION_VIEW).apply {
                    data = Uri.parse("content://com.android.externalstorage.documents/root/primary")
                }
                try {
                    startActivity(dirIntent)
                    result.success(true)
                    return
                } catch (_: Exception) {
                    // DocumentsUI 不可用（部分厂商 ROM），回退到打开文件自身
                }
            }
            val uri = FileProvider.getUriForFile(this, packageName + ".fileprovider", f)
            val mime = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(f.extension.lowercase())
                ?: "application/octet-stream"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("open_failed", e.message, null)
        }
    }

    /**
     * 申请必要媒体权限：Android 13+（TIRAMISU）用分区媒体权限
     * READ_MEDIA_VIDEO/AUDIO/IMAGES，Android 6~12 用 READ_EXTERNAL_STORAGE，
     * 更旧系统安装时即授予、无需运行时申请。返回仍未授予的权限列表（空 = 已全部授予）。
     */
    private fun requestMediaPermissions(): List<String> {
        return try {
            val perms: Array<String> = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(
                    android.Manifest.permission.READ_MEDIA_VIDEO,
                    android.Manifest.permission.READ_MEDIA_AUDIO,
                    android.Manifest.permission.READ_MEDIA_IMAGES,
                )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> arrayOf(
                    android.Manifest.permission.READ_EXTERNAL_STORAGE,
                )
                else -> emptyArray()
            }
            val missing = perms.filter {
                checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED
            }
            if (missing.isNotEmpty()) {
                requestPermissions(missing.toTypedArray(), 1001)
                Log.d("FFmpegpp", "requestMediaPermissions requested: " + missing)
            }
            missing
        } catch (e: Exception) {
            Log.e("FFmpegpp", "requestMediaPermissions error", e)
            emptyList()
        }
    }

    /** 系统壁纸颜色（API 27+），用于 Material You / Monet 动态取色。 */
    private fun wallpaperColors(): Map<String, Int>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return null
        return try {
            val wc = WallpaperManager.getInstance(this)
                .getWallpaperColors(WallpaperManager.FLAG_SYSTEM) ?: return null
            val primary: Int = wc.primaryColor.toArgb()
            val secondary: Int = wc.secondaryColor?.toArgb() ?: 0
            val tertiary: Int = wc.tertiaryColor?.toArgb() ?: 0
            mapOf(
                "primary" to primary,
                "secondary" to secondary,
                "tertiary" to tertiary,
            )
        } catch (e: Exception) {
            null
        }
    }
}
