import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../theme/app_text_scale.dart';
// 控件高度档位令牌：MCP 卡的输入框/按钮、AI 配置详情页的按钮统一按档位取高度，
// 不再用 `SizedBox(height: 30)` 压高度（会与主题 v12 内边距打架）
import '../theme/app_control_size.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/masonry_grid.dart';
import '../widgets/install_dialog.dart';
import 'keybinding_page.dart';
import 'command_page.dart';
import 'log_page.dart';
import 'credits_page.dart';
import 'ads_page.dart';
import '../platform/app_platform.dart';
// 高刷新率开关的即时生效（Android 专用，见 services/refresh_rate.dart）
import '../services/refresh_rate.dart';
// 生效的菜单栏位置：设置页自身也在主 Tab 的 PageView 里，底部让出的高度
// 要跟着菜单栏位置走（底部胶囊 96 / 竖排导轨 20）
import '../widgets/mobile_nav_scope.dart';
import '../widgets/font_picker.dart';
// 背景预览缩略图复用主壳那条**唯一**的壁纸解码入口：同参数（屏幕逻辑尺寸 +
// DPR）构造出的 ResizeImage 与主壳的 `==` 相等 → 命中同一个 ImageCache 条目，
// 不额外解码一份，也不会出现「缩略图与真实壁纸构图不一致」。
// settings_page ↔ app.dart 互为循环引用，Dart 允许（wallpaper_background.dart
// 与 app.dart 早就是同样的情况）。
import '../app.dart' show wallpaperImageProvider;
import '../services/ffmpeg_installer.dart';
import '../services/update_service.dart' as updater;
import '../services/shell_open.dart';
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/option_menu_bar.dart';
import '../widgets/app_card.dart';
import '../widgets/app_slider.dart';
// harmonizedAccent（协调主题色，解决「选主题色太亮」）/ neutralGray（真中性灰，
// 解决「灰色夹杂主题色」）/ GlassTuning（玻璃细节参数）都在这里。
import '../widgets/liquid_glass_fallback.dart';
import '../widgets/wallpaper_background.dart';
import 'ai_settings_mobile.dart';

final _s = Platform.pathSeparator;

/// 应用文档目录（Android 持久化，避免 systemTemp 被系统清空）
String _androidAppDir() => _cachedAppDir;
String _cachedAppDir = '${Directory.systemTemp.path}${_s}FFmpeg++';
bool _appDirInit = false;

/// 初始化 Android 应用文档目录（在 SettingsPage 首次构建时调用）
Future<void> _ensureAndroidAppDir() async {
  if (_appDirInit) return;
  _appDirInit = true;
  try {
    final dir = await getApplicationDocumentsDirectory();
    _cachedAppDir = '${dir.path}${_s}FFmpeg++';
  } catch (_) {
    // 解析失败（罕见）：把标记复位以便下次重试。否则 _cachedAppDir 会永久停在
    // systemTemp 兜底值 —— 导入的字体被写进缓存目录，而启动时 main._loadCustomFonts()
    // 只从「应用文档目录/FFmpeg++/fonts」加载，重启后字体就「消失」了。
    _appDirInit = false;
  }
}

/// 获取用户数据目录，避免 Program Files 权限问题
String _userDataDir() {
  if (Platform.isAndroid) {
    // Android：使用 path_provider 的应用文档目录（持久化，不会被系统清空）
    return _androidAppDir();
  } else if (Platform.isWindows) {
    return '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}${_s}FFmpeg++';
  } else if (Platform.isMacOS) {
    return '${Platform.environment['HOME'] ?? '/tmp'}/Library/Application Support/FFmpeg++';
  } else {
    final base = Platform.environment['XDG_DATA_HOME'] ??
        '${Platform.environment['HOME'] ?? '/tmp'}$_s.local${_s}share';
    return '$base${_s}FFmpeg++';
  }
}

/// 复制文件到用户数据目录下的子文件夹，返回新路径（失败返回 null）
Future<String?> _copyToAppDir(String srcPath, String subDir) async {
  try {
    final targetDir = Directory('${_userDataDir()}$_s$subDir');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final fileName = srcPath.split(RegExp(r'[\\/]')).last;
    final destPath = '${targetDir.path}$_s$fileName';
    final srcFile = File(srcPath);
    if (srcFile.existsSync()) {
      await srcFile.copy(destPath);
      return destPath;
    }
  } catch (_) {}
  return null;
}

/// 壁纸优化复制：识别屏幕分辨率，若原图大于屏幕分辨率则先解码缩放到
/// 屏幕大小并重编码为 PNG 再保存 —— 减小体积、避免大图导致添加后卡死/
/// 内存暴涨。返回保存路径（失败回退为普通复制）。
///
/// [maxW]/[maxH] 为目标物理像素分辨率，调用方在 async 前从 View 同步取得，
/// 避免 BuildContext 跨 async gap。
Future<String?> _copyBackgroundOptimized(String srcPath, int maxW, int maxH) async {
  try {
    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) return null;
    final bytes = await srcFile.readAsBytes();

    // 用 dart:ui 解码原图，获取实际尺寸
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final srcW = image.width;
    final srcH = image.height;
    codec.dispose();

    // 原图小于等于屏幕分辨率：无需缩放，直接走普通复制
    if (srcW <= maxW && srcH <= maxH) {
      image.dispose();
      return await _copyToAppDir(srcPath, 'background');
    }

    // 等比缩放到屏幕分辨率内（长边对齐），scale 单一化确保两个方向缩放一致、绝不拉伸
    final scale = math.min(maxW / srcW, maxH / srcH);
    final targetW = math.max(1, (srcW * scale).round());
    final targetH = math.max(1, (srcH * scale).round());

    // 缩放 + 编码（高质量重采样避免下采样变糊；PNG 无损）
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale, scale);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final picture = recorder.endRecording();
    final resized = await picture.toImage(targetW, targetH);
    picture.dispose();
    image.dispose();

    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    if (byteData == null) return await _copyToAppDir(srcPath, 'background');

    // 保存为 .png（与原文件名区分，避免覆盖源图）
    final targetDir = Directory('${_userDataDir()}$_s${'background'}');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final baseName = srcPath.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final destPath = '${targetDir.path}$_s${baseName}_opt.png';
    await File(destPath).writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    return destPath;
  } catch (_) {
    // 解码/缩放失败（如超大图内存不足）：回退普通复制
    return await _copyToAppDir(srcPath, 'background');
  }
}

/// 从内存字节保存背景图（Android 11+ content:// URI 场景：picker 返回 bytes 而非路径）。
/// 解码后用 [maxW]/[maxH] 限制最大尺寸，重编码为 PNG 存入应用文档目录。
Future<String?> _saveBackgroundBytes(Uint8List bytes, String fileName, int maxW, int maxH) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final srcW = image.width;
    final srcH = image.height;
    codec.dispose();

    // 原图小于等于屏幕分辨率：直接保存原始字节
    if (srcW <= maxW && srcH <= maxH) {
      image.dispose();
      return await _saveRawBackground(bytes, fileName);
    }

    // 等比缩放到屏幕分辨率内（长边对齐），scale 单一化确保两个方向缩放一致、绝不拉伸
    final scale = math.min(maxW / srcW, maxH / srcH);
    final targetW = math.max(1, (srcW * scale).round());
    final targetH = math.max(1, (srcH * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale, scale);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final picture = recorder.endRecording();
    final resized = await picture.toImage(targetW, targetH);
    picture.dispose();
    image.dispose();

    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    if (byteData == null) return await _saveRawBackground(bytes, fileName);
    return await _saveRawBackground(byteData.buffer.asUint8List(), '${fileName}_opt');
  } catch (_) {
    return await _saveRawBackground(bytes, fileName);
  }
}

/// 把背景字节直接写入应用文档目录 background/ 下，返回绝对路径（失败返回 null）
Future<String?> _saveRawBackground(Uint8List bytes, String name) async {
  try {
    final targetDir = Directory('${_userDataDir()}$_s${'background'}');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final destPath = '${targetDir.path}$_s$safeName';
    if (!File(destPath).existsSync() || !_sameBytes(destPath, bytes)) {
      await File(destPath).writeAsBytes(bytes, flush: true);
    }
    return destPath;
  } catch (_) {
    return null;
  }
}

/// 快速判断目标文件内容是否与字节一致（避免重复写盘）
bool _sameBytes(String path, Uint8List bytes) {
  try {
    final f = File(path);
    if (!f.existsSync()) return false;
    // 先比较长度（快速路径），再比较内容（避免同长度不同文件被误判）
    if (f.lengthSync() != bytes.length) return false;
    final existing = f.readAsBytesSync();
    for (int i = 0; i < bytes.length; i++) {
      if (existing[i] != bytes[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// 用系统默认浏览器打开链接。见 [ShellOpen] 里关于 `cmd /c start` 注入的说明。
Future<void> openExternalUrl(String url) => ShellOpen.url(url);

// 二级设置页壁纸背景已统一抽到 widgets/wallpaper_background.dart 的
// withWallpaper()，公开供移动端 AI 设置等二级页面复用。

// ═══════════════════════════════════════════
// 设置项元数据 —— 分区 / 卡片 / 搜索关键字
// ═══════════════════════════════════════════

class _CardDef {
  final String id;
  final String Function(AppStrings) title;
  /// 移动端一级菜单行首图标（MIUI 风格圆角图标块）。
  final IconData icon;

  /// 额外的搜索关键字（中英文都写，全小写）。卡片标题会自动并入搜索范围。
  final List<String> keywords;
  final Widget Function(BuildContext, AppState) build;

  const _CardDef({
    required this.id,
    required this.title,
    required this.icon,
    required this.keywords,
    required this.build,
  });

  /// 中英文标题 + 关键字都参与匹配，这样无论界面当前是哪种语言，
  /// 输入 "font" 或 "字体" 都能命中同一张卡片。
  bool matches(String query) {
    if (query.isEmpty) return true;
    if (title(AppStrings.zh).toLowerCase().contains(query)) return true;
    if (title(AppStrings.en).toLowerCase().contains(query)) return true;
    for (final k in keywords) {
      if (k.contains(query)) return true;
    }
    return false;
  }
}

class _SectionDef {
  final String id;
  final String Function(AppStrings) title;
  final IconData icon;
  final List<_CardDef> cards;
  const _SectionDef({required this.id, required this.title, required this.icon, required this.cards});
}

// ═══════════════════════════════════════════
// 设置页
// ═══════════════════════════════════════════

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static void showUpdateDialogStatic(BuildContext ctx, AppStrings s, updater.UpdateResult result) {
    _showUpdateDialog(ctx, s, result);
  }

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  /// 移动端搜索是否展开（内联展开在顶栏下方，而非弹出对话框）。
  bool _searchExpanded = false;

  /// 桌面端左侧主菜单当前选中的分区 id。
  String _selectedSection = 'general';

  @override
  void initState() {
    super.initState();
    if (isAndroidPlatform) _ensureAndroidAppDir();
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  /// 全局搜索「跳转到某设置项」后，短暂高亮的卡片 id（渐隐描边，便于定位）。
  String? _highlightCardId;
  Timer? _highlightTimer;

  /// 搜索结果 / 分区导航的「定位到某个设置卡片」：
  /// 切到该卡片所属分区、清空搜索、把卡片滚动到视野内并短暂高亮描边。
  /// （这是设置页搜索的核心：搜索 → 直接落到具体设置项，而不是让用户自己再找。）
  void _jumpToCard(String cardId) {
    _CardDef? target;
    String sectionId = _selectedSection;
    for (final sec in _sections) {
      for (final c in sec.cards) {
        if (c.id == cardId) {
          target = c;
          sectionId = sec.id;
          break;
        }
      }
      if (target != null) break;
    }
    if (target == null) return;
    _highlightTimer?.cancel();
    setState(() {
      _selectedSection = sectionId;
      _query = '';
      _searchExpanded = false;
      _highlightCardId = cardId;
    });
    _searchCtrl.clear();
    _searchFocus.unfocus();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightCardId = null);
    });
    // 帧后滚动到该卡片（GlobalKey 由 _cardKey 统一维护，桌面/移动两条渲染路径共用）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _cardKeys[cardId]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: 0.15);
    });
  }

  /// 每个设置卡片一个稳定 GlobalKey（用于 [Scrollable.ensureVisible] 定位）。
  final Map<String, GlobalKey> _cardKeys = <String, GlobalKey>{};
  GlobalKey _cardKey(String id) => _cardKeys.putIfAbsent(id, () => GlobalKey());

  /// 搜索结果跳转后的短暂高亮描边（渐隐；1.8s 后由 _highlightCardId 清空）。
  /// 搜索结果里每张卡片的头部：分区 · 卡片名 + 「定位」按钮。
  ///
  /// 用户要的是「搜索设置项可以更好的定位到需要的项」（尤其是电脑端）：
  /// 光列出命中的卡片还不够，点「定位」才是真正的跳转 —— 切分区 + 滚动到卡片 + 高亮。
  Widget _resultHeader(
      _SectionDef sec, _CardDef c, ColorScheme scheme, AppStrings s, BuildContext ctx) {
    final AppStrings ls = AppStrings.of(ctx.read<AppState>().config.language);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
      child: Row(children: [
        Icon(sec.icon, size: 13, color: scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text('${sec.title(ls)} · ${c.title(ls)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant)),
        ),
        TextButton.icon(
          onPressed: () => _jumpToCard(c.id),
          icon: const Icon(Icons.my_location, size: 13),
          label: Text(s.isZh ? '定位' : 'Locate', style: const TextStyle(fontSize: 11)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            minimumSize: const Size(0, 26),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ]),
    );
  }

  Widget _highlightWrap(String cardId, Widget child) {
    final on = _highlightCardId == cardId;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: on
              ? Theme.of(context).colorScheme.primary.withAlpha(190)
              : Colors.transparent,
          width: on ? 1.6 : 0,
        ),
      ),
      child: child,
    );
  }
  /// 选择左侧主菜单的分区：顺手清空搜索，右侧完整展示该分区。
  void _selectSection(String id) {
    if (_query.isNotEmpty) {
      _searchCtrl.clear();
      _query = '';
    }
    if (_selectedSection == id) return;
    setState(() => _selectedSection = id);
  }

  static final List<_SectionDef> _sections = [
    // 「通用」收纳不属于视觉外观的全局项（语言），与「外观」解耦。
    _SectionDef(
      id: 'general',
      title: (s) => s.secGeneral,
      icon: Icons.language_outlined,
      cards: [
        _CardDef(
          id: 'language',
          title: (s) => s.language,
          icon: Icons.translate,
          keywords: ['语言', '界面', '中文', 'language', 'english', 'chinese',
              'interface', 'locale', 'i18n'],
          build: _buildLanguage,
        ),
      ],
    ),
    _SectionDef(
      id: 'appearance',
      title: (s) => s.secAppearance,
      icon: Icons.palette_outlined,
      cards: [
        // 「外观」原为单张巨型「主题」卡（模式+主题色+背景+样式+画布 全塞一起），
        // 现按关注点拆成 4 张分层卡片，各自独立可搜索、移动端不再长滑。
        _CardDef(
          id: 'theme',
          title: (s) => s.cardTheme,
          icon: Icons.brightness_6_outlined,
          keywords: ['深色', '暗色', '浅色', 'dark', 'light', 'mode', '模式',
              '主题色', '强调色', '颜色', 'accent', 'color', 'theme',
              '动态取色', 'monet', 'dynamic', '渐变', 'gradient'],
          build: _buildTheme,
        ),
        _CardDef(
          id: 'background',
          title: (s) => s.isZh ? '背景' : 'Background',
          icon: Icons.wallpaper_outlined,
          keywords: ['背景', '壁纸', 'background', 'wallpaper', '图片', 'image',
              '不透明度', 'opacity', '透明', 'alpha'],
          build: _buildBackgroundCard,
        ),
        _CardDef(
          id: 'surfaceStyle',
          title: (s) => s.styleLabel,
          icon: Icons.style_outlined,
          keywords: ['样式', 'style', '卡片', 'card', '液态玻璃', 'liquid',
              '玻璃', 'glass', '模糊', 'blur', '灰色', 'gray',
              '底部', 'bottom', 'nav', '导航', '药丸', 'pill', '表面', 'surface',
              '菜单', 'menu', '侧边栏', 'sidebar', '顶栏', 'topbar', '顶部菜单',
              '毛玻璃', 'frosted', '透明度', '不透明度', 'opacity', 'alpha',
              '边框', '描边', '线条', 'border', 'outline', 'stroke', '颜色', '宽度',
              '跟随主题色', 'follow', 'gpu', '实验',
              // 拆卡后的三张卡标题也要能被搜到（预设 / 玻璃与材质 / 特效）
              '预设', 'preset', '方案', '材质', 'material',
              '粒子', 'particle', '特效', 'effect', '动效', '动画'],
          build: _buildSurfaceStyleCard,
        ),
        // 玻璃细节：桌面端独立成卡（右侧面板没有三级页机制，一屏平铺得下）。
        // 移动端已下沉为「外观 → 样式 → 玻璃细节」三级页 —— 用户要求
        // 「玻璃细节放到样式里面（就是玻璃细节成三级菜单）」。
        if (!isMobilePlatform)
          _CardDef(
            id: 'glassDetail',
            title: (s) => s.isZh ? '玻璃细节' : 'Glass details',
            icon: Icons.blur_on_outlined,
            keywords: ['玻璃', 'glass', '模糊', 'blur', '模糊度', '通透', 'clarity',
                '透明', '高光', 'highlight', 'specular', '光斑', '位置', 'position',
                '边缘光', 'edge', 'rim', '描边', '细节', 'detail', '微调'],
            build: _buildGlassDetailCard,
          ),
        _CardDef(
          id: 'nodeEditorStyle',
          title: (s) => s.nodeEditorStyleLabel,
          icon: Icons.account_tree_outlined,
          keywords: ['节点编辑器', '画布', 'canvas', '背景', 'grid',
              '逻辑门', 'gate', 'ansi', 'iec', 'ieee', '符号', 'symbol',
              // 界面尺寸（药丸大小）也在这张卡里，补上对应搜索词
              '药丸', 'pill', '大小', 'size', '尺寸', '放大镜', 'zoom',
              '界面', 'ui', '菜单栏', 'toolbar', '缩放', 'scale',
              // 三级页（编辑模式 / 自动保存）的搜索词也要挂在这张卡上，
              // 否则移动端在设置里搜「自动保存」找不到东西。
              '编辑模式', '快速模式', 'edit', 'mode', 'classic', '蓝图', 'blueprint',
              '自动保存', '草稿', '保存间隔', 'autosave', 'draft', 'save',
              '横屏', 'landscape'],
          build: _buildNodeEditorStyleCard,
        ),
        _CardDef(
          id: 'font',
          title: (s) => s.font,
          icon: Icons.text_fields,
          keywords: ['字体', '字号', '字重', 'font', 'size', 'weight',
              'typeface', '导入', 'import', '大小'],
          build: _buildFont,
        ),
      ],
    ),
    _SectionDef(
      id: 'processing',
      title: (s) => s.secProcessing,
      icon: Icons.movie_filter_outlined,
      cards: [
        // 移动端 ffmpeg/ffprobe 已内置在 APK（jniLibs），无需展示安装/路径设置
        if (!isMobilePlatform)
          _CardDef(
            id: 'ffmpeg',
            title: (s) => s.ffmpegSettings,
            icon: Icons.memory_outlined,
            keywords: ['ffmpeg', 'ffprobe', '编码', 'codec', '安装', 'install',
                '检测', 'detect', '路径', 'path', '下载', 'download'],
            build: (ctx, state) => _FfmpegCard(state: state),
          ),
        _CardDef(
          id: 'output',
          title: (s) => s.output,
          icon: Icons.folder_outlined,
          keywords: ['输出', '目录', '文件夹', 'output', 'directory', 'folder',
              '中间', 'intermediate', '临时', 'temp', 'path', '路径'],
          build: _buildOutput,
        ),
        _CardDef(
          id: 'tasks',
          title: (s) => s.cardTasks,
          icon: Icons.playlist_play,
          keywords: ['任务', '并发', '同时', '线程', 'task', 'concurrent',
              'parallel', 'thread', '解析', 'probe', '通知', 'notification',
              '队列', 'queue'],
          build: _buildTasks,
        ),
      ],
    ),
    // 「编辑器」分区**仅桌面端保留**：移动端的「编辑模式 / 自动保存」已下沉为
    // 「外观 → 节点编辑器 → 编辑模式 / 自动保存」三级页（见
    // _buildNodeEditorStyleCard），快捷键本来就只在桌面端有意义 —— 整段在移动端
    // 会变成一个空分区（一级菜单里多出一行点不动的标题）。
    if (!isMobilePlatform)
      _SectionDef(
        id: 'editor',
        title: (s) => s.secEditor,
        icon: Icons.account_tree_outlined,
        cards: [
          _CardDef(
            id: 'editorMode',
            title: (s) => s.cardEditorMode,
            icon: Icons.account_tree_outlined,
            keywords: ['编辑', '编辑器', '节点', '画布', '蓝图',
                'editor', 'node', 'canvas', 'blueprint', 'classic', 'mode', '模式'],
            build: _buildEditorMode,
          ),
          _CardDef(
            id: 'shortcuts',
            title: (s) => s.cardShortcuts,
            icon: Icons.keyboard_outlined,
            keywords: ['快捷键', '键位', '按键', '热键', 'shortcut', 'keybinding',
                'keyboard', 'hotkey', 'key'],
            build: _buildShortcuts,
          ),
          _CardDef(
            id: 'autosave',
            title: (s) => s.cardAutosave,
            icon: Icons.save_outlined,
            keywords: ['自动保存', '草稿', '恢复', 'autosave', 'draft',
                'auto', 'save', '恢复'],
            build: _buildAutosave,
          ),
        ],
      ),
    // 移动端专用：命令与日志从底部导航移入设置（避免底部元素过多）
    if (isMobilePlatform)
      _SectionDef(
        id: 'tools',
        title: (s) => s.isZh ? '工具' : 'Tools',
        icon: Icons.handyman_outlined,
        cards: [
          _CardDef(
            id: 'command',
            title: (s) => s.navCommand,
            icon: Icons.terminal,
            keywords: ['命令', 'ffmpeg', 'command', 'terminal', '终端', '执行', 'run', '模板', 'template'],
            build: _buildMobileCommandEntry,
          ),
          _CardDef(
            id: 'logs',
            title: (s) => s.qLogs,
            icon: Icons.receipt_long_outlined,
            keywords: ['日志', 'log', 'logs', '输出', 'output', '进度', 'progress', '调试', 'debug'],
            build: _buildMobileLogsEntry,
          ),
        ],
      ),
    _SectionDef(
      id: 'ai',
      title: (s) => s.secAi,
      icon: Icons.auto_awesome_outlined,
      cards: [
        _CardDef(
          id: 'ai',
          title: (s) => s.mcpTitle,
          icon: Icons.auto_awesome_outlined,
          keywords: ['ai', 'mcp', '模型', 'model', 'api', 'key', 'token',
              'openai', 'anthropic', 'claude', 'gpt', '提示词', 'prompt',
              '权限', 'permission', '助手', 'assistant', '端口', 'port', '服务',
              '提供商', 'provider', 'deepseek', 'ollama'],
          // 移动端：提供商列表式设置（二级菜单）；桌面端：原有卡片 + 底部弹窗
          build: (ctx, state) => isMobilePlatform
              ? mobileAiSettingsContent(ctx, state)
              : _buildMcpAi(ctx, state),
        ),
      ],
    ),
    _SectionDef(
      id: 'advanced',
      title: (s) => s.secAdvanced,
      icon: Icons.tune_outlined,
      cards: [
        // 预测式返回手势（仅 Android 端）
        if (isAndroidPlatform)
          _CardDef(
            id: 'predictiveBack',
            title: (s) => s.predictiveBack,
            icon: Icons.swipe_left_alt_outlined,
            keywords: ['返回', '手势', '预测', '侧滑', 'back', 'gesture',
                'predictive', 'swipe', '返回动画', '系统', 'system'],
            build: _buildPredictiveBack,
          ),
        // 显示（仅移动端）：高刷新率（90 / 120 / 144Hz）
        if (isMobilePlatform)
          _CardDef(
            id: 'display',
            title: (s) => s.displayLabel,
            icon: Icons.screenshot_monitor_outlined,
            keywords: ['显示', '刷新率', '高刷', '高刷新率', '帧率', '流畅', '顺滑',
                'display', 'refresh', 'rate', 'hz', 'high', 'smooth', 'fps',
                '120', '90', '144', '60', '屏幕', 'screen'],
            build: _buildDisplay,
          ),
        _CardDef(
          id: 'preload',
          title: (s) => s.isZh ? '预加载' : 'Preload',
          icon: Icons.shutter_speed_outlined,
          keywords: ['预加载', '预载', 'preload', '启动', 'startup', 'launch',
              '性能', 'performance', 'CPU', '内存', 'memory', '绘制', '渲染',
              'render', '加载', 'load'],
          build: _buildPreload,
        ),
        _CardDef(
          id: 'debug',
          title: (s) => s.dDebug,
          icon: Icons.bug_report_outlined,
          keywords: ['调试', '日志', '诊断', 'debug', 'log', 'logs',
              'verbose', 'diagnostic', '保存', 'save'],
          build: _buildDebug,
        ),
        _CardDef(
          id: 'cache',
          title: (s) => s.cardCache,
          icon: Icons.cleaning_services_outlined,
          keywords: ['缓存', '清除', '清理', '删除', 'cache', 'clear',
              'clean', 'cleanup', 'purge', 'reset'],
          build: _buildCache,
        ),
      ],
    ),
    _SectionDef(
      id: 'about',
      title: (s) => s.secAbout,
      icon: Icons.info_outline,
      cards: [
        // 「检查更新」不再是独立卡片：入口嵌入到「关于」卡片内
        // （桌面=按钮+自动检查开关；移动=发布页链接），搜索关键字一并并入。
        _CardDef(
          id: 'about',
          title: (s) => s.aboutTitle,
          icon: Icons.info_outline,
          keywords: ['关于', '版本', '赞助', '捐赠', '许可', 'about', 'version',
              'sponsor', 'donate', 'license', 'github', 'blog', '作者', 'author',
              '更新', '升级', 'update', 'upgrade', '检查', 'check', '自动'],
          build: _buildAbout,
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // 只在配置变化时重建：卡片内容全部派生自 config，而进度心跳/日志/任务
    // 等无关通知不该触发设置页整页重建。签名比较成本 O(1)。
    return Selector<AppState, int>(
      // 注意：这里必须覆盖「设置页 UI 会显示」的全部配置字段，否则外部改动
      // （如字体字重、主题色、玻璃参数从别处被修改）不会让设置页重建，
      // 控件会一直显示旧值 —— 用户反馈的「字重改不了」就是这个签名漏字段造成的。
      selector: (_, state) => Object.hashAll([
        state.config.language,
        state.darkMode,
        state.config.cardStyle,
        state.config.menuStyle,
        state.config.navStyle,
        state.config.pillStyle,
        state.config.fontSize,
        state.config.fontWeightIndex,
        state.config.fontFamily,
        state.config.themeColor,
        state.config.themeColor2,
        state.config.backgroundImage,
        state.config.backgroundOpacity,
        state.config.cardOpacity,
        state.config.glassEffect,
        state.config.glassFollowTheme,
        // 设置卡片玻璃：原 settingsFrostedGlass / noCardGlass 两个互斥开关已
        // 合并为单一 settingsGlassMode（派生 getter 仍可读，见 AppConfig）。
        state.config.settingsGlassMode,
        state.config.sliderParticles,
        state.config.glassGpuOnDesktop,
        // 玻璃细节：任何一项变化都要重建设置页，否则控件显示旧值
        state.config.glassBlur,
        state.config.glassClarity,
        state.config.glassHighlight,
        state.config.glassLightPos,
        state.config.glassEdge,
        state.config.themeTone,
        state.config.ffmpegPath,
        state.config.ffprobePath,
        // ── 「高级」分区与 AI/MCP 卡的开关类字段（[FIX] PC 端开关点了没反应）──
        // 这些 SwitchListTile 全是受控控件（value 直读 config），而 Selector 只在
        // 签名哈希变化时才重建整页 —— 之前 noPreload / debugMode 等字段不在签名里，
        // 点击后配置写进去了但页面不重建，开关视觉上纹丝不动（与注释里
        // 「字重改不了」同根因）。凡是设置页 UI 会显示的字段必须全部在此列出。
        state.config.predictiveBack,
        state.config.useDynamicColor,
        state.config.mobileNavPlacement,
        state.config.borderEnabled,
        state.config.borderWidth,
        state.config.borderColor,
        state.config.canvasBg,
        state.config.gateStd,
        state.config.editorToolbarScale,
        state.config.editorZoomScale,
        state.config.defaultOutputDir,
        state.config.intermediateDir,
        state.config.editMode,
        state.config.useNodeEditorLandscape,
        state.config.autosaveEnabled,
        state.config.autosaveIntervalSec,
        state.config.maxConcurrentTasks,
        state.config.probeThreads,
        state.config.enableSystemNotification,
        state.config.highRefreshRate,
        state.config.noPreload,
        state.config.debugMode,
        state.config.saveLogs,
        state.config.logSavePath,
        state.config.autoCheckUpdate,
        // mcpEnabled 之前漏在签名外 —— MCP 总开关是 SwitchListTile（受控控件，
        // value 直读 config），点击后配置写盘成功但整页不重建，开关视觉上纹丝不动，
        // 与 noPreload / 字重 是同一条根因。
        state.config.mcpEnabled,
        state.config.mcpPort,
        state.config.mcpHost,
        state.config.mcpAllowWrite,
        state.config.mcpAllowFsAccess,
        state.config.aiEnabled,
        state.config.aiReadAccess,
        state.config.aiWriteAccess,
        state.config.aiAutoExecute,
        state.config.aiAllowAsk,
        // aiAskSkipTools 是工具白名单芯片（selected 直读 config 里的列表），
        // 不在签名里则勾选后芯片不变色。updateConfig 会替换整个 List 实例，
        // 因此清单身份哈希能正确变化。
        state.config.aiAskSkipTools,
        state.config.aiGraphMode,
        state.config.aiShowThinking,
        state.config.aiAutoTitle,
        state.config.aiTitlePrompt,
        state.config.aiSystemPrompt,
        state.config.aiApproveMode,
        state.config.activeAiProfileId,
      ]),
      builder: (context, _, _) {
        final state = context.read<AppState>();
        final s = AppStrings.of(state.config.language);
        final scheme = Theme.of(context).colorScheme;
        if (isMobilePlatform) {
          // ═══════════════════════════════════════
          // 移动端独立设置界面
          // ═══════════════════════════════════════
          final query = _query.trim().toLowerCase();
          final searching = query.isNotEmpty;
          final visible = <(_SectionDef, List<_CardDef>)>[];
          for (final sec in _sections) {
            final hits = sec.cards.where((c) => c.matches(query)).toList();
            if (hits.isNotEmpty) visible.add((sec, hits));
          }

          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(children: [
              // 全屏可滚动的设置列表（顶部留出药丸空间）
              // 不再包 RepaintBoundary：之前的 RepaintBoundary 把 ListView 内容缓存成独立层，
              // 导致 OCLiquidGlassGroup 的 _onScroll→markNeedsPaint 在该缓存层下被吞掉，
              // shader 的场景坐标永远停在旧位置 → 玻璃在滚动后消失。
              // 各玻璃卡片内部已有 OCLiquidGlassGroup→RepaintBoundary→OCLiquidGlass 的
              // 独立层，隔绝了无关重绘，不再需要外层 RepaintBoundary。
              if (visible.isEmpty && searching)
                _emptyState(scheme, s)
              else
                ListView(
                  // addRepaintBoundaries:false：卡片内的壁纸开窗 painter 必须每帧
                  // 按当前变换重算（若子项被 RepaintBoundary 缓存，滚动时缓存
                  // 平移会重新引入「玻璃与背景错位」）。
                  // 左右留白全部交给分区卡自己（见 _buildMobileSection 的 14px 内边距），
                  // ListView 只负责上下：顶部药丸占位 + 底部导航栏净空。
                  addRepaintBoundaries: false,
                  padding: EdgeInsets.fromLTRB(
                      0,
                      MobileUi.pageTopPadding(context),
                      0,
                      MobileUi.navClearanceFor(
                          MobileNavPlacementScope.of(context))),
                  children: [
                    for (final (sec, cards) in visible)
                      _buildMobileSection(sec, cards, context, state, scheme, s),
                    const SizedBox(height: 16),
                  ],
                ),
              // 顶部药丸浮层（不影响滚动）
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildMobileTopBar(s, scheme),
              ),
            ]),
          );
        }

        // ═══════════════════════════════════════
        // 桌面端设置界面：左侧主菜单（分区导航）+ 右侧子选项面板
        // ═══════════════════════════════════════
        final query = _query.trim().toLowerCase();
        final searching = query.isNotEmpty;

        // 搜索时跨分区收集命中卡片（右侧分组展示）；未搜索时只看选中分区
        final hitsBySection = <(_SectionDef, List<_CardDef>)>[];
        for (final sec in _sections) {
          final hits = sec.cards.where((c) => c.matches(query)).toList();
          if (hits.isNotEmpty) hitsBySection.add((sec, hits));
        }
        // 选中分区兜底（分区增删后不悬空）
        if (_sections.indexWhere((sec) => sec.id == _selectedSection) < 0) {
          _selectedSection = _sections.first.id;
        }
        final selectedSec =
            _sections.firstWhere((sec) => sec.id == _selectedSection);

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(children: [
            GlassTopBar(
              title: Text(s.settingsTitle),
              center: _searchField(scheme, s),
            ),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // 左：主菜单（分区导航，搜索时显示命中数徽标）
                _buildSectionNav(hitsBySection, searching, scheme, state),
                // 右：子选项面板（搜索时为跨分区命中结果）
                Expanded(
                  child: searching
                      ? (hitsBySection.isEmpty
                          ? _emptyState(scheme, s)
                          : _buildSearchResults(hitsBySection, context, state, scheme))
                      : _buildSectionPane(selectedSec, context, state, scheme),
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }

  // ── 桌面端专用：左侧主菜单 + 右侧子选项面板 ──

  /// 左侧主菜单：分区导航列表。
  /// 搜索时每项右侧显示该分区的命中数量徽标；点击即退出搜索并切换分区。
  Widget _buildSectionNav(
    List<(_SectionDef, List<_CardDef>)> hitsBySection,
    bool searching,
    ColorScheme scheme,
    AppState state,
  ) {
    final hitCounts = <String, int>{
      for (final (sec, cards) in hitsBySection) sec.id: cards.length,
    };
    return SizedBox(
      width: 190,
      child: ListView(
        // addRepaintBoundaries:false —— 子项是玻璃卡（BackdropFilter），而 Skia 下
        // BackdropFilter 的输入会被光栅缓存：外层若套 RepaintBoundary，玻璃自身
        // 内容不变时引擎直接复用上一次的滤波快照，滚动后玻璃里仍是旧背景
        //（见 LiquidGlassBackdrop 顶部的图层约定）。左栏几乎不滚动，关掉无碍。
        addRepaintBoundaries: false,
        padding: const EdgeInsets.fromLTRB(10, 12, 6, 16),
        children: [
          for (final sec in _sections)
            Padding(
              // 每个父选项各占一张卡（原先是裸排在左栏上、未选中态完全透明）：
              // 用户反馈「通用 / 外观等父选项没有框包裹」。走 _cardShell → AppCard
              // 后左栏与右侧面板同材质，同样跟随「主题 → 样式 → 卡片样式」。
              // 圆角 12 与 _navItem 的选中胶囊一致 —— 选中时胶囊正好贴满整张卡。
              padding: const EdgeInsets.only(bottom: 6),
              child: _cardShell(
                context,
                state,
                _navItem(sec, searching, hitCounts[sec.id] ?? 0, scheme),
                radius: 12,
              ),
            ),
        ],
      ),
    );
  }

  /// 主菜单条目：图标 + 分区名，选中态为主题色药丸（颜色/字重随选中过渡）。
  Widget _navItem(
    _SectionDef sec,
    bool searching,
    int hitCount,
    ColorScheme scheme,
  ) {
    final selected = sec.id == _selectedSection;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _selectSection(sec.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? scheme.primary.withAlpha(34) : Colors.transparent,
          border: Border.all(
              color: selected ? scheme.primary.withAlpha(90) : Colors.transparent),
        ),
        child: Row(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: Icon(
              sec.icon,
              key: ValueKey('${sec.id}_$selected'),
              size: 16,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sec.title(AppStrings.of(context.read<AppState>().config.language)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          // 搜索时：该分区命中的设置项数量徽标
          if (searching)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(28),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text('$hitCount',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary)),
            ),
        ]),
      ),
    );
  }

  /// 右侧面板：当前分区的全部设置卡片。
  /// 切换分区时淡入 + 轻微位移动画；列数随窗口宽度自适应。
  Widget _buildSectionPane(
    _SectionDef sec,
    BuildContext ctx,
    AppState state,
    ColorScheme scheme,
  ) {
    return LayoutBuilder(builder: (ctx, cons) {
      // 窄窗口单列，宽窗口最多三列
      final cols = cons.maxWidth < 640 ? 1 : (cons.maxWidth < 1100 ? 2 : 3);
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0.02, 0), end: Offset.zero)
                .animate(anim),
            child: child,
          ),
        ),
        child: SingleChildScrollView(
            key: ValueKey('pane_${sec.id}'),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            // 分区标题行（左侧菜单已高亮当前分区，这里提供上下文）
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Row(children: [
                Icon(sec.icon, size: 16, color: scheme.primary),
                const SizedBox(width: 7),
                Text(
                    sec.title(
                        AppStrings.of(ctx.read<AppState>().config.language)),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const SizedBox(width: 12),
                Expanded(
                    child: Divider(
                        color: scheme.outlineVariant.withAlpha(70), height: 1)),
              ]),
            ),
            MasonryGrid(
              columns: cols,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in sec.cards)
                  // GlobalKey：搜索结果「定位」时用 Scrollable.ensureVisible 滚到这里
                  KeyedSubtree(
                    key: _cardKey(c.id),
                    child: _highlightWrap(
                      c.id,
                      // 不包 RepaintBoundary：它会光栅缓存玻璃卡的开窗 painter，
                      // 滚动时直接复用旧图层平移 → 卡内壁纸跟着卡片走
                      //（见 app_card 的 _WallpaperWindowPainter）。
                      // 搜索定位依赖外层 KeyedSubtree 的 GlobalKey，与本层无关。
                      c.build(ctx, state),
                    ),
                  ),
              ],
            ),
          ]),
        ),
      );
    });
  }

  /// 搜索结果面板：跨分区列出所有命中的设置卡片，按分区分组。
  Widget _buildSearchResults(
    List<(_SectionDef, List<_CardDef>)> hitsBySection,
    BuildContext ctx,
    AppState state,
    ColorScheme scheme,
  ) {
    return LayoutBuilder(builder: (ctx, cons) {
      final cols = cons.maxWidth < 640 ? 1 : (cons.maxWidth < 1100 ? 2 : 3);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          for (final (sec, cards) in hitsBySection) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Row(children: [
                Icon(sec.icon, size: 14, color: scheme.primary),
                const SizedBox(width: 7),
                Text(
                    sec.title(
                        AppStrings.of(ctx.read<AppState>().config.language)),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                        color: scheme.primary)),
                const SizedBox(width: 8),
                Text('${cards.length}',
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
                const SizedBox(width: 12),
                Expanded(
                    child: Divider(
                        color: scheme.outlineVariant.withAlpha(70), height: 1)),
              ]),
            ),
            MasonryGrid(
              columns: cols,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in cards)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 搜索结果头：分区 · 卡片名 + 「定位」按钮 ——
                      // 点一下即切到该分区、把卡片滚进视野并高亮（设置页搜索的核心动作）。
                      _resultHeader(sec, c, scheme, AppStrings.of(state.config.language), ctx),
                      _highlightWrap(
                        c.id,
                        // 同上：不包 RepaintBoundary，避免开窗 painter 被缓存。
                        c.build(ctx, state),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ]),
      );
    });
  }

  // ── 移动端专用 ──

  /// 移动端顶栏：统一走 [MobilePillTopBar]（主界面基准的唯一实现）——
  /// 左标题药丸 + 右搜索按钮药丸；搜索时标题层淡出缩放，同一颗搜索药丸
  /// 从 44px「变长」到 200px 并水平居中，关闭即收起并清空。
  Widget _buildMobileTopBar(AppStrings s, ColorScheme scheme) {
    return MobilePillTopBar(
      title: Text(s.settingsTitle),
      actions: [
        MobileGlassPillAction(
          icon: Icons.search,
          tooltip: s.setSearchHint,
          color: scheme.onSurface,
          onTap: () {
            setState(() => _searchExpanded = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _searchFocus.requestFocus();
            });
          },
        ),
      ],
      // 主界面不折叠（用户要求「主界面不要搞...了」）。本页常驻操作只有「搜索」
      // 一个，本来也不会折叠，这里显式关掉以免以后加操作时行为与其它主界面不一致。
      collapseActions: false,
      searching: _searchExpanded,
      // 搜索药丸：与主界面（项目页）共用同一实现，不再各写一份
      searchChild: MobileSearchPill(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        hint: s.setSearchHint,
        onChanged: (v) => setState(() => _query = v),
        onClose: () {
          setState(() {
            _searchExpanded = false;
            _searchCtrl.clear();
            _query = '';
          });
          _searchFocus.unfocus();
        },
      ),
    );
  }

  /// 移动端设置分区：Android 16 原生设置风格 —— 小号字重标题，
  /// 无图标、无着色，仅灰色文字（onSurfaceVariant），下方为卡片项。
  /// Android 16 风格移动端分区：一级菜单只展示「标题在左、开关/箭头在右」的设置行，
  /// 具体设置项进入二级菜单。
  ///
  /// **一主题一卡**（2026-09-14 改）：此前整个分区的设置行被合并进同一张圆角卡片、
  /// 行之间用细分隔线，于是「主题色 / 背景 / 表面样式 / 玻璃细节 / 字体」看起来是
  /// 一大坨（用户反馈「卡片给我分开，按主题分开不要合并到一块」）。现在每个
  /// [_CardDef]（= 一个主题）各占一张卡，与桌面端右侧面板「一卡一主题」的粒度一致。
  Widget _buildMobileSection(
    _SectionDef sec,
    List<_CardDef> cards,
    BuildContext context,
    AppState state,
    ColorScheme scheme,
    AppStrings s,
  ) {
    if (cards.isEmpty) return const SizedBox.shrink();

    // 一个分区 = 一张卡：条目之间用细分隔线区分。
    //
    // 曾经改成「一主题一卡」（每个设置项各占一张卡），但用户明确要求
    // 「设置界面你不要每个都分开，像是主题、背景等整合到一张卡片」，
    // 于是回到分区级卡片 —— 视觉上更整、滚动距离更短，靠分隔线仍能分清单项。
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      // 全局搜索跳转过来时高亮命中的设置行（见 _highlightWrap）
      rows.add(KeyedSubtree(
        key: _cardKey(cards[i].id),
        child: _highlightWrap(
            cards[i].id, _buildMobileRow(cards[i], context, state, scheme, s)),
      ));
      if (i < cards.length - 1) {
        rows.add(Divider(
          height: 0.5,
          thickness: 0.5,
          indent: 16,
          endIndent: 16,
          color: scheme.outlineVariant.withAlpha(60),
        ));
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(sec.title(s), style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
          letterSpacing: 0.3,
        )),
      ),
      Padding(
        // 卡片左右内边距 14（原 8）：用户反馈「设置的卡片宽度过宽，再缩小」。
        // 二级页为 subListPadding 12 + _glass 12 = 24，比一级菜单更窄一点，
        // 刻意保留这个两级层次差别。底部 7 = 相邻两张卡之间的间距。
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
        // 分区卡统一走 _cardShell → AppCard，遵循「主题→样式→卡片样式」。
        child: _cardShell(context, state, Column(children: rows)),
      ),
    ]);
  }

  /// 一条设置行：左标题，右侧开关 / 分段切换 / 箭头（进入二级菜单）。
  Widget _buildMobileRow(
    _CardDef c, BuildContext context, AppState state, ColorScheme scheme, AppStrings s) {
    final title = c.title(s);

    // 纯开关：直接在一级菜单右侧放 Switch
    if (c.id == 'predictiveBack') {
      final cfg = state.config;
      return SwitchListTile(
        value: cfg.predictiveBack,
        onChanged: (v) => state.updateConfig((cc) => cc..predictiveBack = v),
        secondary: _miIcon(scheme, c.icon),
        title: Text(title, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
        subtitle: Text(s.predictiveBackHint,
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      );
    }

    // 语言：一级菜单右侧放紧凑的中/EN 分段切换
    if (c.id == 'language') {
      return _mobileLanguageRow(state, scheme, c.icon);
    }

    // 命令 / 日志：直接进入对应页面（它们的「内容」本身就是入口，不套二级页）
    return ListTile(
      leading: _miIcon(scheme, c.icon),
      title: Text(title, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
      trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      onTap: () {
        if (c.id == 'command') {
          // CommandPage / LogPage 自身已用 withWallpaper 铺壁纸，且顶栏自带安全区
          // 偏移。这里若再套一层 withWallpaper + SafeArea：
          //   1) 双层壁纸多解码一次并多一层遮罩；
          //   2) SafeArea 会把子树的 MediaQuery.padding.top 清零 → 顶栏被状态栏压住。
          Navigator.of(context).push(
              MaterialPageRoute(allowSnapshotting: false, builder: (_) => const CommandPage()));
        } else if (c.id == 'logs') {
          Navigator.of(context).push(
              MaterialPageRoute(allowSnapshotting: false, builder: (_) => const LogPage()));
        } else if (c.id == 'cache') {
          // 缓存：直接弹出确认框，不进入二级页
          _clearCache(context, state, scheme, s);
        } else {
          _pushMobileSubPage(context, title, c.build);
        }
      },
    );
  }

  /// 语言行：左边「语言」标题，右边中文 / EN 紧凑分段切换。
  Widget _mobileLanguageRow(AppState state, ColorScheme scheme, IconData icon) {
    final cfg = state.config;
    return ListTile(
      leading: _miIcon(scheme, icon),
      title: Text(AppStrings.of(cfg.language).language,
          style: TextStyle(fontSize: 14, color: scheme.onSurface)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      // 统一「菜单栏选项」控件：行内分段药丸（选中主题色药丸 + 图标淡入动画）
      //
      // 宽度 108：两个短选项（中文 / EN）足够紧凑。此前 128 时两段各约 62px，
      // 在只有 2~3 个汉字的标签旁留下大片空白，视觉上「选项卡过宽」。
      trailing: SizedBox(
        width: 108,
        child: OptionMenuBar<String>(
          expandable: false,
          value: cfg.language,
          items: const [
            OptionItem('zh', '中文'),
            OptionItem('en', 'EN'),
          ],
          onChanged: (v) => state.updateConfig((c) => c..language = v),
        ),
      ),
    );
  }

  /// 二级设置页：全屏（覆盖底部导航栏），顶部返回栏 + 可滚动内容。
  ///
  /// 薄包装：真正的实现在顶层函数 [_pushSettingsSubPage]。之所以提升出去，是因为
  /// 「外观 → 样式 → 玻璃细节」这类**三级**页的入口写在顶层的卡片构建函数
  /// （[_buildSurfaceStyleCard]）里，那里拿不到 State 实例。
  void _pushMobileSubPage(
    BuildContext context, String title, Widget Function(BuildContext, AppState) contentBuilder) {
    _pushSettingsSubPage(context, title, contentBuilder);
  }

  Widget _searchField(ColorScheme scheme, AppStrings s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: LayoutBuilder(builder: (ctx, cons) => SizedBox(
          width: math.min(260.0, cons.maxWidth * 0.62),
          height: 38,
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
            textAlignVertical: TextAlignVertical.center,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: s.setSearchHint,
              hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withAlpha(90),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              prefixIcon: Icon(Icons.search, size: 17, color: scheme.outline),
              prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, size: 15, color: scheme.outline),
                      tooltip: s.setClearSearch,
                      onPressed: _clearSearch,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(19),
                borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(19),
                borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(19),
                borderSide: BorderSide(color: scheme.primary.withAlpha(160), width: 1.4),
              ),
            ),
          ),
        ),
        ),
      );

  Widget _emptyState(ColorScheme scheme, AppStrings s) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off, size: 44, color: scheme.outline.withAlpha(140)),
          const SizedBox(height: 12),
          Text(s.setNoMatch, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(s.setNoMatchHint, style: TextStyle(fontSize: 11, color: scheme.outline)),
          const SizedBox(height: 14),
          TextButton.icon(
            icon: const Icon(Icons.close, size: 15),
            label: Text(s.setClearSearch, style: const TextStyle(fontSize: 12)),
            onPressed: _clearSearch,
          ),
        ]),
      );
}


/// 带标签的滑块，拖动时对写入全局配置做节流。
///
/// 原来 `onChanged` 直接调 `state.updateConfig`，而它会 `notifyListeners()`，
/// 于是拖一次滑块 = 每秒 60 次整棵树重建（设置页有十几张卡片）。
/// 这里把滑块位置和标签放在本地 state 里做到即时跟手，全局配置最多每 40ms 推一次，
/// 松手时再补一次精确值——预览照样是实时的，重建次数少了三分之二。

/// 设置卡片容器。
/// 移动端：Android 16 原生设置风格 —— 低对比度主题色卡片（surfaceContainerLow），
/// 无玻璃光效，仅简洁的圆角 + 细边框 + 弱阴影，清晰易读。
/// 桌面端：保持原有玻璃效果（liquid/blur/none）与透明度。
/// MIUI 风格行首图标块：圆角方底 + 主题色图标，用于移动端一级菜单设置行。
Widget _miIcon(ColorScheme scheme, IconData icon) => Container(
  width: 34,
  height: 34,
  decoration: BoxDecoration(
    color: scheme.primary.withAlpha(0x28),
    borderRadius: BorderRadius.circular(10),
  ),
  child: Icon(icon, size: 19, color: scheme.primary),
);

/// 设置页分组卡片外壳 —— 所有分组卡（设置行 / AI·MCP 卡 / 各设置卡）
/// 统一委托给 AppCard，由「主题→样式→卡片样式」（cfg.cardStyle 四值）接管：
/// 跟随主题色(纯色) / 液态玻璃 / 模糊 / 灰色。
///
/// 玻璃卡在滚动中的「图层分离」由 app_card 的壁纸开窗（绑定渲染）根治：
/// 卡片 paint 时直接画静态壁纸、按当前帧变换对齐，不再有采样滞后，
/// 因此这里不再需要任何「滚动降级 / 变色」机制（已整体移除）。
Widget _cardShell(
  BuildContext ctx,
  AppState state,
  Widget child, {
  double radius = 18,
}) {
  return AppCard(
    style: state.config.cardStyle,
    radius: radius,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: double.infinity),
      child: child,
    ),
  );
}

/// 设置二级 / 三级页：全屏（覆盖底部导航栏），顶部返回栏 + 可滚动内容。
///
/// 顶层函数（原先只是 `_SettingsPageState._pushMobileSubPage` 私有方法）：三级页
/// （如「外观 → 样式 → 玻璃细节」）的入口写在顶层的卡片构建函数里，拿不到 State，
/// 所以打开逻辑必须能在顶层直接调用。State 里的 [_SettingsPageState._pushMobileSubPage]
/// 保留为同名薄包装，既有二级页调用点无需改动。
void _pushSettingsSubPage(
  BuildContext context,
  String title,
  Widget Function(BuildContext, AppState) contentBuilder,
) {
  Navigator.of(context).push(MaterialPageRoute(allowSnapshotting: false,
    builder: (ctx) => Consumer<AppState>(
      builder: (ctx2, state, _) => withWallpaper(
        ctx2,
        Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(children: [
            MobileSubPageTopBar(
              title: Text(title),
              onBack: () => Navigator.of(ctx2).maybePop(),
            ),
            Expanded(
              child: ListView(
                // addRepaintBoundaries:false —— 见移动端主列表同款注释：
                // 壁纸开窗 painter 必须每帧按当前变换重算，不能被子项缓存平移。
                // 左右间距与设置主界面卡片对齐（主界面 = ListView + 分区卡内边距 14）。
                // 此前为 0：MCP/AI 等二级页卡片通顶通底，比主界面卡片明显更宽。
                addRepaintBoundaries: false,
                padding: MobileUi.subListPadding(top: 12, bottom: 48),
                children: [contentBuilder(ctx2, state)],
              ),
            ),
          ]),
        ),
      ),
    )));
}

Widget _glass(BuildContext ctx, AppState state, String title, List<Widget> children) {
  const radius = 20.0;
  const pad = EdgeInsets.fromLTRB(16, 12, 16, 12);
  final onSurfaceVariant = Theme.of(ctx).colorScheme.onSurfaceVariant;

  final titleRow = Padding(
    padding: pad,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: onSurfaceVariant)),
      const SizedBox(height: 8),
      ...children,
    ]),
  );

  return Padding(
    // 卡片相对内容区的左右留白（10 → 12）：用户反馈「设置的卡片宽度过宽，再缩小」。
    // 主界面列表行另有 14px 分区内边距（见 _buildMobileSection），两级合计 26；
    // 二级页为 subListPadding 12 + 这里 12 = 24，与主界面基本对齐。
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
    child: _cardShell(ctx, state, titleRow, radius: radius),
  );
}

/// 二级页里的「三级页入口」行：图标 + 标题 + 一行作用说明 + 右箭头。
///
/// 抽成共享实现的原因：玻璃细节 / 编辑模式 / 自动保存等入口形态完全一样，
/// 各写一遍就会在字号、内边距、图标尺寸上互相差几个 px（用户对这类不一致
/// 很敏感）。调用前**自己加一条细分隔线**（`Divider` height 1）与上方内容分开。
Widget _subPageEntry(
  BuildContext ctx,
  ColorScheme scheme,
  Color clr, {
  required IconData icon,
  required String label,
  required String scope,
  required VoidCallback onTap,
}) {
  return InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 15, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: clr, fontSize: 12)),
                const SizedBox(height: 2),
                Text(scope,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
              ]),
        ),
        Icon(Icons.chevron_right, size: 18, color: scheme.outline),
      ]),
    ),
  );
}

/// 路径字段（标签 + 输入框 + 浏览按钮）
Widget _pf(BuildContext ctx, String label, String value, ValueChanged<String> onChange, VoidCallback onBrowse) {
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, color: clr)),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(child: _PathField(value: value, label: '', scheme: scheme, onChange: onChange)),
        const SizedBox(width: 6),
        OutlinedButton(
          onPressed: onBrowse,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
          child: const Icon(Icons.folder_open, size: 16),
        ),
      ]),
    ]),
  );
}

/// 链接按钮
/// 小号链接（博客/GitHub 等），不再是占满全宽的大按钮。
Widget _link(String label, String url) => TextButton.icon(
  onPressed: () => openExternalUrl(url),
  icon: const Icon(Icons.open_in_new, size: 12),
  label: Text(label, style: const TextStyle(fontSize: 11)),
  style: TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    minimumSize: const Size(0, 28),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    // 这里原本写死 `foregroundColor: Color(0xFF5E6AD2)`（= 默认种子色）。
    // 后果：换主题色后这些链接仍是紫蓝色（浅色主题下比主题 primary 更亮更艳），
    // 与旁边所有主题化控件不协调。删掉后走 TextButton 的默认
    // colorScheme.primary，自动跟随主题 —— 同时这也修掉了「硬件写死不改主题」。
  ),
);

/// 信息行（关于页）
Widget _infoRow(String label, String value, ColorScheme scheme, {Widget? trailing}) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Row(children: [
    Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
    ?trailing,
    Flexible(
      child: Tooltip(message: value, child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurface, fontWeight: FontWeight.w500)),
      ),
    ),
  ]),
);

/// iOS 风格按钮
Widget _iosButton({
  required IconData icon, required String label,
  required Color color, required Color bg, required VoidCallback onTap,
}) => Material(
  color: bg,
  borderRadius: BorderRadius.circular(14),
  child: InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
            overflow: TextOverflow.ellipsis)),
      ]),
    ),
  ),
);

/// 主题色圆点
Widget _dot(ColorScheme sc, bool sel, Color c, String tip, VoidCallback onTap) => Tooltip(
  message: tip,
  child: GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 28, height: 28,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(
          color: sel ? sc.primary : Colors.transparent,
          width: 3,
        ),
      ),
      child: sel ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
    ),
  ),
);

/// 自定义取色入口按钮（内联于 _buildTheme，见其 Wrap 实现）


class _SettingSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) label;
  final TextStyle labelStyle;
  final ValueChanged<double> onCommit;

  /// 拖动过程中就写回配置（而不仅仅是松手时写一次）。
  ///
  /// 默认 false：只改本地状态，父级不重建，滑动全程流畅无中断。
  /// 字号滑块传 true —— 用户要的是「滑一下就能看出整个界面变大变小」，
  /// 松手才生效的话，在一堆 12~13px 的文字里很难察觉到变化
  /// （用户反馈的「滑动滑块后软件实际字体大小并未发生变化」）。
  final bool liveCommit;

  const _SettingSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.labelStyle,
    required this.onCommit,
    this.divisions,
    this.liveCommit = false,
  });

  @override
  State<_SettingSlider> createState() => _SettingSliderState();
}

class _SettingSliderState extends State<_SettingSlider> {
  double? _dragValue;

  /// [ _SettingSlider.liveCommit] 的节流定时器：拖动时每 80ms 才写一次配置，
  /// 否则每帧都 notifyListeners → 整页（含液态玻璃卡片）逐帧重建会掉帧。
  Timer? _liveTimer;
  static const Duration _liveThrottle = Duration(milliseconds: 80);

  double get _current => _dragValue ?? widget.value;

  void _onChanged(double v) {
    setState(() => _dragValue = v);
    // 仅本地更新不触发父级重建，确保滑动全程流畅无中断
    if (!widget.liveCommit) return;
    _liveTimer?.cancel();
    _liveTimer = Timer(_liveThrottle, () {
      if (mounted) widget.onCommit(v);
    });
  }

  void _onChangeEnd(double v) {
    _liveTimer?.cancel();
    _liveTimer = null;
    widget.onCommit(v);
    setState(() => _dragValue = null);
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // 布局约定（用户要求）：**上面**是描述该项滑块改变的内容（如「字号: 17」），
      // **下面**才是滑块本体，且滑块独占一整行（不再与标签左右分栏）。
      // 旧实现是 `Row(label, Expanded(slider))`：标签与滑块挤在一行，长标签
      // （如「边框宽度」）会把滑块压窄，滑动手感与可读性都差。
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.label(_current),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.labelStyle),
        const SizedBox(height: 2),
        // 统一走 AppSlider（全应用唯一滑块实现）：胶囊轨道 + 主题色填充 +
        // 玻璃留空 + 拖动粒子。裸 Slider 拿不到玻璃底（那需要一层 widget），
        // 所以这里改为显式使用 AppSlider，不要再改回 `Slider(`。
        AppSlider(
          value: _current.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: _onChanged,
          onChangeEnd: _onChangeEnd,
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════
// 各设置卡片
// ═══════════════════════════════════════════

const _presets = [
  ('Linear Purple', 0xFF5E6AD2), ('Ocean Blue', 0xFF3B82F6),
  ('Emerald', 0xFF10B981), ('Amber', 0xFFF59E0B),
  ('Rose', 0xFFEF4444), ('Cyan', 0xFF06B6D4), ('Violet', 0xFF8B5CF6),
];

const _kDefaultAnthropicModel = 'claude-3-5-sonnet-20241022';

/// 询问模式下可选「无需确认」的操作 key。
///
/// 只存 key、显示名由 [_askSkipLabel] 按语言给出：原先这里把中文显示名写进常量，
/// 英文界面下这 5 个 chip 恒为中文（与 ai_settings_mobile.dart 里同款 bug 一并修掉）。
const _askSkipKeys = <String>['save', 'undo_redo', 'error_check', 'clear_all', 'tools'];

String _askSkipLabel(String key, bool isZh) => switch (key) {
      'save' => isZh ? '保存' : 'Save',
      'undo_redo' => isZh ? '撤销/重做' : 'Undo/Redo',
      'error_check' => isZh ? '错误检查' : 'Error check',
      'clear_all' => isZh ? '清空画布' : 'Clear canvas',
      'tools' => isZh ? '工具执行' : 'Run tools',
      _ => key,
    };

/// 主题卡：模式 / 主题色 / 背景 / 样式（卡片样式、底部菜单栏样式、
/// 顶部药丸样式、节点编辑器）。桌面端内联在「外观」分区，移动端作为
/// 一级菜单「主题」行的二级菜单内容。
/// 「外观 → 主题」卡片：亮/暗模式 + 主题色（预设/自定义渐变/Android 动态取色）。
///
/// 拆分说明：此前「主题」一张卡把 模式 + 主题色 + 背景 + 表面样式 + 画布样式 +
/// 逻辑门标准 全塞在一起（单卡 130+ 行控件，移动端要滑很久才找到一项）。现按
/// 关注点拆为 主题 / 背景 / 表面样式 / 节点编辑器 四张卡，各自可被搜索命中。
Widget _buildTheme(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  // 动态取色开启时，自定义主题色（预设/取色器）不生效
  final dynamicOn = isMobilePlatform && cfg.useDynamicColor;

  // 二级页「按主题分开、不要集中在一个卡片内」（用户要求）：本页拆成两张卡 ——
  // ① 模式（亮 / 暗）② 主题色（预设 / 自定义取色 / 动态取色 / 协调度）。
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _glass(ctx, state, s.isZh ? '模式' : 'Appearance mode', [
      // 亮 / 暗色切换
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(s.themeMode, style: TextStyle(color: clr)),
          subtitle: Text(state.darkMode ? s.darkMode : (s.isZh ? '浅色模式' : 'Light Mode'),
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          value: state.darkMode,
          onChanged: (v) => state.toggleDarkMode(v)),
    ]),
    const SizedBox(height: 8),
    _glass(ctx, state, s.isZh ? '主题色' : 'Accent color', [
    // ── 主题色（预设 / 自定义 / 动态取色） ──
    Row(children: [
      Expanded(child: Text(s.accentColor, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: clr, fontSize: 12))),
      if (dynamicOn) ...[
        Icon(Icons.auto_awesome, size: 12, color: scheme.primary),
        const SizedBox(width: 4),
        Flexible(child: Text(s.themeDynamicOn,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.primary))),
      ],
    ]),
    // Android Monet 动态取色（跟随系统壁纸）；开启后自定义主题色不生效
    if (isMobilePlatform)
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(s.themeDynamicColor, style: TextStyle(color: clr, fontSize: 12)),
          subtitle: Text(s.themeDynamicColorHint,
              style: TextStyle(fontSize: 10, color: scheme.outline)),
          value: cfg.useDynamicColor,
          onChanged: (v) => state.updateConfig((c) => c..useDynamicColor = v)),
    const SizedBox(height: 8),
    // 预设色 + 自定义取色：动态取色开启时置灰禁用
    Opacity(
      opacity: dynamicOn ? 0.35 : 1.0,
      child: IgnorePointer(
        ignoring: dynamicOn,
        child: Wrap(spacing: 8, runSpacing: 8, children: [
      ..._presets.map((p) => _dot(scheme, cfg.themeColor == p.$2 && cfg.themeColor2 < 0, Color(p.$2), p.$1,
          () => state.updateConfig((c) => c..themeColor = p.$2..themeColor2 = -1))),
      // 自定义取色：若已设渐变色则显示渐变圆点，点击进入渐变/纯色设置
      GestureDetector(
        onTap: () => _pickColor(ctx, state),
        child: Tooltip(
          message: cfg.themeColor2 >= 0 ? (state.config.language == 'zh' ? '当前渐变色' : 'Current gradient') : (state.config.language == 'zh' ? '自定义（支持渐变）' : 'Custom (gradient)'),
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: cfg.themeColor2 >= 0
                  ? LinearGradient(colors: [Color(cfg.themeColor), Color(cfg.themeColor2)], begin: Alignment.topLeft, end: Alignment.bottomRight)
                  : const LinearGradient(colors: [Color(0xFFFF5F6D), Color(0xFFFFC371), Color(0xFF36D1DC), Color(0xFF5B86E5)]),
              border: Border.all(color: cfg.themeColor2 >= 0 ? scheme.primary : scheme.outlineVariant.withAlpha(80), width: cfg.themeColor2 >= 0 ? 2 : 1),
            ),
            child: const Icon(Icons.add, size: 14, color: Colors.white),
          ),
        ),
      ),
          ]),
        ),
      ),
    const SizedBox(height: 6),
    // ── 主题色协调度 ──
    // 「跟随主题色」大面积铺底时若直接用 scheme.primary（暗色下是 tone 80 的
    // 高亮色）非常刺眼 —— 用户反馈「选择主题色又很亮」。这里给一个 0~0.8 的
    // 混合系数：0% = 原色（与改动前一致），越大越并入表面色。由
    // liquid_glass_fallback.harmonizedAccent 统一应用到所有「跟随主题色」的
    // 玻璃/实色表面（AppCard / MobileGlassPill / MobileBottomNav / GlassPanel）。
    _SettingSlider(
      value: cfg.themeTone, min: 0, max: 0.8, divisions: 16,
      label: (v) => '${s.isZh ? '主题色协调度' : 'Accent harmony'}: ${(v * 100).round()}%',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..themeTone = v),
    ),
    Text(s.isZh
            ? '仅作用于「跟随主题色」的卡片 / 底栏 / 药丸底色，0% 即原主题色'
            : 'Only affects accent-tinted cards, nav bar and pills; 0% = raw accent',
        style: TextStyle(fontSize: 10, color: scheme.outline)),
    ]),
  ]);
}

/// 「外观 → 背景」卡片：壁纸选择 + 不透明度（原 _ThemeBackgroundSection）。
Widget _buildBackgroundCard(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.isZh ? '背景' : 'Background', const [
    _ThemeBackgroundSection(),
  ]);
}

/// 「外观 → 表面样式」二级页。
///
/// **按主题拆成 4 张卡**（用户反馈「二级菜单卡片给我分开，按主题分开不要合并到
/// 一块」——此前 预设 / 表面样式 / 面板玻璃 / 开关们 / 边框 / 粒子 全挤在同一张卡里，
/// 找不到东西）：
/// ① 样式预设（整套外观一键切换）
/// ② 表面样式（卡片 / 菜单 / 底部菜单栏 / 顶部药丸，逐项调 + 模糊度）
/// ③ 玻璃与材质（面板玻璃 / 玻璃底色 / 设置卡片玻璃 / GPU / 添加边框）
/// ④ 特效（滑块粒子）
///
/// 返回 Column 是安全的：桌面端本函数被塞进 MasonryGrid 的单元格里，一个 Column
/// 就等价于「同一列的 4 张卡」，MasonryGrid 不会再包一层 AppCard（不会套娃）；
/// 移动端二级页把它放进 ListView，同样是 4 张独立的卡。
Widget _buildSurfaceStyleCard(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final zh = s.isZh;
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  // 只有真的有表面样式选了「模糊」，才需要那颗模糊度滑块（见下）。
  final bool anyBlur = cfg.cardStyle == SurfaceStyle.blur ||
      cfg.navStyle == SurfaceStyle.blur ||
      cfg.pillStyle == SurfaceStyle.blur ||
      (!isMobilePlatform && cfg.menuStyle == SurfaceStyle.blur);

  // 二级页也「一主题一张卡」。
  //
  // 口径变更史（改前必读）：**一级菜单**要求「一个分区一张卡」（整合成一张），
  // **二级页**反过来 —— 用户原话「你设置界面分的很好，但是二级菜单比如样式界面
  // (样式预设与表面样式等等)没有进行分开，而是集中在一个卡片内」。所以本页返回
  // **4 张独立卡**：样式预设 / 表面样式 / 玻璃与材质 / 特效，各自带自己的卡标题。
  // 桌面端这个返回值被放进 MasonryGrid 单元格，所以**绝不能在外面再包 AppCard**。
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    // ① 样式预设
    _glass(ctx, state, zh ? '样式预设' : 'Style presets',
        _buildStylePresets(ctx, state)),
    const SizedBox(height: 8),

    // ② 表面样式
    _glass(ctx, state, zh ? '表面样式' : 'Surface style', [
    // 布局统一：左 = 图标 + 文字（含作用范围说明），右 = 下拉菜单（展开动画）
    _styleRow(ctx,
        icon: Icons.view_carousel_outlined,
        label: s.cardStyleLabel,
        scope: s.cardStyleScope,
        value: cfg.cardStyle,
        onSelected: (v) => state.updateConfig((c) => c..cardStyle = v)),
    // 桌面端：左侧菜单栏 + 各页顶部菜单栏的表面样式（原来固定液态玻璃）
    if (!isMobilePlatform)
      _styleRow(ctx,
          icon: Icons.view_sidebar_outlined,
          label: s.isZh ? '菜单样式' : 'Menu Style',
          scope: s.isZh
              ? '作用于 左侧菜单栏 和 各页顶部菜单栏（仅桌面端）'
              : 'Applies to the sidebar and page top bars (desktop only)',
          value: cfg.menuStyle,
          onSelected: (v) => state.updateConfig((c) => c..menuStyle = v)),
    if (isMobilePlatform) ...[
      _styleRow(ctx,
          icon: Icons.menu,
          label: s.navStyleLabel,
          value: cfg.navStyle,
          onSelected: (v) => state.updateConfig((c) => c..navStyle = v)),
      // 菜单栏位置（仅移动端）：自动（宽屏 → 左侧竖排导轨）/ 底部 / 左侧 / 右侧。
      // 「自动」按屏幕横纵比判定，判定逻辑全应用只有一份
      // （platform/app_platform.dart 的 resolveMobileNavPlacement），
      // 这里只负责把用户的选择写进配置。
      _optionRow(ctx,
          icon: Icons.vertical_split_outlined,
          label: s.navPlacementLabel,
          scope: s.navPlacementScope,
          value: cfg.mobileNavPlacement,
          items: [
            OptionItem('auto', s.navPlacementAuto, icon: Icons.auto_mode),
            OptionItem('bottom', s.navPlacementBottom,
                icon: Icons.align_vertical_bottom),
            OptionItem('left', s.navPlacementLeft,
                icon: Icons.align_horizontal_left),
            OptionItem('right', s.navPlacementRight,
                icon: Icons.align_horizontal_right),
          ],
          onSelected: (v) =>
              state.updateConfig((c) => c..mobileNavPlacement = v)),
      _styleRow(ctx,
          icon: Icons.crop_landscape_outlined,
          label: s.pillStyleLabel,
          value: cfg.pillStyle,
          onSelected: (v) => state.updateConfig((c) => c..pillStyle = v)),
    ],
    // ── 「模糊」样式的模糊度 ──
    //
    // 用户要求：「如果样式选了模糊，那么下面的滑块就要能调节它的模糊度」。
    // 四个表面样式（卡片 / 菜单 / 底部菜单栏 / 顶部药丸）的 blur 分支都从同一个
    // `glassBlur` 取 σ（AppCard / MobileBottomNav / MobileGlassPill / GlassPanel），
    // 所以这颗滑块直接绑 `glassBlur` 就对全部「模糊」表面生效。它与「玻璃细节 →
    // 玻璃模糊度」是**同一个参数**，这里只是把它放到真正需要它的地方：
    // 仅当确实有表面选了「模糊」时才出现，因此不会多出一个常年可见的重复项。
    if (anyBlur) ...[
      const SizedBox(height: 6),
      _SettingSlider(
        value: cfg.glassBlur,
        min: 0,
        max: 30,
        divisions: 30,
        // 拖动过程中就写回配置：模糊度改的是整块卡片的模糊程度，若松手才生效，
        // 拖动时看着毫无变化，会被判定成「滑块坏了」（与字号滑块同一个坑）。
        liveCommit: true,
        label: (v) => '${zh ? '模糊度' : 'Blur'}: ${v.round()}',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..glassBlur = v),
      ),
      Text(
          zh
              ? '即时作用于所有「模糊」表面（卡片 / 菜单 / 底部菜单栏 / 药丸）；'
                  '与「玻璃细节 → 玻璃模糊度」是同一个参数'
              : 'Applies live to every "Blur" surface; same value as '
                  'Glass details → Blur',
          style: TextStyle(fontSize: 10, color: scheme.outline)),
    ],
    ]),
    const SizedBox(height: 8),

    // ③ 玻璃与材质
    _glass(ctx, state, zh ? '玻璃与材质' : 'Glass & material', [
    // ── 玻璃与材质各项（面板玻璃 / 玻璃底色 / 设置卡片玻璃 / GPU / 边框）──
    ..._buildGlassMaterialItems(ctx, state),

    // ── 玻璃细节入口（放在卡末：下行导航行按惯例排最后）──
    if (isMobilePlatform) ...[
      const SizedBox(height: 6),
      Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
      _subPageEntry(ctx, scheme, clr,
          icon: Icons.blur_on_outlined,
          label: zh ? '玻璃细节' : 'Glass details',
          scope: zh
              ? '模糊度 / 通透度 / 高光强度与位置 / 边缘光'
              : 'Blur, clarity, highlight position, edge light',
          onTap: () => _pushSettingsSubPage(
              ctx, zh ? '玻璃细节' : 'Glass details', _buildGlassDetailCard)),
    ],
    ]),
    const SizedBox(height: 8),

    // ④ 特效
    _glass(ctx, state, zh ? '特效' : 'Effects', _buildEffectItems(ctx, state)),
  ]);
}

/// 「玻璃与材质」卡的内容：面板玻璃效果 + 玻璃底色遵循主题色 + 设置卡片玻璃 +
/// GPU 液态玻璃 + 「添加边框」。
///
/// 2026-09-14 拆分：原先这些项与「样式预设 / 表面样式 / 滑块粒子」同挤在一张卡里
/// （用户反馈「二级菜单卡片给我分开，按主题分开不要合并到一块」），现已按主题拆开 ——
/// 本函数只保留「玻璃与材质」，预设与特效分别移到 [_buildStylePresets]（在
/// [_buildSurfaceStyleCard] 里单独成卡）与 [_buildEffectItems]。
///
/// 用户反馈与对应做法：
/// * 「液态玻璃效果选项放进样式里面」→ 原独立卡片并入「样式」二级页；
/// * 「模糊强度不管用…下面三个选项也不管用，而且也没有存在的必要」→ 删除折射强度/镜面高光/
///   模糊强度三个数值项（只作用于桌面 GPU shader 路径与模糊 σ，实测无感；σ 已回到各调用点常量）；
/// * 「样式里面增加『添加边框选项』，开启后为所有卡片以及药丸添加有线的边框，可改颜色和宽度」→
///   新增 borderEnabled/borderColor/borderWidth，由 widgets/liquid_glass_fallback.dart 的
///   withConfigurableBorder 统一叠加到所有卡片与药丸上。
///
/// 移动端可用性修复（用户反馈「设置-样式 里的玻璃效果与下面三个开关无效」）：
/// 这三个开关与「玻璃效果」此前只被桌面端的 [GlassPanel] 读取，而移动端的
/// 卡片 / 药丸 / 底部菜单栏走的是 AppCard、MobileGlassPill、MobileBottomNav，
/// 它们完全不读这些字段 —— 于是开关拨动后界面毫无变化。现在语义已经接通：
/// * glassFollowTheme → AppCard / MobileGlassPill / MobileBottomNav 的玻璃 tint；
/// * settingsFrostedGlass → AppCard 的「液态玻璃改走扁平模糊」分支；
/// * noCardGlass → AppCard 退回主题色实心；
/// * glassEffect → GlassPanel 系面板（弹窗 / 命令页 / 日志页 / 节点编辑器等）。
/// 三者默认均为 false，默认观感与修复前保持一致。
List<Widget> _buildGlassMaterialItems(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  final zh = s.isZh;

  return [
    // ── 玻璃效果（非卡片表面：弹窗 / 面板；桌面端另含顶栏与侧边栏）──
    //
    // 与上面三行同构：左 = 图标 + 文字（+ 作用范围说明），右 = 固定宽度下拉。
    // 旧实现把「液态玻璃 / 模糊 / 跟随主题色」三个选项硬塞进右侧 _kMenuWidth
    // 宽的小框里，每项只剩约 40px，文字全部被截断、只剩三个图标 —— 即用户
    // 反馈的「玻璃效果的具体设置项未显示」「字体都显示不全」。改成下拉后：
    // 当前值在框内完整显示，展开列表里三个选项也都带完整文字。
    Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Icon(Icons.blur_on_outlined, size: 15, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(zh ? '面板玻璃效果' : 'Panel glass effect',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: clr, fontSize: 12)),
            const SizedBox(height: 2),
            Text(
                zh
                    ? (isMobilePlatform
                        ? '作用于 弹窗 / 面板'
                        : '作用于 顶栏 / 侧边栏 / 弹窗菜单')
                    : (isMobilePlatform
                        ? 'Applies to popups & panels'
                        : 'Applies to bars, sidebar and menus'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: scheme.outline)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: _kMenuWidth,
          child: OptionMenuBar<String>(
            expandable: true,
            value: (cfg.glassEffect == 'blur' || cfg.glassEffect == 'none')
                ? cfg.glassEffect
                : 'liquid',
            items: [
              OptionItem('liquid', s.surfaceStyleLiquid, icon: Icons.water_drop_outlined),
              OptionItem('blur', s.glassBlur, icon: Icons.blur_on_outlined),
              OptionItem('none', s.surfaceStyleTheme, icon: Icons.format_color_fill),
            ],
            onChanged: (v) => state.updateConfig((c) => c..glassEffect = v),
          ),
        ),
      ]),
    ),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(zh ? '玻璃底色遵循主题色' : 'Tint glass with theme color',
            style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(zh ? '开启后玻璃/卡片底色使用协调后的主题色而不是表面灰'
                : 'Use the harmonized accent color instead of surface gray',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.glassFollowTheme,
        onChanged: (v) => state.updateConfig((c) => c..glassFollowTheme = v)),
    // ── 设置卡片玻璃（三选一）──
    // 去重：原先这里是「设置项以毛玻璃展示」+「不使用卡片玻璃效果」两个独立
    // 开关，语义互斥又重复（用户反馈「下方选项中有重复项」）。现在合并为一个
    // 三选一下拉，唯一数据源是 AppConfig.settingsGlassMode。
    Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Row(children: [
        Icon(Icons.dashboard_customize_outlined, size: 15, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(zh ? '设置卡片玻璃' : 'Settings card glass',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: clr, fontSize: 12)),
            const SizedBox(height: 2),
            Text(zh ? '仅作用于设置页的卡片' : 'Applies to settings cards only',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: scheme.outline)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: _kMenuWidth,
          child: OptionMenuBar<String>(
            expandable: true,
            value: cfg.settingsGlassMode,
            items: [
              OptionItem('follow',
                  zh ? '跟随样式' : 'Follow',
                  icon: Icons.link,
                  subtitle: zh ? '与卡片样式一致' : 'Same as card style'),
              OptionItem('frosted',
                  zh ? '毛玻璃' : 'Frosted',
                  icon: Icons.blur_on_outlined,
                  subtitle: zh ? '扁平模糊，长列表更易读' : 'Flat blur, easier to read'),
              OptionItem('solid',
                  zh ? '主题色实心' : 'Solid',
                  icon: Icons.format_color_fill,
                  subtitle: zh ? '不透明，低配更流畅' : 'Opaque, smoother on low-end'),
            ],
            onChanged: (v) => state.updateConfig((c) => c..settingsGlassMode = v),
          ),
        ),
      ]),
    ),
    // PC 专属：桌面端的 shader backdrop 坐标系不成立（见 gpuGlassEnabledOf 注释），
    // 开启后顶栏/侧栏/页签栏的玻璃里会出现被放大错位的壁纸片段，且内存最贵。
    // 2026-09-18 起桌面端**无条件**走「模糊 + 倒角高光」回退，该开关不再生效，
    // 因此这里改为不可交互的说明行 —— 留一个拨不动的开关等于骗用户。
    // （配置字段 glassGpuOnDesktop 仍保留：JSON 兼容，且将来若修好坐标系可直接复用。）
    if (!isMobilePlatform)
      ListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(zh ? 'GPU 液态玻璃（桌面端不可用）' : 'GPU liquid glass (unavailable on desktop)',
              style: TextStyle(color: scheme.outline, fontSize: 13)),
          subtitle: Text(zh
                  ? '桌面图形后端的 backdrop 坐标系与 shader 假设不一致，开启会导致玻璃里出现放大的壁纸碎片，已停用；当前使用「模糊 + 倒角高光」回退（背景即真实壁纸）'
                  : 'Shader backdrop coordinates are not reliable on desktop backends; disabled. Using blur + bevel highlight fallback instead.',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          trailing: Icon(Icons.block, size: 18, color: scheme.outline)),
    const SizedBox(height: 4),
    // ── 添加边框：所有卡片与药丸的实线描边 ──
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(zh ? '添加边框' : 'Add borders',
            style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(
            zh ? '为所有卡片与药丸添加实线边框，可自定义颜色与宽度'
               : 'Draw a solid border around all cards and pills (custom color & width)',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.borderEnabled,
        onChanged: (v) => state.updateConfig((c) => c..borderEnabled = v)),
    if (cfg.borderEnabled) ...[
      Row(children: [
        Expanded(
          child: Text(zh ? '边框颜色' : 'Border color',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: clr, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        // 色块即按钮：点开复用主题色取色面板（只取单色，渐变开关被忽略），样式一致
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _pickBorderColor(ctx, state),
          child: Container(
            width: 44,
            height: 26,
            decoration: BoxDecoration(
              color: Color(cfg.borderColor),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('#${(cfg.borderColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
      ]),
      const SizedBox(height: 6),
      _SettingSlider(
        value: cfg.borderWidth, min: 0.5, max: 4.0, divisions: 7,
        label: (v) => '${zh ? '边框宽度' : 'Border width'}: ${v.toStringAsFixed(1)}',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..borderWidth = v),
      ),
    ],
  ];
}

/// 「特效」卡：滑块拖动时的彗星拖尾（自 [_buildSurfaceStyleCard] 的 ④ 使用）。
///
/// 单独成卡（而不是并进「玻璃与材质」）：它是动画项，跟玻璃材质不是一个主题。
/// 关闭后彗星层连 Ticker / 绘制层都不建，是低配设备换帧率的开关
/// （见 widgets/app_slider.dart 的性能约定）。
///
/// 注意：这一项从 2026-09 起由「离散粒子」改为「连续彗星拖尾」，但**配置字段名与
/// JSON 键刻意保持不变**（`sliderParticles` / `slider_particles` / 旧键
/// `slider_stars`），老配置文件零迁移。
List<Widget> _buildEffectItems(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  final zh = cfg.language == 'zh';
  return [
    SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(zh ? '滑块彗星拖尾' : 'Slider comet trail',
            style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(
            zh
                ? '拖动滑块时从把手（填充段最右端）向左甩出的彗星尾迹，最多占轨道总长 22%（关闭后零帧开销）'
                : 'Comet trail pulled left from the handle while dragging, up to 22% of the track '
                    '(off = zero frame cost)',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.sliderParticles,
        onChanged: (v) => state.updateConfig((c) => c..sliderParticles = v)),
  ];
}

// ═══════════════════════════════════════════════════════════════════
// 样式预设（样式卡顶部的可视化方案选择）
// ═══════════════════════════════════════════════════════════════════

/// 一套样式预设的「外观补丁」值对象。
///
/// ## 为什么要有它
///
/// 改造前每套预设各写一份 `apply`（级联写 8~11 个外观字段）和一份 `matches`
/// （只挑 1~4 个字段比对），两边长期不对称，于是「预设芯片高亮」与「实际观感」
/// 会脱钩：
///
/// - `liquid` 写入 11 个字段，`matches` 只看 4 个（卡片族样式、glassEffect、
///   glassFollowTheme、通透度）；手动把「高光强度」拖到别处，它照样亮着；
/// - `clear` 写入 11 个字段，`matches` 只看 2 个 → 手动把通透度拖到 82%，
///   「轻薄通透」就亮起来，但模糊度/高光/边缘光还是上一套的值，看到的并不是它；
/// - `theme` 写入 `themeTone = 0.55`，而其余四套完全不碰这个字段 → 从「主题色」
///   切回「液态玻璃」后协调度仍残留 0.55（默认 0.45），观感与新装不一致，
///   但 `matches` 仍然报「已选中」。这是唯一一处真正会让观感偏离预设名义值的残留。
///
/// 现在 `applyTo` 与 `matches` 共用同一份数据，字段不可能再漏；每次套用都写满
/// 全部字段（幂等），上一套预设的残留值会被彻底覆盖。
///
/// ## 数值网格约束
///
/// 预设写入的数值必须落在「玻璃细节」滑块的网格上，否则用户一碰滑块数值就被
/// 吸附走、预设再也不会匹配：模糊度 step 1、通透度/高光位置 step 0.05、
/// 高光强度/边缘光 step 0.1、主题色协调度 step 0.05。
/// 原 `clear` 的通透度 0.82 不在 0.05 网格上（滑块只能取到 0.80/0.85），
/// 已修正为 0.80。
@immutable
class _StyleValues {
  final String cardStyle;
  final String navStyle;
  final String pillStyle;
  final String menuStyle;
  final String glassEffect;
  final String settingsGlassMode;
  final bool glassFollowTheme;
  final double glassBlur;
  final double glassClarity;
  final double glassHighlight;
  final double glassLightPos;
  final double glassEdge;
  final double themeTone;

  const _StyleValues({
    required this.cardStyle,
    required this.navStyle,
    required this.pillStyle,
    required this.menuStyle,
    required this.glassEffect,
    required this.settingsGlassMode,
    required this.glassFollowTheme,
    required this.glassBlur,
    required this.glassClarity,
    required this.glassHighlight,
    required this.glassLightPos,
    required this.glassEdge,
    required this.themeTone,
  });

  /// 全部字段一次写齐（幂等）。级联表达式的值就是接收者，可直接喂 `updateConfig`。
  void applyTo(AppConfig c) {
    c
      ..cardStyle = cardStyle
      ..navStyle = navStyle
      ..pillStyle = pillStyle
      ..menuStyle = menuStyle
      ..glassEffect = glassEffect
      ..settingsGlassMode = settingsGlassMode
      ..glassFollowTheme = glassFollowTheme
      ..glassBlur = glassBlur
      ..glassClarity = glassClarity
      ..glassHighlight = glassHighlight
      ..glassLightPos = glassLightPos
      ..glassEdge = glassEdge
      ..themeTone = themeTone;
  }

  /// 与 [applyTo] 逐字段一一对应。double 留 0.005 容差（JSON 往返的浮点误差）。
  bool matches(AppConfig c) =>
      c.cardStyle == cardStyle &&
      c.navStyle == navStyle &&
      c.pillStyle == pillStyle &&
      c.menuStyle == menuStyle &&
      c.glassEffect == glassEffect &&
      c.settingsGlassMode == settingsGlassMode &&
      c.glassFollowTheme == glassFollowTheme &&
      (c.glassBlur - glassBlur).abs() < 0.005 &&
      (c.glassClarity - glassClarity).abs() < 0.005 &&
      (c.glassHighlight - glassHighlight).abs() < 0.005 &&
      (c.glassLightPos - glassLightPos).abs() < 0.005 &&
      (c.glassEdge - glassEdge).abs() < 0.005 &&
      (c.themeTone - themeTone).abs() < 0.005;
}

/// 一套样式预设：名字/说明/预览类别 + 一份 [_StyleValues]。
class _StylePreset {
  final String id;
  final String Function(bool zh) name;
  final String Function(bool zh) desc;
  /// 预览卡的样式类别：'liquid' | 'theme' | 'blur' | 'gray' | 'clear'
  final String preview;
  final _StyleValues values;
  const _StylePreset({
    required this.id,
    required this.name,
    required this.desc,
    required this.preview,
    required this.values,
  });

  /// 写入整套外观字段，并回传同一个 [AppConfig] 实例。
  ///
  /// 必须返回值：调用点是 `updateConfig((c) => p.apply(c))`，而 `updateConfig`
  /// 要一个 `AppConfig Function(AppConfig)`。级联写入只改字段、不换引用，
  /// 所以直接回传接收者即可（改成 `void` 会让调用点报
  /// RETURN_OF_INVALID_TYPE_FROM_CLOSURE）。
  AppConfig apply(AppConfig c) {
    values.applyTo(c);
    return c;
  }
  bool matches(AppConfig c) => values.matches(c);
}

/// 5 套预设。默认值全部有出处（见 AppConfig 里各字段注释）——
/// `liquid` 的一组数值与 AppConfig 的出厂默认完全一致，所以首次启动
/// 「液态玻璃」必然处于选中态。
///
/// 不拥有玻璃参数的两套（theme / gray，都是 glassEffect = 'none'，玻璃参数
/// 在该模式下不参与渲染）仍然把玻璃参数写回出厂默认，这样「切过去再切回来」
/// 的结果是确定的，而不是被动继承上一套预设的残留。
final List<_StylePreset> _stylePresets = [
  _StylePreset(
    id: 'liquid',
    name: (zh) => zh ? '液态玻璃' : 'Liquid',
    desc: (zh) => zh ? '折射玻璃' : 'Refraction',
    preview: 'liquid',
    values: const _StyleValues(
      cardStyle: 'liquid', navStyle: 'liquid', pillStyle: 'liquid', menuStyle: 'liquid',
      glassEffect: 'liquid', settingsGlassMode: 'follow', glassFollowTheme: false,
      glassBlur: 16.0, glassClarity: 0.45, glassHighlight: 1.0,
      glassLightPos: 0.0, glassEdge: 1.0, themeTone: 0.45,
    ),
  ),
  _StylePreset(
    id: 'clear',
    name: (zh) => zh ? '轻薄通透' : 'Airy',
    desc: (zh) => zh ? '高透光' : 'High clarity',
    preview: 'clear',
    values: const _StyleValues(
      cardStyle: 'liquid', navStyle: 'liquid', pillStyle: 'liquid', menuStyle: 'liquid',
      glassEffect: 'liquid', settingsGlassMode: 'follow', glassFollowTheme: false,
      // 通透度 0.82 → 0.80：0.82 落在滑块 0.05 网格之外，
      // 用户一旦碰过通透度滑块，本预设就永远无法再次匹配。
      glassBlur: 24.0, glassClarity: 0.80, glassHighlight: 1.3,
      glassLightPos: 0.25, glassEdge: 1.4, themeTone: 0.45,
    ),
  ),
  _StylePreset(
    id: 'theme',
    name: (zh) => zh ? '主题色' : 'Accent',
    desc: (zh) => zh ? '协调实色' : 'Harmonized',
    preview: 'theme',
    values: const _StyleValues(
      cardStyle: 'theme', navStyle: 'theme', pillStyle: 'theme', menuStyle: 'theme',
      glassEffect: 'none', settingsGlassMode: 'solid', glassFollowTheme: true,
      glassBlur: 16.0, glassClarity: 0.45, glassHighlight: 1.0,
      glassLightPos: 0.0, glassEdge: 1.0, themeTone: 0.55,
    ),
  ),
  _StylePreset(
    id: 'blur',
    name: (zh) => zh ? '扁平模糊' : 'Flat blur',
    desc: (zh) => zh ? '易读' : 'Readable',
    preview: 'blur',
    values: const _StyleValues(
      cardStyle: 'blur', navStyle: 'blur', pillStyle: 'blur', menuStyle: 'blur',
      glassEffect: 'blur', settingsGlassMode: 'follow', glassFollowTheme: false,
      glassBlur: 20.0, glassClarity: 0.55, glassHighlight: 0.6,
      glassLightPos: 0.0, glassEdge: 0.5, themeTone: 0.45,
    ),
  ),
  _StylePreset(
    id: 'gray',
    name: (zh) => zh ? '极简灰' : 'Minimal gray',
    desc: (zh) => zh ? '中性无彩' : 'Neutral',
    preview: 'gray',
    values: const _StyleValues(
      cardStyle: 'gray', navStyle: 'gray', pillStyle: 'gray', menuStyle: 'gray',
      glassEffect: 'none', settingsGlassMode: 'follow', glassFollowTheme: false,
      glassBlur: 16.0, glassClarity: 0.45, glassHighlight: 1.0,
      glassLightPos: 0.0, glassEdge: 1.0, themeTone: 0.45,
    ),
  ),
];

/// 预设预览的小块玻璃：用当前主题色/协调度画出该方案的大致观感。
Widget _presetSwatch(BuildContext ctx, _StylePreset p, bool selected) {
  final scheme = Theme.of(ctx).colorScheme;
  final isDark = scheme.brightness == Brightness.dark;
  // 预览用「该预设自己的」协调度，而不是用户当前配置里的实时值：
  // 点击会写入 values.themeTone，若预览读实时值，就会出现
  // 「点击前看到的底色」与「点击后的实际底色」不一致（尤其「主题色」预设
  // 写的是 0.55，而用户当前可能是 0.45）。顺带少一个 AppState 订阅。
  final tone = p.values.themeTone;
  final accent = harmonizedAccent(scheme, tone);
  final gray = neutralGray(scheme.surfaceContainerHigh);
  // 声明成 BoxDecoration（而非抽象 Decoration）：下面选中态要用 copyWith 加柔光，
  // copyWith 只存在于 BoxDecoration 上。
  BoxDecoration deco;
  switch (p.preview) {
    case 'theme':
      deco = BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, Color.lerp(accent, scheme.surface, 0.35)!],
        ),
      );
      break;
    case 'gray':
      deco = BoxDecoration(
        color: gray,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
      );
      break;
    case 'blur':
      deco = BoxDecoration(
        color: scheme.surface.withAlpha(isDark ? 200 : 220),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(isDark ? 40 : 14), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      );
      break;
    case 'clear':
      deco = BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface.withAlpha(isDark ? 90 : 120),
            scheme.surface.withAlpha(isDark ? 30 : 40),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1.2),
      );
      break;
    default: // liquid
      deco = BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surface.withAlpha(isDark ? 210 : 225),
            scheme.surface.withAlpha(isDark ? 120 : 150),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(isDark ? 45 : 16), blurRadius: 7, offset: const Offset(0, 2)),
        ],
      );
  }
  return Stack(children: [
    // 预览块：选中态额外加一层主题色柔光，让「当前正在用哪套」一眼可见
    //（外框的高亮见 _buildStylePresets 的 AnimatedContainer）。
    Container(
      width: 58,
      height: 30,
      decoration: selected
          ? deco.copyWith(boxShadow: [
              BoxShadow(
                color: scheme.primary.withAlpha(isDark ? 90 : 60),
                blurRadius: 8,
                spreadRadius: 0.5,
              ),
            ])
          : deco,
    ),
    // 左上角高光：所有玻璃方案的共同特征
    Positioned(
      left: 6, top: 3,
      child: Container(
        width: p.preview == 'gray' ? 0 : (selected ? 26 : 22),
        height: 6,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          gradient: LinearGradient(colors: [
            Colors.white.withValues(alpha: 0.45),
            Colors.white.withValues(alpha: 0.0),
          ]),
        ),
      ),
    ),
  ]);
}

/// 样式预设选择行（样式卡顶部）。点一下即套用整套外观。
List<Widget> _buildStylePresets(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  final zh = cfg.language == 'zh';

  Widget entry(_StylePreset p) {
    final selected = p.matches(cfg);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => state.updateConfig((c) => p.apply(c)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? scheme.primary.withAlpha(30)
                : scheme.surfaceContainerHighest.withAlpha(60),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withAlpha(80),
              width: selected ? 1.5 : 0.8,
            ),
          ),
          child: Column(children: [
            _presetSwatch(ctx, p, selected),
            const SizedBox(height: 5),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (selected) ...[
                Icon(Icons.check_circle, size: 11, color: scheme.primary),
                const SizedBox(width: 3),
              ],
              Text(p.name(zh),
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? scheme.primary : clr)),
            ]),
            Text(p.desc(zh),
                style: TextStyle(fontSize: 9, color: scheme.outline)),
          ]),
        ),
      ),
    );
  }

  return [
    // 不再自带「预设方案」小标题：拆卡之后它就是「样式预设」这张卡的正文，
    // 再加一层小标题会与卡片标题重复（用户对重复项敏感）。
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [for (final p in _stylePresets) entry(p)]),
    ),
  ];
}

/// 「玻璃细节」卡：模糊度 / 通透度 / 高光强度与位置 / 边缘光。
///
/// 用户反馈「玻璃效果需提供详细可调的设置项，包括玻璃模糊度、通透度、
/// 高光强度与位置、边缘光等具体参数」。五项都接到全部玻璃渲染路径
/// （见 widgets/liquid_glass_fallback.dart 的 GlassTuning）。
Widget _buildGlassDetailCard(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  final zh = cfg.language == 'zh';
  return _glass(ctx, state, zh ? '玻璃细节' : 'Glass details', [
    Text(
        zh
            ? '作用于所有玻璃表面：卡片 / 底部菜单栏 / 顶部药丸 / 弹窗与面板'
            : 'Applies to every glass surface: cards, bottom nav, pills, popups, panels',
        style: TextStyle(fontSize: 10, color: scheme.outline)),
    const SizedBox(height: 10),
    _SettingSlider(
      value: cfg.glassBlur, min: 0, max: 30, divisions: 30,
      // 拖动中就写回配置：模糊度的效果是「整块玻璃变糊/变清」，松手才生效时
      // 拖动过程中看不出差别，会被判定成「滑块不管用」（与字号滑块同一个坑）。
      liveCommit: true,
      label: (v) => '${zh ? '玻璃模糊度' : 'Blur'}: ${v.round()}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassBlur = v),
    ),
    _SettingSlider(
      value: cfg.glassClarity, min: 0, max: 1, divisions: 20,
      label: (v) => '${zh ? '通透度' : 'Clarity'}: ${(v * 100).round()}%',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassClarity = v),
    ),
    _SettingSlider(
      value: cfg.glassHighlight, min: 0, max: 1.6, divisions: 16,
      label: (v) => '${zh ? '高光强度' : 'Highlight'}: ${v.toStringAsFixed(1)}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassHighlight = v),
    ),
    _SettingSlider(
      value: cfg.glassLightPos, min: 0, max: 1, divisions: 20,
      label: (v) =>
          '${zh ? '高光位置' : 'Light position'}: ${zh ? (v <= 0.05 ? '左上' : v >= 0.95 ? '右下' : '${(v * 100).round()}%') : '${(v * 100).round()}%'}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassLightPos = v),
    ),
    _SettingSlider(
      value: cfg.glassEdge, min: 0, max: 2, divisions: 20,
      label: (v) => '${zh ? '边缘光' : 'Edge light'}: ${v.toStringAsFixed(1)}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassEdge = v),
    ),
    const SizedBox(height: 4),
    Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => state.updateConfig((c) => c
          ..glassBlur = 16.0
          ..glassClarity = 0.45
          ..glassHighlight = 1.0
          ..glassLightPos = 0.0
          ..glassEdge = 1.0),
        icon: const Icon(Icons.restart_alt, size: 15),
        label: Text(zh ? '恢复默认' : 'Reset', style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ),
    ),
  ]);
}

/// 边框颜色选择：复用主题色的取色面板 [_CP]（只取第一个颜色）。
Future<void> _pickBorderColor(BuildContext ctx, AppState state) async {
  final isZh = state.config.language == 'zh';
  final cp = _CP(initial: Color(state.config.borderColor), isZh: isZh);
  final res = isMobilePlatform
      ? await showModalBottomSheet<_GradResult>(
          context: ctx,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SafeArea(top: false, child: cp),
        )
      : await showDialog<_GradResult>(
          context: ctx,
          builder: (_) => Center(child: SizedBox(width: 320, child: cp)),
        );
  if (res == null) return;
  state.updateConfig((c) => c..borderColor = res.c1);
}

/// 「外观 → 节点编辑器」卡片：画布背景 + 逻辑门符号标准。
Widget _buildNodeEditorStyleCard(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  return _glass(ctx, state, s.nodeEditorStyleLabel, [
    // 画布背景：下拉菜单样式（跟随全局 / 灰色 / 黑色 / 白色）
    Row(children: [
      Expanded(child: Text(s.canvasBgLabel, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: clr, fontSize: 12))),
      SizedBox(width: _kMenuWidth, child: OptionMenuBar<String>(
        expandable: true,
        value: cfg.canvasBg,
        items: [
          OptionItem('global', s.canvasFollowGlobal, icon: Icons.public_outlined),
          OptionItem('gray', s.canvasGray, icon: Icons.grid_4x4),
          OptionItem('black', s.canvasBlack, icon: Icons.dark_mode_outlined),
          OptionItem('white', s.canvasWhite, icon: Icons.light_mode_outlined),
        ],
        onChanged: (v) => state.updateConfig((c) => c..canvasBg = v),
      )),
    ]),
    const SizedBox(height: 10),
    // 逻辑门符号标准：ANSI/IEEE 或 IEC
    // 统一「左 = 图标+文字描述，右 = 调节选项」：标签在左、分段药丸在右，
    // 不再让标签独占一行把控件挤到下一行。
    Row(children: [
      Expanded(
        child: Text(s.gateStdLabel,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: clr, fontSize: 12)),
      ),
      SizedBox(
        width: _kMenuWidth,
        // 下拉菜单（expandable: true）：用户要求「逻辑门符号标准改为下拉菜单样式，
        // 跟上面画布背景选项一样」—— 两个选项的短列表用行内分段药丸会让触控目标
        // 只有 ~58px 宽，且与上方「画布背景」的控件形态不一致。
        child: OptionMenuBar<String>(
          expandable: true,
          value: cfg.gateStd,
          items: const [
            OptionItem('ansi', 'ANSI/IEEE'),
            OptionItem('iec', 'IEC'),
          ],
          onChanged: (v) => state.updateConfig((c) => c..gateStd = v),
        ),
      ),
    ]),

    // ── 界面尺寸（仅移动端）──
    //
    // 用户反馈「节点编辑器界面的上方药丸太大了（在竖屏下）希望设置能加一个调整这个
    // 大小的功能（再加一个调整左下方放大镜那个药丸大小的选项）」。
    //
    // 这两项配置其实早就存在（editorToolbarScale / editorZoomScale），但原先埋在
    // 「自动保存」那张卡里 —— 卡名与「药丸大小」毫无关系，用户根本找不到，于是
    // 反馈成「希望加一个这个功能」。这里移到画布外观相关的本卡，并：
    // * 范围下限 0.7 → 0.5（竖屏下 0.7 仍偏大，用户希望还能更小）；
    // * 拖动即生效（liveCommit）：改的是工具栏/药丸尺寸，松手才生效时拖动过程
    //   看不出变化，容易被判定成「滑块坏了」。
    if (isMobilePlatform) ...[
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Row(children: [
          Text(s.isZh ? '界面尺寸' : 'UI size',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                  letterSpacing: 0.2)),
          const SizedBox(width: 8),
          Expanded(
              child:
                  Divider(height: 1, color: scheme.outlineVariant.withAlpha(70))),
        ]),
      ),
      _SettingSlider(
        value: cfg.editorToolbarScale.clamp(0.5, 1.6),
        min: 0.5, max: 1.6, divisions: 11,
        liveCommit: true,
        label: (v) => '${s.isZh ? '顶部菜单栏大小' : 'Top toolbar size'}: ${(v * 100).round()}%',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..editorToolbarScale = v),
      ),
      _SettingSlider(
        value: cfg.editorZoomScale.clamp(0.5, 1.6),
        min: 0.5, max: 1.6, divisions: 11,
        liveCommit: true,
        label: (v) => '${s.isZh ? '放大镜（缩放药丸）大小' : 'Zoom pill size'}: ${(v * 100).round()}%',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..editorZoomScale = v),
      ),
      const SizedBox(height: 8),
    ],

    // ── 编辑器设置（编辑模式 / 自动保存）：三级菜单 ──
    //
    // 用户要求「编辑器设置(包括编辑模式和自动保存)迁移到节点编辑器这个设置项目内，
    // 它们作为三级菜单」。这两项原本是「编辑器」分区里的两张一级卡片（一级菜单
    // 点一下就直接进二级页），现在收进本卡、点进去才是设置本体。
    // 桌面端仍是独立卡片：桌面右栏没有三级页机制（与「玻璃细节」同一处理）。
    if (isMobilePlatform) ...[
      const SizedBox(height: 6),
      Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
      _subPageEntry(ctx, scheme, clr,
          icon: Icons.account_tree_outlined,
          label: s.cardEditorMode,
          scope: s.isZh ? '节点编辑器 / 快速模式' : 'Node editor / Quick mode',
          onTap: () =>
              _pushSettingsSubPage(ctx, s.cardEditorMode, _buildEditorMode)),
      _subPageEntry(ctx, scheme, clr,
          icon: Icons.save_outlined,
          label: s.cardAutosave,
          scope: s.isZh
              ? '草稿自动保存与保存间隔'
              : 'Draft autosave and save interval',
          onTap: () =>
              _pushSettingsSubPage(ctx, s.cardAutosave, _buildAutosave)),
    ],
  ]);
}

/// 设置页「菜单栏选项」控件的统一触发宽度与选项列表历史上限。
/// （选项控件统一为 widgets/option_menu_bar.dart 的 OptionMenuBar：
///   任务卡下拉的触发按钮样式 + 主菜单条目的药丸选中动画。）
///
/// 宽度取值依据：触发按钮内的固定开销 = 左右内边距 2×10 + 箭头 16 + 间隙 4
/// = 40px，剩余全部给当前值文字。选项里最长的值是「跟随主题色」（5 个汉字，
/// 约 60px @12sp），因此 116 即可完整显示——此前为 132 且触发按钮内还有一个
/// 与文字平分剩余宽度的 Spacer，导致「框比内容宽、框内文字反而被截断」。
/// 用户反馈「右侧选项框过宽需收窄、框内文字要完整显示」，故收窄到 116。
const double _kMenuWidth = 116;

/// 各字重样本使用的 FontWeight（与 AppConfig.fontWeightValues 一一对应）。
const List<FontWeight> _kFontWeights = [
  FontWeight.w300,
  FontWeight.w400,
  FontWeight.w500,
  FontWeight.w600,
  FontWeight.w700,
];

/// 字重选择控件：5 个各自用**该字重**渲染的「Aa」样本，点一下即生效。
///
/// 为什么不用下拉：下拉选项文字本身是同一字重（选项列表只有名字），用户
/// 看不到「细体 / 粗体」的实际差别，反馈「字重设置项需提供可选字重选项，
/// 使用户能够实际选择字重」。这里直接给出可视化样本，所见即所点。
Widget _fontWeightPicker(
  BuildContext ctx,
  AppState state,
  AppStrings s,
  ColorScheme scheme,
) {
  final cfg = state.config;
  final clr = scheme.onSurface;
  final labels = s.isZh
      ? const ['细体', '常规', '中等', '半粗', '粗体']
      : const ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold'];
  final family = cfg.fontFamily.isEmpty ? null : cfg.fontFamily;
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(s.qWeight, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 6),
    Row(children: [
      for (var i = 0; i < _kFontWeights.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(
          child: Tooltip(
            message: '${labels[i]} · ${AppConfig.fontWeightValues[i]}',
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => state.updateConfig((c) => c..fontWeightIndex = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 48,
                decoration: BoxDecoration(
                  color: cfg.fontWeightIndex == i
                      ? scheme.primary.withAlpha(38)
                      : scheme.surfaceContainerHighest.withAlpha(70),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: cfg.fontWeightIndex == i
                        ? scheme.primary
                        : scheme.outlineVariant.withAlpha(90),
                    width: cfg.fontWeightIndex == i ? 1.4 : 0.8,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Aa',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.1,
                          fontFamily: family,
                          fontWeight: _kFontWeights[i],
                          color: cfg.fontWeightIndex == i ? scheme.primary : clr,
                        )),
                    Text(labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 9,
                            height: 1.2,
                            fontFamily: family,
                            color: scheme.outline)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ]),
  ]);
}

/// 表面样式设置行：左 = 图标 + 文字（可选作用范围说明），右 = 四值
/// 「菜单栏选项」控件（按钮 + 展开选项列表，key 绑定当前值，配置被外部
/// 改动如低配自动降级后重建时菜单显示最新值）。
/// 通用「图标 + 标签（可选说明）+ 下拉选项」设置行。
///
/// 抽出来的原因：表面样式那四行与新增的「菜单栏位置」是同一套版式，若各自
/// 内联一遍，间距、溢出处理、OptionMenuBar 的展开动画约定迟早漂移
///（原实现明确要求「不给 OptionMenuBar 绑随 value 变化的 key」，见下）。
Widget _optionRow(
  BuildContext ctx, {
  required IconData icon,
  required String label,
  String? scope,
  required String value,
  required List<OptionItem<String>> items,
  required ValueChanged<String> onSelected,
}) {
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(children: [
      Icon(icon, size: 15, color: scheme.primary),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 大字号下固定宽度控件旁的标签不换行（只省略），避免行高变化导致
        // 「标签与选择框不对称」的观感（见设置页各类设置行）。
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: clr, fontSize: 12)),
        if (scope != null) ...[
          const SizedBox(height: 2),
          Text(scope, style: TextStyle(fontSize: 10, color: scheme.outline),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ])),
      const SizedBox(width: 8),
      SizedBox(
        width: _kMenuWidth,
        child: OptionMenuBar<String>(
          // 这里刻意不再给 OptionMenuBar 绑「随 value 变化」的 key。
          // 当前值由 value 参数直接下发，State 不缓存它，所以外部改动
          // （如低配自动降级）本就能正确刷新；而带 value 的 key 会在每次
          // 选值后把 State 整个重建 —— State 一换，收起动画刚开始就被卸载，
          // 浮层「啪」地消失（用户反馈「展开/收起没有动画」）。
          expandable: true,
          value: value,
          items: items,
          onChanged: onSelected,
        ),
      ),
    ]),
  );
}

/// 表面样式行（卡片 / 菜单 / 底部菜单栏 / 顶部药丸共用同一组四值）。
Widget _styleRow(
  BuildContext ctx, {
  required IconData icon,
  required String label,
  String? scope,
  required String value,
  required ValueChanged<String> onSelected,
}) {
  final s = AppStrings.of(ctx.read<AppState>().config.language);
  return _optionRow(
    ctx,
    icon: icon,
    label: label,
    scope: scope,
    value: value,
    items: [
      OptionItem('theme', s.surfaceStyleTheme, icon: Icons.format_color_fill),
      OptionItem('liquid', s.surfaceStyleLiquid, icon: Icons.water_drop_outlined),
      OptionItem('blur', s.glassBlur, icon: Icons.blur_on_outlined),
      OptionItem('gray', s.surfaceStyleGray, icon: Icons.grid_4x4),
    ],
    onSelected: onSelected,
  );
}

/// 选择并应用新背景图：先同步取屏幕物理分辨率（大图自动缩放），
/// Android 11+ content:// URI 用内存字节落盘。
Future<void> _pickBackground(BuildContext ctx, AppState state) async {
  final view = View.of(ctx);
  final dpr = view.devicePixelRatio;
  final logical = view.physicalSize / dpr;
  final maxW = (logical.width * dpr).ceil();
  final maxH = (logical.height * dpr).ceil();
  final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
      // 仅 Android 需要内存字节（content:// URI 无法用 File 读取）
      withData: isAndroidPlatform);
  if (r == null || r.files.isEmpty) return;
  final file = r.files.first;
  final path = file.path;
  final useBytes = (path == null || path.startsWith('content://')) && file.bytes != null;
  if (useBytes) {
    final saved = await _saveBackgroundBytes(file.bytes!, file.name, maxW, maxH);
    if (saved != null) {
      state.updateConfig((c) => c..backgroundImage = saved);
    }
  } else if (path != null) {
    // 大图自动压缩到屏幕分辨率，避免体积过大导致卡死
    final copied = await _copyBackgroundOptimized(path, maxW, maxH);
    state.updateConfig((c) => c..backgroundImage = copied ?? path);
  }
}

/// 主题→背景：预览缩略图 + 明确的「选择 / 更换 / 移除」按钮
/// + 背景不透明度与卡片不透明度两条滑块。
///
/// 版式（自上而下）：
///   ① 预览行 —— 缩略图 + 「当前背景」标签与文件名（未设置时改为一行说明）；
///   ② 操作行 —— 主按钮「选择图片 / 更换图片」+（有背景时）「移除」；
///   ③ 两条不透明度滑块。
///
/// 为什么重写：原实现只有一个可点的整行 + 一个 16px 的小叉号 —— 看不到当前壁纸
/// 长什么样，也读不出「点这里能干什么」，两个动作都没有文字（用户反馈「背景的
/// 更改选项按钮太简单了」）。缩略图走主壳那条唯一的解码 provider，同参数
/// ⇒ 同一个 ImageCache 条目，缓存命中时零额外开销。
class _ThemeBackgroundSection extends StatefulWidget {
  const _ThemeBackgroundSection();
  @override
  State<_ThemeBackgroundSection> createState() => _ThemeBackgroundSectionState();
}

class _ThemeBackgroundSectionState extends State<_ThemeBackgroundSection> {
  /// 缩略图尺寸（逻辑像素）。
  static const double _thumbW = 92;
  static const double _thumbH = 62;

  /// 背景文件存在性的进程级缓存。
  ///
  /// 为什么必须缓存：本组件订阅了整个 AppState（见 build 里的 watch），转码
  /// 进度心跳之类的 notify 也会让它重建 —— 在 build 里直接 `existsSync()`
  /// 会把同步磁盘 IO 摊到每一次心跳上。与主壳同样策略（app.dart 的
  /// `_bgFileExists`）：路径 → 结果，同一路径只查一次。
  static final Map<String, bool> _existsCache = {};
  static bool _bgExists(String path) =>
      _existsCache.putIfAbsent(path, () => File(path).existsSync());

  @override
  Widget build(BuildContext context) {
    // 必须 watch 而不是 read：外层 `_glass(...)` 的 children 是 const 列表，
    // 父级重建时 Flutter 会因「同一 Widget 实例」直接短路，本组件自己的 build
    // 根本不会被调用 —— 只有自己订阅 AppState 才能保证配置一变就刷新。
    final state = context.watch<AppState>();
    final cfg = state.config;
    final s = AppStrings.of(cfg.language);
    final scheme = Theme.of(context).colorScheme;
    final clr = scheme.onSurface;
    final hasBg = cfg.backgroundImage.isNotEmpty;
    final name = hasBg ? cfg.backgroundImage.split(RegExp(r'[\\/]')).last : '';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── ① 预览行 ──
      Row(children: [
        _bgThumb(context, scheme, cfg.backgroundImage),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.bgCurrent,
                  style: TextStyle(
                      fontSize: 10, color: scheme.outline, letterSpacing: 0.3)),
              const SizedBox(height: 3),
              Text(
                hasBg ? name : s.bgEmptyHint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: hasBg ? clr : scheme.outline),
              ),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 10),
      // ── ② 操作行 ──
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _pickBackground(context, state),
            icon: Icon(
                hasBg ? Icons.swap_horiz : Icons.add_photo_alternate_outlined,
                size: 16),
            label: Text(hasBg ? s.bgReplace : s.bgChoose,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              side: BorderSide(color: scheme.primary.withAlpha(90)),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        if (hasBg) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => state.updateConfig((c) => c..backgroundImage = ''),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: Text(s.remove),
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.error,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              side: BorderSide(color: scheme.error.withAlpha(80)),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ]),
      Divider(height: 20, color: scheme.outlineVariant.withAlpha(60)),
      // ── ③ 两条不透明度滑块 ──
      // 直接平铺展示（原为「折叠 → 展开」的二级菜单，用户反馈不必要的折叠：
      // 这两个滑块是背景设置的核心项，展开后卡片还会被撑高。
      // 现在卡片高度在一帧内就是最终高度，不再有展开/收起动画）。
      _SettingSlider(
        value: cfg.backgroundOpacity, min: 0.0, max: 1.0, divisions: 100,
        label: (v) => '${s.bgOpacity}: ${(v * 100).round()}%',
        labelStyle: TextStyle(color: clr, fontSize: 11),
        onCommit: (v) => state.updateConfig((c) => c..backgroundOpacity = v),
      ),
      const SizedBox(height: 2),
      _SettingSlider(
        value: cfg.cardOpacity, min: 0.0, max: 1.0, divisions: 100,
        label: (v) => '${s.cardOpacity}: ${(v * 100).round()}%',
        labelStyle: TextStyle(color: clr, fontSize: 11),
        onCommit: (v) => state.updateConfig((c) => c..cardOpacity = v),
      ),
    ]);
  }

  /// 背景预览缩略图：有背景且文件在 → 真实预览；否则给一个中性占位框
  /// （不留破图，也避免"未设置"时留一块空白）。
  Widget _bgThumb(BuildContext context, ColorScheme scheme, String path) {
    final bool ok = path.isNotEmpty && _bgExists(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: _thumbW,
        height: _thumbH,
        child: ok
            ? Image(
                // 与主壳**同参数**：命中同一 ImageCache 条目，不二次解码
                image: wallpaperImageProvider(
                  path,
                  MediaQuery.sizeOf(context).width,
                  MediaQuery.sizeOf(context).height,
                  MediaQuery.devicePixelRatioOf(context),
                ),
                fit: BoxFit.cover,
                // 文件被外部删除 / 解码失败时回落到占位框
                errorBuilder: (_, _, _) => _bgThumbPlaceholder(scheme),
              )
            : _bgThumbPlaceholder(scheme),
      ),
    );
  }

  Widget _bgThumbPlaceholder(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.onSurface.withAlpha(10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant.withAlpha(70)),
        ),
        child: Icon(Icons.wallpaper_outlined, size: 22, color: scheme.outline),
      );
}

/// 移动端设置 → 工具 → 命令：进入命令页
Widget _buildMobileCommandEntry(BuildContext ctx, AppState state) {
  final scheme = Theme.of(ctx).colorScheme;
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.navCommand, [
    ListTile(
      dense: true, contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.terminal_outlined, color: scheme.primary, size: 22),
      title: Text(s.isZh ? '手动执行 FFmpeg 命令' : 'Run custom FFmpeg commands',
          style: TextStyle(fontSize: 13, color: scheme.onSurface)),
      subtitle: Text(s.isZh ? '命令输入 + 快捷模板 + 参数参考'
          : 'Manual input + quick templates + parameter reference',
          style: TextStyle(fontSize: 11, color: scheme.outline)),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      // CommandPage 自带壁纸与安全区顶栏，不再外层重复包装（见 _mobileToolRow 注释）
      onTap: () => Navigator.of(ctx).push(
          MaterialPageRoute(allowSnapshotting: false, builder: (_) => const CommandPage())),
    ),
  ]);
}

/// 移动端设置 → 工具 → 日志：进入日志页
Widget _buildMobileLogsEntry(BuildContext ctx, AppState state) {
  final scheme = Theme.of(ctx).colorScheme;
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.qLogs, [
    ListTile(
      dense: true, contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.terminal, color: scheme.primary, size: 22),
      title: Text(s.isZh ? '查看运行日志' : 'View runtime logs',
          style: TextStyle(fontSize: 13, color: scheme.onSurface)),
      subtitle: Text(s.isZh ? '后端输出、FFmpeg 进度与错误信息'
          : 'Backend output, FFmpeg progress and errors',
          style: TextStyle(fontSize: 11, color: scheme.outline)),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      // LogPage 自带壁纸与安全区顶栏，不再外层重复包装（见 _mobileToolRow 注释）
      onTap: () => Navigator.of(ctx).push(
          MaterialPageRoute(allowSnapshotting: false, builder: (_) => const LogPage())),
    ),
  ]);
}

/// 预测式返回手势开关（Android，仅安卓端展示）。
Widget _buildPredictiveBack(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.predictiveBack, [
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(s.isZh ? '启用预测式返回手势' : 'Enable predictive back gesture',
          style: TextStyle(color: clr, fontSize: 13)),
      subtitle: Text(s.predictiveBackHint,
          style: TextStyle(fontSize: 11, color: scheme.outline)),
      value: cfg.predictiveBack,
      onChanged: (v) => state.updateConfig((c) => c..predictiveBack = v),
    ),
  ]);
}

Widget _buildLanguage(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  if (isMobilePlatform) {
    // 移动端：全宽单选（与其它设置项等长），避免下拉菜单宽度过短。
    return _glass(ctx, state, s.language, [
      // 统一「菜单栏选项」控件：按钮 + 展开选项列表
      OptionMenuBar<String>(
        value: cfg.language,
        items: const [
          OptionItem('zh', '中文 (简体)', icon: Icons.language),
          OptionItem('en', 'English', icon: Icons.language),
        ],
        onChanged: (v) => state.updateConfig((c) => c..language = v),
      ),
    ]);
  }

  return _glass(ctx, state, s.language, [
    // 左右布局：标签在左、下拉在右（固定宽度，不再整行拉满）
    Row(children: [
      Expanded(child: Text(s.languageInterface, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: clr, fontSize: 12))),
      // 宽度统一取 _kMenuWidth（含前置图标后留给文字约 54px）：标签用
      // 「中文 / English」而不是「中文 (简体)」，保证框内文字完整不被截断。
      SizedBox(width: _kMenuWidth, child: OptionMenuBar<String>(
        expandable: true,
        value: cfg.language,
        leadingIcon: Icons.language,
        items: [
          OptionItem('zh', s.isZh ? '中文' : 'Chinese'),
          OptionItem('en', 'English'),
        ],
        onChanged: (v) => state.updateConfig((c) => c..language = v),
      )),
    ]),
  ]);
}

Widget _buildFont(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  if (isMobilePlatform) {
    // 移动端：只保留「系统字体」与「导入字体」两个选项，不再展示字体列表。
    return _glass(ctx, state, s.font, [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.text_fields, size: 20, color: scheme.onSurfaceVariant),
        title: Text(s.isZh ? '系统字体（默认）' : 'System font (default)',
            style: TextStyle(fontSize: 13, color: clr)),
        trailing: cfg.fontFamily.isEmpty
            ? Icon(Icons.check_circle, size: 19, color: scheme.primary)
            : const SizedBox(width: 19),
        onTap: () => state.updateConfig((c) => c..fontFamily = ''),
      ),
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.upload_file_outlined, size: 20, color: scheme.onSurfaceVariant),
        title: Text(s.isZh ? '导入字体' : 'Import font',
            style: TextStyle(fontSize: 13, color: clr)),
        subtitle: cfg.fontFamily.isEmpty
            ? null
            : Text(cfg.fontFamily,
                style: TextStyle(fontSize: 11, color: scheme.outline),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
        trailing: cfg.fontFamily.isNotEmpty
            ? Icon(Icons.check_circle, size: 19, color: scheme.primary)
            : Icon(Icons.chevron_right, size: 19, color: scheme.outline),
        onTap: () => _pickFont(ctx, state),
      ),
      // 导入后给一行「用该字体真实渲染」的预览：此前移动端导入完只有一行文件名，
      // 且那行字本身还是系统字体渲染的，用户完全无法判断字体有没有生效
      // （用户反馈的「字体能否导入后显示」）。这一行同时也是字号滑块的直观反馈。
      if (cfg.fontFamily.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(90),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
            ),
            child: Text('字体预览 Font Preview 123',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15, fontFamily: cfg.fontFamily, color: clr)),
          ),
        ),
      const Divider(height: 12, color: Colors.transparent),
      _SettingSlider(
        value: cfg.fontSize, min: 10, max: 21, divisions: 11,
        // liveCommit：拖动过程中整页字号就跟着变（见 _SettingSlider.liveCommit）。
        // 松手才生效时，12~13px 的文字只差 1~2px，用户会以为「滑块没作用」。
        liveCommit: true,
        label: (v) => '${s.fontSize}: ${v.round()}',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..fontSize = v),
      ),
      // 字重：可视化样本（每个「Aa」用对应字重渲染，点选即生效）
      _fontWeightPicker(ctx, state, s, scheme),
    ]);
  }

  return _glass(ctx, state, s.font, [
    FontPicker(currentFont: cfg.fontFamily, language: cfg.language, showImport: true,
        onImport: () => _pickFont(ctx, state),
        onSelected: (v) => state.updateConfig((c) => c..fontFamily = v)),
    const SizedBox(height: 10),
    _SettingSlider(
      value: cfg.fontSize, min: 10, max: 21, divisions: 11,
      liveCommit: true, // 拖动即生效，理由同移动端分支
      label: (v) => '${s.fontSize}: ${v.round()}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..fontSize = v),
    ),
    // 字重：可视化样本（每个「Aa」用对应字重渲染，点选即生效）
    _fontWeightPicker(ctx, state, s, scheme),
  ]);
}

Widget _buildOutput(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.output, [
    _pf(ctx, s.outputDir, cfg.defaultOutputDir,
        (v) => state.updateConfig((c) => c..defaultOutputDir = v),
        () async { final d = await FilePicker.platform.getDirectoryPath(); if (d != null) state.updateConfig((c) => c..defaultOutputDir = d); }),
    const SizedBox(height: 8),
    _pf(ctx, s.intermediateDir, cfg.intermediateDir,
        (v) => state.updateConfig((c) => c..intermediateDir = v),
        () async { final d = await FilePicker.platform.getDirectoryPath(); if (d != null) state.updateConfig((c) => c..intermediateDir = d); }),
    Padding(padding: const EdgeInsets.only(top: 2),
        child: Text(s.intermediateHint, style: TextStyle(fontSize: 11, color: scheme.outline))),
  ]);
}

Widget _buildEditorMode(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  return _glass(ctx, state, s.cardEditorMode, [
    // 编辑方式（传统表单模式已彻底移除）：统一「菜单栏选项」控件
    OptionMenuBar<int>(
      value: cfg.editMode,
      items: [
        OptionItem(0, s.isZh ? '节点编辑器' : 'Node Editor',
            icon: Icons.account_tree_outlined,
            subtitle: s.isZh ? '蓝图式节点画布，可处理复杂的多步骤逻辑'
                             : 'Blueprint-style canvas for complex multi-step logic'),
        OptionItem(1, s.isZh ? '快速模式' : 'Quick Mode',
            icon: Icons.bolt_outlined,
            subtitle: s.isZh ? '选择文件后快速配置处理参数，适配视频/图片/音频'
                             : 'Quickly configure processing per file type (video/image/audio)'),
      ],
      onChanged: (v) => state.updateConfig((c) => c..editMode = v),
    ),
  ]);
}

Widget _buildAutosave(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardAutosave, [
    if (isMobilePlatform) ...[
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(s.isZh ? '节点编辑器横屏' : 'Landscape node editor', style: TextStyle(color: clr, fontSize: 13)),
          subtitle: Text(s.isZh ? '进入节点编辑器时默认横屏显示，画布更宽（移动端）' : 'Open the node editor in landscape by default for a wider canvas (mobile)',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          value: cfg.useNodeEditorLandscape,
          onChanged: (v) => state.updateConfig((c) => c..useNodeEditorLandscape = v)),
      const Divider(height: 4, color: Colors.transparent),
    ],
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '启用节点编辑器自动保存' : 'Enable editor autosave', style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(s.isZh ? '编辑节点画布时定期保存草稿，异常退出后可恢复' : 'Periodically save drafts while editing; restore after abnormal exit',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.autosaveEnabled,
        onChanged: (v) => state.updateConfig((c) => c..autosaveEnabled = v)),
    const SizedBox(height: 6),
    // 左右布局：标签左、下拉右（固定宽度，不再整行拉满）
    Row(children: [
      Expanded(child: Text(s.isZh ? '保存间隔' : 'Save Interval', maxLines: 1,
          overflow: TextOverflow.ellipsis, style: TextStyle(color: clr, fontSize: 12))),
      // 「选项文字不跟随应用内字号」（用户要求）：下拉是固定宽度(104)的选项控件，
      // 字号一大，「30 秒 / 不限制」这类文字就被省略号截断。系统字号仍然生效，
      // 见 theme/app_text_scale.dart 的 withoutAppTextScale。
      withoutAppTextScale(ctx, SizedBox(width: 104, child: DropdownButtonFormField<int>(borderRadius: BorderRadius.circular(12), initialValue: cfg.autosaveIntervalSec, isDense: true, isExpanded: true,
          style: TextStyle(fontSize: 12, color: clr), dropdownColor: scheme.surface,
          decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          items: [
            for (final sec in [10, 30, 60, 120, 300])
              DropdownMenuItem(value: sec, child: Text(sec < 60
                  ? (s.isZh ? '$sec 秒' : '$sec s')
                  : (s.isZh ? '${sec ~/ 60} 分钟' : '${sec ~/ 60} min'))),
          ],
          onChanged: (v) { if (v != null) state.updateConfig((c) => c..autosaveIntervalSec = v); }))),
    ]),
    const SizedBox(height: 4),
    Text(s.isZh ? '停止操作后多久自动保存一次' : 'How long after edits stop before autosaving', style: TextStyle(fontSize: 10, color: scheme.outline)),
  ]);
}

Widget _buildShortcuts(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardShortcuts, [
    ListTile(dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.keyboard, size: 20, color: scheme.primary),
        title: Text(s.isZh ? '快捷键配置' : 'Keyboard Shortcuts', style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(s.isZh ? '配置画布和基本操作快捷键' : 'Configure canvas and basic shortcuts', style: TextStyle(fontSize: 11, color: scheme.outline)),
        trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
        onTap: () => showKeybindingDialog(ctx, isZh: s.isZh)),
  ]);
}

Widget _buildTasks(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  // 二级页「按主题分开」：拆成 ① 并发与解析（性能）② 通知。
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _glass(ctx, state, s.isZh ? '并发与解析' : 'Concurrency & probing', [
    // 左右布局：标签左、下拉右（固定宽度，不再整行拉满）
    Row(children: [
      Expanded(child: Text(s.isZh ? '同时启用任务数' : 'Concurrent Tasks', maxLines: 1,
          overflow: TextOverflow.ellipsis, style: TextStyle(color: clr, fontSize: 12))),
      withoutAppTextScale(ctx, SizedBox(width: 104, child: DropdownButtonFormField<int>(borderRadius: BorderRadius.circular(12), initialValue: cfg.maxConcurrentTasks, isDense: true, isExpanded: true,
          style: TextStyle(fontSize: 12, color: clr), dropdownColor: scheme.surface,
          decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          items: [
            ...List.generate(8, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
            DropdownMenuItem(value: 0, child: Text(s.isZh ? '不限制' : 'Unlimited')),
          ],
          onChanged: (v) { if (v != null) state.updateConfig((c) => c..maxConcurrentTasks = v); }))),
    ]),
    const SizedBox(height: 4),
    Text(s.isZh ? '控制队列中同时处理的任务数量' : 'Controls how many tasks run in parallel', style: TextStyle(fontSize: 10, color: scheme.outline)),
    const SizedBox(height: 12),
    Row(children: [
      Expanded(child: Text(s.isZh ? '解析线程数' : 'Probe Threads', maxLines: 1,
          overflow: TextOverflow.ellipsis, style: TextStyle(color: clr, fontSize: 12))),
      withoutAppTextScale(ctx, SizedBox(width: 104, child: DropdownButtonFormField<int>(borderRadius: BorderRadius.circular(12), initialValue: cfg.probeThreads, isDense: true, isExpanded: true,
          style: TextStyle(fontSize: 12, color: clr), dropdownColor: scheme.surface,
          decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          items: List.generate(8, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
          onChanged: (v) { if (v != null) state.updateConfig((c) => c..probeThreads = v); }))),
    ]),
    const SizedBox(height: 4),
    Text(s.isZh ? '添加文件时同时解析的线程数，增大可加快批量导入速度' : 'Number of concurrent probe threads when importing files', style: TextStyle(fontSize: 10, color: scheme.outline)),
    ]),
    const SizedBox(height: 8),
    _glass(ctx, state, s.isZh ? '通知' : 'Notifications', [
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(s.isZh ? '任务完成系统通知' : 'Task completion notification', style: TextStyle(color: clr, fontSize: 13)),
          subtitle: Text(s.isZh ? '每个任务完成时发送系统通知' : 'Send system notification when each task finishes', style: TextStyle(fontSize: 11, color: scheme.outline)),
          value: cfg.enableSystemNotification,
          onChanged: (v) => state.updateConfig((c) => c..enableSystemNotification = v)),
    ]),
  ]);
}

/// 「高级 → 预加载」卡片：关闭预加载开关。
///
/// 开启后启动时仅构建/绘制当前页面（如项目页），处理队列、设置等其余页面
/// 等用户手动切换到时才构建——启动更快、启动内存更低，代价是首次切换
/// 页面时现场构建（可能短暂增加 CPU 占用）。
/// 屏幕最高刷新率的探测结果缓存（进程内只查一次）。
///
/// 必须缓存**同一个 Future 实例**：FutureBuilder 若在 build 里新建 Future，
/// 会在「完成 → 重建 → 又新建 → 又完成」之间自激循环。
Future<double?>? _maxRateFuture;

/// 「显示」卡片（仅移动端）：高刷新率。
///
/// 开启 = 请求「当前分辨率下的最高刷新率」（原生三条路径见
/// services/refresh_rate.dart 与 MainActivity.applyRefreshRate）；关闭 = 交还
/// 系统默认（更省电）。屏幕本身只有 60Hz 时开启不会有任何变化 —— 因此这里把
/// 实测值直接显示出来，用户能自己确认「设备支持多少」。
Widget _buildDisplay(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  final maxRate = _maxRateFuture ??= RefreshRate.maxRefreshRate();
  return _glass(ctx, state, s.displayLabel, [
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(s.highRefreshRateLabel,
          style: TextStyle(color: clr, fontSize: 13)),
      subtitle: Text(s.highRefreshRateHint,
          style: TextStyle(fontSize: 10, color: scheme.outline)),
      value: cfg.highRefreshRate,
      onChanged: (v) {
        state.updateConfig((c) => c..highRefreshRate = v);
        // 立即生效（不等下次启动）：toggle 一按就改窗口帧率偏好
        unawaited(RefreshRate.applyEnabled(v));
      },
    ),
    FutureBuilder<double?>(
      future: maxRate,
      builder: (ctx, snap) {
        final max = snap.data;
        final text = max == null
            ? (s.isZh
                ? '未能读取屏幕刷新率（非 Android 或系统限制）'
                : 'Display refresh rate unavailable')
            : (s.isZh
                ? '屏幕当前分辨率最高刷新率：${_fmtHz(max)}'
                : 'Display max refresh rate: ${_fmtHz(max)}');
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Icon(Icons.speed_outlined, size: 14, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 10.5, color: scheme.outline))),
          ]),
        );
      },
    ),
  ]);
}

/// 119.99 → '120Hz'；非整数（如 59.94）保留一位小数。
String _fmtHz(double v) {
  final r = v.roundToDouble();
  return (v - r).abs() < 0.5 ? '${r.toInt()}Hz' : '${v.toStringAsFixed(1)}Hz';
}

Widget _buildPreload(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.isZh ? '预加载' : 'Preload', [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '关闭预加载' : 'Disable Preload',
            style: TextStyle(color: scheme.onSurface, fontSize: 13)),
        // 文案要与实际被跳过的项目对齐：此前只写了「其他页面切换时才绘制」，
        // 而实测这条开关同时管着字体列表枚举与壁纸解码（见 main.dart 的
        // warmupEnabled），说明与实际不符。
        // 唯一不受它管的是「自定义字体加载」—— 那是功能不是预热，不做就缺字体。
        subtitle: Text(
            s.isZh
                ? '启动时只绘制当前页面：跳过后台页面构建、字体列表枚举与壁纸解码预热。\n注意：首次切换到某个页面时会现场构建，可能短暂增加 CPU 占用。'
                : 'At startup only the current page is drawn: background page builds, font-list enumeration and wallpaper decode are skipped.\nNote: the first visit to a page builds it on the spot, which may briefly raise CPU usage.',
            style: TextStyle(fontSize: 10, color: scheme.outline)),
        value: cfg.noPreload,
        onChanged: (v) => state.updateConfig((c) => c..noPreload = v)),
  ]);
}

Widget _buildDebug(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final clr = Theme.of(ctx).colorScheme.onSurface;
  return _glass(ctx, state, s.dDebug, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.dDebugMode, style: TextStyle(color: clr, fontSize: 13)),
        value: cfg.debugMode, onChanged: (v) => state.updateConfig((c) => c..debugMode = v)),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.dSaveLogs, style: TextStyle(color: clr, fontSize: 13)),
        value: cfg.saveLogs, onChanged: (v) => state.updateConfig((c) => c..saveLogs = v)),
    if (cfg.saveLogs)
      _pf(ctx, s.dLogPath, cfg.logSavePath,
          (v) => state.updateConfig((c) => c..logSavePath = v),
          () async { final d = await FilePicker.platform.getDirectoryPath(); if (d != null) state.updateConfig((c) => c..logSavePath = d); }),
  ]);
}

Widget _buildCache(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.cardCache, [
    SizedBox(width: double.infinity, child: Material(
      color: scheme.errorContainer.withAlpha(100),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _clearCache(ctx, state, scheme, s),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.delete_sweep_rounded, size: 20, color: scheme.error),
            const SizedBox(width: 8),
            Text(s.isZh ? '清除缓存' : 'Clear Cache', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.error)),
          ]),
        ),
      ),
    )),
    const SizedBox(height: 6),
    // 说明两个子选项各自的代价：图片/字体删掉要重新导入，导入缓存删掉只是回收空间
    Text(
        s.isZh
            ? '点击后选择：清除「图片 / 字体」，或清除导入缓存（副本、缩略图）'
            : 'Choose: clear images/fonts, or clear import cache (copies, thumbnails)',
        style: TextStyle(fontSize: 10, height: 1.35, color: scheme.outline)),
  ]);
}

/// 打开「广告」三级页面（设置 → 关于 → 广告）。
/// AdsPage 与 CreditsPage 一样自带壁纸与安全区顶栏，这里不再包 SafeArea
/// （外层 SafeArea 会把 MediaQuery.padding.top 清零，顶栏会被状态栏压住）。
void _openAds(BuildContext ctx) {
  Navigator.of(ctx).push(MaterialPageRoute(allowSnapshotting: false, builder: (_) => const AdsPage()));
}

void _openCredits(BuildContext ctx) {
  // CreditsPage 自带壁纸与安全区顶栏（MobileSubPageTopBar 读取 padding.top），
  // 外层再套 SafeArea 会把 padding.top 清零 → 顶栏被状态栏压住。
  // 桌面端 padding 恒为 0，去掉 SafeArea 无影响。
  Navigator.of(ctx).push(MaterialPageRoute(allowSnapshotting: false, builder: (_) => const CreditsPage()));
}

/// 关于页展示的编译日期（发布时更新）。
///
/// 抽成常量：此前移动端与桌面端两个分支里各写一份字面量，改一处必漏另一处。
const String kAboutBuildDate = '2026-09-19';

Widget _buildAbout(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  final bool mobile = isMobilePlatform;
  final String version = 'v${updater.currentVersion}';
  final double iconSize = mobile ? 72 : 48;

  // ── 卡 1：图标 + 软件名 + 版本号 ──
  // 只放「一眼能认出这是什么软件、什么版本」的身份信息。
  // 编译日期原先挤在头部，现挪到卡 2 的版本信息里 —— 它是版本细节，放在头部会让
  // 头部退化成「什么都往上堆」的信息板（用户反馈的正是头图与信息混在一起）。
  final Widget headerCard = _glass(ctx, state, s.aboutTitle, [
    Center(child: Column(children: [
      const SizedBox(height: 4),
      ClipRRect(
          borderRadius: BorderRadius.circular(mobile ? 16 : 12),
          child: Image.asset('rele/icon.png', width: iconSize, height: iconSize, fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(Icons.play_circle_fill, size: iconSize, color: scheme.primary))),
      SizedBox(height: mobile ? 10 : 8),
      Text('FFmpeg++',
          style: TextStyle(fontSize: mobile ? 20 : 16, fontWeight: FontWeight.w700, color: scheme.primary)),
      const SizedBox(height: 2),
      Text(version, style: TextStyle(fontSize: mobile ? 13 : 12, color: scheme.outline)),
      const SizedBox(height: 4),
    ])),
  ]);

  // ── 卡 2：版本与更新 ──
  // 版本信息 / 更新入口 / 外部链接 / 赞助 / 引用 / 广告。
  final String infoTitle = s.isZh ? '版本与更新' : 'Version & Updates';
  final Widget infoCard = mobile
      // 移动端统一用整行可点的 ListTile 形态（副标题写清作用），
      // 「编译日期」是纯信息行，同样用 ListTile 但无 onTap，与相邻行对齐。
      ? _glass(ctx, state, infoTitle, [
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline, size: 20, color: scheme.primary),
            title: Text(s.aboutVersion, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            trailing: Text(version,
                style: TextStyle(fontSize: 13, color: scheme.outline, fontWeight: FontWeight.w500)),
          ),
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.event_outlined, size: 20, color: scheme.primary),
            title: Text(s.aboutBuildDate, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            trailing: Text(kAboutBuildDate,
                style: TextStyle(fontSize: 13, color: scheme.outline, fontWeight: FontWeight.w500)),
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.system_update_alt, size: 20, color: scheme.primary),
            title: Text(s.cardUpdate, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            subtitle: Text(
                s.isZh ? '点按在线检查新版本；长按直达发布页'
                       : 'Tap to check online; long-press to open the release page',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
            trailing: const Icon(Icons.chevron_right, size: 16),
            // 移动端也走在线检查：发现新版本弹窗展示（APK 分发，下载动作
            // 自动降级为浏览器打开发布页/下载链接，见 _showUpdateDialog）
            onTap: () => _checkForUpdate(ctx, s),
            onLongPress: () => openExternalUrl(
                'https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases'),
          ),
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.code, size: 20, color: scheme.primary),
            title: Text(s.aboutGithub, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => openExternalUrl('https://github.com/lvbaoshigao/FFmpeg_plus_plus'),
          ),
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.article_outlined, size: 20, color: scheme.primary),
            title: Text(s.aboutBlog, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => openExternalUrl('https://blog-clstone.netlify.app/'),
          ),
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.volunteer_activism, size: 20, color: scheme.primary),
            title: Text(s.aboutSponsor, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showSponsor(ctx, scheme, s),
          ),
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.favorite_outline, size: 20, color: scheme.primary),
            title: Text(s.aboutReferences, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openCredits(ctx),
          ),
          // 广告入口（三级页面）：当前没有广告投放 → 页面显示「哦先生目前并没有放广告」空状态
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.campaign_outlined, size: 20, color: scheme.primary),
            title: Text(s.isZh ? '广告' : 'Ads', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            subtitle: Text(s.isZh ? '查看广告内容' : 'View sponsored content',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openAds(ctx),
          ),
        ])
      : _glass(ctx, state, infoTitle, [
          _infoRow(s.aboutVersion, version, scheme),
          _infoRow(s.aboutBuildDate, kAboutBuildDate, scheme),
          _infoRow(s.aboutBlog, 'blog-clstone.netlify.app', scheme),
          _infoRow(s.aboutGithub, 'github.com/lvbaoshigao/FFmpeg_plus_plus', scheme),
          const SizedBox(height: 8),
          // 「检查更新」入口（原独立「更新」卡片已并入这里）：自动检查开关 + 手动检查按钮
          SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
              title: Text(s.isZh ? '启动时自动检查更新' : 'Auto-check updates on startup',
                  style: TextStyle(color: scheme.onSurface, fontSize: 13)),
              subtitle: Text(s.isZh ? '静默检查，仅在有新版本时通知'
                      : 'Silent check, notifies only when new version available',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              value: state.config.autoCheckUpdate,
              onChanged: (v) => state.updateConfig((c) => c..autoCheckUpdate = v)),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: _iosButton(icon: Icons.volunteer_activism, label: s.aboutSponsorBtn,
                color: scheme.primary, bg: scheme.primaryContainer, onTap: () => _showSponsor(ctx, scheme, s))),
            const SizedBox(width: 8),
            Expanded(child: _iosButton(icon: Icons.system_update, label: s.checkUpdate,
                color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
                onTap: () => _checkForUpdate(ctx, s))),
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: _iosButton(
              icon: Icons.favorite_outline, label: s.aboutReferences,
              color: scheme.onSurface, bg: scheme.surfaceContainerHighest.withAlpha(100),
              onTap: () => _openCredits(ctx))),
          const SizedBox(height: 8),
          // 广告入口（三级页面）：与「引用」同一套按钮/页面样式
          SizedBox(width: double.infinity, child: _iosButton(
              icon: Icons.campaign_outlined, label: s.isZh ? '广告' : 'Ads',
              color: scheme.onSurface, bg: scheme.surfaceContainerHighest.withAlpha(100),
              onTap: () => _openAds(ctx))),
          const SizedBox(height: 10),
          Wrap(spacing: 4, runSpacing: 4, children: [
            _link(s.aboutBlogLink, 'https://blog-clstone.netlify.app/'),
            _link('GitHub', 'https://github.com/lvbaoshigao/FFmpeg_plus_plus'),
          ]),
        ]);

  // 两张卡纵向排布。**必须** CrossAxisAlignment.stretch：默认的 center 会让
  // 每张卡各取自身固有宽度 —— 卡 2 内容多、卡 1 内容少，宽度就对不上，
  // 而「两张卡宽度保持一致」正是本次改造的硬要求。
  // 两张 _glass 之间自己补 12 的间距：网格的 runSpacing 只作用在网格项之间，
  // 不会管网格项内部的这两张卡。
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      headerCard,
      const SizedBox(height: 12),
      infoCard,
    ],
  );
}

Widget _buildMcpAi(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.mcpTitle, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.mcpEnable, style: TextStyle(color: clr)),
        subtitle: cfg.mcpEnabled
            ? Text(
                state.mcpError != null
                    ? state.mcpError!
                    : state.mcpRunning ? (s.isZh ? '运行中' : 'Running') : (s.isZh ? '已停止' : 'Stopped'),
                style: TextStyle(fontSize: 10, color: state.mcpError != null ? scheme.sem.danger : state.mcpRunning ? scheme.sem.success : scheme.sem.neutral))
            : null,
        value: cfg.mcpEnabled,
        onChanged: (v) => state.toggleMcpServer(v)),
    if (cfg.mcpEnabled) ...[
      _McpFieldRow(
        label: Text('${s.mcpPort}:', style: TextStyle(color: clr, fontSize: 12)),
        field: _McpTextField(
          value: cfg.mcpPort.toString(), label: '', scheme: scheme,
          size: AppControlSize.regular,
          onChange: (v) {
            final port = int.tryParse(v);
            if (port != null && port > 0 && port < 65536) {
              state.updateConfig((c) => c..mcpPort = port);
            }
          },
        ),
        action: FilledButton.tonalIcon(
          style: AppControlSize.regular.buttonStyle(filled: true),
          icon: Icon(Icons.refresh, size: AppControlSize.regular.iconSize),
          label: Text(s.isZh ? '应用' : 'Apply', style: const TextStyle(fontSize: 11)),
          onPressed: () async {
            state.mcpError = null;
            await state.stopMcpServer();
            await state.startMcpServer();
          },
        ),
      ),
      const SizedBox(height: 8),
      _McpFieldRow(
        label: Text(s.isZh ? '监听地址:' : 'Bind host:', style: TextStyle(color: clr, fontSize: 12)),
        field: _McpTextField(
          value: cfg.mcpHost, label: '', scheme: scheme,
          hint: '127.0.0.1',
          size: AppControlSize.regular,
          onChange: (v) {
            final host = v.trim();
            // 允许留空（回退 127.0.0.1）；其余只做基本字符校验，重启后生效
            if (host.isEmpty || RegExp(r'^[A-Za-z0-9.:_-]+$').hasMatch(host)) {
              state.updateConfig((c) => c..mcpHost = host);
            }
          },
        ),
        note: Text(
          s.isZh ? '改后点「应用」。设为 0.0.0.0 将暴露到局域网并启用访问令牌' : 'Click Apply. 0.0.0.0 exposes to LAN and enables token',
          style: TextStyle(fontSize: 10, color: scheme.outline),
        ),
      ),
    ],
    if (cfg.mcpEnabled && state.mcpRunning && state.mcpToken != null)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: SelectableText(
          '${s.isZh ? '局域网访问令牌' : 'LAN access token'}: ${state.mcpToken}',
          style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600),
        ),
      ),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '允许 MCP 写入' : 'Allow MCP Write', style: TextStyle(color: clr, fontSize: 12)),
        subtitle: Text(s.isZh ? '关闭时 MCP 只能读取画布/文件，所有修改操作会被拒绝' : 'When off, MCP can only read the canvas/files; all write actions are rejected',
            style: TextStyle(fontSize: 10, color: scheme.outline)),
        value: cfg.mcpAllowWrite,
        onChanged: (v) => state.updateConfig((c) => c..mcpAllowWrite = v)),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '允许 MCP 访问文件系统' : 'Allow MCP File Access', style: TextStyle(color: clr, fontSize: 12)),
        subtitle: Text(s.isZh ? '控制列目录/文件信息/媒体探测三个工具；本机任何程序都能调用 MCP，不依赖时可关闭' : 'Gates list_directory / read_file_info / probe_video; any local program can call MCP — turn off when unused',
            style: TextStyle(fontSize: 10, color: scheme.outline)),
        value: cfg.mcpAllowFsAccess,
        onChanged: (v) => state.updateConfig((c) => c..mcpAllowFsAccess = v)),
    const SizedBox(height: 8),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.aiEnable, style: TextStyle(color: clr)),
        value: cfg.aiEnabled,
        onChanged: (v) => state.updateConfig((c) => c..aiEnabled = v)),
    if (cfg.aiEnabled)
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          // 次级链接动作：走 compact 档（28 高），与卡片里的表单控件（regular 32）
          // 形成层级差，不再是「一个光秃秃的主题默认按钮贴右下角」
          style: AppControlSize.compact.buttonStyle(),
          icon: Icon(Icons.tune, size: AppControlSize.compact.iconSize),
          label: Text(s.aiMoreOptions, style: const TextStyle(fontSize: 12)),
          onPressed: () => _showAiSettingsDialog(ctx, state, s),
        ),
      ),
  ]);
}

void _showAiSettingsDialog(BuildContext ctx, AppState state, AppStrings s) {
  if (isMobilePlatform) {
    // 移动端：AI「更多选项」改为二级页面（全屏 + 返回按钮），而非 PC 式底部弹窗
    Navigator.of(ctx).push(MaterialPageRoute<void>(allowSnapshotting: false, 
      builder: (bCtx) => Scaffold(
        body: SafeArea(child: _aiSettingsContent(bCtx, state, s, asSheet: false)),
      ),
    ));
    return;
  }
  showModalBottomSheet(
    context: ctx,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 限制最大宽度并居中：宽屏下 AI 设置面板不再拉满整屏
    constraints: const BoxConstraints(maxWidth: 880),
    builder: (bCtx) => _aiSettingsContent(bCtx, state, s, asSheet: true),
  );
}

/// AI 设置内容主体。asSheet=true 以底部弹层呈现（桌面），asSheet=false 以全屏
/// 二级页面呈现（移动端，带返回按钮）。两种形态复用同一段配置表单。
Widget _aiSettingsContent(BuildContext bCtx, AppState state, AppStrings s, {required bool asSheet}) {
  final zh = s.isZh;
  // 持久状态（闭包捕获，StatefulBuilder 重建时保留）：
  // 当前选中的配置 id + 正在编辑的草稿（null=尚未开始编辑）
  String selProfileId = state.config.aiProfiles.isNotEmpty
      ? (state.config.activeAiProfileId.isNotEmpty
          ? state.config.activeAiProfileId
          : state.config.aiProfiles.first.id)
      : '';
  AiProfile? draft;
  bool showPreset = false;
  return StatefulBuilder(builder: (ctx2, setDState) {
        final cfg = state.config;
        final scheme = Theme.of(ctx2).colorScheme;
        final clr = scheme.onSurface;
        final cardColor = scheme.surface.withAlpha((cfg.cardOpacity * 255).round().clamp(0, 255));

        // 当前编辑对象：优先草稿，其次从列表取
        AiProfile? selected() {
          if (draft != null) return draft;
          for (final pr in cfg.aiProfiles) {
            if (pr.id == selProfileId) return pr;
          }
          return null;
        }

        Widget section(String title, IconData icon, List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          child: Padding(padding: const EdgeInsets.all(14), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
              ]),
              const SizedBox(height: 10),
              ...children,
            ],
          )),
        );

        // 标题行：移动端二级页面带返回按钮；桌面弹层只有标题 + 完成
        Widget headerRow({required bool withBack}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            if (withBack) ...[
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new, size: 16, color: clr),
                onPressed: () => Navigator.pop(bCtx),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              const SizedBox(width: 4),
            ],
            Text(s.aiSettings, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: clr)),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(bCtx), child: Text(zh ? '完成' : 'Done')),
          ]),
        );

        // 内容列表（AI 配置 / 权限 / 行为 / 提示词等分区），两种形态共用
        Widget listBody(ScrollController? ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
                  // ── AI 配置（左右分区：左列表 / 右详情） ──
                  section(zh ? 'AI 配置' : 'AI Profiles', Icons.folder_shared_outlined, [
                    SizedBox(
                      height: 300,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // ══ 左：配置列表 ══
                        Container(
                          width: 170,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withAlpha(50),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outlineVariant.withAlpha(50)),
                          ),
                          child: Column(children: [
                            Expanded(
                              child: cfg.aiProfiles.isEmpty
                                  ? Center(child: Text(zh ? '暂无配置' : 'No profiles',
                                      style: TextStyle(fontSize: 11, color: scheme.outline)))
                                  : ListView.builder(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      itemCount: cfg.aiProfiles.length,
                                      itemBuilder: (_, i) {
                                        final pr = cfg.aiProfiles[i];
                                        final isSel = pr.id == selProfileId;
                                        return InkWell(
                                          onTap: () { selProfileId = pr.id; draft = null; showPreset = false; setDState(() {}); },
                                          child: Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isSel ? scheme.primaryContainer.withAlpha(120) : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Row(children: [
                                              Icon(
                                                pr.enabled
                                                    ? (isSel ? Icons.radio_button_checked : Icons.cloud_outlined)
                                                    : Icons.cloud_off_outlined,
                                                size: 13,
                                                color: isSel ? scheme.primary : (pr.enabled ? scheme.outline : scheme.outline.withAlpha(60)),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(child: Text(pr.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                                      color: isSel ? scheme.primary : (pr.enabled ? clr : scheme.outline)))),
                                            ]),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            Divider(height: 1, color: scheme.outlineVariant.withAlpha(40)),
                            // 新建配置
                            InkWell(
                              onTap: () {
                                final np = AiProfile(name: zh ? '新配置' : 'New Profile');
                                // 只建本地草稿，点"保存"才落库。
                                // 原实现立即 updateConfig 持久化，不保存就关闭对话框会留下幽灵配置。
                                selProfileId = np.id; draft = np; showPreset = true;
                                setDState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Icon(Icons.add, size: 14, color: scheme.primary),
                                  const SizedBox(width: 4),
                                  Text(zh ? '新建配置' : 'New Profile',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary)),
                                ]),
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(width: 12),
                        // ══ 右：配置详情 ══
                        Expanded(
                          child: selected() == null
                              ? Center(child: Text(zh ? '选择或新建一个配置' : 'Select or create a profile',
                                  style: TextStyle(fontSize: 11, color: scheme.outline)))
                              : _buildProfileDetail(ctx2, state, setDState, scheme, clr, s, zh, selected()!, selProfileId, draft, showPreset, () {
                                  selProfileId = cfg.aiProfiles.isNotEmpty ? cfg.aiProfiles.first.id : '';
                                  draft = null;
                                  setDState(() {});
                                }),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                  ]),

                  // ── Permissions ──
                  section(s.aiPermissions, Icons.security_outlined, [
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiReadAccess, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiReadAccessDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiReadAccess,
                        onChanged: (v) { state.updateConfig((c) => c..aiReadAccess = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiWriteAccess, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiWriteAccessDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiWriteAccess,
                        onChanged: (v) { state.updateConfig((c) => c..aiWriteAccess = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiAutoExecute, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiAutoExecuteDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiAutoExecute,
                        onChanged: (v) { state.updateConfig((c) => c..aiAutoExecute = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiAllowAsk, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiAllowAskDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiAllowAsk,
                        onChanged: (v) { state.updateConfig((c) => c..aiAllowAsk = v); setDState(() {}); }),
                  ]),
                  // ── Advanced ──
                  section(s.aiAdvanced, Icons.tune_outlined, [
                    // 图生成模式：下拉菜单（原分段按钮在窄栏里两个长标签会挤压换行）
                    Row(children: [
                      Expanded(child: Text(s.aiGraphModeLabel,
                          style: TextStyle(color: clr, fontSize: 12))),
                      SizedBox(width: _kMenuWidth, child: OptionMenuBar<String>(
                        key: ValueKey('aiGraphMode_${cfg.aiGraphMode}'),
                        expandable: true,
                        value: cfg.aiGraphMode,
                        items: [
                          OptionItem('redo', s.aiGraphModeRedo, icon: Icons.refresh),
                          OptionItem('modify', s.aiGraphModeModify, icon: Icons.edit_outlined),
                        ],
                        onChanged: (v) {
                          state.updateConfig((c) => c..aiGraphMode = v);
                          setDState(() {});
                        },
                      )),
                    ]),
                    const SizedBox(height: 8),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiShowThinking, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiShowThinkingDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiShowThinking,
                        onChanged: (v) { state.updateConfig((c) => c..aiShowThinking = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiAutoTitleLabel, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiAutoTitleDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiAutoTitle,
                        onChanged: (v) { state.updateConfig((c) => c..aiAutoTitle = v); setDState(() {}); }),
                    if (cfg.aiAutoTitle) ...[
                      const SizedBox(height: 4),
                      Text(s.aiTitlePromptLabel, style: TextStyle(color: clr, fontSize: 12)),
                      const SizedBox(height: 6),
                      _McpTextField(
                        value: cfg.aiTitlePrompt,
                        label: '',
                        hint: s.isZh ? '标题生成提示词（可改写）' : 'Title prompt (editable)',
                        scheme: scheme,
                        minLines: 2,
                        maxLines: 4,
                        onChange: (v) => state.updateConfig((c) => c..aiTitlePrompt = v),
                      ),
                    ],
                    const SizedBox(height: 4),
                    // 会话模式：自动批准 / 询问
                    Text(s.aiApproveModeLabel, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    OptionMenuBar<String>(
                      expandable: false,
                      value: cfg.aiApproveMode,
                      items: [
                        OptionItem('ask', s.aiApproveModeAsk),
                        OptionItem('auto', s.aiApproveModeAuto),
                      ],
                      onChanged: (v) { state.updateConfig((c) => c..aiApproveMode = v); setDState(() {}); },
                    ),
                    const SizedBox(height: 6),
                    Text(s.aiApproveModeDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                    const SizedBox(height: 12),
                    // 询问模式下无需确认的操作
                    Text(s.aiAskSkipLabel, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final key in _askSkipKeys)
                        FilterChip(
                          label: Text(_askSkipLabel(key, s.isZh),
                              style: const TextStyle(fontSize: 11)),
                          selected: cfg.aiAskSkipTools.contains(key),
                          visualDensity: VisualDensity.compact,
                          onSelected: (sel) {
                            state.updateConfig((c) {
                              final set = c.aiAskSkipTools.toSet();
                              if (sel) { set.add(key); } else { set.remove(key); }
                              c.aiAskSkipTools = set.toList();
                              return c;
                            });
                            setDState(() {});
                          },
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Text(s.aiCustomPrompt, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    // 用有状态的字段持有 controller：这里原先每次 setDState 都会新建一个
                    // TextEditingController，导致光标跳回开头、根本没法连续输入。
                    _McpTextField(
                      value: cfg.aiSystemPrompt,
                      label: '',
                      hint: s.aiCustomPromptHint,
                      scheme: scheme,
                      minLines: 3,
                      maxLines: 5,
                      onChange: (v) => state.updateConfig((c) => c..aiSystemPrompt = v),
                    ),
                  ]),
                ],
        );

        if (asSheet) {
          return DraggableScrollableSheet(
            initialChildSize: 0.85,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            builder: (_, scrollCtrl) => GlassPanel(
              radius: 20,
              child: Column(children: [
                const SizedBox(height: 8),
                Container(width: 36, height: 4, decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2))),
                headerRow(withBack: false),
                Expanded(child: listBody(scrollCtrl)),
              ]),
            ),
          );
        }
        // 移动端二级页面：标题行（带返回）+ 内容列表
        return Column(children: [
          headerRow(withBack: true),
          Expanded(child: listBody(null)),
        ]);
      });
}

/// 对 AiProfile 应用供应商预设（一键填充端点/模型/上下文）。
/// 公开供移动端提供商详情页复用。
void applyProfilePreset(AiProfile c, String preset) {
  switch (preset) {
    case 'openai':
      c.provider = 'openai';
      c.apiUrl = 'https://api.openai.com/v1/chat/completions';
      c.model = 'gpt-4o';
      c.contextWindow = 128000;
    case 'anthropic':
      c.provider = 'anthropic';
      c.apiUrl = 'https://api.anthropic.com/v1/messages';
      c.model = _kDefaultAnthropicModel;
      c.contextWindow = 200000;
    case 'deepseek':
      c.provider = 'openai';
      c.apiUrl = 'https://api.deepseek.com/v1/chat/completions';
      c.model = 'deepseek-chat';
      c.contextWindow = 64000;
    case 'ollama':
      c.provider = 'openai';
      c.apiUrl = 'http://localhost:11434/v1/chat/completions';
      c.model = 'llama3';
      c.contextWindow = 8192;
  }
}

/// 右侧配置详情：编辑选中配置的全部字段（含供应商预设）。
Widget _buildProfileDetail(
  BuildContext ctx,
  AppState state,
  StateSetter setDState,
  ColorScheme scheme,
  Color clr,
  AppStrings s,
  bool zh,
  AiProfile profile,
  String selProfileId,
  AiProfile? draft,
  bool showPreset,
  VoidCallback onDeleted,
) {
  // 用 Key 保持编辑中草稿的 controller 稳定
  Widget field(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, color: clr)),
      const SizedBox(height: 4),
      child,
    ]),
  );

  return SingleChildScrollView(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 供应商预设（新建/编辑都可一键填充）
      if (showPreset) ...[
        field(zh ? '供应商预设（一键填充）' : 'Provider Preset', OptionMenuBar<String>(
          expandable: true,
          value: profile.provider == 'anthropic' ? 'anthropic'
              : profile.apiUrl.contains('deepseek') ? 'deepseek'
              : profile.apiUrl.contains('localhost') || profile.apiUrl.contains('11434') ? 'ollama'
              : 'openai',
          items: const [
            OptionItem('openai', 'OpenAI'),
            OptionItem('anthropic', 'Anthropic (Claude)'),
            OptionItem('deepseek', 'DeepSeek'),
            OptionItem('ollama', 'Ollama (本地)'),
          ],
          onChanged: (preset) {
            applyProfilePreset(profile, preset);
            setDState(() {});
          },
        )),
        const SizedBox(height: 8),
      ],
      // 配置名
      field(zh ? '配置名' : 'Name', _ProfileTextField(
        value: profile.name,
        onChange: (v) { profile.name = v; },
      )),
      // 协议
      field(zh ? '请求方式 / 协议' : 'Protocol', OptionMenuBar<String>(
        expandable: false,
        value: profile.provider,
        items: [
          OptionItem('openai', zh ? 'OpenAI 兼容' : 'OpenAI'),
          OptionItem('anthropic', 'Anthropic'),
        ],
        onChanged: (v) { profile.provider = v; setDState(() {}); },
      )),
      const SizedBox(height: 10),
      // API Key（可切换显示/隐藏）
      field(s.aiApiKey, _McpTextField(
        value: profile.apiKey,
        label: '',
        scheme: scheme,
        obscure: true,
        onChange: (v) { profile.apiKey = v; },
      )),
      // Base URL
      field(s.aiApiUrl, _ProfileTextField(
        value: profile.apiUrl,
        onChange: (v) { profile.apiUrl = v; },
      )),
      // 模型
      field(s.aiModel, _ProfileTextField(
        value: profile.model,
        onChange: (v) { profile.model = v; },
      )),
      // 上下文窗口
      field(zh ? '上下文窗口 (token)' : 'Context Window (tokens)', _ProfileTextField(
        value: profile.contextWindow.toString(),
        keyboardType: TextInputType.number,
        onChange: (v) { final n = int.tryParse(v); if (n != null && n >= 1000) profile.contextWindow = n; },
      )),
      // 最大输出
      field(zh ? '最大输出 token' : 'Max Output Tokens', _ProfileTextField(
        value: profile.maxTokens.toString(),
        keyboardType: TextInputType.number,
        onChange: (v) { final n = int.tryParse(v); if (n != null && n > 0) profile.maxTokens = n; },
      )),
      // 温度
      field(zh ? '温度 (0-2)' : 'Temperature (0-2)', _ProfileTextField(
        value: profile.temperature.toStringAsFixed(1),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChange: (v) { final t = double.tryParse(v); if (t != null && t >= 0 && t <= 2) profile.temperature = t; },
      )),
      // 操作按钮：两个按钮都包 Expanded ⇒ 等宽；高度统一走 comfortable 档。
      // 改造前「保存」是 Expanded 吃掉剩余宽度，「设为当前」只占内容宽度，
      // 两个按钮宽度差一倍（宽窗口下尤其明显），看着像两个不同层级的控件并排。
      Row(children: [
        Expanded(child: FilledButton.icon(
          style: AppControlSize.comfortable.buttonStyle(filled: true),
          icon: Icon(Icons.save_outlined, size: AppControlSize.comfortable.iconSize),
          label: Text(zh ? '保存' : 'Save', style: const TextStyle(fontSize: 12)),
          onPressed: () {
            final name = profile.name.trim();
            if (name.isEmpty) {
              showToast(ctx, zh ? '配置名不能为空' : 'Name is required', type: ToastType.error);
              return;
            }
            // 落库（编辑已有项或新项）
            state.updateConfig((c) {
              final i = c.aiProfiles.indexWhere((e) => e.id == profile.id);
              if (i >= 0) {
                c.aiProfiles[i] = profile;
              } else {
                c.aiProfiles.add(profile);
              }
              if (c.activeAiProfileId.isEmpty) c.activeAiProfileId = profile.id;
              return c;
            });
            showToast(ctx, zh ? '配置已保存' : 'Profile saved', type: ToastType.success);
          },
        )),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(
          style: AppControlSize.comfortable.buttonStyle(),
          icon: Icon(
            state.config.activeAiProfileId == profile.id ? Icons.radio_button_checked : Icons.radio_button_off,
            size: AppControlSize.comfortable.iconSize,
          ),
          label: Text(zh ? '设为当前' : 'Use', style: const TextStyle(fontSize: 12)),
          onPressed: () {
            state.updateConfig((c) { c.activeAiProfileId = profile.id; return c; });
            setDState(() {});
          },
        )),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _iosButton(icon: Icons.wifi_tethering, label: s.aiPing,
            color: scheme.primary, bg: scheme.primaryContainer,
            onTap: () {
              // 把当前配置临时同步到默认字段，供测试函数使用
              state.updateConfig((c) {
                c.aiApiKey = profile.apiKey;
                c.aiApiUrl = profile.apiUrl;
                c.aiProvider = profile.provider;
                return c;
              }).ignore();
              pingAi(ctx, state, s);
            })),
        const SizedBox(width: 8),
        Expanded(child: _iosButton(icon: Icons.list, label: s.aiListModels,
            color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
            onTap: () {
              state.updateConfig((c) {
                c.aiApiKey = profile.apiKey;
                c.aiApiUrl = profile.apiUrl;
                c.aiProvider = profile.provider;
                return c;
              }).ignore();
              // 选中的模型写回当前正在编辑的 profile（而非全局默认字段）
              listAiModels(ctx, state, s, onPicked: (m) {
                profile.model = m;
                setDState(() {});
              });
            })),
      ]),
      if (draft != null) ...[
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          icon: const Icon(Icons.delete_outline, size: 16),
          label: Text(zh ? '删除此配置' : 'Delete this profile', style: const TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
          onPressed: () {
            state.updateConfig((c) {
              c.aiProfiles.removeWhere((e) => e.id == profile.id);
              if (c.activeAiProfileId == profile.id) c.activeAiProfileId = '';
              return c;
            });
            onDeleted();
          },
        )),
      ],
    ]),
  );
}

/// Anthropic 的 /v1/models 拿不到时的兜底列表。
const _kKnownAnthropicModels = [
  'claude-opus-5',
  'claude-sonnet-5',
  'claude-haiku-4-5',
];

String _httpReason(int code) => switch (code) {
  400 => 'Bad Request',
  401 => 'Unauthorized (check API Key)',
  403 => 'Forbidden',
  404 => 'Not Found (check API URL)',
  429 => 'Too Many Requests',
  500 => 'Server Error',
  502 => 'Bad Gateway',
  503 => 'Service Unavailable',
  _ => 'Error',
};

/// 测试当前 AI 配置连通性（读取 config 默认字段 aiApiKey/aiApiUrl/aiProvider）。
/// 公开供移动端提供商详情页复用（调用前先同步所选提供商字段到默认字段）。
Future<void> pingAi(BuildContext ctx, AppState state, AppStrings s) async {
  final cfg = state.config;
  if (cfg.aiApiKey.isEmpty) {
    if (ctx.mounted) showToast(ctx, s.aiNotConfigured, type: ToastType.warning);
    return;
  }
  final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/chat/completions$|/messages$'), '');
  final modelsUrl = baseUrl.endsWith('/v1') ? '$baseUrl/models' : '$baseUrl/v1/models';
  state.addLog('[AI] Ping $modelsUrl ...', category: 'info');
  try {
    final uri = Uri.parse(modelsUrl);
    final headers = <String, String>{};
    if (cfg.aiProvider == 'anthropic') {
      headers['x-api-key'] = cfg.aiApiKey;
      headers['anthropic-version'] = '2023-06-01';
    } else {
      headers['Authorization'] = 'Bearer ${cfg.aiApiKey}';
    }
    final sw = Stopwatch()..start();
    final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    final ok = resp.statusCode >= 200 && resp.statusCode < 400;
    state.addLog('[AI] Ping ${ok ? "OK" : "FAIL"}: ${resp.statusCode}, ${ms}ms', category: ok ? 'info' : 'error');
    if (ctx.mounted) showToast(ctx, ok ? '${resp.statusCode} OK — ${ms}ms' : 'HTTP ${resp.statusCode} ${_httpReason(resp.statusCode)}', type: ok ? ToastType.success : ToastType.error);
  } catch (e) {
    state.addLog('[AI] Ping failed: $e', category: 'error');
    if (ctx.mounted) showToast(ctx, 'Error: $e', type: ToastType.error);
  }
}

/// 拉取模型列表并弹出选择器；[onPicked] 收到用户选中的模型名
/// （写入哪个 model 字段由调用方决定）。公开供移动端提供商详情页复用。
/// 拉取供应商模型列表。
///
/// [onPicked] 用户在选择器里点选某个模型时回调。
/// [onListed] 拉取成功后回调完整列表 —— 供「提供商设置 → 模型」页把结果
/// 落进 AiProfile.models（带能力标记），而不只是选一个当前模型。
Future<void> listAiModels(BuildContext ctx, AppState state, AppStrings s,
    {required ValueChanged<String> onPicked,
    ValueChanged<List<String>>? onListed}) async {
  final cfg = state.config;
  if (cfg.aiApiKey.isEmpty) {
    if (ctx.mounted) showToast(ctx, s.aiNotConfigured, type: ToastType.warning);
    return;
  }
  state.addLog('[AI] 获取模型列表...', category: 'info');
  try {
    final headers = <String, String>{};
    if (cfg.aiProvider == 'anthropic') {
      final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/messages$'), '');
      final modelsUrl = baseUrl.endsWith('/v1') ? '$baseUrl/models' : '$baseUrl/v1/models';
      headers['x-api-key'] = cfg.aiApiKey;
      headers['anthropic-version'] = '2023-06-01';
      final resp = await http.get(Uri.parse(modelsUrl), headers: headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final models = (data['data'] as List?)?.map((m) => m['id'] as String).toList() ?? [];
        models.sort();
        state.addLog('[AI] Anthropic 获取到 ${models.length} 个模型', category: 'info');
        onListed?.call(models);
        if (ctx.mounted) _showModelPicker(ctx, state, models, s, onPicked);
      } else {
        state.addLog('[AI] Anthropic models endpoint unavailable (${resp.statusCode}), using known models', category: 'info');
        final known = List.of(_kKnownAnthropicModels);
        onListed?.call(known);
        if (ctx.mounted) _showModelPicker(ctx, state, known, s, onPicked);
      }
      return;
    }
    // OpenAI-compatible: GET /v1/models
    final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/chat/completions$'), '');
    headers['Authorization'] = 'Bearer ${cfg.aiApiKey}';
    final resp = await http.get(Uri.parse('$baseUrl/models'), headers: headers).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      final models = (data['data'] as List?)?.map((m) => m['id'] as String).toList() ?? [];
      models.sort();
      state.addLog('[AI] 获取到 ${models.length} 个模型', category: 'info');
      onListed?.call(models);
      if (ctx.mounted) _showModelPicker(ctx, state, models, s, onPicked);
    } else {
      state.addLog('[AI] 获取模型失败: ${resp.statusCode}', category: 'error');
      if (ctx.mounted) showToast(ctx, 'HTTP ${resp.statusCode}', type: ToastType.error);
    }
  } catch (e) {
    state.addLog('[AI] 获取模型失败: $e', category: 'error');
    if (ctx.mounted) showToast(ctx, 'Error: $e', type: ToastType.error);
  }
}

/// 查询账户余额。
///
/// 各供应商余额端点没有统一标准，这里按「OpenAI 兼容」常见约定依次尝试：
/// 1. `/dashboard/billing/subscription` + `/dashboard/billing/credit_grants`
///    （OpenAI 早期与多数国内中转站沿用）
/// 2. `/user/info`（部分 one-api / new-api 面板）
///
/// 返回可读余额字符串；全部端点不可用时返回 null（由调用方提示「不支持」），
/// 而不是抛错——避免把「供应商没这个接口」当成配置错误误导用户。
Future<String?> fetchAiBalance(AiProfile profile) async {
  final keys = profile.effectiveKeys;
  if (keys.isEmpty) return null;
  final key = keys.first;
  // 从完整请求地址里剥出 API 根（去掉 /chat/completions、/messages、/responses）
  var base = profile.apiUrl
      .replaceAll(RegExp(r'/chat/completions/?$'), '')
      .replaceAll(RegExp(r'/messages/?$'), '')
      .replaceAll(RegExp(r'/responses/?$'), '');
  if (base.endsWith('/')) base = base.substring(0, base.length - 1);

  final headers = {'Authorization': 'Bearer $key'};
  const timeout = Duration(seconds: 10);

  // 1) credit_grants（余额 + 已用）
  try {
    final resp = await http
        .get(Uri.parse('$base/dashboard/billing/credit_grants'), headers: headers)
        .timeout(timeout);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final total = (data['total_granted'] as num?)?.toDouble();
      final used = (data['total_used'] as num?)?.toDouble();
      final available = (data['total_available'] as num?)?.toDouble();
      if (available != null || total != null) {
        final parts = <String>[];
        if (available != null) parts.add('可用 \$${available.toStringAsFixed(2)}');
        if (used != null) parts.add('已用 \$${used.toStringAsFixed(2)}');
        if (total != null) parts.add('总额 \$${total.toStringAsFixed(2)}');
        return parts.join(' · ');
      }
    }
  } catch (_) {
    // 端点不存在/网络问题 → 继续尝试下一个
  }

  // 2) one-api / new-api 面板的 /user/info（quota 单位为 500000 = $1）
  try {
    final resp = await http
        .get(Uri.parse('$base/user/info'), headers: headers)
        .timeout(timeout);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final d = data['data'];
      if (d is Map) {
        final quota = (d['quota'] as num?)?.toDouble();
        final usedQuota = (d['used_quota'] as num?)?.toDouble();
        if (quota != null) {
          const unit = 500000.0; // one-api 约定：500000 quota = $1
          final parts = <String>['可用 \$${(quota / unit).toStringAsFixed(2)}'];
          if (usedQuota != null) {
            parts.add('已用 \$${(usedQuota / unit).toStringAsFixed(2)}');
          }
          return parts.join(' · ');
        }
      }
    }
  } catch (_) {
    // 同上
  }

  return null;
}

void _showModelPicker(BuildContext ctx, AppState state, List<String> models, AppStrings s, ValueChanged<String> onPicked) {
  if (models.isEmpty) {
    showToast(ctx, s.isZh ? '未找到模型' : 'No models found', type: ToastType.warning);
    return;
  }
  showDialog(context: ctx, builder: (dCtx) {
    final scheme = Theme.of(dCtx).colorScheme;
    return AlertDialog(
      title: Text(s.aiListModels, style: TextStyle(color: scheme.onSurface, fontSize: 15)),
      content: SizedBox(
        width: 300, height: 400,
        child: ListView.builder(
          itemCount: models.length,
          itemBuilder: (_, i) => ListTile(
            dense: true,
            title: Text(models[i], style: TextStyle(fontSize: 12, color: scheme.onSurface)),
            selected: models[i] == state.config.aiModel,
            selectedTileColor: scheme.primaryContainer.withAlpha(60),
            onTap: () {
              state.addLog('[AI] 已选择模型: ${models[i]}', category: 'info');
              Navigator.pop(dCtx);
              onPicked(models[i]);
              showToast(ctx, '${s.isZh ? "已选择" : "Selected"}: ${models[i]}', type: ToastType.success);
            },
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.close))],
    );
  });
}

Future<void> _pickFont(BuildContext ctx, AppState state) async {
  final isZh = state.config.language == 'zh';
  // Android：SAF/content:// URI 常常拿不到真实磁盘路径（path 为 null），
  // 必须同时取内存字节兜底 —— 之前只认 path，HyperOS/MIUI 上会出现
  // 「选了字体却毫无反应」的静默失败。
  final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['ttf', 'otf'],
      withData: isAndroidPlatform);
  if (r == null || r.files.isEmpty) return;
  final picked = r.files.first;
  final fileName = picked.name;
  if (!fileName.toLowerCase().endsWith('.ttf') && !fileName.toLowerCase().endsWith('.otf')) {
    if (ctx.mounted) showToast(ctx, isZh ? '请选择 .ttf 或 .otf 字体文件' : 'Please pick a .ttf/.otf font file', type: ToastType.error);
    return;
  }
  final fontName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  // 落盘目录必须先确定：_ensureAndroidAppDir 是 initState 里 fire-and-forget 的，
  // 之前这里不 await，一旦它还没解析完就把字体写进了 systemTemp/FFmpeg++/fonts
  // （安卓上即应用缓存目录），而启动加载只认「应用文档目录/FFmpeg++/fonts」
  // → 表现为「导入的字体重启后不见了」（用户反馈的「导入后不显示」）。
  await _ensureAndroidAppDir();
  try {
    // 1) 取得字体字节：优先磁盘路径，content:// 时用内存字节
    Uint8List? bytes;
    String? srcPath = picked.path;
    if (srcPath != null && !srcPath.startsWith('content://') && await File(srcPath).exists()) {
      bytes = await File(srcPath).readAsBytes();
    } else if (picked.bytes != null) {
      bytes = picked.bytes;
      srcPath = null; // 字节来源，下面改用落盘后的路径
    }
    if (bytes == null) {
      if (ctx.mounted) showToast(ctx, isZh ? '无法读取字体文件' : 'Cannot read font file', type: ToastType.error);
      return;
    }
    // 2) 先落盘到应用数据目录 fonts/（重启后由 main.dart 重新加载）
    String? fontFilePath;
    if (srcPath != null) {
      fontFilePath = await _copyToAppDir(srcPath, 'fonts');
    }
    if (fontFilePath == null) {
      // 字节来源或复制失败：手动写入
      final dir = Directory('${_userDataDir()}$_s' 'fonts');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      fontFilePath = '${dir.path}$_s$fileName';
      await File(fontFilePath).writeAsBytes(bytes, flush: true);
    }
    // 3) 注册进引擎并应用（FontLoader 注册的族名 = 文件名去扩展名）
    final fontLoader = FontLoader(fontName);
    fontLoader.addFont(Future.value(ByteData.sublistView(bytes)));
    await fontLoader.load();
    state.updateConfig((c) => c..fontFamily = fontName);
    if (ctx.mounted) showToast(ctx, isZh ? '字体 "$fontName" 已加载并应用' : 'Font "$fontName" loaded and applied', type: ToastType.success);
  } catch (e) {
    // 加载失败不设置 fontFamily（否则全局文本回退到坏字体）
    if (ctx.mounted) showToast(ctx, isZh ? '字体加载失败: $e' : 'Font load failed: $e', type: ToastType.error);
  }
}

/// 「清除缓存」的两个子选项（用户要求点按钮后先让用户选清哪一类）。
///
/// 两件事的代价完全不同，混在一起做并不合适：
/// * [assets] —— 删掉已导入的字体文件与背景图片，**之后要重新导入**；
/// * [caches] —— 删掉导入副本（file_picker 副本 / ffmpegpp_import_* / 缩略图），
///   只是回收空间，项目内容不受影响，大文件可能释放几百 MB。
enum _CacheScope {
  /// 只清除已导入的字体文件与背景图片
  assets,

  /// 只清除导入缓存（不含字体与背景图片）
  caches,
}

/// 「清除缓存」入口：先弹出两个子选项，再执行对应清理。
Future<void> _clearCache(BuildContext ctx, AppState state, ColorScheme scheme, AppStrings s) async {
  final scope = await showDialog<_CacheScope>(
    context: ctx,
    builder: (dCtx) => AlertDialog(
      title: Text(s.isZh ? '清除缓存' : 'Clear Cache',
          style: TextStyle(color: scheme.onSurface)),
      contentPadding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        _cacheOption(
          dCtx,
          scheme,
          scope: _CacheScope.assets,
          icon: Icons.image_outlined,
          title: s.isZh ? '清除图片 / 字体' : 'Clear images / fonts',
          desc: s.isZh
              ? '删除已导入的字体文件和背景图片，之后需要重新选择'
              : 'Delete imported fonts and background image; re-select afterwards',
        ),
        const SizedBox(height: 6),
        _cacheOption(
          dCtx,
          scheme,
          scope: _CacheScope.caches,
          icon: Icons.cleaning_services_outlined,
          title: s.isZh ? '清除缓存' : 'Clear cache',
          desc: s.isZh
              ? '删除导入副本（大文件可能占几百 MB）与缩略图；\n仍被项目 / 队列引用的副本会保留'
              : 'Delete import copies (hundreds of MB possible) and thumbnails;\n'
                'copies still referenced by projects/queue are kept',
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(s.isZh ? '取消' : 'Cancel')),
      ],
    ),
  );
  if (scope == null || !ctx.mounted) return;

  try {
    // ── 分支一：只清字体 / 背景图 ──
    if (scope == _CacheScope.assets) {
      final freed = await _clearImportedAssets(state);
      if (ctx.mounted) {
        final freedText = freed > 0 ? '（释放 ${_humanSize(freed)}）' : '';
        showToast(ctx,
            s.isZh ? '已清除导入的图片和字体$freedText' : 'Images and fonts cleared$freedText',
            type: ToastType.success);
      }
      return;
    }

    // ── 分支二：只清导入缓存 ──
    final freed = await state.purgeImportCachesNow();
    if (ctx.mounted) {
      final freedText = freed > 0 ? '（释放 ${_humanSize(freed)}）' : '';
      showToast(ctx,
          s.isZh ? '缓存已清除$freedText' : 'Cache cleared$freedText',
          type: ToastType.success);
    }
  } catch (e) {
    if (ctx.mounted) showToast(ctx, s.isZh ? '清除失败: $e' : 'Clear failed: $e', type: ToastType.error);
  }
}

/// 弹窗里的一个子选项行（图标 + 标题 + 说明），点选后以 [_CacheScope] 结束对话框。
Widget _cacheOption(
  BuildContext dCtx,
  ColorScheme scheme, {
  required _CacheScope scope,
  required IconData icon,
  required String title,
  required String desc,
}) {
  return Material(
    color: scheme.surfaceContainerHighest.withAlpha(90),
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(dCtx, scope),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const SizedBox(height: 2),
              Text(desc,
                  style: TextStyle(fontSize: 10.5, height: 1.35, color: scheme.outline)),
            ]),
          ),
        ]),
      ),
    ),
  );
}

/// 只清除「已导入的字体文件 + 背景图片」，返回释放的字节数。
///
/// 与 `AppState.purgeImportCachesNow()`（导入副本）分开：字体/图片删掉要重新导入，
/// 导入副本删掉只是少占空间 —— 代价不同，所以由用户在弹窗里自己选（见 [_CacheScope]）。
Future<int> _clearImportedAssets(AppState state) async {
  final dataDir = _userDataDir();
  // 记下被删掉的字体名：如果当前正在用其中之一，就回退到系统默认字体，
  // 否则 fontFamily 会一直指向一个已经不存在的字体。
  final removedFonts = <String>{};
  var freed = 0;
  for (final sub in ['fonts', 'background']) {
    final dir = Directory('$dataDir$_s$sub');
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync().whereType<File>()) {
      if (sub == 'fonts') {
        removedFonts.add(f.path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), ''));
      }
      try {
        freed += f.lengthSync();
        f.deleteSync();
      } catch (_) {}
    }
  }
  state.updateConfig((c) {
    c.backgroundImage = '';
    if (removedFonts.contains(c.fontFamily)) c.fontFamily = AppConfig.defaultFontFamily;
    return c;
  });
  return freed;
}

/// 字节数 → 人类可读文本（B / KB / MB / GB，保留 1 位小数）。
/// 用于「清除缓存」后告知用户实际释放了多少空间。
String _humanSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

Future<void> _checkForUpdate(BuildContext ctx, AppStrings s) async {
  showToast(ctx, s.checking, type: ToastType.info);
  final result = await updater.checkForUpdate(preferLanzou: s.isZh);
  if (!ctx.mounted) return;
  if (result.error != null && !result.hasUpdate) {
    showToast(ctx, s.updateFailed, type: ToastType.error);
    return;
  }
  if (!result.hasUpdate) {
    showToast(ctx, '${s.alreadyLatest} (v${updater.currentVersion})', type: ToastType.success);
    return;
  }
  _showUpdateDialog(ctx, s, result);
}

void _showUpdateDialog(BuildContext ctx, AppStrings s, updater.UpdateResult result) {
  final scheme = Theme.of(ctx).colorScheme;
  // 移动端为 APK 分发：桌面那套「下载 exe + 替换重启」不适用，
  // 一律走「前往下载」（浏览器打开发布页/下载链接）。
  final allowAutoUpdate = !isMobilePlatform &&
      result.source == updater.UpdateSource.github &&
      result.downloadUrl != null;
  showDialog(
    context: ctx,
    builder: (dCtx) => AlertDialog(
      icon: Icon(Icons.system_update, color: scheme.primary, size: 32),
      title: Text(s.updateAvailable, style: TextStyle(color: scheme.onSurface)),
      content: SizedBox(
          // 窄屏（手机）下固定 420 宽会溢出：移动端撑满对话框宽度
          width: isMobilePlatform ? double.maxFinite : 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.isZh ? '新版本: v${result.remoteVersion}\n当前版本: v${updater.currentVersion}'
            : 'New: v${result.remoteVersion}\nCurrent: v${updater.currentVersion}', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        if (result.password != null && result.password!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.key, size: 14, color: scheme.primary),
            const SizedBox(width: 4),
            Text(s.isZh ? '提取密码: ' : 'Password: ', style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
            SelectableText(result.password!, style: TextStyle(fontSize: 13, color: scheme.onSurface, fontWeight: FontWeight.bold)),
          ]),
        ],
        const SizedBox(height: 12),
        Text(s.isZh ? '更新日志:' : 'Release Notes:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
        const SizedBox(height: 4),
        if (result.releaseNotes != null && result.releaseNotes!.isNotEmpty)
          ConstrainedBox(constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(child: Text(result.releaseNotes!, style: TextStyle(fontSize: 11, color: scheme.onSurface))))
        else
          Text(result.releaseNotesError
              ? (s.isZh ? '无法获取更新日志 (GitHub 连接失败)' : 'Failed to get release notes (GitHub connection failed)')
              : (s.isZh ? '暂无更新日志' : 'No release notes available'),
              style: TextStyle(fontSize: 11, color: scheme.outline, fontStyle: FontStyle.italic)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.aboutClose)),
        if (allowAutoUpdate)
          FilledButton(onPressed: () { Navigator.pop(dCtx); _downloadAndInstall(ctx, s, result.downloadUrl!, result.downloadSha256); },
              child: Text(s.isZh ? '自动更新' : 'Auto Update'))
        else
          FilledButton(onPressed: () {
            Navigator.pop(dCtx);
            openExternalUrl(result.downloadUrl ?? 'https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases/latest');
          }, child: Text(s.goDownload)),
      ],
    ),
  );
}

Future<void> _downloadAndInstall(BuildContext ctx, AppStrings s, String url, [String? expectedSha256]) async {
  final scheme = Theme.of(ctx).colorScheme;
  final progressNotifier = ValueNotifier<double>(0);
  final statusNotifier = ValueNotifier<String>(s.isZh ? '准备下载...' : 'Preparing...');
  var dialogOpen = true;
  showDialog(context: ctx, barrierDismissible: false,
    builder: (_) => PopScope(canPop: false, child: AlertDialog(
      title: Text(s.isZh ? '下载更新' : 'Downloading Update', style: TextStyle(color: scheme.onSurface)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<double>(valueListenable: progressNotifier,
            // 统一进度条：与全应用滑动条同一规格（圆角轨道 + 主题色）
            builder: (_, v, _) => AppProgressBar(value: v > 0 ? v : null)),
        const SizedBox(height: 8),
        ValueListenableBuilder<String>(valueListenable: statusNotifier,
            builder: (_, v, _) => Text(v, style: TextStyle(fontSize: 11, color: scheme.outline))),
      ]),
    )),
  ).whenComplete(() => dialogOpen = false);
  try {
    final filePath = await updater.downloadUpdate(url, onProgress: (received, total) {
      if (total > 0) {
        progressNotifier.value = received / total;
        statusNotifier.value = '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
      }
    }, expectedSha256: expectedSha256);
    if (!ctx.mounted) return;
    // 未提供校验文件时给出明确警示，避免用户误以为已做过完整性校验（H-4）
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      showToast(ctx, s.isZh
          ? '提示：发布方未提供 SHA-256，安装包未做完整性校验'
          : 'Note: publisher provided no SHA-256; package integrity was not verified',
          type: ToastType.warning);
    }
    if (dialogOpen) Navigator.pop(ctx);
    await updater.installAndRestart(filePath);
  } catch (e) {
    if (ctx.mounted) {
      if (dialogOpen) Navigator.pop(ctx);
      showToast(ctx, '${s.updateFailed}: $e', type: ToastType.error);
    }
  } finally {
    progressNotifier.dispose();
    statusNotifier.dispose();
  }
}

Future<void> _pickColor(BuildContext ctx, AppState state) async {
  final isZh = state.config.language == 'zh';
  final cp = _CP(
    initial: Color(state.config.themeColor),
    initial2: state.config.themeColor2 >= 0 ? Color(state.config.themeColor2) : null,
    isZh: isZh,
  );
  // 移动端：底部弹层（全宽、自滚动），避免固定 320px 弹窗在窄屏上挤压出下划线/裁切伪影
  final res = isMobilePlatform
      ? await showModalBottomSheet<_GradResult>(
          context: ctx,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SafeArea(top: false, child: cp),
        )
      : await showDialog<_GradResult>(context: ctx, builder: (_) => Center(
          child: SizedBox(width: 320, child: cp),
        ));
  if (res == null) return;
  state.updateConfig((c) => c..themeColor = res.c1..themeColor2 = res.c2 ?? -1);
}

void _showSponsor(BuildContext ctx, ColorScheme scheme, AppStrings s) {
  showDialog(context: ctx, builder: (dCtx) => AlertDialog(
    title: Text(s.aboutSponsor, style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w700, fontSize: 18)),
    content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(s.aboutThanks, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
      const SizedBox(height: 12),
      Text(s.aboutZoomHint, style: TextStyle(fontSize: 10, color: scheme.outline)),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Expanded(child: _qrImage(ctx, 'rele/wx.png', s.aboutWxTitle, scheme)),
        const SizedBox(width: 16),
        Expanded(child: _qrImage(ctx, 'rele/zfb.jpg', s.aboutZfbTitle, scheme)),
      ]),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.aboutClose))],
  ));
}

Widget _qrImage(BuildContext ctx, String asset, String label, ColorScheme scheme) => GestureDetector(
  onTap: () => _showFullImage(ctx, asset, scheme),
  child: Column(children: [
    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
    const SizedBox(height: 8),
    ClipRRect(borderRadius: BorderRadius.circular(8),
        // 缩略图固定高 160 逻辑像素，而 wx.png / zfb.jpg 是 1220x1563 / 1170x1755
        // 的原图 —— 不设 cacheHeight 会按原始分辨率解码（单张约 7~8MB RGBA，
        // 且 Image.asset 不会自动套 ResizeImage）。全屏查看走 _showFullImage，
        // 那条路径刻意不设 cap，以保留 InteractiveViewer 4x 缩放的清晰度。
        child: Image.asset(asset,
            height: 160,
            cacheHeight: (160 * MediaQuery.devicePixelRatioOf(ctx)).round(),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Container(height: 160, alignment: Alignment.center,
                child: Text('加载失败', style: TextStyle(color: scheme.outline))))),
  ]),
);

void _showFullImage(BuildContext ctx, String asset, ColorScheme scheme) {
  showDialog(context: ctx, builder: (dCtx) => Dialog(
    backgroundColor: Colors.transparent,
    child: GestureDetector(onTap: () => Navigator.pop(dCtx),
      child: InteractiveViewer(minScale: 0.5, maxScale: 4.0,
        child: ClipRRect(borderRadius: BorderRadius.circular(12),
            child: Image.asset(asset, fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(padding: const EdgeInsets.all(32),
                    child: Text('加载失败', style: TextStyle(color: scheme.outline)))))),
    ),
  ));
}

// ═══════════════════════════════════════════
// FFmpeg 检测卡片
// ═══════════════════════════════════════════

class _FfmpegCard extends StatefulWidget {
  final AppState state;
  const _FfmpegCard({required this.state});
  @override
  State<_FfmpegCard> createState() => _FfmpegCardState();
}

class _FfmpegCardState extends State<_FfmpegCard> {
  bool _checking = false;
  bool _found = false;
  String _version = '';
  String _path = '';

  @override
  void initState() { super.initState(); _syncState(); }

  @override
  void didUpdateWidget(_FfmpegCard old) {
    super.didUpdateWidget(old);
    if (!_checking) _syncState();
  }

  void _syncState() {
    _found = widget.state.envOk;
    _version = widget.state.ffmpegVersion;
    _path = widget.state.config.ffmpegPath;
  }

  Future<void> _detect() async {
    setState(() => _checking = true);
    await widget.state.recheckEnv();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _found = widget.state.envOk;
      _version = widget.state.ffmpegVersion;
      _path = widget.state.config.ffmpegPath;
    });
    widget.state.addLog(_found ? 'FFmpeg detected: $_version' : 'FFmpeg not found', category: _found ? 'ffmpeg' : 'error');
  }

  Future<void> _browseFfmpeg() async {
    final isZh = widget.state.config.language == 'zh';
    final r = await FilePicker.platform.pickFiles(
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? ['exe'] : null,
      dialogTitle: isZh ? '选择 ffmpeg' : 'Select ffmpeg',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final exePath = r.files.first.path;
    if (exePath == null) return;
    setState(() => _checking = true);
    try {
      final result = await Process.run(exePath, ['-version'], runInShell: false);
      if (result.exitCode == 0 && result.stdout.toString().contains('ffmpeg version')) {
        final versionLine = result.stdout.toString().split('\n').first;
        final dir = exePath.replaceAll(RegExp(r'[\\/][^\\/]+$'), '');
        final ffprobeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
        if (!mounted) return;
        setState(() { _found = true; _version = versionLine; _path = exePath; _checking = false; });
        widget.state.updateConfig((c) => c..ffmpegPath = exePath..ffprobePath = '$dir${Platform.pathSeparator}$ffprobeName');
        widget.state.backend.setPaths(ffmpeg: exePath, ffprobe: '$dir${Platform.pathSeparator}$ffprobeName');
        if (Platform.isWindows) await _addToPath(dir);
        widget.state.addLog('FFmpeg configured: $_version', category: 'ffmpeg');
        if (mounted) showToast(context, 'FFmpeg found at: $dir', type: ToastType.success);
      } else {
        if (!mounted) return;
        setState(() => _checking = false);
        showToast(context, isZh ? '所选文件不是有效的 ffmpeg' : 'Selected file is not a valid ffmpeg', type: ToastType.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      showToast(context, isZh ? '检测失败: $e' : 'Detection failed: $e', type: ToastType.error);
    }
  }

  Future<void> _addToPath(String dir) async {
    if (!Platform.isWindows) return;
    final isZh = widget.state.config.language == 'zh';
    try {
      final regResult = await Process.run('cmd', ['/c', 'echo %PATH%']);
      if (regResult.stdout.toString().contains(dir)) return;
      final regResult2 = await Process.run('reg', ['query', r'HKCU\Environment', '/v', 'Path']);
      var existingPath = '';
      if (regResult2.exitCode == 0) {
        for (final line in regResult2.stdout.toString().split('\n')) {
          if (line.contains('Path') && line.contains('REG_')) {
            existingPath = line.split('REG_').last.trim().replaceFirst(RegExp(r'^\w+\s+'), '');
            break;
          }
        }
      }
      existingPath = existingPath.trim();
      if (existingPath.contains(dir)) return;
      // 只有 reg 查询成功且现有 PATH 非空时才追加；否则跳过，避免覆盖用户 PATH
      if (regResult2.exitCode != 0 || existingPath.isEmpty) {
        if (mounted) showToast(context, isZh ? '读取 PATH 失败，已跳过添加到系统 PATH' : 'Failed to read PATH, skipped adding', type: ToastType.error);
        return;
      }
      final newPath = '$existingPath;$dir';
      // 原实现用 `setx`：它有 1024 字符硬上限会截断 PATH，且会把
      // REG_EXPAND_SZ（含 %SystemRoot% 等引用）强制展开成 REG_SZ，
      // 可能永久损坏用户 PATH（L-5）。改用 PowerShell 的
      // [Environment]::SetEnvironmentVariable(...,'User')，走注册表 API：
      // 无长度截断、保留原有值类型，且只影响当前用户。
      final escaped = newPath.replaceAll("'", "''");
      final ps = await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-Command',
        "[Environment]::SetEnvironmentVariable('Path','$escaped','User')",
      ]);
      if (ps.exitCode != 0) {
        throw Exception('设置用户 PATH 失败: ${ps.stderr}');
      }
    } catch (e) {
      if (mounted) showToast(context, isZh ? '添加到系统 PATH 失败: $e' : 'Failed to add to PATH: $e', type: ToastType.error);
    }
  }

  Future<void> _confirmDelete(bool isZh) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final s = Theme.of(ctx).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.delete_forever, color: s.error, size: 32),
          title: Text(isZh ? '删除 FFmpeg' : 'Delete FFmpeg'),
          content: Text(isZh ? '将删除程序目录下的 ffmpeg.exe 和 ffprobe.exe，确定？'
              : 'Delete ffmpeg.exe and ffprobe.exe from the app directory?', style: TextStyle(fontSize: 13, color: s.onSurface)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isZh ? '取消' : 'Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: s.error),
                child: Text(isZh ? '删除' : 'Delete')),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    FfmpegInstaller.uninstall();
    widget.state.updateConfig((c) => c..ffmpegPath = ''..ffprobePath = '');
    setState(() { _found = false; _version = ''; _path = ''; });
    widget.state.addLog('已删除程序目录下的 FFmpeg', category: 'info');
    if (mounted) showToast(context, isZh ? 'FFmpeg 已删除' : 'FFmpeg deleted', type: ToastType.info);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = widget.state.config;
    final s = AppStrings.of(cfg.language);
    final isZh = cfg.language == 'zh';

    // 移动端：FFmpeg 已内置在 APK 中（jniLibs），无需安装/选择/删除
    if (isMobilePlatform) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        Row(children: [
          Icon(Icons.check_circle, size: 16, color: _found ? scheme.sem.success : scheme.sem.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(
              _found ? s.ffmpegFound : (isZh ? '内置 FFmpeg 加载中…' : 'Bundled FFmpeg loading…'),
              style: TextStyle(fontSize: 13,
                  color: _found ? scheme.sem.success : scheme.sem.warning,
                  fontWeight: FontWeight.w600))),
        ]),
        if (_version.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Text(_version, style: TextStyle(fontSize: 10, color: scheme.outline),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (_path.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 6),
              child: Text(_path, style: TextStyle(fontSize: 9, color: scheme.outline.withAlpha(150)),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 14),
              label: Text(s.recheck, style: const TextStyle(fontSize: 11)), onPressed: _detect)),
        ]),
        const SizedBox(height: 4),
        Text(isZh ? '移动端已内置 FFmpeg 库，无需额外安装'
            : 'FFmpeg is bundled with the app on mobile — no installation needed',
            style: TextStyle(fontSize: 10, color: scheme.outline)),
      ]);
    }

    if (!_found && !_checking) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        Center(child: Column(children: [
          Icon(Icons.warning_amber, size: 32, color: scheme.sem.warning),
          const SizedBox(height: 8),
          Text(s.ffmpegNotFound, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.sem.warning)),
          const SizedBox(height: 12),
          FilledButton.icon(icon: const Icon(Icons.download, size: 18),
              label: Text(isZh ? '自动安装 FFmpeg' : 'Install FFmpeg', style: const TextStyle(fontSize: 13)),
              onPressed: () async { final ok = await FfmpegInstallDialog.show(context); if (ok == true) _detect(); }),
          const SizedBox(height: 8),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.tonalIcon(icon: const Icon(Icons.search, size: 16),
                label: Text(isZh ? '检测' : 'Detect', style: const TextStyle(fontSize: 11)), onPressed: _detect),
            const SizedBox(width: 8),
            TextButton.icon(icon: const Icon(Icons.folder_open, size: 14),
                label: Text(isZh ? '手动选择' : 'Manual', style: const TextStyle(fontSize: 11)), onPressed: _browseFfmpeg),
          ]),
        ])),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.center, children: _ffmpegLinks),
      ]);
    }

    if (_checking) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        const SizedBox(height: 12),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 8),
        Center(child: Text(isZh ? '正在检测...' : 'Detecting...', style: TextStyle(fontSize: 12, color: scheme.outline))),
      ]);
    }

    final isBundled = FfmpegInstaller.isInstalled &&
        _path.isNotEmpty && _path.startsWith(Directory(Platform.resolvedExecutable).parent.path);
    return _glass(context, widget.state, s.ffmpegSettings, [
      Row(children: [
        Icon(Icons.check_circle, size: 16, color: scheme.sem.success),
        const SizedBox(width: 8),
        Expanded(child: Text(s.ffmpegFound, style: TextStyle(fontSize: 13, color: scheme.sem.success, fontWeight: FontWeight.w600))),
      ]),
      if (_version.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text(_version, style: TextStyle(fontSize: 10, color: scheme.outline), maxLines: 2, overflow: TextOverflow.ellipsis)),
      if (_path.isNotEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Text(_path, style: TextStyle(fontSize: 9, color: scheme.outline.withAlpha(150)), maxLines: 2, overflow: TextOverflow.ellipsis)),
      Row(children: [
        Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 14),
            label: Text(s.recheck, style: const TextStyle(fontSize: 11)), onPressed: _detect)),
        if (isBundled) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(icon: Icon(Icons.delete_outline, size: 14, color: scheme.error),
              label: Text(isZh ? '删除' : 'Delete', style: TextStyle(fontSize: 11, color: scheme.error)),
              style: OutlinedButton.styleFrom(side: BorderSide(color: scheme.error.withAlpha(120))),
              onPressed: () => _confirmDelete(isZh)),
        ],
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 4, runSpacing: 4, children: _ffmpegLinks),
    ]);
  }

  static List<Widget> get _ffmpegLinks => [
    _link('ffmpeg.org', 'https://ffmpeg.org'),
    _link('gyan.dev', 'https://github.com/AnimMouse/ffmpeg-stable-autobuild'),
    _link('BtbN', 'https://github.com/BtbN/FFmpeg-Builds/releases'),
  ];
}

// ═══════════════════════════════════════════
// 取色器
// ═══════════════════════════════════════════

/// 渐变主题色选择结果：c1=起色，c2 为 null 表示纯色主题
class _GradResult {
  final int c1;
  final int? c2;
  _GradResult(this.c1, this.c2);
}

/// 主题渐变色预设（起色, 止色, 名称）
const _gradPresets = <(int, int, String)>[
  (0xFF5E6AD2, 0xFF8B5CF6, '紫罗兰'),
  (0xFF3B82F6, 0xFF06B6D4, '海洋'),
  (0xFF10B981, 0xFF84CC16, '翡翠'),
  (0xFFF59E0B, 0xFFEF4444, '熔岩'),
  (0xFFEC4899, 0xFFF97316, '日落'),
  (0xFF8B5CF6, 0xFFEC4899, '霓虹'),
  (0xFF64748B, 0xFF0EA5E9, '钢蓝'),
  (0xFF111827, 0xFF5E6AD2, '夜幕'),
];

class _CP extends StatefulWidget {
  final Color initial;
  final Color? initial2;
  final bool isZh;
  const _CP({required this.initial, required this.isZh, this.initial2});
  @override
  State<_CP> createState() => _CPState();
}

class _CPState extends State<_CP> {
  late double _h1, _s1, _v1;
  late double _h2, _s2, _v2;
  // null = 纯色主题；非 null = 渐变主题
  bool _gradEnabled;

  _CPState() : _gradEnabled = false;

  @override
  void initState() {
    super.initState();
    final h1 = HSVColor.fromColor(widget.initial);
    _h1 = h1.hue; _s1 = h1.saturation; _v1 = h1.value;
    if (widget.initial2 != null) {
      _gradEnabled = true;
      final h2 = HSVColor.fromColor(widget.initial2!);
      _h2 = h2.hue; _s2 = h2.saturation; _v2 = h2.value;
    } else {
      _gradEnabled = false;
      final h2 = HSVColor.fromColor(widget.initial);
      _h2 = h2.hue + 20; _s2 = h2.saturation; _v2 = h2.value;
    }
  }

  Color get c1 => HSVColor.fromAHSV(1, _h1, _s1, _v1).toColor();
  Color get c2 => HSVColor.fromAHSV(1, _h2, _s2, _v2).toColor();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    // 原先写死 Color(0xFF9AA0A6)：一个冷调灰，既不随主题（浅色/深色）变化，
    // 也和同页其他次要文字用的 scheme.outline 不是同一个灰 → 同一层级两种灰。
    final sectionHint = TextStyle(fontSize: 10, color: scheme.outline);
    // 液态玻璃：跟随全局玻璃配置（液态/模糊/无效果），主题着色跟随 glassFollowTheme
    return GlassPanel(
      radius: 18,
      blur: 14,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(Icons.palette_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(widget.isZh ? '主题颜色' : 'Theme Color',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Icon(Icons.close, size: 18, color: scheme.outline),
              ),
            ]),
            const SizedBox(height: 12),
            // 预览：纯色或渐变
            Container(height: 44, width: double.infinity, alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _gradEnabled ? null : c1,
                gradient: _gradEnabled
                    ? LinearGradient(colors: [c1, c2], begin: Alignment.topLeft, end: Alignment.bottomRight)
                    : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
              ),
              child: Text(_gradEnabled ? (widget.isZh ? '渐变' : 'Gradient') : (widget.isZh ? '纯色' : 'Solid'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
            const SizedBox(height: 12),
            // 是否使用渐变色（通俗开关）
            Row(children: [
              Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.isZh ? '使用渐变色' : 'Use gradient',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface))),
              Switch(
                value: _gradEnabled,
                onChanged: (v) => setState(() => _gradEnabled = v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ]),
            const SizedBox(height: 12),
            // 常用色板（单色 / 渐变通用）
            Text(widget.isZh ? '常用颜色' : 'Common colors', style: labelStyle),
            const SizedBox(height: 8),
            if (_gradEnabled)
              Wrap(spacing: 8, runSpacing: 8, children: _gradPresets.map((g) {
                final selected = g.$1 == c1.toARGB32() && g.$2 == c2.toARGB32();
                return GestureDetector(
                  onTap: () {
                    final h1 = HSVColor.fromColor(Color(g.$1));
                    final h2 = HSVColor.fromColor(Color(g.$2));
                    setState(() { _h1 = h1.hue; _s1 = h1.saturation; _v1 = h1.value; _h2 = h2.hue; _s2 = h2.saturation; _v2 = h2.value; _gradEnabled = true; });
                  },
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color(g.$1), Color(g.$2)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      shape: BoxShape.circle,
                      border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant.withAlpha(90), width: selected ? 3 : 1),
                    ),
                  ),
                );
              }).toList())
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final preset in const [
                  0xFF5E6AD2, 0xFF3B82F6, 0xFF06B6D4, 0xFF10B981, 0xFF84CC16,
                  0xFFF59E0B, 0xFFF97316, 0xFFEF4444, 0xFFEC4899, 0xFF8B5CF6,
                  0xFF64748B, 0xFF000000, 0xFFFFFFFF, 0xFFF8FAFC,
                ])
                  GestureDetector(
                    onTap: () {
                      final hsv = HSVColor.fromColor(Color(preset));
                      setState(() { _h1 = hsv.hue; _s1 = hsv.saturation; _v1 = hsv.value; });
                    },
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: Color(preset),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
                      ),
                      child: preset == c1.toARGB32() ? const Icon(Icons.check, size: 13, color: Colors.white) : null,
                    ),
                  ),
              ]),
            const SizedBox(height: 12),
            // 自定义微调
            Text(widget.isZh ? '自定义微调' : 'Fine-tune', style: labelStyle),
            Text(widget.isZh ? '用色相 / 饱和度 / 明度精确调整颜色' : 'Adjust hue / saturation / value precisely',
                style: sectionHint),
            const SizedBox(height: 4),
            _colorRow(c1, [
              _sl('H', _h1, 0, 360, (v) => setState(() => _h1 = v)),
              _sl('S', _s1, 0, 1, (v) => setState(() => _s1 = v)),
              _sl('V', _v1, 0, 1, (v) => setState(() => _v1 = v)),
            ]),
            if (_gradEnabled) ...[
              const SizedBox(height: 6),
              Text(widget.isZh ? '第二种颜色（渐变终点）' : 'Second color (end of gradient)', style: labelStyle),
              const SizedBox(height: 4),
              _colorRow(c2, [
                _sl('H', _h2, 0, 360, (v) => setState(() => _h2 = v)),
                _sl('S', _s2, 0, 1, (v) => setState(() => _s2 = v)),
                _sl('V', _v2, 0, 1, (v) => setState(() => _v2 = v)),
              ]),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text('#${_hex(c1)}${_gradEnabled ? ' → #${_hex(c2)}' : ''}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: scheme.onSurfaceVariant))),
              TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.isZh ? '取消' : 'Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context,
                    _GradResult(c1.toARGB32(), _gradEnabled ? c2.toARGB32() : null)),
                child: Text(widget.isZh ? '选择' : 'Select'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  String _hex(Color c) => c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  Widget _colorRow(Color swatch, List<Widget> sliders) {
    return Row(children: [
      Container(width: 22, height: 22, decoration: BoxDecoration(
        color: swatch, shape: BoxShape.circle, border: Border.all(color: Color(0x33000000)))), 
      const SizedBox(width: 8),
      Expanded(child: Column(children: sliders)),
    ]);
  }

  // 取色面板的 R/G/B 滑杆：同样走 AppSlider（胶囊 + 主题色填充 + 玻璃留空），
  // 不要改回裸 Slider —— 裸 Slider 没有玻璃底那一层。
  Widget _sl(String l, double v, double min, double max, ValueChanged<double> cb) => Row(children: [
    SizedBox(width: 12, child: Text(l, style: TextStyle(fontSize: 10))),
    Expanded(child: AppSlider(value: v, min: min, max: max, compact: true, onChanged: cb)),
  ]);
}

class _PathField extends StatefulWidget {
  final String value;
  final String label;
  final ColorScheme scheme;
  final ValueChanged<String> onChange;
  const _PathField({required this.value, required this.label, required this.scheme, required this.onChange});
  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_PathField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _ctrl,
    style: const TextStyle(fontSize: 12),
    decoration: InputDecoration(
      labelText: widget.label.isEmpty ? null : widget.label,
      isDense: true,
      border: const OutlineInputBorder(),
      labelStyle: TextStyle(fontSize: 11, color: widget.scheme.outline),
    ),
    onChanged: widget.onChange,
  );
}

/// MCP 卡里的「标签 + 输入框 + 动作」一行。
///
/// 改造前这一行是 `Row([Text('端口: '), SizedBox(width: 80, child: 输入框),
/// SizedBox(height: 30, child: 按钮)])`，三个问题：
/// 1. 标签宽度跟着文案变 —— 中英文切换、端口/监听地址两行之间标签宽度不等，
///    下面的输入框左边缘就错开；
/// 2. 输入框宽度写死 80 / 130，与右侧按钮的比例随窗口宽度漂移；
/// 3. 按钮被 `SizedBox(height: 30)` 压过，而主题 `filledButtonTheme` 带 `vertical: 12`
///    内边距，30 高会把内容顶出/裁掉，与同一张卡里其它控件高度也对不上。
///
/// 现在：标签固定 [labelW]、动作固定 [actionW]、输入框 [Expanded] 吃掉剩余宽度，
/// 高度一律由 [AppControlSize] 档位决定（不压 SizedBox）。[note] 说明文字独立成行
/// 并对齐到输入框左边缘 —— 塞在 Row 里会被挤成三四行、把行高顶起来。
class _McpFieldRow extends StatelessWidget {
  /// 标签列固定宽度：够放「监听地址:」/「Bind host:」，中英文切换不跳动。
  /// 与移动端 AI 设置页共用 [AppControlSize.labelW]，两端比例一致。
  static const double labelW = AppControlSize.labelW;

  /// 动作按钮列固定宽度：够放「应用」/「Apply」，语言切换不跳动。
  /// 与移动端 AI 设置页共用 [AppControlSize.actionW]，两端比例一致。
  static const double actionW = AppControlSize.actionW;

  final Widget label;
  final Widget field;
  final Widget? action;
  final Widget? note;

  const _McpFieldRow({required this.label, required this.field, this.action, this.note});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: labelW, child: label),
            Expanded(child: field),
            if (action != null) ...[
              const SizedBox(width: 8),
              SizedBox(width: actionW, child: action),
            ],
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: labelW),
            child: note,
          ),
      ],
    );
  }
}

class _McpTextField extends StatefulWidget {
  final String value;
  final String label;
  final String? hint;
  final ColorScheme scheme;
  final bool obscure;
  final int minLines;
  final int maxLines;
  final ValueChanged<String> onChange;

  /// 非空时按该档位对齐控件高度与水平内边距（把主题 `inputDecorationTheme`
  /// 的 `contentPadding: v12` 压回档位高度）；为空则沿用主题默认外观。
  final AppControlSize? size;

  const _McpTextField({
    required this.value,
    required this.label,
    required this.scheme,
    this.hint,
    this.obscure = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.size,
    required this.onChange,
  });
  @override
  State<_McpTextField> createState() => _McpTextFieldState();
}

class _McpTextFieldState extends State<_McpTextField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);
  bool _hidden = true;

  @override
  void didUpdateWidget(_McpTextField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) _ctrl.text = widget.value;
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final obscuring = widget.obscure && _hidden;
    final Widget field = TextField(
      controller: _ctrl,
      obscureText: obscuring,
      minLines: obscuring ? 1 : widget.minLines,
      maxLines: obscuring ? 1 : widget.maxLines,
      style: TextStyle(fontSize: 13, color: widget.scheme.onSurface),
      decoration: (widget.size == null ? const InputDecoration() : widget.size!.denseInput())
          .copyWith(
        labelText: widget.label.isEmpty ? null : widget.label,
        hintText: widget.hint,
        hintStyle: widget.hint == null ? null : TextStyle(fontSize: 11, color: widget.scheme.outline),
        isDense: true,
        alignLabelWithHint: widget.maxLines > 1,
        labelStyle: TextStyle(fontSize: 11, color: widget.scheme.outline),
        suffixIconConstraints: widget.size == null ? null : AppControlSize.iconSlot,
        suffixIcon: widget.obscure ? IconButton(
          icon: Icon(_hidden ? Icons.visibility_off : Icons.visibility, size: 16, color: widget.scheme.outline),
          onPressed: () => setState(() => _hidden = !_hidden),
          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        ) : null,
      ),
      onChanged: widget.onChange,
    );
    // 钉死到档位高度：不给死高度时，带「眼睛」后缀图标的字段会被 InputDecorator
    // 默认的 48×48 图标约束顶高（桌面端折算后 40），比同一行不带后缀图标的字段高一截
    return widget.size == null ? field : widget.size!.fieldBox(field);
  }
}

class _ProfileTextField extends StatefulWidget {
  final String value;
  final TextInputType? keyboardType;
  final ValueChanged<String> onChange;
  const _ProfileTextField({required this.value, this.keyboardType, required this.onChange});
  @override
  State<_ProfileTextField> createState() => _ProfileTextFieldState();
}

class _ProfileTextFieldState extends State<_ProfileTextField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_ProfileTextField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) _ctrl.text = widget.value;
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _ctrl,
    keyboardType: widget.keyboardType,
    style: const TextStyle(fontSize: 12),
    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
    onChanged: widget.onChange,
  );
}
