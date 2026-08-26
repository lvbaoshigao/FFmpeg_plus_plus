package com.ffmpegpp.ffmpegpp_gui

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.app.WallpaperManager
import android.opengl.EGL14
import android.opengl.GLES20
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
                    // 在文件管理器中定位到指定文件/目录（打开其父目录并尽量跳到该目录）
                    "revealFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        if (path.isEmpty()) {
                            result.error("empty_path", "path is empty", null)
                        } else {
                            revealFile(path, result)
                        }
                    }
                    // 申请必要媒体权限（读取视频/音频/图片，旧系统 READ_EXTERNAL_STORAGE）
                    "requestMediaPermissions" -> result.success(requestMediaPermissions())
                    // 系统资源占用：CPU / 内存 / GPU（顶栏资源监视器）
                    "systemStats" -> result.success(systemStats())
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
                // 目录：尽量让系统文件管理器（DocumentsUI）直接打开到该目录，
                // 而不是只进「文件」APP 首页。
                if (openDocumentsUiAt(f)) {
                    result.success(true)
                    return
                }
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
     * 在文件管理器中定位到 [path]：文件定位到其父目录，目录直接打开。
     * 旧实现一律打开「文件」APP 首页（DocumentsUI root），不会跳到目标位置。
     * 现在的策略（按优先级）：
     * 1. 目标在共享存储（/storage/emulated/0、SD 卡）→ 构造 DocumentsUI 的
     *    目录 document URI，直接打开到该目录（等同于桌面端的"在文件夹中显示"）；
     * 2. 目标在应用私有目录（DocumentsUI 无权浏览）→ 直接打开文件本身，
     *    视频会跳进系统播放器，用户立刻看到处理结果；
     * 3. 都失败 → 退回「文件」APP 首页。
     */
    private fun revealFile(path: String, result: MethodChannel.Result) {
        try {
            val f = File(path)
            val dir = if (f.isDirectory) f else f.parentFile
            // 1) 共享存储目录：打开到具体文件夹
            if (dir != null && openDocumentsUiAt(dir)) {
                result.success(true)
                return
            }
            // 2) 应用私有目录（或目录定位失败）：直接打开文件本身
            if (f.exists() && f.isFile) {
                try {
                    val uri = FileProvider.getUriForFile(this, packageName + ".fileprovider", f)
                    val mime = MimeTypeMap.getSingleton()
                        .getMimeTypeFromExtension(f.extension.lowercase())
                        ?: "application/octet-stream"
                    startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mime)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    })
                    result.success(true)
                    return
                } catch (_: Exception) {}
            }
            // 3) 兜底：文件管理器首页
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("content://com.android.externalstorage.documents/root/primary")
            })
            result.success(true)
        } catch (e: Exception) {
            result.error("open_failed", e.message, null)
        }
    }

    /**
     * 让系统文件管理器（DocumentsUI）直接打开到 [dir] 目录。
     * 通过 ExternalStorageProvider 的 document URI 实现：
     * content://com.android.externalstorage.documents/document/<volume>:<相对路径>
     * 仅支持共享存储；应用私有目录（/data/data/...）返回 false。
     */
    private fun openDocumentsUiAt(dir: File): Boolean {
        return try {
            val abs = dir.absoluteFile
            val docId: String? = run {
                // 内置共享存储：/storage/emulated/0/<rel> → primary:<rel>
                val extRoot = android.os.Environment.getExternalStorageDirectory().absoluteFile
                val rel = try { abs.relativeTo(extRoot).path } catch (_: Exception) { null }
                if (rel != null && !rel.startsWith("..")) {
                    return@run if (rel.isEmpty() || rel == ".") "primary:" else "primary:$rel"
                }
                // 外置卡：/storage/<uuid>/<rel> → <uuid>:<rel>
                val p = abs.path
                if (p.startsWith("/storage/")) {
                    val rest = p.removePrefix("/storage/")
                    val uuid = rest.substringBefore('/')
                    if (uuid.isNotEmpty() && uuid != "emulated" && uuid != "self") {
                        val sub = rest.substringAfter('/', "")
                        return@run if (sub.isEmpty()) "$uuid:" else "$uuid:$sub"
                    }
                }
                null
            }
            if (docId == null) return false
            val uri = android.provider.DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents", docId)
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/directory")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
            true
        } catch (_: Exception) {
            false
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

    // ── 系统资源监控（顶栏 CPU / 内存 / GPU 占用） ──
    //
    // 为什么需要原生实现：部分 ROM（MIUI 等）用 SELinux 拦截 app 读 /proc/stat，
    // Dart 侧读取抛异常后 CPU 与内存一起被置为 -1（--）；且 Android 没有
    // nvidia-smi/lspci，GPU 占用与名称只能在原生侧获取。
    // - 内存：ActivityManager.MemoryInfo —— 系统 API，任何 ROM 都可用
    // - CPU：/proc/stat 两次采样差值（被拦截的 ROM 上返回 -1，UI 显示 --）
    // - GPU%：sysfs 探测（高通 kgsl 等），不可用时返回 -1
    // - GPU 名称：临时 EGL pbuffer 上下文读 GL_RENDERER，只查一次并缓存

    private var prevCpuTotal: Long = -1
    private var prevCpuIdle: Long = -1
    // 应用级 CPU 兜底采样（/proc/stat 被 SELinux 拦截的 ROM 上使用）
    private var prevAppJiffies: Long = -1
    private var prevAppSampleNanos: Long = -1L
    private var cpuSysBlocked = false
    private var cachedGpuName: String? = null
    private var gpuPercentPath: String? = null

    private fun systemStats(): Map<String, Any> {
        val ram = readRamGb()
        return mapOf(
            "cpuPercent" to readCpuPercent(),
            "ramUsedGb" to ram[0],
            "ramTotalGb" to ram[1],
            "gpuPercent" to readGpuPercent(),
            "gpuName" to gpuName(),
        )
    }

    /**
     * CPU 占用 %。优先读 /proc/stat 得全系统占用（两次采样差值）；
     * 部分 ROM（MIUI 等）用 SELinux 拦截应用读 /proc/stat —— 文件能打开但读到
     * 空行/抛异常，这时退回「应用级」统计（本应用 UID 下全部进程，含 ffmpeg
     * 子进程），保证队列页始终有真实数值而不是恒为 "--"。
     * 首次采样只建立基线，返回 -1（UI 显示 --）。
     */
    private fun readCpuPercent(): Double {
        if (!cpuSysBlocked) {
            val sys = readSystemCpuPercent()
            if (sys != null) return sys
            cpuSysBlocked = true
            Log.i("FFmpegpp", "/proc/stat 不可读，CPU 占用切换为应用级统计")
        }
        return readAppCpuPercent()
    }

    /** 系统总 CPU%：/proc/stat 差值；不可读返回 null，首次采样返回 -1。 */
    private fun readSystemCpuPercent(): Double? {
        return try {
            val line = File("/proc/stat").useLines { lines ->
                lines.firstOrNull { it.startsWith("cpu ") }
            } ?: return null
            val p = line.split(Regex("\\s+")).drop(1)
                .map { it.toLongOrNull() ?: 0L }
            if (p.size < 4 || p.all { it == 0L }) return null
            val idle = p[3] + (if (p.size > 4) p[4] else 0L) // idle + iowait
            val total = p.sum()
            if (prevCpuTotal < 0L) {
                // 首次采样只建立基线（旧实现这里会返回开机以来的平均值，不准确）
                prevCpuTotal = total
                prevCpuIdle = idle
                return -1.0
            }
            val dt = total - prevCpuTotal
            val di = idle - prevCpuIdle
            prevCpuTotal = total
            prevCpuIdle = idle
            if (dt <= 0 || di < 0 || di > dt) return -1.0
            ((dt - di).toDouble() / dt.toDouble() * 100.0).coerceIn(0.0, 100.0)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 应用级 CPU%（兜底）：汇总与本应用同 UID 的所有进程 /proc/<pid>/stat 的
     * utime+stime 增量（fork+exec 出的 ffmpeg 子进程同 UID，转码负载会被计入），
     * 按「经过时间 × 核数」归一化为占满全部核心的百分比。
     * 同 UID 进程的 /proc/<pid>/stat 始终可读，不受 hidepid/SELinux 影响。
     */
    private fun readAppCpuPercent(): Double {
        return try {
            val myUid = android.os.Process.myUid()
            val hz = try {
                android.system.Os.sysconf(android.system.OsConstants._SC_CLK_TCK)
            } catch (_: Exception) { 100L }
            val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
            var jiffies = 0L
            File("/proc").listFiles()?.forEach { procDir ->
                if (procDir.name.toIntOrNull() == null) return@forEach
                try {
                    val st = android.system.Os.stat(procDir.absolutePath)
                    if (st.st_uid != myUid) return@forEach
                    val stat = File(procDir, "stat").readTextSafe() ?: return@forEach
                    // comm 可能含空格/括号：取最后一个 ')' 之后开始计数。
                    // 其后第 1 个字段是 state(第3列)，因此 utime(14)=fields[11]、
                    // stime(15)=fields[12]。
                    val fields = stat.substringAfterLast(')', "").trim()
                        .split(Regex("\\s+"))
                    val utime = fields.getOrNull(11)?.toLongOrNull() ?: 0L
                    val stime = fields.getOrNull(12)?.toLongOrNull() ?: 0L
                    jiffies += utime + stime
                } catch (_: Exception) {}
            }
            val now = System.nanoTime()
            if (prevAppJiffies < 0L) {
                prevAppJiffies = jiffies
                prevAppSampleNanos = now
                return -1.0
            }
            val dj = jiffies - prevAppJiffies
            val dtSec = (now - prevAppSampleNanos) / 1e9
            prevAppJiffies = jiffies
            prevAppSampleNanos = now
            if (dj < 0 || dtSec <= 0.0) return -1.0
            (dj.toDouble() / hz.toDouble() / dtSec / cores.toDouble() * 100.0)
                .coerceIn(0.0, 100.0)
        } catch (e: Exception) {
            -1.0
        }
    }

    /** 内存占用 [usedGb, totalGb]；ActivityManager 一定可用，异常时返回 -1。 */
    private fun readRamGb(): DoubleArray {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            val gb = 1024.0 * 1024.0 * 1024.0
            val total = mi.totalMem.toDouble() / gb
            val used = ((mi.totalMem - mi.availMem).toDouble() / gb).coerceAtLeast(0.0)
            doubleArrayOf(used, total)
        } catch (e: Exception) {
            doubleArrayOf(-1.0, -1.0)
        }
    }

    /** GPU 占用 %：按已知 sysfs 路径探测（高通 Adreno / Mali / 联发科），失败返回 -1。 */
    private fun readGpuPercent(): Double {
        // 已记住的路径优先
        gpuPercentPath?.let { path ->
            parseGpuPercent(File(path).readTextSafe())?.let { return it }
        }
        val candidates = mutableListOf(
            // 高通 Adreno（kgsl）—— "37 %" 或 "37"
            "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
            "/sys/devices/virtual/kgsl/kgsl-3d0/gpu_busy_percentage",
            "/sys/kernel/gpu/gpu_busy",
            // 联发科 GED
            "/sys/kernel/ged/hal/gpu_utilization",
        )
        // ARM Mali：/sys/devices/platform/<gpu>/utilisation
        try {
            File("/sys/devices/platform").listFiles()?.forEach { dir ->
                if (dir.name.contains("gpu", true) || dir.name.contains("mali", true)) {
                    candidates += File(dir, "utilisation").absolutePath
                    candidates += File(dir, "gpu_busy").absolutePath
                }
            }
        } catch (_: Exception) {}
        for (path in candidates) {
            val v = parseGpuPercent(File(path).readTextSafe())
            if (v != null) {
                gpuPercentPath = path
                return v
            }
        }
        return -1.0
    }

    private fun File.readTextSafe(): String? = try {
        if (exists()) readText().trim() else null
    } catch (_: Exception) {
        null
    }

    /** 解析 "37 %" / "37" / "37 12"（取首个数值）为 0~100 的百分比。 */
    private fun parseGpuPercent(text: String?): Double? {
        if (text.isNullOrEmpty()) return null
        val token = text.split(Regex("\\s+")).firstOrNull()?.removeSuffix("%")
            ?: return null
        val v = token.toDoubleOrNull() ?: return null
        return if (v in 0.0..100.0) v else null
    }

    /** GPU 名称（如 "Adreno 650" / "Mali-G77"）。只查询一次并缓存。 */
    private fun gpuName(): String {
        cachedGpuName?.let { return it }
        val name = try {
            queryGlRenderer()
        } catch (e: Exception) {
            null
        } ?: ""
        if (name.isNotEmpty()) cachedGpuName = name
        return name
    }

    /**
     * 创建 1x1 EGL pbuffer 离屏上下文读取 GL_RENDERER。
     * 无法复用 Flutter 的 GL 上下文（跨线程），临时上下文用完即销毁。
     */
    private fun queryGlRenderer(): String? {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return null
        var context: android.opengl.EGLContext? = null
        var surface: android.opengl.EGLSurface? = null
        var initialized = false
        try {
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return null
            initialized = true
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, numConfigs, 0)
                || numConfigs[0] < 1) return null
            val config = configs[0] ?: return null
            context = EGL14.eglCreateContext(
                display, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            if (context == null || context == EGL14.EGL_NO_CONTEXT) return null
            surface = EGL14.eglCreatePbufferSurface(
                display, config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            if (surface == null || surface == EGL14.EGL_NO_SURFACE) return null
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return null
            return GLES20.glGetString(GLES20.GL_RENDERER)
        } catch (e: Exception) {
            return null
        } finally {
            if (initialized) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                surface?.let { EGL14.eglDestroySurface(display, it) }
                context?.let { EGL14.eglDestroyContext(display, it) }
                EGL14.eglTerminate(display)
            }
        }
    }
}
