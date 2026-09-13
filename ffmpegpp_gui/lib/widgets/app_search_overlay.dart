// ═══════════════════════════════════════════
// 全应用搜索浮层（「像搜索引擎一样」的搜索体验）
//
// 设计目标
// --------
// 1) 一个文件自带数据源、查询与 UI：设置项 / 页面导航 / 项目文件 / 容器 /
//    快捷配置 / 快捷键，六类结果统一成 [_Entry]，按分类分组展示。
// 2) PC 与移动端同一实现，由 [isMobilePlatform] 分叉：
//    - PC：居中浮层（宽 ~640、最高 ~70% 屏高），左侧结果列表 + 右侧概览面板
//      （选中项的详细描述 / 分类 / 操作提示）；↑↓ 选择、Enter 打开、Esc 关闭。
//    - 移动端：全屏浮层（顶部搜索框 + 结果列表），点击整条即跳转。
// 3) 性能：条目只在数据版本变化时构建一次并缓存，输入防抖 120ms，
//    查询阶段仅做 toLowerCase().contains，绝不在输入回调里重建条目。
//
// 为什么把数据源「镜像」在本文件里
// --------------------------------
// 设置页的 _sections / _CardDef 是 settings_page.dart 的私有成员，而本模块
// 不允许改动其它文件（且从 UI 结构里反向解析设置项与文案既脆弱又慢）。
// 因此这里抄一份**只读镜像常量表**（分区 id / 中英标题 / 卡片 id / 中英标题 /
// 关键字），与 settings_page.dart 的 _sections 同步维护；卡片 id 直接复用
// settings_page 的 _CardDef.id，跳转动作走 AppState.focusSettingsCard(cardId)。
// ═══════════════════════════════════════════

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app.dart' show smoothRoute;
import '../models/models.dart';
import '../pages/container_detail_page.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../services/quick_config_storage.dart';
import 'glass_panel.dart';

/// 打开全应用搜索浮层。
///
/// [context] 只需「任意可用的 context」（内部用 `context.read<AppState>()` 取状态），
/// 不需要预先订阅任何东西。浮层关闭后才会执行跳转动作 —— 这样跳转引发的页面
/// 重建 / 路由推入不会和浮层的退场动画抢同一帧，避免动画卡顿与路由叠加。
/// 项目页注册的「按文件名过滤」回调。
///
/// 由 ProjectPageState 在构建时注册（见 pages/project_page.dart）：全局搜索跳转到某个
/// 项目文件时，除了切到项目页，还把文件名回填到项目页搜索框，实现条目级定位。
/// 用回调注册而不是直接 import 项目页 —— 项目页已经 import 了本文件，反向 import
/// 会形成循环依赖。
void Function(String query)? onProjectSearchRequest;

Future<void> showAppSearch(BuildContext context) async {
  final AppState state = context.read<AppState>();
  final bool isZh = state.config.language == 'zh';

  // 快捷配置只存在磁盘上（QuickConfigStorage 只有异步 API），因此在打开浮层前
  // 读一次并缓存；不放进条目构建/输入回调里，避免每次按键触发 IO。
  await _ensureQuickConfigsLoaded();
  if (!context.mounted) return;

  final List<_Entry> entries = _entriesOf(state, isZh);

  // showGeneralDialog 是 PopupRoute（opaque == false），浮层下方的应用界面仍在
  // 渲染树上 —— 移动端/PC 的 GlassPanel 液态玻璃才有真实背景可采样。
  final _Entry? picked = await showGeneralDialog<_Entry>(
    context: context,
    barrierDismissible: true,
    barrierLabel: isZh ? '关闭搜索' : 'Close search',
    // 半透明遮罩：PC 略淡（保留对底层的判断），移动端略深（强调全屏浮层）。
    barrierColor: Colors.black.withAlpha(isMobilePlatform ? 150 : 110),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, _) =>
        _AppSearchOverlay(entries: entries, isZh: isZh),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final faded = FadeTransition(opacity: curved, child: child);
      // 移动端从顶部滑入（贴合「下拉搜索」的心智模型）；PC 轻微放大淡入。
      if (isMobilePlatform) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.03),
            end: Offset.zero,
          ).animate(curved),
          child: faded,
        );
      }
      return ScaleTransition(
        scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
        child: faded,
      );
    },
  );

  if (picked == null) return;
  if (!context.mounted) return;
  // 浮层已关闭 → 再执行动作（设置项聚焦 / 切页 / 推容器详情页）。
  picked.onActivate(context, state);
}

// ═══════════════════════════════════════════
// 结果分类
// ═══════════════════════════════════════════

/// 结果分类。[_Entry] 的添加顺序必须与这里的声明顺序一致
/// （分组渲染按枚举顺序输出，键盘上下移动的下标就取自这个顺序）。
enum _Cat {
  nav(Icons.explore_outlined, '页面', 'Pages'),
  settings(Icons.tune, '设置', 'Settings'),
  projects(Icons.movie_outlined, '项目', 'Projects'),
  containers(Icons.folder_copy_outlined, '容器', 'Containers'),
  quickConfigs(Icons.bolt_outlined, '快捷配置', 'Quick configs'),
  shortcuts(Icons.keyboard_outlined, '快捷键', 'Shortcuts');

  const _Cat(this.icon, this.zh, this.en);

  final IconData icon;
  final String zh;
  final String en;

  String label(bool isZh) => isZh ? zh : en;
}

/// 一条搜索结果。所有字段都在构建时算好（含 [searchText]），
/// 查询阶段只做 contains —— 输入回调里没有任何字符串拼接。
class _Entry {
  final String id;
  final _Cat cat;
  final IconData icon;

  /// 主标题（当前语言）。
  final String title;

  /// 面包屑 / 分类路径（如「设置 › 外观」）。
  final String breadcrumb;

  /// 一句话摘要：标题命中时作为「命中摘要」展示。
  final String summary;

  /// 概览面板里的详细描述。
  final String detail;

  /// 操作提示（如「打开设置 › 外观」）。
  final String hint;

  /// 关键字：既参与匹配，也可作为命中摘要展示（保留原大小写以便展示）。
  final List<String> keywords;

  /// 只参与匹配、不展示的补充文本（文件路径、内部 id、双语文案等）。
  final List<String> extra;

  /// 跳转动作。用 (context, state) 而非闭包捕获 context/state：
  /// 条目是跨帧缓存的，缓存里不能抓着可能失效的 context。
  final void Function(BuildContext context, AppState state) onActivate;

  _Entry({
    required this.id,
    required this.cat,
    required this.icon,
    required this.title,
    required this.breadcrumb,
    required this.summary,
    required this.detail,
    required this.hint,
    required this.keywords,
    required this.onActivate,
    this.extra = const <String>[],
  });

  /// 预拼的匹配文本（全小写）：标题 + 面包屑 + 摘要 + 关键字 + 补充文本。
  /// 用 late final 而非构造函数初始化列表，避免访问初始化形参的限制。
  late final String searchText = _joinSearchText(
      <String>[title, breadcrumb, summary, ...keywords, ...extra]);
}

String _joinSearchText(List<String> parts) {
  final buf = StringBuffer();
  for (final p in parts) {
    if (p.isEmpty) continue;
    if (buf.isNotEmpty) buf.write('\u0001'); // 分隔符：避免跨字段拼接产生假命中
    buf.write(p.toLowerCase());
  }
  return buf.toString();
}

// ═══════════════════════════════════════════
// 条目构建与缓存
// ═══════════════════════════════════════════

/// 条目缓存。null = 尚未构建。[_cacheSignature] 变化（语言 / 媒体库 / 容器 /
/// 快捷配置 / 快捷键 / 调试开关变动）时才重建 —— 既满足「构建一次」的性能要求，
/// 又不会在用户导入文件后搜索到过期的条目。
List<_Entry>? _cache;
int? _cacheSignature;

/// 快捷配置的内存快照（磁盘读取只做一次）。
List<QuickConfig> _quickConfigs = const <QuickConfig>[];
bool _quickConfigsLoaded = false;

Future<void> _ensureQuickConfigsLoaded() async {
  if (_quickConfigsLoaded) return;
  // 先置位再 await：并发打开浮层时不会重复读盘。
  _quickConfigsLoaded = true;
  try {
    _quickConfigs = await QuickConfigStorage.loadAll(null);
  } catch (_) {
    // 目录不存在 / 权限异常 / 单文件解析失败都走这里：退化为「无快捷配置」，
    // 不影响其它五类结果的可用性（也不重试，避免每次打开都撞同一个错误）。
    _quickConfigs = const <QuickConfig>[];
  }
  _cache = null; // 数据源已变化 → 让条目缓存失效
}

/// 取条目列表：签名一致就复用缓存，否则重建一次。
List<_Entry> _entriesOf(AppState state, bool isZh) {
  final int signature = Object.hash(
    isZh,
    state.videos.length,
    // 只看 length 的话「删一个再加一个」或重命名后条目内容会过期（长度不变），
    // 所以把 id 也纳入签名（仅在打开浮层时算一次，成本 O(n)）。
    Object.hashAll(state.videos.map((v) => v.id)),
    state.containers.length,
    Object.hashAll(state.containers.map((c) => c.name)),
    _quickConfigs.length,
    // 快捷键的「按键组合」会原地修改（重新绑定后长度不变），必须参与签名，
    // 否则条目里的按键文本会停在旧值。
    Object.hashAll(state.config.keyBindings.values.map((v) => v.join('+'))),
    state.config.debugMode,
  );
  if (_cache != null && _cacheSignature == signature) return _cache!;
  _cache = _buildEntries(state, isZh);
  _cacheSignature = signature;
  return _cache!;
}

List<_Entry> _buildEntries(AppState state, bool isZh) {
  final List<_Entry> out = <_Entry>[];
  // 顺序 = _Cat.values 顺序（分组渲染依赖这一点）。
  out.addAll(_navEntries(state, isZh));
  out.addAll(_settingsEntries(isZh));
  out.addAll(_videoEntries(state, isZh));
  out.addAll(_containerEntries(state, isZh));
  out.addAll(_quickConfigEntries(isZh));
  out.addAll(_shortcutEntries(state, isZh));
  return out;
}

// ── 页面导航 ──
//
// 平台差异与 app.dart 的页面索引表保持一致（0=项目 1=队列 2=命令 3=配置库
// 4=设置 5=日志）：
// - 移动端底部导航只有 项目/队列/配置库/设置 四项，且没有日志页；
//   移动端的「命令」「日志」入口在设置页的「工具」分区里（见 _settingsMirror），
//   所以这里不生成对应条目，避免出现跳过去也无法抵达的项。
// - 桌面端「日志」页仅在调试模式开启时存在（sidebar 按 debugMode 决定是否显示）。
List<_Entry> _navEntries(AppState state, bool isZh) {
  final List<_Entry> out = <_Entry>[];

  void add({
    required int index,
    required IconData icon,
    required String title,
    required String summary,
    required String detail,
    required List<String> keywords,
  }) {
    out.add(_Entry(
      id: 'nav:$index',
      cat: _Cat.nav,
      icon: icon,
      title: title,
      breadcrumb: isZh ? '页面' : 'Page',
      summary: summary,
      detail: detail,
      hint: isZh ? '跳转到该页面' : 'Switch to this page',
      keywords: keywords,
      onActivate: (_, AppState st) => st.selectNav(index),
    ));
  }

  add(
    index: 0,
    icon: Icons.movie_outlined,
    title: isZh ? '项目' : 'Projects',
    summary: isZh ? '媒体库：导入的文件与容器' : 'Media library: imported files and containers',
    detail: isZh
        ? '项目页是应用的主入口：导入视频/图片/音频、创建容器、进入节点编辑器或把文件加入处理队列。'
        : 'The Projects page is the main entry: import media, create containers, open the node editor or queue files.',
    keywords: isZh
        ? <String>['项目', '视频', '媒体库', '文件', '导入', '容器']
        : <String>['projects', 'videos', 'media', 'files', 'import', 'library'],
  );
  add(
    index: 1,
    icon: Icons.list_alt_outlined,
    title: isZh ? '处理队列' : 'Queue',
    summary: isZh ? '转码任务队列与进度' : 'Transcode task queue and progress',
    detail: isZh
        ? '查看所有已入队任务的进度、速度与剩余时间，开始/停止处理，打开输出文件。'
        : 'Watch progress, speed and ETA of queued tasks, start/stop processing and open outputs.',
    keywords: isZh
        ? <String>['队列', '任务', '进度', '处理', '转码', '开始', '停止']
        : <String>['queue', 'tasks', 'progress', 'processing', 'transcode', 'start', 'stop'],
  );
  if (!isMobilePlatform) {
    add(
      index: 2,
      icon: Icons.terminal_outlined,
      title: isZh ? '命令' : 'Command',
      summary: isZh ? '自定义 FFmpeg 命令' : 'Custom FFmpeg commands',
      detail: isZh
          ? '直接编写并执行自定义 FFmpeg 命令，可保存为模板复用（移动端该入口在 设置 › 工具 › 命令）。'
          : 'Write and run custom FFmpeg commands, savable as templates (on mobile: Settings › Tools › Command).',
      keywords: isZh
          ? <String>['命令', '终端', '执行', '模板', '命令行']
          : <String>['command', 'terminal', 'run', 'template', 'cli'],
    );
  }
  add(
    index: 3,
    icon: Icons.folder_copy_outlined,
    title: isZh ? '配置库' : 'Configs',
    summary: isZh ? '节点图配置与快捷配置' : 'Saved node graphs and quick configs',
    detail: isZh
        ? '集中管理保存过的节点编辑器配置与快捷配置（可导入/导出/编辑）。'
        : 'Manage saved node-editor graphs and quick configs (import/export/edit).',
    keywords: isZh
        ? <String>['配置', '配置库', '快捷配置', '预设', '模板', '导入', '导出']
        : <String>['config', 'configs', 'library', 'quick', 'preset', 'template', 'import', 'export'],
  );
  add(
    index: 4,
    icon: Icons.settings_outlined,
    title: isZh ? '设置' : 'Settings',
    summary: isZh ? '应用的全部设置项' : 'All application settings',
    detail: isZh
        ? '外观、处理、编辑器、AI 与 MCP、高级选项与关于信息。搜索设置项会直接定位到对应卡片。'
        : 'Appearance, processing, editor, AI & MCP, advanced options and about. Settings hits jump straight to the card.',
    keywords: isZh
        ? <String>['设置', '偏好', '选项', '配置']
        : <String>['settings', 'preferences', 'options', 'config'],
  );
  if (!isMobilePlatform && state.config.debugMode) {
    add(
      index: 5,
      icon: Icons.receipt_long_outlined,
      title: isZh ? '日志' : 'Logs',
      summary: isZh ? '运行日志与 ffmpeg 输出' : 'Runtime logs and ffmpeg output',
      detail: isZh
          ? '查看后端/ffmpeg 的实时输出，用于排查探测与转码问题（移动端该入口在 设置 › 工具 › 日志）。'
          : 'Inspect backend/ffmpeg output for probing and transcoding issues (on mobile: Settings › Tools › Logs).',
      keywords: isZh
          ? <String>['日志', '输出', '调试', '进度', '错误']
          : <String>['logs', 'log', 'output', 'debug', 'progress', 'error'],
    );
  }
  return out;
}

// ── 设置项 ──
//
// 【与 settings_page.dart 的 _sections 同步维护】
// 只镜像「可被全局搜索跳转」的要素：分区（面包屑用）、卡片 id（跳转用）、
// 中英标题、关键字（提升召回率）。平台可见性也照抄 settings_page 的条件：
// ffmpeg/shortcuts 仅桌面端、predictiveBack 仅 Android、command/logs 仅移动端、
// tools 分区仅移动端。否则会搜到一张目标平台上根本不存在的卡片，
// focusSettingsCard 只能无声失败。
List<_Entry> _settingsEntries(bool isZh) {
  final List<_Entry> out = <_Entry>[];
  for (final _SettingMirror m in _settingsMirror) {
    if (m.desktopOnly && isMobilePlatform) continue;
    if (m.mobileOnly && !isMobilePlatform) continue;
    if (m.androidOnly && !isAndroidPlatform) continue;
    final _SettingsSection? sec = _sectionOf(m.sectionId);
    final String secLabel = sec == null ? '' : (isZh ? sec.zh : sec.en);
    final String title = isZh ? m.titleZh : m.titleEn;
    final String desc = isZh ? m.descZh : m.descEn;
    final String crumb = secLabel.isEmpty
        ? (isZh ? '设置' : 'Settings')
        : "${isZh ? '设置' : 'Settings'} › $secLabel";
    out.add(_Entry(
      id: 'setting:${m.cardId}',
      cat: _Cat.settings,
      icon: m.icon,
      title: title,
      breadcrumb: crumb,
      summary: desc,
      detail: isZh
          ? '$desc。该设置项位于「$crumb」，打开后会定位并短暂高亮对应卡片。'
          : '$desc. Located under "$crumb"; opening it scrolls to and briefly highlights the card.',
      hint: isZh ? '打开 $crumb' : 'Open $crumb',
      keywords: m.keywords,
      // 分区中英标题也参与匹配：搜「外观」/「appearance」都能命中分区下的全部卡片。
      extra: <String>[
        m.cardId,
        m.titleZh,
        m.titleEn,
        if (sec != null) sec.zh,
        if (sec != null) sec.en,
      ],
      onActivate: (_, AppState st) => st.focusSettingsCard(m.cardId),
    ));
  }
  return out;
}

_SettingsSection? _sectionOf(String id) {
  for (final s in _settingsSections) {
    if (s.id == id) return s;
  }
  return null;
}

/// 设置分区（镜像 settings_page.dart 的 _SectionDef：id + 中英标题）。
class _SettingsSection {
  const _SettingsSection(this.id, this.zh, this.en);
  final String id;
  final String zh;
  final String en;
}

const List<_SettingsSection> _settingsSections = <_SettingsSection>[
  _SettingsSection('general', '通用', 'General'),
  _SettingsSection('appearance', '外观', 'Appearance'),
  _SettingsSection('processing', '处理', 'Processing'),
  _SettingsSection('editor', '编辑器', 'Editor'),
  _SettingsSection('tools', '工具', 'Tools'),
  _SettingsSection('ai', 'AI 与 MCP', 'AI & MCP'),
  _SettingsSection('advanced', '高级', 'Advanced'),
  _SettingsSection('about', '关于', 'About'),
];

/// 设置卡片镜像（id 与 settings_page.dart 的 _CardDef.id 一一对应）。
class _SettingMirror {
  const _SettingMirror({
    required this.sectionId,
    required this.cardId,
    required this.icon,
    required this.titleZh,
    required this.titleEn,
    required this.descZh,
    required this.descEn,
    required this.keywords,
    this.desktopOnly = false,
    this.mobileOnly = false,
    this.androidOnly = false,
  });

  final String sectionId;
  final String cardId;
  final IconData icon;
  final String titleZh;
  final String titleEn;
  final String descZh;
  final String descEn;
  final List<String> keywords;
  final bool desktopOnly;
  final bool mobileOnly;
  final bool androidOnly;
}

/// 【与 settings_page.dart 的 _sections 同步维护】关键字直接沿用设置页里的
/// keywords（用户在那里搜得到，这里也应搜得到）。
const List<_SettingMirror> _settingsMirror = <_SettingMirror>[
  _SettingMirror(
    sectionId: 'general',
    cardId: 'language',
    icon: Icons.translate,
    titleZh: '语言',
    titleEn: 'Language',
    descZh: '界面语言（中文 / English）',
    descEn: 'Interface language (Chinese / English)',
    keywords: <String>['语言', '界面', '中文', 'language', 'english', 'chinese',
        'interface', 'locale', 'i18n'],
  ),
  _SettingMirror(
    sectionId: 'appearance',
    cardId: 'theme',
    icon: Icons.brightness_6_outlined,
    titleZh: '主题',
    titleEn: 'Theme',
    descZh: '深色 / 浅色模式、主题色与渐变、动态取色',
    descEn: 'Dark / light mode, accent color and gradients, dynamic color',
    keywords: <String>['深色', '暗色', '浅色', 'dark', 'light', 'mode', '模式',
        '主题色', '强调色', '颜色', 'accent', 'color', 'theme',
        '动态取色', 'monet', 'dynamic', '渐变', 'gradient'],
  ),
  _SettingMirror(
    sectionId: 'appearance',
    cardId: 'background',
    icon: Icons.wallpaper_outlined,
    titleZh: '背景',
    titleEn: 'Background',
    descZh: '背景图片与不透明度',
    descEn: 'Wallpaper image and opacity',
    keywords: <String>['背景', '壁纸', 'background', 'wallpaper', '图片', 'image',
        '不透明度', 'opacity', '透明', 'alpha'],
  ),
  _SettingMirror(
    sectionId: 'appearance',
    cardId: 'surfaceStyle',
    icon: Icons.style_outlined,
    titleZh: '样式',
    titleEn: 'Style',
    descZh: '卡片 / 底部菜单栏 / 顶部药丸 / 菜单的表面样式',
    descEn: 'Surface style for cards, bottom nav, top pill and menus',
    keywords: <String>['样式', 'style', '卡片', 'card', '液态玻璃', 'liquid',
        '玻璃', 'glass', '模糊', 'blur', '灰色', 'gray',
        '底部', 'bottom', 'nav', '导航', '药丸', 'pill', '表面', 'surface',
        '菜单', 'menu', '侧边栏', 'sidebar', '顶栏', 'topbar', '顶部菜单'],
  ),
  _SettingMirror(
    sectionId: 'appearance',
    cardId: 'glassOptions',
    icon: Icons.water_drop_outlined,
    titleZh: '液态玻璃效果',
    titleEn: 'Liquid Glass',
    descZh: '折射强度、镜面高光、模糊半径与透明度',
    descEn: 'Refraction, specular highlight, blur radius and opacity',
    keywords: <String>['液态玻璃', '玻璃', '折射', '高光', '模糊', '透明度', '不透明度',
        '毛玻璃', '跟随主题色', 'glass', 'liquid', 'refract', 'specular',
        'blur', 'opacity', 'alpha', 'frosted', 'follow', 'gpu'],
  ),
  _SettingMirror(
    sectionId: 'appearance',
    cardId: 'nodeEditorStyle',
    icon: Icons.account_tree_outlined,
    titleZh: '节点编辑器',
    titleEn: 'Node editor',
    descZh: '画布背景、网格与逻辑门符号标准（ANSI / IEC）',
    descEn: 'Canvas background, grid and logic-gate symbol standard (ANSI / IEC)',
    keywords: <String>['节点编辑器', '画布', 'canvas', '背景', 'grid',
        '逻辑门', 'gate', 'ansi', 'iec', 'ieee', '符号', 'symbol'],
  ),
  _SettingMirror(
    sectionId: 'appearance',
    cardId: 'font',
    icon: Icons.text_fields,
    titleZh: '字体',
    titleEn: 'Font',
    descZh: '字体、字号与字重',
    descEn: 'Font family, size and weight',
    keywords: <String>['字体', '字号', '字重', 'font', 'size', 'weight',
        'typeface', '导入', 'import', '大小'],
  ),
  _SettingMirror(
    sectionId: 'processing',
    cardId: 'ffmpeg',
    icon: Icons.memory_outlined,
    titleZh: 'FFmpeg',
    titleEn: 'FFmpeg',
    descZh: 'ffmpeg / ffprobe 路径、安装与检测',
    descEn: 'ffmpeg / ffprobe paths, installation and detection',
    keywords: <String>['ffmpeg', 'ffprobe', '编码', 'codec', '安装', 'install',
        '检测', 'detect', '路径', 'path', '下载', 'download'],
    desktopOnly: true, // 移动端 ffmpeg/ffprobe 内置在 APK，设置页不展示该卡片
  ),
  _SettingMirror(
    sectionId: 'processing',
    cardId: 'output',
    icon: Icons.folder_outlined,
    titleZh: '输出',
    titleEn: 'Output',
    descZh: '输出目录与中间文件目录',
    descEn: 'Default output directory and intermediate directory',
    keywords: <String>['输出', '目录', '文件夹', 'output', 'directory', 'folder',
        '中间', 'intermediate', '临时', 'temp', 'path', '路径'],
  ),
  _SettingMirror(
    sectionId: 'processing',
    cardId: 'tasks',
    icon: Icons.playlist_play,
    titleZh: '任务',
    titleEn: 'Tasks',
    descZh: '并发任务数、探测线程与完成通知',
    descEn: 'Concurrent tasks, probe threads and completion notifications',
    keywords: <String>['任务', '并发', '同时', '线程', 'task', 'concurrent',
        'parallel', 'thread', '解析', 'probe', '通知', 'notification',
        '队列', 'queue'],
  ),
  _SettingMirror(
    sectionId: 'editor',
    cardId: 'editorMode',
    icon: Icons.account_tree_outlined,
    titleZh: '编辑模式',
    titleEn: 'Editor Mode',
    descZh: '默认编辑方式：节点编辑器 / 快速模式',
    descEn: 'Default editing mode: node editor / quick mode',
    keywords: <String>['编辑', '编辑器', '节点', '画布', '蓝图',
        'editor', 'node', 'canvas', 'blueprint', 'classic', 'mode', '模式'],
  ),
  _SettingMirror(
    sectionId: 'editor',
    cardId: 'shortcuts',
    icon: Icons.keyboard_outlined,
    titleZh: '快捷键',
    titleEn: 'Shortcuts',
    descZh: '查看与修改键盘快捷键',
    descEn: 'View and edit keyboard shortcuts',
    keywords: <String>['快捷键', '键位', '按键', '热键', 'shortcut', 'keybinding',
        'keyboard', 'hotkey', 'key'],
    desktopOnly: true, // 移动端无物理键盘，设置页隐藏该卡片
  ),
  _SettingMirror(
    sectionId: 'editor',
    cardId: 'autosave',
    icon: Icons.save_outlined,
    titleZh: '自动保存',
    titleEn: 'Autosave',
    descZh: '节点编辑器草稿自动保存与保存间隔',
    descEn: 'Node editor draft autosave and interval',
    keywords: <String>['自动保存', '草稿', '恢复', 'autosave', 'draft', 'auto',
        'save', '恢复'],
  ),
  _SettingMirror(
    sectionId: 'tools',
    cardId: 'command',
    icon: Icons.terminal,
    titleZh: '命令',
    titleEn: 'Command',
    descZh: '自定义 FFmpeg 命令入口',
    descEn: 'Entry to custom FFmpeg commands',
    keywords: <String>['命令', 'ffmpeg', 'command', 'terminal', '终端', '执行',
        'run', '模板', 'template'],
    mobileOnly: true, // 移动端把「命令」从底部导航移入设置
  ),
  _SettingMirror(
    sectionId: 'tools',
    cardId: 'logs',
    icon: Icons.receipt_long_outlined,
    titleZh: '日志',
    titleEn: 'Logs',
    descZh: '日志与进度输出入口',
    descEn: 'Entry to logs and progress output',
    keywords: <String>['日志', 'log', 'logs', '输出', 'output', '进度', 'progress',
        '调试', 'debug'],
    mobileOnly: true, // 同上：移动端把「日志」移入设置
  ),
  _SettingMirror(
    sectionId: 'ai',
    cardId: 'ai',
    icon: Icons.auto_awesome_outlined,
    titleZh: 'MCP / AI',
    titleEn: 'MCP / AI',
    descZh: 'AI 提供商、模型、密钥与 MCP 服务',
    descEn: 'AI provider, model, API key and MCP server',
    keywords: <String>['ai', 'mcp', '模型', 'model', 'api', 'key', 'token',
        'openai', 'anthropic', 'claude', 'gpt', '提示词', 'prompt',
        '权限', 'permission', '助手', 'assistant', '端口', 'port', '服务',
        '提供商', 'provider', 'deepseek', 'ollama'],
  ),
  _SettingMirror(
    sectionId: 'advanced',
    cardId: 'predictiveBack',
    icon: Icons.swipe_left_alt_outlined,
    titleZh: '预测式返回',
    titleEn: 'Predictive back',
    descZh: '侧滑返回时预览上一页',
    descEn: 'Preview the previous screen when swiping back',
    keywords: <String>['返回', '手势', '预测', '侧滑', 'back', 'gesture',
        'predictive', 'swipe', '返回动画', '系统', 'system'],
    androidOnly: true, // 仅 Android 端展示
  ),
  _SettingMirror(
    sectionId: 'advanced',
    cardId: 'preload',
    icon: Icons.shutter_speed_outlined,
    titleZh: '预加载',
    titleEn: 'Preload',
    descZh: '启动时是否预构建其它页面（启动速度 / 内存权衡）',
    descEn: 'Whether to prebuild other pages at startup (speed vs memory)',
    keywords: <String>['预加载', '预载', 'preload', '启动', 'startup', 'launch',
        '性能', 'performance', 'CPU', '内存', 'memory', '绘制', '渲染',
        'render', '加载', 'load'],
  ),
  _SettingMirror(
    sectionId: 'advanced',
    cardId: 'debug',
    icon: Icons.bug_report_outlined,
    titleZh: '调试',
    titleEn: 'Debug',
    descZh: '调试模式与日志保存',
    descEn: 'Debug mode and log saving',
    keywords: <String>['调试', '日志', '诊断', 'debug', 'log', 'logs',
        'verbose', 'diagnostic', '保存', 'save'],
  ),
  _SettingMirror(
    sectionId: 'advanced',
    cardId: 'cache',
    icon: Icons.cleaning_services_outlined,
    titleZh: '缓存',
    titleEn: 'Cache',
    descZh: '清除缩略图 / 帧预览等缓存数据',
    descEn: 'Clear thumbnail / frame-preview and other caches',
    keywords: <String>['缓存', '清除', '清理', '删除', 'cache', 'clear',
        'clean', 'cleanup', 'purge', 'reset'],
  ),
  _SettingMirror(
    sectionId: 'about',
    cardId: 'about',
    icon: Icons.info_outline,
    titleZh: '关于',
    titleEn: 'About',
    descZh: '版本、检查更新、许可与赞助',
    descEn: 'Version, update check, license and sponsorship',
    keywords: <String>['关于', '版本', '赞助', '捐赠', '许可', 'about', 'version',
        'sponsor', 'donate', 'license', 'github', 'blog', '作者', 'author',
        '更新', '升级', 'update', 'upgrade', '检查', 'check', '自动'],
  ),
];

// ── 项目文件 ──
List<_Entry> _videoEntries(AppState state, bool isZh) {
  final List<_Entry> out = <_Entry>[];
  for (final VideoFile v in state.videos) {
    final String name = v.filename.isNotEmpty
        ? v.filename
        : v.filepath.split(RegExp(r'[\\/]')).last;
    if (name.isEmpty) continue;
    final String meta = <String>[
      if (v.resolution.isNotEmpty) v.resolution,
      if (v.codec.isNotEmpty) v.codec,
      if (v.sizeMb > 0) '${v.sizeMb.toStringAsFixed(1)}MB',
    ].join(' · ');
    final String status =
        v.parsed ? (isZh ? '已解析' : 'parsed') : (isZh ? '待解析' : 'not parsed');
    final String statusMeta = "$status${meta.isEmpty ? '' : ' · $meta'}";
    out.add(_Entry(
      id: 'video:${v.id}',
      cat: _Cat.projects,
      icon: v.fileMediaType == MediaType.audio
          ? Icons.audiotrack_outlined
          : v.fileMediaType == MediaType.image
              ? Icons.image_outlined
              : Icons.movie_outlined,
      title: name,
      breadcrumb: "${isZh ? '项目' : 'Projects'} › $statusMeta",
      summary: isZh ? '项目中的媒体文件' : 'Media file in Projects',
      detail: isZh
          ? '$name（$statusMeta）。跳转会切换到项目页；全局搜索暂不支持在项目页内直接定位单条媒体，需要时可用项目页自带搜索。'
          : '$name ($statusMeta). Opening switches to Projects; the global search cannot focus a single item there yet.',
      hint: isZh ? '切换到项目页' : 'Go to Projects',
      keywords: <String>[
        name,
        if (v.format.isNotEmpty) v.format,
        if (v.codec.isNotEmpty) v.codec,
        if (v.resolution.isNotEmpty) v.resolution,
        v.fileMediaType.name,
        if (isZh) ...<String>['项目', '视频', '媒体', '文件'],
        if (!isZh) ...<String>['project', 'video', 'media', 'file'],
      ],
      extra: <String>[v.filepath, v.id],
      // 除了切到项目页，还把文件名回填到项目页的搜索框（见 onProjectSearchRequest），
      // 这样才是真正的「跳转到那一条」而不是仅仅切页。
      onActivate: (_, AppState st) {
        st.selectNav(0);
        onProjectSearchRequest?.call(name);
      },
    ));
  }
  return out;
}

// ── 容器 ──
List<_Entry> _containerEntries(AppState state, bool isZh) {
  final List<_Entry> out = <_Entry>[];
  for (final FileContainer c in state.containers) {
    if (c.name.isEmpty) continue;
    final String files = isZh
        ? '${c.fileCount} 个文件'
        : "${c.fileCount} file${c.fileCount == 1 ? '' : 's'}";
    out.add(_Entry(
      id: 'container:${c.id}',
      cat: _Cat.containers,
      icon: Icons.folder_copy_outlined,
      title: c.name,
      breadcrumb: "${isZh ? '容器' : 'Containers'} › $files",
      summary: isZh ? '容器：按顺序处理的文件集合' : 'Container: an ordered set of files',
      detail: isZh
          ? '「${c.name}」包含 $files。打开容器详情页可调整顺序、编辑容器专属节点图并批量入队。'
          : '"${c.name}" holds $files. Open the container page to reorder, edit its own graph and queue in bulk.',
      hint: isZh ? '打开容器详情' : 'Open container',
      keywords: <String>[
        c.name,
        if (isZh) ...<String>['容器', '文件夹', '批量', '合集'],
        if (!isZh) ...<String>['container', 'folder', 'batch', 'collection'],
      ],
      extra: <String>[c.id],
      // 与 container_card.dart 的 _enter 一致：smoothRoute + ContainerDetailPage。
      onActivate: (BuildContext ctx, AppState _) {
        Navigator.of(ctx, rootNavigator: true)
            .push(smoothRoute(ContainerDetailPage(containerId: c.id)));
      },
    ));
  }
  return out;
}

// ── 快捷配置 ──
//
// 数据源：QuickConfigStorage（只有异步 loadAll API，已在 showAppSearch 里预读缓存）。
// 动作说明：QuickConfigPage 是「编辑器对话框」，必须由配置库页回写其内存列表
// （配置库页只在 initState 里 loadAll 一次，没有对外刷新入口）。若在这里直接打开
// 编辑器，用户保存后配置库页会停留在旧数据，产生「改了但列表没变」的错觉；
// 因此这里只把用户带到配置库页（selectNav(3)），不做条目级定位（配置库页也没有
// 暴露定位接口），并在概览面板里写明。
List<_Entry> _quickConfigEntries(bool isZh) {
  final List<_Entry> out = <_Entry>[];
  for (final QuickConfig cfg in _quickConfigs) {
    final String name = cfg.name.isNotEmpty
        ? cfg.name
        : (isZh ? '未命名快捷配置' : 'Untitled quick config');
    final String type = cfg.fileType.label(isZh);
    final String items = isZh
        ? '${cfg.items.length} 个配置项'
        : "${cfg.items.length} item${cfg.items.length == 1 ? '' : 's'}";
    final String desc = cfg.description.isNotEmpty
        ? cfg.description
        : (isZh ? '快捷配置' : 'Quick config');
    out.add(_Entry(
      id: 'quick:${cfg.id}',
      cat: _Cat.quickConfigs,
      icon: Icons.bolt_outlined,
      title: name,
      breadcrumb: "${isZh ? '快捷配置' : 'Quick configs'} › $type · $items",
      summary: desc,
      detail: isZh
          ? '$desc（$type，$items）。跳转会打开配置库页的「快捷配置」标签；由于配置库页不暴露定位接口，这里不支持直接打开某一条的编辑器。'
          : '$desc ($type, $items). Opening lands on the config library; it cannot open a single editor because that page exposes no focus API.',
      hint: isZh ? '打开配置库' : 'Open config library',
      keywords: <String>[
        name,
        type,
        if (isZh) ...<String>['快捷配置', '预设', '模板', '配置'],
        if (!isZh) ...<String>['quick', 'config', 'preset', 'template'],
      ],
      extra: <String>[cfg.id, cfg.fileType.name],
      onActivate: (_, AppState st) => st.selectNav(3),
    ));
  }
  return out;
}

// ── 快捷键 ──
//
// 移动端没有物理键盘、设置页也不提供「快捷键」卡片 → 不生成该分类
// （与 _settingsMirror 里 shortcuts 的 desktopOnly 保持一致）。
// 动作：跳到 设置 › 编辑器 › 快捷键 卡片；因为 AppState 只暴露 focusSettingsCard，
// 无法直接定位到某一行快捷键，所以做到「卡片级定位」为止。
List<_Entry> _shortcutEntries(AppState state, bool isZh) {
  final List<_Entry> out = <_Entry>[];
  if (isMobilePlatform) return out;
  final Map<String, List<String>> bindings = state.config.keyBindings;
  for (final MapEntry<String, List<String>> e in bindings.entries) {
    final String actionId = e.key;
    final List<String> keys = e.value;
    final String label = _shortcutLabel(actionId, isZh);
    final String current = _formatKeys(keys, isZh);
    final List<String> defaults =
        AppConfig.defaultKeyBindings[actionId] ?? const <String>[];
    final String defText =
        defaults.isEmpty ? (isZh ? '无' : 'none') : _formatKeys(defaults, isZh);
    out.add(_Entry(
      id: 'key:$actionId',
      cat: _Cat.shortcuts,
      icon: Icons.keyboard_outlined,
      title: label,
      breadcrumb: isZh
          ? '快捷键 › 当前按键：$current'
          : 'Shortcuts › Current: $current',
      summary: isZh ? '当前按键：$current' : 'Current keys: $current',
      detail: isZh
          ? '「$label」当前绑定 $current，默认按键 $defText。跳转会打开「设置 › 编辑器 › 快捷键」卡片，在那里可以重新录制按键。'
          : '"$label" is bound to $current (default $defText). Opening it shows Settings › Editor › Shortcuts where you can re-record it.',
      hint: isZh ? '打开快捷键设置' : 'Open shortcut settings',
      keywords: <String>[
        label,
        ...keys,
        if (isZh) ...<String>['快捷键', '键位', '按键', '热键'],
        if (!isZh) ...<String>['shortcut', 'keybinding', 'key', 'hotkey'],
      ],
      extra: <String>[actionId],
      onActivate: (_, AppState st) => st.focusSettingsCard('shortcuts'),
    ));
  }
  return out;
}

/// 快捷键动作标签。前 11 项与 keybinding_page.dart 的 _actionLabelsZh /
/// _actionLabelsEn 保持一致（那两个 map 是私有的，无法直接引用）；
/// 末尾几项是页面里没有单独文案的导航类快捷键，这里补一份中英文案。
const Map<String, String> _shortcutLabelsZh = <String, String>{
  'project_select_all': '全选视频',
  'queue_add_all': '快速添加所有到队列',
  'queue_start_all': '快速开始所有任务',
  'project_clear_all': '删除所有项目',
  'queue_stop_all': '停止所有任务',
  'canvas_select_all': '选中所有元素',
  'canvas_delete_selected': '删除选中元素',
  'canvas_undo': '撤销',
  'canvas_redo': '重做',
  'canvas_probe_mode': '探测模式',
  'canvas_hide_logic': '隐藏逻辑部分',
  'nav_projects': '切换到项目页',
  'nav_queue': '切换到处理队列',
  'nav_command': '切换到命令页',
  'nav_settings': '切换到设置页',
  'project_search': '项目页内搜索',
  'canvas_pan_button': '画布平移（鼠标）',
  'canvas_select_button': '画布选择（鼠标）',
};

const Map<String, String> _shortcutLabelsEn = <String, String>{
  'project_select_all': 'Select All Videos',
  'queue_add_all': 'Add All to Queue',
  'queue_start_all': 'Start All Tasks',
  'project_clear_all': 'Delete All Projects',
  'queue_stop_all': 'Stop All Tasks',
  'canvas_select_all': 'Select All Elements',
  'canvas_delete_selected': 'Delete Selected Elements',
  'canvas_undo': 'Undo',
  'canvas_redo': 'Redo',
  'canvas_probe_mode': 'Probe Mode',
  'canvas_hide_logic': 'Hide Logic',
  'nav_projects': 'Switch to Projects',
  'nav_queue': 'Switch to Queue',
  'nav_command': 'Switch to Command',
  'nav_settings': 'Switch to Settings',
  'project_search': 'Search in Projects',
  'canvas_pan_button': 'Canvas Pan (mouse)',
  'canvas_select_button': 'Canvas Select (mouse)',
};

String _shortcutLabel(String actionId, bool isZh) {
  final String? label =
      (isZh ? _shortcutLabelsZh : _shortcutLabelsEn)[actionId];
  // 未知动作（后续新增的键位）回退到原始 id，保证仍可被搜索到。
  return label ?? actionId;
}

/// 按键显示文本：与 keybinding_page 的 _formatBinding 同款（' + ' 连接），
/// 仅把 'Control' 缩写为 'Ctrl' 以适配窄列宽。
String _formatKeys(List<String> keys, bool isZh) {
  if (keys.isEmpty) return isZh ? '(未设置)' : '(none)';
  return keys.map((k) => k == 'Control' ? 'Ctrl' : k).join(' + ');
}

// ═══════════════════════════════════════════
// 浮层 UI
// ═══════════════════════════════════════════

class _AppSearchOverlay extends StatefulWidget {
  const _AppSearchOverlay({required this.entries, required this.isZh});

  /// 已构建并缓存的全部条目（本组件只做过滤，不再重建条目）。
  final List<_Entry> entries;
  final bool isZh;

  @override
  State<_AppSearchOverlay> createState() => _AppSearchOverlayState();
}

class _AppSearchOverlayState extends State<_AppSearchOverlay> {
  final TextEditingController _ctrl = TextEditingController();

  /// 键盘事件挂在自己的 FocusNode 上（而不是祖先 Focus）：
  /// TextField 获得焦点后，↑/↓/Enter 会先被它的祖先 Shortcuts 消费（文本编辑
  /// 快捷键），挂在祖先节点上的 onKeyEvent 根本收不到。挂在 primary focus 的
  /// FocusNode 上则第一顺位收到事件。
  late final FocusNode _inputFocus =
      FocusNode(debugLabel: 'appSearchInput', onKeyEvent: _onKeyEvent);

  Timer? _debounce;

  /// 用户原始输入（用于显示）与规范化查询（用于匹配）。
  String _rawQuery = '';
  String _query = '';
  List<_Entry> _visible = const <_Entry>[];
  /// 截断前的命中总数（用于「仅显示前 N 条」提示与签名无关，仅展示）。
  int _totalHits = 0;
  int _sel = 0;

  /// 只挂在「当前选中行」上：键盘移动后用 ensureVisible 把它滚进视野。
  final GlobalKey _selKey = GlobalKey(debugLabel: 'appSearchSelected');
  final ScrollController _scroll = ScrollController();

  /// 防重复跳转：Enter 可能同时触达 onKeyEvent 与 TextField.onSubmitted，
  /// 若两次都 pop，第二次会把浮层下面的页面也弹掉。
  bool _closing = false;

  /// 概览首页的分类计数（条目固定，构建一次即可）。
  late final Map<_Cat, int> _counts = _computeCounts();

  Map<_Cat, int> _computeCounts() {
    final Map<_Cat, int> m = <_Cat, int>{};
    for (final _Entry e in widget.entries) {
      m[e.cat] = (m[e.cat] ?? 0) + 1;
    }
    return m;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── 查询 ──

  /// 输入防抖 120ms：输入框内容即时回显，只有「过滤结果」被节流，
  /// 因此打字不会有延迟感，而结果列表不会每个字符重建一次。
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _applyQuery(value);
    });
  }

  /// 每个分类最多渲染的命中条数。
  ///
  /// 结果列表是一次性构建的（分组标题 + 全部命中行交给 ListView(children:)），
  /// 媒体库很大时（上千个文件）输入单个字母会命中大量条目 → 单帧构建上千行明显掉帧。
  /// 这里按分类截断（搜索引擎的常见做法：先给最相关的一屏，继续输入即可缩小范围），
  /// 截断发生在 _visible 上，因此分组计数、键盘下标、高亮与渲染三者始终一致。
  static const int _kMaxHitsPerCategory = 40;

  void _applyQuery(String raw) {
    final String trimmed = raw.trim();
    setState(() {
      _rawQuery = trimmed;
      _query = trimmed.toLowerCase();
      final List<_Entry> all = _filter(_query);
      _totalHits = all.length;
      _visible = _capPerCategory(all);
      _sel = 0; // 新查询 → 从第一条重新开始
    });
  }

  /// 按分类截断到 [_kMaxHitsPerCategory]（保持原顺序：分组渲染与键盘下标依赖顺序）。
  List<_Entry> _capPerCategory(List<_Entry> all) {
    if (all.length <= _kMaxHitsPerCategory) return all;
    final Map<_Cat, int> seen = <_Cat, int>{};
    final List<_Entry> out = <_Entry>[];
    for (final _Entry e in all) {
      final int n = (seen[e.cat] ?? 0) + 1;
      seen[e.cat] = n;
      if (n <= _kMaxHitsPerCategory) out.add(e);
    }
    return out;
  }

  /// 查询：只有 toLowerCase + contains（searchText 已在构建条目时小写化）。
  List<_Entry> _filter(String q) {
    if (q.isEmpty) return const <_Entry>[];
    final List<_Entry> out = <_Entry>[];
    for (final _Entry e in widget.entries) {
      if (e.searchText.contains(q)) out.add(e);
    }
    return out;
  }

  void _clear() {
    _debounce?.cancel();
    _ctrl.clear();
    _applyQuery('');
    _inputFocus.requestFocus();
  }

  // ── 键盘 ──

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // 只处理按下/长按重复；抬起事件交回系统。
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close(null);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activateSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    if (_visible.isEmpty) return; // 概览首页没有可选项（无键盘导航）
    final int next = (_sel + delta).clamp(0, _visible.length - 1);
    if (next == _sel) return;
    setState(() => _sel = next);
    // 帧后滚动：此时选中行已经用 _selKey 布局完成。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? ctx = _selKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    });
  }

  void _activateSelected() {
    if (_visible.isEmpty) return;
    if (_sel < 0 || _sel >= _visible.length) return;
    _close(_visible[_sel]);
  }

  /// 关闭浮层并把选中的条目回传给 showAppSearch（由它负责跳转）。
  void _close(_Entry? entry) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(entry);
  }

  // ── 布局 ──

  @override
  Widget build(BuildContext context) {
    // 关键：浮层经 showGeneralDialog 弹出，其路由（RawDialogRoute）只提供
    // Semantics + DisplayFeatureSubScreen，**没有 Material 祖先**；而顶部搜索框是
    // TextField，framework 在 TextField.build 首行就 assert(debugCheckHasMaterial)。
    // 因此必须自己补一层透明 Material，否则 debug 构建下打开搜索直接抛断言
    // （release/profile 关断言，所以只在开发期可见）。
    // 不加底色/阴影，避免破坏玻璃浮层观感。
    return Material(
      type: MaterialType.transparency,
      // 移动端：全屏浮层（顶部搜索框 + 结果列表）；PC：居中浮层，左结果 + 右概览。
      child: isMobilePlatform ? _buildMobile(context) : _buildDesktop(context),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final double width = math.min(640.0, media.size.width - 48);
    final double height = math.min(560.0, media.size.height * 0.7);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: GlassPanel(
          radius: 20,
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              _buildSearchBar(scheme, compact: false),
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: _buildResults(compact: false)),
                    VerticalDivider(
                        width: 1, color: scheme.outlineVariant.withAlpha(70)),
                    SizedBox(width: 248, child: _buildOverviewPanel(scheme)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobile(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 键盘弹出时压缩内容高度，避免搜索框/结果被输入法遮住
    // （与 quick_config_page 的手机布局同一套处理）。
    final double keyboardInset = media.viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, 8, 10, 10 + keyboardInset),
        child: Column(
          children: <Widget>[
            GlassPanel(
              radius: 18,
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: _buildSearchBar(scheme, compact: true),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GlassPanel(
                radius: 20,
                padding: EdgeInsets.zero,
                child: _buildResults(compact: true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部搜索框：PC 显示 Esc 提示，移动端显示返回（关闭）按钮。
  Widget _buildSearchBar(ColorScheme scheme, {required bool compact}) {
    return Row(
      children: <Widget>[
        const SizedBox(width: 12),
        if (compact)
          IconButton(
            icon: Icon(Icons.close, size: 20, color: scheme.onSurfaceVariant),
            tooltip: widget.isZh ? '关闭搜索' : 'Close search',
            onPressed: () => _close(null),
          )
        else
          Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: _ctrl,
            focusNode: _inputFocus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            // 移动端输入法「搜索」键走的是 text input 而不是键盘事件，
            // 需要 onSubmitted 才能触发跳转（_closing 保证不会二次 pop）。
            onSubmitted: (_) => _activateSelected(),
            onChanged: _onChanged,
            style: TextStyle(fontSize: compact ? 15 : 16),
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 16),
              hintText: widget.isZh
                  ? '搜索设置、项目、容器、快捷配置、快捷键…'
                  : 'Search settings, projects, containers, quick configs, shortcuts…',
              hintStyle: TextStyle(
                fontSize: compact ? 14 : 15,
                color: scheme.onSurfaceVariant.withAlpha(170),
              ),
            ),
          ),
        ),
        // 只在「已应用的查询」非空时显示清除按钮（_rawQuery 由防抖更新，
        // 因此这里不需要监听 controller 逐字符 setState）。
        if (_rawQuery.isNotEmpty)
          IconButton(
            icon: Icon(Icons.backspace_outlined,
                size: 18, color: scheme.onSurfaceVariant),
            tooltip: widget.isZh ? '清除搜索' : 'Clear search',
            onPressed: _clear,
          ),
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              'Esc',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withAlpha(160),
              ),
            ),
          ),
      ],
    );
  }

  // ── 结果区（三种状态：概览首页 / 空结果 / 分组结果） ──

  Widget _buildResults({required bool compact}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_rawQuery.isEmpty) return _buildHome(scheme, compact);
    if (_visible.isEmpty) return _buildEmpty(scheme);
    return _buildGroupedList(scheme, compact);
  }

  Widget _buildGroupedList(ColorScheme scheme, bool compact) {
    final List<Widget> rows = <Widget>[];
    // 按枚举顺序分组输出：条目添加顺序 = _Cat.values 顺序，
    // 因此这里的 flat 计数就是 _visible 的下标（键盘选择依赖这一点）。
    int flat = 0;
    for (final _Cat cat in _Cat.values) {
      final List<_Entry> group =
          _visible.where((e) => e.cat == cat).toList(growable: false);
      if (group.isEmpty) continue;
      rows.add(_buildGroupHeader(cat, group.length, scheme, compact));
      for (final _Entry e in group) {
        final int index = flat++;
        rows.add(_buildRow(e, index, scheme, compact));
      }
    }
    // 命中被按分类截断时给一行提示，避免用户误以为「只有这么多」。
    if (_totalHits > _visible.length) {
      rows.add(Padding(
        padding: EdgeInsets.fromLTRB(compact ? 14 : 16, 12, 16, 16),
        child: Text(
          widget.isZh
              ? '仅显示前 $_visible.length 条（共 $_totalHits 条），继续输入可缩小范围'
              : 'Showing first $_visible.length of $_totalHits matches — type more to narrow down',
          style: TextStyle(
              fontSize: 11, color: scheme.onSurfaceVariant.withAlpha(170)),
        ),
      ));
    }
    return Scrollbar(
      controller: _scroll,
      child: ListView(
        controller: _scroll,
        padding: EdgeInsets.symmetric(vertical: compact ? 4 : 6),
        children: rows,
      ),
    );
  }

  Widget _buildGroupHeader(
      _Cat cat, int count, ColorScheme scheme, bool compact) {
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 14 : 16, compact ? 10 : 12, 12, 6),
      child: Row(
        children: <Widget>[
          Icon(cat.icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            cat.label(widget.isZh),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withAlpha(180),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child:
                Divider(color: scheme.outlineVariant.withAlpha(60), height: 1),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(_Entry e, int index, ColorScheme scheme, bool compact) {
    final bool selected = index == _sel;
    final String? excerpt = _hitExcerpt(e, _query);
    final TextStyle titleStyle = TextStyle(
      fontSize: compact ? 14 : 14.5,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );
    final TextStyle crumbStyle = TextStyle(
      fontSize: 11,
      color: scheme.onSurfaceVariant.withAlpha(200),
    );
    final TextStyle excerptStyle = TextStyle(
      fontSize: 11.5,
      color: scheme.onSurfaceVariant,
    );
    final TextStyle hitStyle = TextStyle(
      fontSize: compact ? 14 : 14.5,
      fontWeight: FontWeight.w700,
      color: scheme.primary,
    );
    final TextStyle excerptHitStyle = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: scheme.primary,
    );

    return Padding(
      // 选中行用 key 标记，键盘移动后 Scrollable.ensureVisible 用它做滚动锚点。
      key: selected ? _selKey : null,
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 2),
      child: Material(
        color: selected ? scheme.primary.withAlpha(26) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _close(e), // 点击整条即跳转（移动端）／打开（PC）
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 10 : 9,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    e.icon,
                    size: 18,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text.rich(
                        TextSpan(
                            children: _highlightSpans(
                                e.title, _query, titleStyle, hitStyle)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        e.breadcrumb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: crumbStyle,
                      ),
                      if (excerpt != null && excerpt.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 3),
                        Text.rich(
                          TextSpan(children: <InlineSpan>[
                            TextSpan(
                              text: widget.isZh ? '命中 ' : 'Match ',
                              style: excerptStyle,
                            ),
                            ..._highlightSpans(
                                excerpt, _query, excerptStyle, excerptHitStyle),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (compact)
                  Icon(Icons.chevron_right,
                      size: 18, color: scheme.onSurfaceVariant.withAlpha(140)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 空查询 = 概览首页：各分类计数卡片 + 常用入口。
  Widget _buildHome(ColorScheme scheme, bool compact) {
    return ListView(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 14, 12, compact ? 12 : 14, 16),
      children: <Widget>[
        _sectionLabel(widget.isZh ? '分类概览' : 'Categories', scheme),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final _Cat c in _Cat.values) _countCard(c, scheme, compact),
          ],
        ),
        const SizedBox(height: 20),
        _sectionLabel(widget.isZh ? '常用入口' : 'Quick actions', scheme),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: _homeActions()),
        if (!compact) ...<Widget>[
          const SizedBox(height: 20),
          _sectionLabel(widget.isZh ? '提示' : 'Tips', scheme),
          const SizedBox(height: 8),
          Text(
            widget.isZh
                ? '直接输入即可搜索；↑/↓ 选择，Enter 打开，Esc 关闭。'
                : 'Just start typing; ↑/↓ to move, Enter to open, Esc to close.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _sectionLabel(String text, ColorScheme scheme) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _countCard(_Cat cat, ColorScheme scheme, bool compact) {
    return Container(
      width: compact ? 106 : 112,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(cat.icon, size: 15, color: scheme.primary),
          const SizedBox(height: 6),
          Text(
            '${_counts[cat] ?? 0}',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            cat.label(widget.isZh),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 常用入口：复用已有的导航条目（按 id 查缓存条目，保证图标/文案/动作一致；
  /// 目标平台上不存在的页面 —— 例如移动端的「命令」「日志」 —— 自然不会出现在
  /// 条目里，这里也就不会生成对应入口）。
  List<Widget> _homeActions() {
    const List<String> ids = <String>[
      'nav:4', 'nav:0', 'nav:1', 'nav:3', 'nav:2', 'nav:5',
    ];
    final List<Widget> chips = <Widget>[];
    for (final String id in ids) {
      final _Entry? e = _findEntry(id);
      if (e == null) continue;
      chips.add(ActionChip(
        avatar: Icon(e.icon, size: 16),
        label: Text(e.title),
        onPressed: () => _close(e),
      ));
    }
    return chips;
  }

  _Entry? _findEntry(String id) {
    for (final _Entry e in widget.entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 无结果：图标 + 文案 + 清除按钮。
  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.search_off,
                size: 44, color: scheme.onSurfaceVariant.withAlpha(150)),
            const SizedBox(height: 12),
            Text(
              widget.isZh ? '没有找到「$_rawQuery」' : 'No results for "$_rawQuery"',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.isZh
                  ? '试试更短的关键词，或直接搜索「玻璃」「输出」「快捷键」等。'
                  : 'Try a shorter keyword, e.g. "glass", "output" or "shortcut".',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _clear,
              icon: const Icon(Icons.backspace_outlined, size: 16),
              label: Text(widget.isZh ? '清除搜索' : 'Clear search'),
            ),
          ],
        ),
      ),
    );
  }

  /// PC 右侧概览面板：选中项的详细描述 / 分类 / 操作提示。
  Widget _buildOverviewPanel(ColorScheme scheme) {
    final _Entry? e =
        (_sel >= 0 && _sel < _visible.length) ? _visible[_sel] : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (e != null) ...<Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(e.icon, size: 22, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            e.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        e.cat.label(widget.isZh),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      e.breadcrumb,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant.withAlpha(200),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      e.detail,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ] else ...<Widget>[
                    Text(
                      widget.isZh ? '全应用搜索' : 'Search everything',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.isZh
                          ? '一个输入框覆盖设置项、页面、项目媒体、容器、快捷配置与快捷键。输入关键字后，这里会显示选中项的详细说明与跳转目标。'
                          : 'One box over settings, pages, media, containers, quick configs and shortcuts. Once you type, this panel describes the selected hit and where it goes.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Divider(color: scheme.outlineVariant.withAlpha(70), height: 18),
          _keyHint('↑ / ↓', widget.isZh ? '选择结果' : 'Move', scheme),
          _keyHint('Enter', widget.isZh ? '打开选中项' : 'Open', scheme),
          _keyHint('Esc', widget.isZh ? '关闭搜索' : 'Close', scheme),
          if (e != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              e.hint,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _keyHint(String keys, String label, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(140),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              keys,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 高亮 / 命中摘要
// ═══════════════════════════════════════════

/// 把 [text] 中所有与 [q] 匹配（大小写不敏感）的片段切成主题色 TextSpan。
/// [q] 必须是已小写化的查询；[text] 保持原大小写展示。
List<TextSpan> _highlightSpans(
    String text, String q, TextStyle base, TextStyle hit) {
  if (q.isEmpty || text.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }
  final String lower = text.toLowerCase();
  // 极少数语言里 toLowerCase 会改变长度（如 İ U+0130 → 'i' + U+0307），
  // 此时小写下标无法安全映射回原文下标，直接退化为「不高亮」而不是抛 RangeError。
  if (lower.length != text.length) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }
  final List<TextSpan> spans = <TextSpan>[];
  int start = 0;
  while (true) {
    final int i = lower.indexOf(q, start);
    if (i < 0) {
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start), style: base));
      }
      break;
    }
    if (i > start) {
      spans.add(TextSpan(text: text.substring(start, i), style: base));
    }
    spans.add(TextSpan(text: text.substring(i, i + q.length), style: hit));
    start = i + q.length;
  }
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: base));
  return spans;
}

/// 命中摘要：标题命中 → 用一句话摘要；否则取命中的关键字/面包屑原文。
/// 返回 null 表示标题之外没有额外信息（此时行里只显示标题与面包屑）。
String? _hitExcerpt(_Entry e, String q) {
  if (q.isEmpty) return null;
  if (e.title.toLowerCase().contains(q)) return e.summary;
  for (final String k in e.keywords) {
    if (k.toLowerCase().contains(q)) return k;
  }
  if (e.breadcrumb.toLowerCase().contains(q)) return e.breadcrumb;
  // 兜底：extra 里放的是「只参与匹配、不直接展示」的文本（文件路径、id、分区名等）。
  // 命中只落在 extra 时若不回溯，这一行就没有命中摘要，用户看不出为什么命中。
  for (final String x in e.extra) {
    final int i = x.toLowerCase().indexOf(q);
    if (i < 0) continue;
    const int window = 30;
    final int from = (i - window).clamp(0, x.length);
    final int to = (i + q.length + window).clamp(0, x.length);
    // 外层用双引号：字符串里还有单引号包裹的字面量，避免嵌套引号把字符串截断。
    return "${from > 0 ? '…' : ''}${x.substring(from, to)}${to < x.length ? '…' : ''}";
  }
  return null;
}
