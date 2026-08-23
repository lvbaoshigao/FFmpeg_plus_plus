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
        //  - nativeLibraryDir：APK 内置 native 库目录（libffmpegpp.so 后端动态库）
        //  - prepareBundledTool：从 assets 复制 ffmpeg/ffprobe 并 setExecutable
        //  - wallpaperColors：系统壁纸主色（Monet 动态取色种子）
        //  - openUrl：用系统浏览器/默认应用打开 http(s) 链接
        //  - openFile：用默认应用打开本地文件（FileProvider 生成 content:// URI）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ffmpegpp/android")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "prepareBundledTool" -> {
                        val assetName = call.argument<String>("assetName") ?: ""
                        val destPath = call.argument<String>("destPath") ?: ""
                        if (assetName.isEmpty() || destPath.isEmpty()) {
                            result.error("bad_args", "assetName/destPath required", null)
                        } else {
                            result.success(prepareBundledTool(assetName, destPath))
                        }
                    }
                    "wallpaperColors" -> result.success(wallpaperColors())
                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        if (url.isEmpty()) {
                            result.error("empty_url", "url is empty", null)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("open_failed", e.message, null)
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
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 把 APK 内置的可执行文件（assets/ffmpeg、assets/ffprobe）流式复制到目标
     * 路径并设置可执行权限。
     *
     * 不用 jniLibs 装静态二进制：Android 安装器会对 .so 做 ELF 校验，ET_EXEC
     * 静态可执行文件可能不被解压到 nativeLibraryDir，导致子进程 exec 报 127。
     * assets 不被当作原生库校验，复制出来即可用。返回是否成功。
     */
    private fun prepareBundledTool(assetName: String, destPath: String): Boolean {
        return try {
            val dest = File(destPath)
            dest.parentFile?.mkdirs()
            if (!dest.exists() || dest.length() == 0L) {
                assets.open(assetName).use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            }
            val ok = dest.setExecutable(true, true) && dest.setReadable(true, false)
            Log.e("FFmpegpp", "prepareBundledTool asset=$assetName dest=$destPath exists=${dest.exists()} len=${dest.length()} executable=$ok")
            ok
        } catch (e: Exception) {
            Log.e("FFmpegpp", "prepareBundledTool error: $assetName", e)
            false
        }
    }

    /** 用默认应用打开本地文件（目录交给系统文件管理器）。 */
    private fun openFile(path: String, result: MethodChannel.Result) {
        try {
            val f = File(path)
            if (!f.exists()) {
                result.error("not_found", "file not found: $path", null)
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
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
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
