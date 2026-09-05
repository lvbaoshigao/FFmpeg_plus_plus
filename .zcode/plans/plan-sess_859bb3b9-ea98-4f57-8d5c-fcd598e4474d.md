## FFmpeg++ 综合修复与优化方案

### A. 移动端 GPU 编码失效（根因修复）
**根因**：release 工作流不重建 ffmpeg，APK 用旧 jniLibs（无 mediacodec）。
1. `.github/workflows/build-release.yml` `compile-android` job：新增 NDK 安装 + FFmpeg 交叉编译缓存 + 运行 `build/android/build_ffmpeg.sh`（与 debug-build.yml:454-507 对齐），确保 release APK 重新打包新二进制。
2. `build/android/build_ffmpeg.sh` 第 6 节验收：除现有 PT_INTERP/libc++_shared 检查外，**新增硬校验** `strings libffmpeg.so | grep -q h264_mediacodec`，否则 exit 1——杜绝无声打包缺硬编的旧产物。
3. `build/android/build_apk.sh`：sync 后加 strings 抽检，二次防护。
4. `lib/services/quick_config_pipeline.dart:77`：快捷配置不再硬编码 `gpu: 'CPU'`——移动端若可用硬编则优先 MediaCodec（通过 `Platform.isAndroid` 判断，选 `h264_mediacodec`），桌面维持现状。
5. `lib/services/graph_executor.dart`：`_avOptions` 保持现有透传；在 BackendClient 失败回调中，若错误含 "mediacodec"/"encoder not found" 且 gpu != CPU，追加提示「当前 ffmpeg 未编译硬编，请更新/重装」。

### B. Windows 标题栏消失（运行期防御）
1. `windows/runner/win32_window.cpp`：除 Create 时补齐外，新增 `WM_ACTIVATE`/`WM_STYLECHANGING` 处理——检测到 `WS_CAPTION` 被清除时强制补回并 `SWP_FRAMECHANGED` 重绘。
2. `lib/main.dart` `_initWindow`：`setTitleBarStyle(TitleBarStyle.normal)` 后增加一次延迟校验（`windowManager.isMaximized` 触发链路顺带刷新），并在 `setPreventClose(true)` 场景确保样式重应用。
3. `lib/app.dart`：Windows/macOS 分支已走系统标题栏，保持；pipeline_editor/container_detail 里仅 Linux 才渲染自绘 CSD 按钮（加 `Platform.isLinux` 守卫），Windows 上禁用这些页面的 CSD 叠加。

### C. 启动内存优化（延迟加载到首帧后）
1. `lib/main.dart`：runApp 后不再立即 `await appState.init` 阻塞——改 runApp 先跑 splash，首帧回调里再 init；`_preloadFonts`/`_precacheWallpaper` 已有延后逻辑，壁纸解码改为「进入主界面且壁纸非空时才解码，否则跳过」。
2. `lib/app.dart` `_prewarmPages`：移动端不再 4 页全常驻——只常驻当前页 + 相邻 1 页，其余首次点击再建（复用已有 LRU `_evictStalePages`，放开移动端豁免）；桌面端维持 2 页预热。
3. AppCard/玻璃：`liquid`/`blur` 的 BackdropFilter 面板在不可见页（IndexedStack 非当前 index）不渲染模糊（Offstage 或替换为纯色占位），降低首帧 GPU 纹理占用。
4. 壁纸：`wallpaperImageProvider` 已按物理分辨率缩放；增加「壁纸未设置时绝不触发解码」短路（`_precacheWallpaper` 已做，保留），并把 `_bgCache` 的 File.existsSync 移到 compute 外首帧后。

### D. 设置页分层重构
1. `settings_page.dart` `_buildTheme`（3920 行文件将瘦身）：把单卡片拆为多张分组卡——
   - 「主题模式」卡：暗色开关 + 主题色 + 动态取色
   - 「背景」卡：背景选择/不透明度（`_ThemeBackgroundSection` 独立成卡）
   - 「表面样式」卡：卡片样式 + 底部导航样式 + 药丸样式（3 个 _styleRow 归组）
   - 「画布」卡：画布背景下拉 + 逻辑门标准分段按钮
   每卡标题+图标，搜索关键词挂到对应 `_CardDef`。
2. `ai_settings_mobile.dart` `MobileAiAdvancedPage`：同样拆为「图生成」「会话」「提示词」三张卡。

### E. 菜单动画与宽度修复
1. **统一动画**：给 `showMenu`/`PopupMenuButton` 建一个共享封装（新文件 `lib/widgets/animated_popup.dart`），用 `MenuAnchor`+`AnimationStyle`（或 PopScope+ScaleTransition）提供 150ms 淡入+缩放动画；替换 pipeline_editor `_showCanvasMenu`/`_showNodeMenu` 与 config_library 的菜单。
2. **卡片样式右侧菜单过大**：`_styleRow` 的 DropdownMenu 加 `menuHeight: 260` 已做，再补 `menuStyle: MenuStyle(fixedSize: WidgetStatePropertyAll(Size(200, double.nan)))` 限制展开面板宽度；整体下拉宽度由 170 调整为自适应内容+上限 200。
3. **PC 菜单宽度极大**：`app_theme.dart` `popupMenuTheme` 新增 `constraints: BoxConstraints(maxWidth: 280)`；`menuAnchorTheme` 加同样约束；pipeline_editor 内嵌 `PopupMenuButton` 的 `offset` 由 `Offset(200,0)` 改为基于父菜单宽度计算，且自身加 `constraints` 上限。

### F. AI 相关
1. **图生成模式改下拉**：`ai_settings_mobile.dart:783` 的 SegmentedButton 改为 `DropdownMenu<String>`（redo/modify 两项），与设置页风格一致；桌面端 `_buildMcpAi` 内同款控件同步替换。
2. **API 提供商设置页重构**（`ai_settings_mobile.dart` 的 `MobileAiProviderDetailPage` + 桌面 `_buildMcpAi` 对应部分）：
   - 扩展 `AiProfile` 模型（models.dart）：新增 `group`(分组)、`multiKeyEnabled`(多Key模式)、`apiKeys`(List<String>)、`useResponsesApi`(Response API)、`proxyUrl`(网络代理)、`customHeaders`(自定义请求 Map)、`apiPath`(API 路径)、`modelCapabilities`(Map<model,List<capability>>)。fromJson/toJson 向后兼容（缺省字段给默认值）。
   - 详情页改为分区卡片：「基本信息」(名称/分组/启用)、「连接」(供应商类型/协议/API Base URL/API 路径/API Key + 多Key 展开)、「请求」(Response API 开关/自定义请求头/网络代理)、「模型」独立 Tab——含「获取模型列表」按钮（复用 listAiModels）、「添加新模型」按钮、每模型能力 chips（视觉/工具/推理 等，FilterChip 组）。
   - 保留「获取账户余额」入口（调供应商 billing API，OpenAI `/dashboard/billing/credit_grants` 或通用 ping 扩展），失败时降级提示。
3. UI 遵循现有 AppCard/MobileSubPageTopBar 风格，不照抄截图。

### G. MCP 服务修 bug（保留内嵌实现）
`app_state.dart` 2459-2903 修复：
1. `_handleMcpRequest`：`id == null`（通知类如 `notifications/initialized`）直接 202 无 body 返回，不写 JSON-RPC 响应。
2. 新增 `ping` case 返回 `{}`；新增 `logging/setLevel` 最小实现（可选）。
3. `shutdown()`：`stopMcpServer` 改为 `_mcpServer!.close(force: true)` 强制断开进行中连接。
4. `_mcpToolsList`：给每个 tool 的 inputSchema 补 `additionalProperties: false` 与更完整字段描述；resources/list 与 tools/list 支持 `cursor` 参数占位（当前数据量小，返回空 cursor 即可，保证协议兼容）。
5. 错误统一：`tools/call` 业务失败除 isError 外，文本前缀 `Error:`（已做，保持）。

### H. 附带（build-mcp 技能验证项）
按 build-mcp 的 Phase 3 安全方式验证 MCP：写一次性 dart 脚本 `Process.start` 拉起 server、`timeout` 后 terminate，发 initialize/tools.list/ping/notification 验证回包。本批以代码修复为主，验证脚本放 `test/mcp_smoke_test.dart`。

---

### 影响文件清单
- `.github/workflows/build-release.yml`（Android job 重建 ffmpeg）
- `build/android/build_ffmpeg.sh`、`build/android/build_apk.sh`（验收守卫）
- `lib/main.dart`、`lib/app.dart`（内存/标题栏）
- `windows/runner/win32_window.cpp`（标题栏运行期防御）
- `lib/pages/settings_page.dart`（拆卡瘦身）
- `lib/pages/ai_settings_mobile.dart`（图生成下拉 + 提供商页重构）
- `lib/models/models.dart`（AiProfile 扩展）
- `lib/pages/pipeline_editor_page.dart`、`lib/pages/config_library_page.dart`（菜单动画/宽度，CSD 守卫）
- `lib/widgets/app_card.dart`、`lib/theme/app_theme.dart`（菜单约束/玻璃懒渲染）
- `lib/services/quick_config_pipeline.dart`（移动端默认硬编）
- `lib/providers/app_state.dart`（MCP bug 修复）
- 新增 `lib/widgets/animated_popup.dart`（共享菜单动画）
- `test/mcp_smoke_test.dart`（MCP 冒烟）

### 不做
- 不直接在本机交叉编译 Android 二进制（你用 Action 跑）。
- 不重写 MCP 为独立文件（保持 app_state 内嵌，仅修 bug）。
- 不改变现有 AI 聊天功能逻辑，仅改设置 UI 与数据模型。