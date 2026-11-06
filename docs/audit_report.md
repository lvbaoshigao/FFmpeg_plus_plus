# FFmpeg++ 代码审计与 Linux 图标集成报告

日期：2026-11-06　范围：`ffmpegpp_gui/`（Flutter/Dart）、`server_cpp/`（C++ FFI 后端）、`linux/` 打包

---

## 一、结论摘要

| 级别 | 数量 | 状态 | 说明 |
|---|---|---|---|
| High | 2 | 已修复 | AI 凭据恢复失败会连带阻断整个后端启动；配置落盘一次失败后永久失效 |
| Medium | 3 | 2 项待修 / 1 项已修复 | 会话历史非原子写、更新包可无校验安装；Linux 图标与桌面条目缺失（已修复） |
| 已修复 | 4 | — | Linux 图标集成与打包中的三个实测缺陷，见第三节 |

审计方法：逐文件阅读 + 关键路径交叉验证。未实际运行验证的推测会显式标注 **待确认**。

---

## 二、缺陷清单

### [High·已修复] H-1 AI 凭据损坏会导致后端 / FFmpeg / MCP 全部不启动

- 位置：`ffmpegpp_gui/lib/services/ai_credential_store.dart:27-32`、`ffmpegpp_gui/lib/services/config_service.dart:49`、`ffmpegpp_gui/lib/providers/app_state.dart:344`
- 触发条件：安全存储里某条 profile 记录不是合法 JSON 对象（旧版本格式变更、写入中断、字段类型不符）。
- 后果链：
  1. `AiCredentialStore.restore` 中 `jsonDecode` 或 `as String?` 类型转换抛 `FormatException` / `TypeError`；
  2. `ConfigService.load()` 只在“读配置文件”那一段有 try/catch，第 49 行 `await AiCredentialStore.restore(_config)` 无保护，异常继续上抛；
  3. `AppState._initInternal` 的第一条语句就是 `await configService.load()`（第 344 行），异常直接中断该方法——**350-386 行全部不执行**：后端进程不启动、任务队列不恢复、日志监听不挂、MCP 服务不启动；
  4. 用户看到主界面正常，但所有视频处理功能不可用，只剩一行“初始化失败”日志。
- 修复建议：`restore` 内部逐条 try/catch，坏记录删除后继续；`ConfigService.load()` 对凭据恢复单独兜底，保证凭据问题不阻断配置加载。

### [High·已修复] H-2 配置保存失败一次后，后续所有保存被静默放弃

- 位置：`ffmpegpp_gui/lib/services/config_service.dart:53-72`（`save()`）
- 触发条件：任一时刻写盘失败——磁盘满、目录只读、权限变更、杀软锁文件。
- 原因：
  - 第 56 行在真正写盘前就把 `_dirty = false`；
  - 第 58-62 行 `final prev = _saveInFlight; await prev;` **没有 try/catch**：前一次写盘 Future 已失败时，本次 `save()` 立刻抛出，永远走不到后面的 `writeAsString`；
  - `_saveInFlight` 从不重置，失败的 Future 长期串在链头。
- 后果：一次失败后，本会话内所有设置改动（主题、快捷键、AI 配置、MCP 开关）都不再落盘，退出时 `flush()` 也救不回来；重启后改动全丢且无提示。
- 修复建议：`await prev` 包 try/catch（失败只记日志）；`_dirty = false` 移到写盘成功之后；finally 中按引用相等清空 `_saveInFlight`。

### [Medium] M-1 AI 会话历史非原子写入，崩溃即丢整段会话

- 位置：`ffmpegpp_gui/lib/services/ai_chat_history.dart:77-79`
- 触发条件：保存过程中进程被杀 / 断电 / 磁盘错误。
- 后果：`session_<ts>.json` 被截断成半截 JSON；`listSessions()` 对单文件异常是 catch 后跳过的（第 99 行起），该会话**静默消失**，用户只发现“刚才的对话没了”。
- 修复建议：写 `*.json.tmp` 后 rename 覆盖，保证原子性。

### [Medium] M-2 更新包在缺少校验信息时仍可被直接安装执行

- 位置：`ffmpegpp_gui/lib/services/update_service.dart:341-352`、`:364-387`
- 触发条件：GitHub release 未提供同名 `.sha256` 资产（`downloadSha256` 为 null），或服务端未返回 Content-Length（`total == -1`，第 341 行长度校验被跳过）。
- 后果：完整性校验整体失效，下载后直接 `pkexec dpkg -i`（Linux，379-383 行）或 `Process.start`（Windows/macOS）执行。虽已强制 https，但缺发布侧校验时仍属无验证执行。
- 修复建议：无 sha256 时至少校验扩展名/魔数与平台匹配，或在 UI 明示“未校验”并要求二次确认。

### [Medium·已修复] M-3 Linux 版此前没有应用图标与桌面条目

- 现状（修复前）：`linux/` 仅有默认引导；`APPLICATION_ID` 已定义但从未注册图标，任务栏/Dock/Alt-Tab 显示占位图；也没有 `.desktop`，安装后无法从应用菜单启动。
- 已修复，见第三节。

---

## 二·补 已实施修复

### H-1 修复（`ai_credential_store.dart`）
- 安全存储整体读失败（keyring / DBus 不可用）时降级为“无已存凭据”，不再抛出；
- 单条 profile 记录解析失败时删除该条并继续，不影响其他 profile；
- 写入 / 删除统一走不抛异常的 `_writeSafely` / `_deleteSafely`，`save()` 内的 `readAll` 清理也加了兜底。

### H-2 修复（`config_service.dart`）
- `await prev` 包 try/catch：前一次写盘失败只记日志，不再阻断后续写盘；
- `_dirty` 只在写盘**成功后**且期间没有新改动才清除（新增 `_editGeneration` 代次比较）；
- `_saveInFlight` 在 finally 中按引用相等清空，失败的 Future 不再长期挂在链头。

### 验证
- `dart analyze` 对两个文件仅剩 5 条“第三方包路径不存在”的报错（本机 pub cache 缺失导致的既有环境问题），无新增语法 / 类型错误。

### M-1 修复（`ai_chat_history.dart`）——会话历史原子写
- 先序列化到内存，再写同目录 `<目标>.tmp`（`flush: true`），最后 rename 替换；
- POSIX 用 rename 覆盖（原子）；Windows 退化为 `rename 目标→.bak` → `rename tmp→目标` → 删 `.bak`，旧内容始终可回滚；
- 任何失败路径都清理 `.tmp`，返回 null 且不破坏旧会话；`listSessions` 只认 `.json`，不会把半截文件当会话。

### M-2 修复（`update_service.dart`）——更新包完整性
- 新增 `downloadUpdateWithResult`（旧 `downloadUpdate` 签名保留，等价取 `.path`）；
- 有 `.sha256`：比对通过 → verified=true，不一致删除文件并报错；
- 无 `.sha256`：至少校验「非空 + 扩展名与本平台匹配」（.deb/.AppImage | .exe | .dmg | .apk），不通过即删除并抛错；通过则 verified=false + warning，UI 已提示“未做完整性校验”；
- `Content-Length == -1`（chunked）：记录告警但不中断下载，由哈希/基础校验兜底。

## 二·补二 本轮 Agent 与 UI 修复

### 1. 选择「下拉菜单外观」后控件不刷新（根因）
`settings_page.dart` 的 `Selector<AppState,int>` 用 `Object.hashAll([...])` 做重建签名，但**漏了 `config.dropdownAppearance`**：选完配置写进去了，页面不重建，`_optionRow` 仍把旧值下发，于是下拉框显示旧选项。已把该字段加入签名（与 `mobileBottomActionSide` / 字重等“漏字段”同一条根因）。

### 2. 四种下拉外观“看起来一样”
`option_menu_bar.dart` 的 `_menuPanelShell` 原先把四档透明度挤在 190~230、着色也极淡，实际观感几乎一致。现按「越来越实、着色越来越重、描边越来越亮」拉开梯度（blur 20/14/12/0，surface alpha 150/206/224，primary tint 30/74/44，border 中性→主色由淡到亮）。同时 `ScaleMenuButton` 里写死的 `appearance: 'theme'` 改为读取 `config.dropdownAppearance`。

### 3. Agent 长对话 / 莫名中断（`pipeline_editor_page.dart`）
- **发送被拒**：原逻辑「窗口 - 输出预算 - 系统提示 - 本轮输入 < 0」就直接弹提示拒绝发送，长对话/大画布下会突然发不出去。改为先压输出预算（下限 256）→ 再丢历史 → 只有本轮输入本身超窗才拒绝；
- **看门狗掐断**：SDK 整条请求超时 5 分钟，长回答/推理模型/工具轮后续写很容易超时，用户看到的就是“自己中断了”。放宽到 20 分钟；
- **错误文案**：任何异常都写「（已中断）请求失败」，误导用户。新增 `_aiFailureNote`，按超时 / 限流 429 / 连接中断 / 鉴权失败 / 其它 分类说明，并保留已生成内容。

### 4. 会话统计不准
- 消息里只存「最后一轮」的用量，多轮工具调用 / 续写轮的消耗在重载会话后丢失；现在把会话累计值随历史存进 JSON（`total_in` / `total_out`），加载时优先用累计值，旧文件回退按消息求和；
- 停止 / 失败路径原先不累计 token（统计凭空变少），现已在两条路径补上；
- `usage` 字段可能是 `num`，统一 `.toInt()` 后再累加，避免类型/精度问题。

### 5. PC 端会话过宽
桌面端气泡宽度原为「可用宽度 × 80%」，宽面板（独立窗口 / 大屏）下每行长达数百字符。新增桌面端 1000px 可读行宽上限（移动端仍按比例），正文不再横跨整屏。

### 验证
- `dart analyze` 五个改动文件：仅剩“第三方包不存在”类环境报错，无新增语法/类型错误；
- `git diff --check` 通过（`update_service.dart` 的 CRLF 已归一为 LF）。

## 三、Linux 应用图标集成（已完成并实测）

### 改动文件

| 文件 | 作用 |
|---|---|
| `ffmpegpp_gui/linux/runner/icons/hicolor/{16,22,24,32,48,64,128,256,512}/apps/com.ffmpegpp.gui.png` | 9 档尺寸图标集，源图为已有 `rele/icon.png`（256×256 RGBA，与 `make/FFmpeg++.png` 字节一致） |
| `ffmpegpp_gui/linux/runner/my_application.cc` | 窗口图标：注册主题搜索路径 + `gtk_window_set_icon_name` + `gtk_window_set_icon_from_file`；dev 模式回退源码树 |
| `ffmpegpp_gui/linux/runner/CMakeLists.txt` | 注入 `APP_ICON_SOURCE_DIR` 供 dev 模式查找 |
| `ffmpegpp_gui/linux/CMakeLists.txt` | 安装 hicolor 图标树、生成 `.desktop`、安装启动器脚本 |
| `ffmpegpp_gui/linux/runner/ffmpegpp_launcher.sh.in` | 启动器：把 `XDG_DATA_DIRS` 指向 bundle 内 `share`，保证桌面按图标名解析成功 |

### 实测验证结果

```text
# 1) 图标确实写进了窗口（X11 _NET_WM_ICON，按 32 位 cardinal 读取）
_NET_WM_ICON(CARDINAL) = 256, 256, 0, 0, ...      → 256×256 像素数据存在

# 2) 桌面条目合法、无警告
desktop-file-validate .../ffmpegpp_gui.desktop    → VALIDATE_OK

# 3) 图标主题可建索引缓存
gtk-update-icon-cache -f -t share/icons/hicolor    → 生成 icon-theme.cache

# 4) 应用能在 bundle 内正常启动（后端 DLL 加载并 ready）
[init] 3-calling pythonProcess.start(.../lib/libffmpegpp.so)
[init] 6-ready result: ready
```

### 过程中修掉的三个真实缺陷

1. **启动器路径错误**：初版用 `$SELF_DIR/..` 定位 bundle 根，而启动器本就位于 bundle 根，实测报 `exec ... not found`，应用完全起不来。已改为 `$SELF_DIR`。
2. **图标路径多了一级 `../`**：`my_application.cc` 原先拼 `exe_dir + "/../share/icons"`，但 bundle 里二进制与 `share/` 同级，路径永远命中不了，窗口图标为空。已修正。
3. **GTK 版本 API 用错**：用了 GTK4 的 `g_icon_theme_*`，本项目是 GTK3（3.24.49），编译直接失败。已改为 `gtk_icon_theme_append_search_path`。

> 注：`_NET_WM_ICON` 最初读出来像“空”，是因为 `xprop` 不知道属性类型时打印空串；加 `-f _NET_WM_ICON 32c` 后可见完整数据。该误判已在验证脚本中修正。

---

## 四、环境限制（影响验证范围）

1. 本机 Flutter SDK 位于只读挂载（`/mnt/devtools/apps/flutter`），`bin/flutter` 因无法写 `bin/cache/engine.stamp` 而以退出码 1 结束；`flutter build` / `flutter analyze` / `flutter test` 在本环境不可用。
2. `~/.pub-cache` 已不存在，`linux/flutter/ephemeral/.plugin_symlinks/*` 全部悬空，重新 CMake 配置会因缺插件目录而失败。因此图标验证是通过**直接 `cmake --build` + `cmake --install`**（复用此前生成的 ephemeral 产物）完成的；`.desktop` 新文案另用最小 CMake 工程单独验证了生成逻辑。
3. 未在本环境跑通的：`flutter test` 全量回归。建议在具备完整 SDK + pub cache 的机器上补跑 `flutter test` 与 `flutter build linux --release`。

---

## 五、后续建议

1. ~~优先修 H-1、H-2~~ —— 已修复（见“二·补”）。
2. M-1 改原子写，成本极低，建议尽快做。
3. 上架 Flathub/AppImage 时建议补 `StartupWMClass=ffmpegpp_gui`（当前 WM_CLASS 为 `ffmpegpp_gui`/`Ffmpegpp_gui`），避免任务栏出现重复图标。
