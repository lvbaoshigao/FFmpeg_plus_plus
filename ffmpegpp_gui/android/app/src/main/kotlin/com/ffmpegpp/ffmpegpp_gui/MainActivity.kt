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
                    // 高刷新率（Dart 侧 services/refresh_rate.dart）：
                    //  - maxRefreshRate：当前分辨率下可用的最高刷新率（Hz）
                    //  - setPreferredRefreshRate：请求指定刷新率（0 = 交还系统默认）
                    "maxRefreshRate" -> result.success(maxRefreshRate().toDouble())
                    "setPreferredRefreshRate" -> {
                        val rate = (call.argument<Number>("rate") ?: 0).toFloat()
                        result.success(applyRefreshRate(rate))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── 高刷新率（90 / 120 / 144Hz） ──
    //
    // 为什么需要原生实现：Android 应用默认不一定跑在屏幕的最高刷新率上 ——
    // 大量 ROM（MIUI / ColorOS / HarmonyOS 等）只给「声明了高刷意图」的应用开高帧，
    // 窗口的 preferredRefreshRate 留空时会把帧率锁在 60Hz，于是 120Hz 屏幕上的
    // Flutter 界面仍按 60fps 渲染。这里三条路径一起上：
    //  1. API 30+ 的 Surface.setFrameRate(rate, FRAME_RATE_COMPATIBILITY_DEFAULT)
    //     —— 官方推荐入口，也是唯一能被系统「自适应刷新率」协商的 API
    //     （它随内容静止/滚动自动升降，而不是死锁 120Hz）。
    //     ⚠️ 这两个成员**只存在于 android.view.Surface**（实测 setFrameRate 与
    //     FRAME_RATE_COMPATIBILITY_DEFAULT 都是 since API 30）——View、SurfaceView、
    //     SurfaceHolder 上**都没有**同名成员，写成 `view.setFrameRate(...)` 或
    //     `surfaceView.setFrameRate(...)` 都编不过（CI 上踩过）。唯一入口是
    //     `surfaceView.holder.surface.setFrameRate(...)`。
    //  2. window.attributes.preferredRefreshRate（全版本，部分 ROM 只认它）；
    //  3. API 23~29 的 preferredDisplayModeId，精确选中「**同分辨率**下刷新率
    //     最高」的显示模式 —— 绝不能跨分辨率选模式（那会把屏幕分辨率改掉）。

    /** 上次请求的刷新率（< 0 = 尚未设置过）；onResume 时重放，见下。 */
    private var lastRefreshRate: Float = -1f

    /** 是否已挂过 SurfaceHolder 回调（只挂一次）。 */
    private var surfaceCallbackAdded = false

    override fun onResume() {
        super.onResume()
        // 系统在 pause/resume 后可能重置帧率偏好（部分 ROM 会退回 60Hz），
        // 这里按上次请求重放一次；从未设置过则什么都不做。
        if (lastRefreshRate >= 0f) applyRefreshRate(lastRefreshRate)
        // 冷启动时 onResume 早于 SurfaceView 的 surfaceCreated —— 此刻 Surface 尚未
        // 有效，路径① 无法生效。补挂一次 Holder 回调，等 Surface 就绪后自动重放。
        scheduleSurfaceCallback()
    }

    /**
     * 挂一次 SurfaceHolder 回调：Surface 创建后按上次请求重放（见 [onResume]）。
     * 走 decorView.post 是因为 FlutterActivity 的顺序为
     * `onAttach → configureFlutterEngine → setContentView` —— configureFlutterEngine
     * 阶段视图树里还没有 FlutterView，只有 post 之后才能找到它。
     */
    private fun scheduleSurfaceCallback() {
        if (surfaceCallbackAdded) return
        window?.decorView?.post { registerSurfaceCallback() }
    }

    /** 找到承载渲染的 SurfaceView 并挂上 Holder 回调（只挂一次）。 */
    private fun registerSurfaceCallback() {
        if (surfaceCallbackAdded) return
        val sv = window?.decorView?.let { findSurfaceView(it) } ?: return
        surfaceCallbackAdded = true
        sv.holder.addCallback(object : android.view.SurfaceHolder.Callback {
            override fun surfaceCreated(holder: android.view.SurfaceHolder) {
                if (lastRefreshRate >= 0f) applyRefreshRate(lastRefreshRate)
            }

            override fun surfaceChanged(
                holder: android.view.SurfaceHolder,
                format: Int,
                width: Int,
                height: Int
            ) {
            }

            override fun surfaceDestroyed(holder: android.view.SurfaceHolder) {}
        })
    }

    /**
     * 当前显示屏。API 30+ 用 Activity.getDisplay()；旧版本上
     * windowManager.defaultDisplay 虽被标记废弃，但仍是唯一可用入口，
     * 故在函数级抑制 DEPRECATION（写成局部表达式注解在部分 Kotlin 版本上不可靠）。
     */
    @Suppress("DEPRECATION")
    private fun currentDisplay(): android.view.Display? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
        else windowManager.defaultDisplay
    } catch (_: Exception) {
        null
    }

    /**
     * 当前分辨率下可用的最高刷新率（Hz）。取不到返回 0。
     *
     * 只在「与当前模式同宽高」的候选里取最大值：跨分辨率的高刷模式
     * （如 QHD@60 vs FHD@120）不能随便切，切了等于改用户的分辨率设置。
     */
    @Suppress("DEPRECATION")
    private fun maxRefreshRate(): Float {
        val d = currentDisplay() ?: return 0f
        val currentRate = try {
            d.refreshRate
        } catch (_: Exception) {
            0f
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return currentRate
        return try {
            val cur = d.mode
            var bestSameRes = 0f
            for (m in d.supportedModes) {
                if (m.physicalWidth == cur.physicalWidth &&
                    m.physicalHeight == cur.physicalHeight &&
                    m.refreshRate > bestSameRes
                ) {
                    bestSameRes = m.refreshRate
                }
            }
            if (bestSameRes > 0f) maxOf(bestSameRes, currentRate) else currentRate
        } catch (_: Exception) {
            currentRate
        }
    }

    /**
     * 请求以 [rate] 刷新；rate <= 0 表示交还系统默认（不干预）。
     * 返回是否至少有一条设置路径生效（仅用于日志/诊断，失败不抛异常）。
     */
    private fun applyRefreshRate(rate: Float): Boolean {
        val target = if (rate > 0f) rate else 0f
        return try {
            var ok = false
            // 路径①：API 30+ 官方接口。setFrameRate 只存在于 android.view.Surface，
            // 所以必须走 `SurfaceView.holder.surface` —— SurfaceView 自己也没有
            // 这个方法（`surfaceView.setFrameRate(...)` 编不过）。Surface 未就绪时
            // 跳过，等 registerSurfaceCallback 在 surfaceCreated 后重放。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val surf = window?.decorView?.let { findSurfaceView(it) }?.holder?.surface
                if (surf != null && surf.isValid) {
                    try {
                        surf.setFrameRate(
                            target,
                            android.view.Surface.FRAME_RATE_COMPATIBILITY_DEFAULT
                        )
                        ok = true
                    } catch (e: Exception) {
                        Log.w("FFmpegpp", "setFrameRate failed: " + e.message)
                    }
                }
            }
            // 路径②：窗口属性（全版本；部分 ROM 只认这个）
            val attrs = window?.attributes
            if (attrs != null) {
                attrs.preferredRefreshRate = if (target <= 0f) 0f else target
                // 路径③：API 23~29 用显示模式 ID 精确指定（API 30+ 该字段已废弃）
                if (target > 0f && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    val d = currentDisplay()
                    val cur = d?.mode
                    var bestId = -1
                    var bestRate = -1f
                    if (d != null && cur != null) {
                        for (m in d.supportedModes) {
                            if (m.physicalWidth != cur.physicalWidth ||
                                m.physicalHeight != cur.physicalHeight
                            ) continue
                            // 取「不超过请求值的最接近档位」，避免请求 90 却拿到 120
                            val r = m.refreshRate
                            if (r <= target + 1f && r > bestRate) {
                                bestRate = r
                                bestId = m.modeId
                            }
                        }
                    }
                    if (bestId >= 0) attrs.preferredDisplayModeId = bestId
                }
                window.attributes = attrs
                ok = true
            }
            lastRefreshRate = target
            Log.i("FFmpegpp", "applyRefreshRate target=" + target + " ok=" + ok)
            ok
        } catch (e: Exception) {
            Log.e("FFmpegpp", "applyRefreshRate error", e)
            false
        }
    }

    /**
     * 在视图树里深度优先查找承载渲染的 SurfaceView。
     *
     * FlutterView 由 FlutterSurfaceView 承载（SurfaceView 子类），但它是被包在容器
     * 里的，所以不能直接对 decorView 强转。若应用改用 texture 渲染模式
     * （FlutterTextureView，非 SurfaceView）则返回 null —— 此时只走路径②。
     */
    private fun findSurfaceView(v: android.view.View): android.view.SurfaceView? {
        if (v is android.view.SurfaceView) return v
        if (v is android.view.ViewGroup) {
            for (i in 0 until v.childCount) {
                val found = findSurfaceView(v.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
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
