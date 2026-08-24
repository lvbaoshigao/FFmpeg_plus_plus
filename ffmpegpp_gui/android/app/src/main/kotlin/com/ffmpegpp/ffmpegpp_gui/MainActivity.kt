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
                    // code_cache 目录（SELinux 上下文 app_exec_data_file，允许 exec）
                    "codeCacheDir" -> result.success(codeCacheDir.absolutePath)
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

    /**
     * 把 APK 内置的可执行文件（assets/ffmpeg、assets/ffprobe）流式复制到目标
     * 路径并设置可执行权限。
     *
     * 【完整性校验】使用 assets.openFd(assetName).length 获取预期文件大小，
     * 与目标文件对比。如果大小不匹配（可能是上次复制中途被杀导致截断），
     * 删除并重新复制。复制后再次验证大小，确保文件完整。
     *
     * 【前提】build.gradle.kts 必须配置 noCompress += listOf("ffmpeg", "ffprobe")，
     * 否则 assets.openFd() 会抛异常（压缩后的 asset 无法直接获取长度）。
     *
     * 不用 jniLibs 装静态二进制：Android 安装器会对 .so 做 ELF 校验，ET_EXEC
     * 静态可执行文件可能不被解压到 nativeLibraryDir，导致子进程 exec 报 127。
     * assets 不被当作原生库校验，复制出来即可用。返回是否成功。
     */
    private fun prepareBundledTool(assetName: String, destPath: String): Boolean {
        return try {
            val dest = File(destPath)
            dest.parentFile?.mkdirs()
            
            // 获取预期文件大小（noCompress 配置后，asset 未压缩，可用 openFd 获取长度）
            val expectedSize = assets.openFd(assetName).length
            Log.d("FFmpegpp", "prepareBundledTool expected size for " + assetName + ": " + expectedSize + " bytes")
            
            // 检查目标文件是否存在且大小正确
            if (!dest.exists() || dest.length() != expectedSize) {
                if (dest.exists()) {
                    Log.w("FFmpegpp", "prepareBundledTool size mismatch: existing=" + dest.length() + " expected=" + expectedSize + ", deleting and re-copying")
                    dest.delete()
                }
                
                // 流式复制
                assets.open(assetName).use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
                
                // 验证复制后的大小
                if (dest.length() != expectedSize) {
                    Log.e("FFmpegpp", "prepareBundledTool copy verification failed: copied=" + dest.length() + " expected=" + expectedSize)
                    dest.delete()
                    return false
                }
                
                Log.d("FFmpegpp", "prepareBundledTool copied " + assetName + " successfully: " + dest.length() + " bytes")
            } else {
                Log.d("FFmpegpp", "prepareBundledTool " + assetName + " already exists with correct size, skipping copy")
            }
            
            val ok = dest.setExecutable(true, true) && dest.setReadable(true, false)
            Log.d("FFmpegpp", "prepareBundledTool asset=" + assetName + " dest=" + destPath + " exists=" + dest.exists() + " len=" + dest.length() + " executable=" + ok)
            ok
        } catch (e: Exception) {
            Log.e("FFmpegpp", "prepareBundledTool error: " + assetName, e)
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
                Log.e("FFmpegpp", "requestMediaPermissions requested: $missing")
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