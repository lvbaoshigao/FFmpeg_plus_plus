import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

// 背景预览缩略图复用主壳那条**唯一**的壁纸解码入口：同参数（屏幕逻辑尺寸 +
// DPR）构造出的 ResizeImage 与主壳的 `==` 相等 → 命中同一个 ImageCache 条目，
// 不额外解码一份，也不会出现「缩略图与真实壁纸构图不一致」。
// settings_page ↔ app.dart 互为循环引用，Dart 允许（wallpaper_background.dart
// 与 app.dart 早就是同样的情况）。
import '../app.dart' show wallpaperImageProvider;
import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
// ColorOS 流体云进度开关的能力判定（Android 专用，见 ColorOsFluidCloud.kt）
import '../services/android_platform.dart';
import '../services/diagnostic_trace.dart';
import '../services/directory_picker.dart';
import '../services/ffmpeg_installer.dart';
import '../services/progress_feature_availability.dart';
// 高刷新率开关的即时生效（Android 专用，见 services/refresh_rate.dart）
import '../services/refresh_rate.dart';
import '../services/shell_open.dart';
import '../services/update_service.dart' as updater;
import '../services/wallpaper_image_optimizer.dart';
// 控件高度档位令牌：MCP 卡的输入框/按钮、AI 配置详情页的按钮统一按档位取高度，
// 不再用 `SizedBox(height: 30)` 压高度（会与主题 v12 内边距打架）
import '../theme/app_semantic_colors.dart';
import '../theme/app_strings.dart';
import '../theme/app_text_scale.dart';
import '../theme/settings_typography.dart';
import '../widgets/app_alert_dialog.dart';
import '../widgets/app_card.dart';
import '../widgets/app_slider.dart';
import '../widgets/font_picker.dart';
import '../widgets/adaptive_top_bar.dart';
import '../widgets/glass_panel.dart';
import '../widgets/install_dialog.dart';
import '../widgets/masonry_grid.dart';
import '../widgets/mobile_glass_pill.dart';
// 生效的菜单栏位置：设置页自身也在主 Tab 的 PageView 里，底部让出的高度
// 要跟着菜单栏位置走（底部胶囊 96 / 竖排导轨 20）
import '../widgets/mobile_nav_scope.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/option_menu_bar.dart';
import '../widgets/selection_highlight.dart';
import '../widgets/theme_color_picker.dart';
import '../widgets/toast.dart';
import '../widgets/wallpaper_background.dart';
// Linux CSD（自绘窗口修饰）：二级 / 三级全屏路由页统一套 WindowChrome，
// 否则路由盖住主窗口标题栏后既不能拖动也没有窗口按钮。
import '../widgets/window_chrome.dart';
import 'ads_page.dart';
import 'ai_settings_mobile.dart';
import 'command_page.dart';
import 'credits_page.dart';
import 'keybinding_page.dart';
import 'log_page.dart';
import 'settings_search.dart';

final _s = Platform.pathSeparator;
const _maxWallpaperSourceBytes = 32 * 1024 * 1024;

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
    final base =
        Platform.environment['XDG_DATA_HOME'] ??
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
Future<String?> _copyBackgroundOptimized(
  String srcPath,
  int maxW,
  int maxH,
) async {
  try {
    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) return null;
    if (await srcFile.length() > _maxWallpaperSourceBytes) {
      return await _copyToAppDir(srcPath, 'background');
    }
    final bytes = await srcFile.readAsBytes();

    final optimized = await WallpaperImageOptimizer.optimize(
      bytes,
      maxWidth: maxW,
      maxHeight: maxH,
    );
    if (optimized == null || identical(optimized, bytes)) {
      return await _copyToAppDir(srcPath, 'background');
    }
    final baseName = srcFile.uri.pathSegments.last.replaceAll(
      RegExp(r'\.[^.]+$'),
      '',
    );
    return await _saveRawBackground(optimized, '${baseName}_opt.png');
  } on WallpaperImageTooLargeToResizeException {
    rethrow;
  } catch (_) {
    // 解码/缩放失败（如超大图内存不足）：回退普通复制
    return await _copyToAppDir(srcPath, 'background');
  }
}

/// 从内存字节保存背景图（Android 11+ content:// URI 场景：picker 返回 bytes 而非路径）。
/// 解码后用 [maxW]/[maxH] 限制最大尺寸，重编码为 PNG 存入应用文档目录。
Future<String?> _saveBackgroundBytes(
  Uint8List bytes,
  String fileName,
  int maxW,
  int maxH,
) async {
  final optimized = await WallpaperImageOptimizer.optimize(
    bytes,
    maxWidth: maxW,
    maxHeight: maxH,
  );
  if (optimized == null || identical(optimized, bytes)) {
    return await _saveRawBackground(bytes, fileName);
  }
  final baseName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  return await _saveRawBackground(optimized, '${baseName}_opt.png');
}

Future<String?> _saveBackgroundStream(
  Stream<List<int>> source,
  String fileName,
) async {
  File? destination;
  IOSink? sink;
  try {
    final targetDir = Directory('${_userDataDir()}$_s${'background'}');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[^\\w.\\-]'), '_');
    final boundedName = safeName.length > 100
        ? safeName.substring(safeName.length - 100)
        : safeName;
    destination = File(
      '${targetDir.path}$_s${DateTime.now().microsecondsSinceEpoch}_$boundedName',
    );
    sink = destination.openWrite();
    await sink.addStream(source);
    await sink.flush();
    await sink.close();
    return destination.path;
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      await destination?.delete();
    } catch (_) {}
    return null;
  }
}

/// 把背景字节直接写入应用文档目录 background/ 下，返回绝对路径（失败返回 null）
Future<String?> _saveRawBackground(Uint8List bytes, String name) async {
  try {
    final targetDir = Directory('${_userDataDir()}$_s${'background'}');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final safeName = WallpaperImageOptimizer.contentAddressedFileName(
      name,
      bytes,
    );
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

TextSpan _searchLabelSpan(
  String text,
  SettingsSearch search,
  TextStyle style,
  Color highlightColor,
) {
  final ranges = search.highlights(text);
  if (ranges.isEmpty) {
    return TextSpan(text: text, style: style);
  }
  final markedStyle = style.copyWith(
    color: highlightColor,
    fontWeight: FontWeight.w700,
    backgroundColor: highlightColor.withAlpha(30),
  );
  final spans = <TextSpan>[];
  var start = 0;
  for (final range in ranges) {
    if (range.start > start) {
      spans.add(TextSpan(text: text.substring(start, range.start)));
    }
    spans.add(
      TextSpan(
        text: text.substring(range.start, range.end),
        style: markedStyle,
      ),
    );
    start = range.end;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start)));
  }
  return TextSpan(style: style, children: spans);
}

Text _highlightedSearchText(
  String text,
  SettingsSearch search,
  TextStyle style,
  Color highlightColor, {
  Key? key,
}) => Text.rich(
  _searchLabelSpan(text, search, style, highlightColor),
  key: key,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
);

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
}

class _SectionDef {
  final String id;
  final String Function(AppStrings) title;
  final IconData icon;
  final List<_CardDef> cards;
  const _SectionDef({
    required this.id,
    required this.title,
    required this.icon,
    required this.cards,
  });
}

// ═══════════════════════════════════════════
// 设置页
// ═══════════════════════════════════════════

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static void showUpdateDialogStatic(
    BuildContext ctx,
    AppStrings s,
    updater.UpdateResult result,
  ) {
    _showUpdateDialog(ctx, s, result);
  }

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  String _parsedQuery = '';
  SettingsSearch _search = SettingsSearch('');

  SettingsSearch get _searchQuery {
    if (_parsedQuery != _query) {
      _parsedQuery = _query;
      _search = SettingsSearch(_query);
    }
    return _search;
  }

  List<(_SectionDef, List<_CardDef>)> _searchGroups(
    SettingsSearch query,
    AppStrings strings,
  ) {
    if (query.isEmpty) {
      return const [];
    }
    final alternate = strings.isZh ? AppStrings.en : AppStrings.zh;
    final groups = <(_SectionDef, List<_CardDef>, int)>[];
    for (final section in _sections) {
      final hits = <(_CardDef, int)>[];
      for (final card in section.cards) {
        final score = query.score(
          title: card.title(strings),
          alternateTitle: card.title(alternate),
          keywords: card.keywords,
          section: section.title(strings),
          alternateSection: section.title(alternate),
        );
        if (score > 0) {
          hits.add((card, score));
        }
      }
      if (hits.isEmpty) {
        continue;
      }
      hits.sort((a, b) {
        final byScore = b.$2.compareTo(a.$2);
        return byScore != 0
            ? byScore
            : section.cards
                  .indexOf(a.$1)
                  .compareTo(section.cards.indexOf(b.$1));
      });
      groups.add((section, [for (final hit in hits) hit.$1], hits.first.$2));
    }
    groups.sort((a, b) {
      final byScore = b.$3.compareTo(a.$3);
      return byScore != 0
          ? byScore
          : _sections.indexOf(a.$1).compareTo(_sections.indexOf(b.$1));
    });
    return [for (final (section, cards, _) in groups) (section, cards)];
  }

  List<String> _matchingLabels(
    _SectionDef section,
    _CardDef card,
    AppStrings strings,
  ) {
    final alternate = strings.isZh ? AppStrings.en : AppStrings.zh;
    return _searchQuery.evidence(
      title: card.title(strings),
      section: section.title(strings),
      candidates: [
        card.title(alternate),
        ...card.keywords,
        section.title(alternate),
      ],
    );
  }

  /// 移动端搜索是否展开（内联展开在顶栏下方，而非弹出对话框）。
  bool _searchExpanded = false;

  /// 桌面端左侧主菜单当前选中的分区 id。
  String _selectedSection = 'general';
  bool _sectionNavCollapsed = false;

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
      Scrollable.ensureVisible(
        ctx,
        duration: MediaQuery.disableAnimationsOf(ctx)
            ? Duration.zero
            : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.15,
      );
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
    _SectionDef sec,
    _CardDef c,
    ColorScheme scheme,
    AppStrings s,
  ) {
    final sectionTitle = sec.title(s);
    final cardTitle = c.title(s);
    final matchingKeywords = _matchingLabels(sec, c, s);
    final search = _searchQuery;
    final titleStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
      child: Row(
        children: [
          Icon(sec.icon, size: 13, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: _highlightedSearchText(
                        sectionTitle,
                        search,
                        titleStyle,
                        scheme.primary,
                      ),
                    ),
                    Text(' · ', style: titleStyle),
                    Flexible(
                      child: _highlightedSearchText(
                        cardTitle,
                        search,
                        titleStyle,
                        scheme.primary,
                        key: ValueKey('settings-search-result-${c.id}'),
                      ),
                    ),
                  ],
                ),
                if (matchingKeywords.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                        children: [
                          for (var i = 0; i < matchingKeywords.length; i++) ...[
                            if (i > 0) const TextSpan(text: ' · '),
                            _searchLabelSpan(
                              matchingKeywords[i],
                              search,
                              const TextStyle(),
                              scheme.primary,
                            ),
                          ],
                        ],
                      ),
                      key: ValueKey('settings-search-evidence-${c.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => _jumpToCard(c.id),
            icon: const Icon(Icons.my_location, size: 13),
            label: Text(
              s.isZh ? '定位' : 'Locate',
              style: const TextStyle(fontSize: 11),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              minimumSize: const Size(0, 26),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _highlightWrap(String cardId, Widget child) {
    final on = _highlightCardId == cardId;
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
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
    if (_selectedSection == id && _query.isEmpty) return;
    _searchCtrl.clear();
    _searchFocus.unfocus();
    setState(() {
      _query = '';
      _selectedSection = id;
    });
  }

  Duration get _sectionTransitionDuration =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  // The InkWells and selection share this font-based extent, including at
  // large text scales. Search badges and collapse never change row geometry.
  double get _sectionNavRowHeight =>
      math.max(40, MediaQuery.textScalerOf(context).scale(12.5) * 1.4 + 18);

  // Desktop, mobile and search share this order: general preferences first,
  // feature-specific options next, then diagnostics, maintenance and About.
  // Within each section, show common controls before overrides and fine tuning.
  static final List<_SectionDef> _sections = [
    _SectionDef(
      id: 'general',
      title: (s) => s.secGeneral,
      icon: Icons.language_outlined,
      cards: [
        _CardDef(
          id: 'language',
          title: (s) => s.language,
          icon: Icons.translate,
          keywords: [
            '语言',
            '界面',
            '中文',
            'language',
            'english',
            'chinese',
            'interface',
            'locale',
            'i18n',
          ],
          build: _buildLanguage,
        ),
      ],
    ),
    _SectionDef(
      id: 'appearance',
      title: (s) => s.secAppearance,
      icon: Icons.palette_outlined,
      cards: [
        _CardDef(
          id: 'theme',
          title: (s) => s.cardTheme,
          icon: Icons.brightness_6_outlined,
          keywords: [
            '深色',
            '暗色',
            '浅色',
            'dark',
            'light',
            'mode',
            '模式',
            '主题色',
            '强调色',
            '颜色',
            'accent',
            'color',
            'theme',
            '动态取色',
            'monet',
            'dynamic',
            '渐变',
            'gradient',
          ],
          build: _buildTheme,
        ),
        _CardDef(
          id: 'background',
          title: (s) => s.isZh ? '背景' : 'Background',
          icon: Icons.wallpaper_outlined,
          keywords: [
            '背景',
            '壁纸',
            'background',
            'wallpaper',
            '图片',
            'image',
            '不透明度',
            'opacity',
            '透明',
            'alpha',
          ],
          build: _buildBackgroundCard,
        ),
        _CardDef(
          id: 'font',
          title: (s) => s.font,
          icon: Icons.text_fields,
          keywords: [
            '字体',
            '字号',
            '字重',
            'font',
            'size',
            'weight',
            'typeface',
            '导入',
            'import',
            '大小',
          ],
          build: _buildFont,
        ),
        _CardDef(
          id: 'surfaceStyle',
          title: (s) => s.isZh ? '界面材质与动效' : 'Surfaces & effects',
          icon: Icons.style_outlined,
          keywords: [
            '样式',
            'style',
            '预设',
            'preset',
            '材质',
            'material',
            '表面',
            'surface',
            '卡片',
            'card',
            '弹窗',
            'popup',
            '面板',
            'panel',
            '下拉菜单',
            'dropdown',
            '液态玻璃',
            'liquid',
            '毛玻璃',
            'frosted',
            '玻璃细节',
            'glass details',
            '模糊度',
            'blur',
            '通透度',
            'clarity',
            '高光',
            'highlight',
            '光斑',
            '边缘光',
            'edge light',
            '灰色',
            'gray',
            '边框',
            '描边',
            'border',
            'outline',
            '跟随主题色',
            'theme tint',
            '彗星拖尾',
            '粒子',
            '动效',
            '动画',
            '关闭所有动画效果',
            '关闭动画',
            'Disable all animations',
            'animation',
            'motion',
            'reduce motion',
            '特效',
            'particle',
            'comet',
            'effects',
          ],
          build: _buildSurfaceStyleCard,
        ),
        _CardDef(
          id: 'navigationStyle',
          title: (s) => s.isZh ? '导航与选中样式' : 'Navigation & selection',
          icon: Icons.view_sidebar_outlined,
          keywords: [
            '菜单样式',
            'menu style',
            '导航',
            'navigation',
            '侧边栏',
            'sidebar',
            '底部',
            'bottom',
            '顶栏',
            'top bar',
            '药丸',
            'pill',
            '位置',
            'placement',
            '自动收起',
            'auto-hide',
            '选中高亮',
            '选中指示器',
            '选中遮罩',
            '选中框',
            '导航遮罩',
            'selection mask',
            'selection indicator',
            'selection highlight',
            'theme accent',
            'liquid glass',
            'frosted glass',
            'outline',
          ],
          build: _buildNavigationAppearance,
        ),
        _CardDef(
          id: 'nodeEditorStyle',
          title: (s) => s.nodeEditorStyleLabel,
          icon: Icons.account_tree_outlined,
          keywords: [
            '节点编辑器', '画布', 'canvas', '背景', 'grid',
            '逻辑门', 'gate', 'ansi', 'iec', 'ieee', '符号', 'symbol',
            // 界面尺寸（药丸大小）也在这张卡里，补上对应搜索词
            '药丸', 'pill', '大小', 'size', '尺寸', '放大镜', 'zoom',
            '界面', 'ui', '菜单栏', 'toolbar', '缩放', 'scale',
            // 三级页（编辑模式 / 自动保存）的搜索词也要挂在这张卡上，
            // 否则移动端在设置里搜「自动保存」找不到东西。
            '编辑模式', '快速模式', 'edit', 'mode', 'classic', '蓝图', 'blueprint',
            '自动保存', '草稿', '保存间隔', 'autosave', 'draft', 'save',
            '横屏', 'landscape', '元素布局', '节点布局', 'element layout',
            'traditional', 'list',
          ],
          build: _buildNodeEditorStyleCard,
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
            keywords: [
              'ffmpeg',
              'ffprobe',
              '编码',
              'codec',
              '安装',
              'install',
              '检测',
              'detect',
              '路径',
              'path',
              '下载',
              'download',
            ],
            build: (ctx, state) => _FfmpegCard(state: state),
          ),
        _CardDef(
          id: 'output',
          title: (s) => s.output,
          icon: Icons.folder_outlined,
          keywords: [
            '输出',
            '目录',
            '文件夹',
            'output',
            'directory',
            'folder',
            '中间',
            'intermediate',
            '临时',
            'temp',
            'path',
            '路径',
          ],
          build: _buildOutput,
        ),
        _CardDef(
          id: 'tasks',
          title: (s) => s.cardTasks,
          icon: Icons.playlist_play,
          keywords: [
            '任务',
            '并发',
            '同时',
            '线程',
            'task',
            'concurrent',
            'parallel',
            'thread',
            '解析',
            'probe',
            '通知',
            'notification',
            '队列',
            'queue',
          ],
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
            keywords: [
              '编辑',
              '编辑器',
              '节点',
              '画布',
              '蓝图',
              'editor',
              'node',
              'canvas',
              'blueprint',
              'classic',
              'mode',
              '模式',
            ],
            build: _buildEditorMode,
          ),
          _CardDef(
            id: 'shortcuts',
            title: (s) => s.cardShortcuts,
            icon: Icons.keyboard_outlined,
            keywords: [
              '快捷键',
              '键位',
              '按键',
              '热键',
              'shortcut',
              'keybinding',
              'keyboard',
              'hotkey',
              'key',
            ],
            build: _buildShortcuts,
          ),
          _CardDef(
            id: 'autosave',
            title: (s) => s.cardAutosave,
            icon: Icons.save_outlined,
            keywords: [
              '自动保存',
              '草稿',
              '恢复',
              'autosave',
              'draft',
              'auto',
              'save',
              '恢复',
            ],
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
            keywords: [
              '命令',
              'ffmpeg',
              'command',
              'terminal',
              '终端',
              '执行',
              'run',
              '模板',
              'template',
            ],
            build: _buildMobileCommandEntry,
          ),
          _CardDef(
            id: 'logs',
            title: (s) => s.qLogs,
            icon: Icons.receipt_long_outlined,
            keywords: [
              '日志',
              'log',
              'logs',
              '输出',
              'output',
              '进度',
              'progress',
              '调试',
              'debug',
            ],
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
          keywords: [
            'ai',
            'mcp',
            '模型',
            'model',
            'api',
            'key',
            'token',
            'openai',
            'anthropic',
            'claude',
            'gpt',
            '提示词',
            'prompt',
            '权限',
            'permission',
            '助手',
            'assistant',
            '端口',
            'port',
            '服务',
            '提供商',
            'provider',
            'deepseek',
            'ollama',
          ],
          // PC 与移动端复用同一套 AI / MCP 设置与提供商详情页面。
          build: aiSettingsContent,
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
            keywords: [
              '返回',
              '手势',
              '预测',
              '侧滑',
              'back',
              'gesture',
              'predictive',
              'swipe',
              '返回动画',
              '系统',
              'system',
            ],
            build: _buildPredictiveBack,
          ),
        // 显示（仅移动端）：高刷新率（90 / 120 / 144Hz）
        if (isMobilePlatform)
          _CardDef(
            id: 'display',
            title: (s) => s.displayLabel,
            icon: Icons.screenshot_monitor_outlined,
            keywords: [
              '显示',
              '刷新率',
              '高刷',
              '高刷新率',
              '帧率',
              '流畅',
              '顺滑',
              'display',
              'refresh',
              'rate',
              'hz',
              'high',
              'smooth',
              'fps',
              '120',
              '90',
              '144',
              '60',
              '屏幕',
              'screen',
            ],
            build: _buildDisplay,
          ),
        _CardDef(
          id: 'preload',
          title: (s) => s.isZh ? '预加载' : 'Preload',
          icon: Icons.shutter_speed_outlined,
          keywords: [
            '预加载',
            '预载',
            'preload',
            '启动',
            'startup',
            'launch',
            '性能',
            'performance',
            'CPU',
            '内存',
            'memory',
            '绘制',
            '渲染',
            'render',
            '加载',
            'load',
          ],
          build: _buildPreload,
        ),
        _CardDef(
          id: 'debug',
          title: (s) => s.dDebug,
          icon: Icons.bug_report_outlined,
          keywords: [
            '调试',
            '日志',
            '诊断',
            'debug',
            'log',
            'logs',
            '非常详细的日志',
            '详细日志',
            '探针',
            'trace',
            'very verbose logs',
            'verbose',
            'diagnostic',
            '保存',
            'save',
          ],
          build: _buildDebug,
        ),
        _CardDef(
          id: 'nodeUsage',
          title: (s) => s.isZh ? '节点使用频次' : 'Node usage frequency',
          icon: Icons.bar_chart_outlined,
          keywords: [
            '节点使用频次',
            '节点使用次数',
            '清除节点使用频次',
            '重置节点使用次数',
            '清空',
            '重置',
            '频次重置',
            '使用统计',
            '排序',
            'node',
            'usage',
            'frequency',
            'count',
            'statistics',
            'reset',
            'clear',
            'ranking',
          ],
          build: (context, _) => const NodeUsageSettingsCard(),
        ),
        _CardDef(
          id: 'cache',
          title: (s) => s.cardCache,
          icon: Icons.cleaning_services_outlined,
          keywords: [
            '缓存',
            '清除',
            '清理',
            '删除',
            'cache',
            'clear',
            'clean',
            'cleanup',
            'purge',
            'reset',
          ],
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
          keywords: [
            '关于',
            '版本',
            '赞助',
            '捐赠',
            '许可',
            'about',
            'version',
            'sponsor',
            'donate',
            'license',
            'github',
            'blog',
            '作者',
            'author',
            '更新',
            '升级',
            'update',
            'upgrade',
            '检查',
            'check',
            '自动',
          ],
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
        state.config.selectionIndicatorStyle,
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
        state.config.mobileTheme,
        // 底部动作按钮所在侧（仅移动端）：受控 _optionRow 直读 config，
        // 漏在签名外会「选了左侧但页面不重建、下拉仍显示旧值」
        // （与 mobileNavPlacement / 字重改不了同一条根因）。
        state.config.mobileBottomActionSide,
        // 下拉菜单外观：同样是被受控 _optionRow 直读的字段。漏在签名外时，
        // 选完「液态玻璃 / 毛玻璃 / 高光」配置写进去了但设置页不重建，下拉
        // 触发框仍显示旧选项（用户反馈「选择主题时框框不会选中这个主题，
        // 仅仅局限于下拉控制栏的主题切换」），而其它控件因为字段都在签名里
        // 所以表现正常。
        state.config.dropdownAppearance,
        // 滑动自动收起底部菜单栏：受控 SwitchListTile 直读 config，
        // 漏在签名外会「点了没反应」（与 mobileNavPlacement 同根因）。
        state.config.navAutoHide,
        state.config.borderEnabled,
        state.config.borderWidth,
        state.config.borderColor,
        state.config.canvasBg,
        state.config.gateStd,
        // 小地图开关：同样是受控 SwitchListTile 直读 config，漏在签名外
        // 会「点了没反应」（与 noPreload / mcpEnabled 同根因）
        state.config.nodeMiniMap,
        state.config.nodeSnap,
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
        state.config.fluidCloudProgress,
        state.config.islandProgress,
        state.config.highRefreshRate,
        state.config.noPreload,
        state.config.debugMode,
        state.config.veryVerboseLogs,
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
        final query = _searchQuery;
        final searching = !query.isEmpty;
        final hitsBySection = _searchGroups(query, s);
        if (isMobilePlatform) {
          // ═══════════════════════════════════════
          // 移动端独立设置界面
          // ═══════════════════════════════════════
          final visible = searching
              ? hitsBySection
              : [for (final section in _sections) (section, section.cards)];

          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                // 全屏可滚动的设置列表（顶部留出药丸空间）
                // 不再包 RepaintBoundary：之前的 RepaintBoundary 把 ListView 内容缓存成独立层，
                // 导致 OCLiquidGlassGroup 的 _onScroll→markNeedsPaint 在该缓存层下被吞掉，
                // shader 的场景坐标永远停在旧位置 → 玻璃在滚动后消失。
                // 各玻璃卡片内部已有 OCLiquidGlassGroup→RepaintBoundary→OCLiquidGlass 的
                // 独立层，隔绝了无关重绘，不再需要外层 RepaintBoundary。
                if (visible.isEmpty && searching)
                  Padding(
                    padding: EdgeInsets.only(
                      top: MobileUi.pageTopPadding(context),
                      bottom: MediaQuery.viewInsetsOf(context).bottom > 0
                          ? 0
                          : MobileUi.navClearanceFor(
                              MobileNavPlacementScope.of(context),
                              context: context,
                            ),
                    ),
                    child: _emptyState(scheme, s),
                  )
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
                        MobileNavPlacementScope.of(context),
                        context: context,
                      ),
                    ),
                    children: [
                      for (final (sec, cards) in visible)
                        _buildMobileSection(
                          sec,
                          cards,
                          context,
                          state,
                          scheme,
                          s,
                          query: query,
                        ),
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
              ],
            ),
          );
        }

        // ═══════════════════════════════════════
        // 桌面端设置界面：左侧主菜单（分区导航）+ 右侧子选项面板
        // ═══════════════════════════════════════
        // 选中分区兜底（分区增删后不悬空）
        if (_sections.indexWhere((sec) => sec.id == _selectedSection) < 0) {
          _selectedSection = _sections.first.id;
        }
        final selectedSec = _sections.firstWhere(
          (sec) => sec.id == _selectedSection,
        );

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            children: [
              AdaptiveTopBar(
                expandedBuilder: (_) => GlassTopBar(
                  title: Text(s.settingsTitle),
                  center: _searchField(scheme, s),
                ),
                compactBuilder: (_) => _buildMobileTopBar(s, scheme),
              ),
              Expanded(
                // Keep the detail subtree in the same slot when resizing.
                child: Flex(
                  direction: MediaQuery.sizeOf(context).width < 700
                      ? Axis.vertical
                      : Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (MediaQuery.sizeOf(context).width < 700)
                      _buildCompactSectionNav(
                        hitsBySection,
                        searching,
                        scheme,
                        state,
                      )
                    else
                      _buildSectionNav(hitsBySection, searching, scheme, state),
                    Expanded(
                      // Animate only the live pane; never retain an outgoing
                      // glass surface or a second set of card GlobalKeys.
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey(
                          'settings_detail_${searching ? 'search' : selectedSec.id}',
                        ),
                        tween: Tween(
                          begin: MediaQuery.disableAnimationsOf(context)
                              ? 1
                              : 0,
                          end: 1,
                        ),
                        duration: _sectionTransitionDuration,
                        curve: Curves.easeOutCubic,
                        builder: (context, progress, child) =>
                            Transform.translate(
                              offset: Offset(0, 6 * (1 - progress)),
                              child: child,
                            ),
                        child: searching
                            ? (hitsBySection.isEmpty
                                  ? _emptyState(scheme, s)
                                  : _buildSearchResults(
                                      hitsBySection,
                                      context,
                                      state,
                                      scheme,
                                    ))
                            : _buildSectionPane(
                                selectedSec,
                                context,
                                state,
                                scheme,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
    final s = AppStrings.of(state.config.language);
    return AnimatedContainer(
      duration: _sectionTransitionDuration,
      curve: Curves.easeOutCubic,
      width: _sectionNavCollapsed ? 64 : 190,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Keep labels out of the intermediate, icon-only collapse widths.
          final collapsed = constraints.maxWidth < 150;
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 6, 16),
            // The panel may cache its surface. Keep the moving backdrop
            // sampler outside that cache, beneath the interactive rows.
            child: Stack(
              fit: StackFit.expand,
              children: [
                GlassPanel(
                  radius: 20,
                  blur: 12,
                  style: state.config.menuStyle,
                  child: const SizedBox.expand(),
                ),
                Material(
                  color: Colors.transparent,
                  child: ListView(
                    addRepaintBoundaries: false,
                    padding: EdgeInsets.symmetric(
                      horizontal: collapsed ? 4 : 6,
                      vertical: 6,
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Tooltip(
                          message: _sectionNavCollapsed
                              ? (s.isZh
                                    ? '展开设置导航'
                                    : 'Expand settings navigation')
                              : (s.isZh
                                    ? '收起设置导航'
                                    : 'Collapse settings navigation'),
                          child: InkWell(
                            key: const ValueKey('settings_section_nav_toggle'),
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setState(
                              () =>
                                  _sectionNavCollapsed = !_sectionNavCollapsed,
                            ),
                            child: Container(
                              height: _sectionNavRowHeight,
                              padding: EdgeInsets.symmetric(
                                horizontal: collapsed ? 6 : 12,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest.withAlpha(
                                  45,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisAlignment: collapsed
                                    ? MainAxisAlignment.center
                                    : MainAxisAlignment.start,
                                children: [
                                  Icon(
                                    _sectionNavCollapsed
                                        ? Icons.chevron_right
                                        : Icons.chevron_left,
                                    size: 17,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  if (!collapsed) ...[
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        s.isZh ? '收起导航' : 'Collapse navigation',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.4,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      _buildSectionNavItems(
                        hitsBySection,
                        searching,
                        scheme,
                        collapsed: collapsed,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionNavItems(
    List<(_SectionDef, List<_CardDef>)> hitsBySection,
    bool searching,
    ColorScheme scheme, {
    bool collapsed = false,
    Axis direction = Axis.vertical,
  }) {
    final counts = <String, int>{
      for (final (sec, cards) in hitsBySection) sec.id: cards.length,
    };
    final vertical = direction == Axis.vertical;
    final rowHeight = _sectionNavRowHeight;
    final index = _sections.indexWhere((sec) => sec.id == _selectedSection);
    final rows = [
      for (final sec in _sections)
        Padding(
          padding: EdgeInsets.only(
            bottom: vertical ? 2 : 0,
            right: vertical ? 0 : 6,
          ),
          child: SizedBox(
            height: rowHeight,
            width: vertical ? null : 112,
            child: _navItem(
              sec,
              searching,
              counts[sec.id] ?? 0,
              scheme,
              collapsed: collapsed,
            ),
          ),
        ),
    ];
    return Stack(
      children: [
        AnimatedPositionedDirectional(
          // Font changes resize real hit targets immediately, so snap the
          // decoration to the new geometry rather than tweening stale bounds.
          key: ValueKey(rowHeight),
          duration: _sectionTransitionDuration,
          curve: Curves.easeOutCubic,
          top: vertical ? index * (rowHeight + 2) : 0,
          start: vertical ? 0 : index * 118.0,
          end: vertical ? 0 : null,
          width: vertical ? null : 112,
          height: rowHeight,
          child: const IgnorePointer(
            child: SelectionHighlight(
              key: ValueKey('settings_section_selection'),
            ),
          ),
        ),
        if (vertical)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          )
        else
          Row(mainAxisSize: MainAxisSize.min, children: rows),
      ],
    );
  }

  /// Each actual row owns input immediately; the moving background is decoration.
  Widget _navItem(
    _SectionDef sec,
    bool searching,
    int hitCount,
    ColorScheme scheme, {
    bool collapsed = false,
  }) {
    final selected = sec.id == _selectedSection;
    final title = sec.title(
      AppStrings.of(context.read<AppState>().config.language),
    );
    final icon = Icon(
      sec.icon,
      key: ValueKey('${sec.id}_$selected'),
      size: 17,
      color: selected ? scheme.primary : scheme.onSurfaceVariant,
    );
    return Semantics(
      selected: selected,
      button: true,
      label: collapsed ? title : null,
      child: Tooltip(
        message: collapsed ? title : '',
        excludeFromSemantics: true,
        child: InkWell(
          key: ValueKey('settings_section_${sec.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _selectSection(sec.id),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 6 : 12,
              vertical: 9,
            ),
            child: collapsed
                ? Center(child: icon)
                : Row(
                    children: [
                      icon,
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            fontWeight: selected ? FontWeight.w600 : null,
                            color: selected
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (searching)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(28),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '$hitCount',
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactSectionNav(
    List<(_SectionDef, List<_CardDef>)> hitsBySection,
    bool searching,
    ColorScheme scheme,
    AppState state,
  ) {
    return SizedBox(
      height: _sectionNavRowHeight + 8,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: _buildSectionNavItems(
          hitsBySection,
          searching,
          scheme,
          direction: Axis.horizontal,
        ),
      ),
    );
  }

  /// 右侧面板：当前分区的全部设置卡片。
  /// 分区即时替换，不叠加旧分区的整页退场动画。
  Widget _buildSectionPane(
    _SectionDef sec,
    BuildContext ctx,
    AppState state,
    ColorScheme scheme,
  ) {
    return LayoutBuilder(
      builder: (ctx, _) {
        // 不保留退场整页：避免双份玻璃绘制及快速返回时 GlobalKey 冲突。
        return SingleChildScrollView(
          key: ValueKey('pane_${sec.id}'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分区标题行（左侧菜单已高亮当前分区，这里提供上下文）
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Row(
                  children: [
                    Icon(sec.icon, size: 16, color: scheme.primary),
                    const SizedBox(width: 7),
                    Text(
                      sec.title(
                        AppStrings.of(ctx.read<AppState>().config.language),
                      ),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Divider(
                        color: scheme.outlineVariant.withAlpha(70),
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              MasonryGrid(
                // 桌面设置使用一致的单列列表，避免多列卡片高度错位和扫描负担。
                columns: 1,
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
            ],
          ),
        );
      },
    );
  }

  /// 搜索结果面板：跨分区列出所有命中的设置卡片，按分区分组。
  Widget _buildSearchResults(
    List<(_SectionDef, List<_CardDef>)> hitsBySection,
    BuildContext ctx,
    AppState state,
    ColorScheme scheme,
  ) {
    return LayoutBuilder(
      builder: (ctx, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (sec, cards) in hitsBySection) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Row(
                    children: [
                      Icon(sec.icon, size: 14, color: scheme.primary),
                      const SizedBox(width: 7),
                      _highlightedSearchText(
                        sec.title(
                          AppStrings.of(ctx.read<AppState>().config.language),
                        ),
                        _searchQuery,
                        const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                        scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${cards.length}',
                        style: SettingsTypography.description.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Divider(
                          color: scheme.outlineVariant.withAlpha(70),
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                MasonryGrid(
                  columns: 1,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in cards)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 搜索结果头：分区 · 卡片名 + 「定位」按钮 ——
                          // 点一下即切到该分区、把卡片滚进视野并高亮（设置页搜索的核心动作）。
                          _resultHeader(
                            sec,
                            c,
                            scheme,
                            AppStrings.of(state.config.language),
                          ),
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
            ],
          ),
        );
      },
    );
  }

  // ── 移动端专用 ──

  /// 搜索圆钮向左展开至居中，标题药丸同步淡出。
  Widget _buildMobileTopBar(AppStrings s, ColorScheme scheme) {
    return MobilePillTopBar(
      title: Text(s.settingsTitle),
      actions: [
        MobileGlassPillAction(
          icon: Icons.search,
          tooltip: s.setSearchHint,
          color: scheme.onSurface,
          onTap: () => setState(() => _searchExpanded = true),
        ),
      ],
      // 主界面不折叠（用户要求「主界面不要搞...了」）。本页常驻操作只有「搜索」
      // 一个，本来也不会折叠，这里显式关掉以免以后加操作时行为与其它主界面不一致。
      collapseActions: false,
      searching: _searchExpanded || _searchCtrl.text.isNotEmpty,
      // 搜索药丸：与主界面（项目页）共用同一实现，不再各写一份
      searchChild: MobileSearchPill(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        hint: s.setSearchHint,
        onChanged: (v) => setState(() => _query = v),
        onClose: () {
          _searchCtrl.clear();
          setState(() {
            _searchExpanded = false;
            _query = '';
          });
        },
      ),
    );
  }

  Widget _searchMatchBadges(
    String cardId,
    List<String> keywords,
    SettingsSearch query,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final keyword in keywords)
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(22),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: _highlightedSearchText(
                  keyword,
                  query,
                  TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                  scheme.primary,
                  key: ValueKey('settings-match-$cardId-$keyword'),
                ),
              ),
            ),
        ],
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
    AppStrings s, {
    required SettingsSearch query,
  }) {
    if (cards.isEmpty) return const SizedBox.shrink();

    // 一个分区 = 一张卡：条目之间用细分隔线区分。
    //
    // 曾经改成「一主题一卡」（每个设置项各占一张卡），但用户明确要求
    // 「设置界面你不要每个都分开，像是主题、背景等整合到一张卡片」，
    // 于是回到分区级卡片 —— 视觉上更整、滚动距离更短，靠分隔线仍能分清单项。
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      final card = cards[i];
      final matchingKeywords = _matchingLabels(sec, card, s);
      final row = _buildMobileRow(card, context, state, scheme, s);
      rows.add(
        KeyedSubtree(
          key: _cardKey(card.id),
          child: _highlightWrap(
            card.id,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                if (matchingKeywords.isNotEmpty)
                  _searchMatchBadges(card.id, matchingKeywords, query, scheme),
              ],
            ),
          ),
        ),
      );
      if (i < cards.length - 1) {
        rows.add(
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: 16,
            endIndent: 16,
            color: scheme.outlineVariant.withAlpha(60),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: _highlightedSearchText(
            sec.title(s),
            query,
            SettingsTypography.sectionTitle.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            scheme.primary,
          ),
        ),
        Padding(
          // 卡片左右内边距 14（原 8）：用户反馈「设置的卡片宽度过宽，再缩小」。
          // 二级页为 subListPadding 12 + _glass 12 = 24，比一级菜单更窄一点，
          // 刻意保留这个两级层次差别。底部 7 = 相邻两张卡之间的间距。
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
          // 分区卡统一走 _cardShell → AppCard，遵循「主题→样式→卡片样式」。
          child: _cardShell(context, state, Column(children: rows)),
        ),
      ],
    );
  }

  /// 一条设置行：左标题，右侧开关 / 分段切换 / 箭头（进入二级菜单）。
  Widget _buildMobileRow(
    _CardDef c,
    BuildContext context,
    AppState state,
    ColorScheme scheme,
    AppStrings s,
  ) {
    final title = c.title(s);
    final highlightedTitle = _highlightedSearchText(
      title,
      _searchQuery,
      TextStyle(fontSize: 14, color: scheme.onSurface),
      scheme.primary,
    );

    // 纯开关：直接在一级菜单右侧放 Switch
    if (c.id == 'predictiveBack') {
      final cfg = state.config;
      return SwitchListTile(
        value: cfg.predictiveBack,
        onChanged: (v) => state.updateConfig((cc) => cc..predictiveBack = v),
        secondary: _miIcon(scheme, c.icon),
        title: highlightedTitle,
        subtitle: Text(
          s.predictiveBackHint,
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      );
    }

    // 语言选项直接在一级菜单展开。
    if (c.id == 'language') {
      return _mobileLanguageRow(state, scheme, c.icon, highlightedTitle);
    }

    // 命令 / 日志：直接进入对应页面（它们的「内容」本身就是入口，不套二级页）
    return ListTile(
      leading: _miIcon(scheme, c.icon),
      title: highlightedTitle,
      trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      onTap: () {
        if (c.id == 'command') {
          // CommandPage / LogPage 自身已用 withWallpaper 铺壁纸，且顶栏自带安全区
          // 偏移。这里若再套一层 withWallpaper + SafeArea：
          //   1) 双层壁纸多解码一次并多一层遮罩；
          //   2) SafeArea 会把子树的 MediaQuery.padding.top 清零 → 顶栏被状态栏压住。
          Navigator.of(context).push(
            MaterialPageRoute(
              allowSnapshotting: false,
              builder: (_) => const CommandPage(),
            ),
          );
        } else if (c.id == 'logs') {
          Navigator.of(context).push(
            MaterialPageRoute(
              allowSnapshotting: false,
              builder: (_) => const LogPage(),
            ),
          );
        } else if (c.id == 'cache') {
          // 缓存：直接弹出确认框，不进入二级页
          _clearCache(context, state, scheme, s);
        } else {
          _pushMobileSubPage(context, title, c.build);
        }
      },
    );
  }

  /// The language picker uses the same menu as the other settings controls.
  Widget _mobileLanguageRow(
    AppState state,
    ColorScheme scheme,
    IconData icon,
    Widget title,
  ) {
    final label = AppStrings.of(state.config.language).languageInterface;
    final menu = _languageMenu(state, label);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inline =
              constraints.maxWidth >= 220 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21;
          final labelRow = Row(
            children: [
              _miIcon(scheme, icon),
              const SizedBox(width: 12),
              Expanded(child: title),
            ],
          );
          return Flex(
            direction: inline ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: inline
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.stretch,
            children: [
              if (inline) ...[
                Expanded(child: labelRow),
                const SizedBox(width: 12),
                SizedBox(width: 124, child: menu),
              ] else ...[
                labelRow,
                const SizedBox(height: 6),
                menu,
              ],
            ],
          );
        },
      ),
    );
  }

  /// 二级设置页：全屏（覆盖底部导航栏），顶部返回栏 + 可滚动内容。
  ///
  /// 薄包装：真正的实现在顶层函数 [_pushSettingsSubPage]。之所以提升出去，是因为
  /// 「外观 → 样式 → 玻璃细节」这类**三级**页的入口写在顶层的卡片构建函数
  /// （[_buildSurfaceStyleCard]）里，那里拿不到 State 实例。
  void _pushMobileSubPage(
    BuildContext context,
    String title,
    Widget Function(BuildContext, AppState) contentBuilder,
  ) {
    _pushSettingsSubPage(context, title, contentBuilder);
  }

  Widget _searchField(ColorScheme scheme, AppStrings s) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: LayoutBuilder(
      builder: (ctx, cons) => SizedBox(
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
            prefixIconConstraints: const BoxConstraints(
              minWidth: 34,
              minHeight: 34,
            ),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.close, size: 15, color: scheme.outline),
                    tooltip: s.setClearSearch,
                    onPressed: _clearSearch,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(19),
              borderSide: BorderSide(
                color: scheme.outlineVariant.withAlpha(70),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(19),
              borderSide: BorderSide(
                color: scheme.outlineVariant.withAlpha(70),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(19),
              borderSide: BorderSide(
                color: scheme.primary.withAlpha(160),
                width: 1.4,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _emptyState(ColorScheme scheme, AppStrings s) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 44,
            color: scheme.outline.withAlpha(140),
          ),
          const SizedBox(height: 12),
          Text(
            s.setNoMatch,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            s.setNoMatchHint,
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          TextButton.icon(
            icon: const Icon(Icons.close, size: 15),
            label: Text(s.setClearSearch, style: const TextStyle(fontSize: 12)),
            onPressed: _clearSearch,
          ),
        ],
      ),
    ),
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
// 移动端：中性图标块（不混入莫奈动态色），与液态玻璃卡片同一中性体系。
Widget _miIcon(ColorScheme scheme, IconData icon) => Container(
  width: 34,
  height: 34,
  decoration: BoxDecoration(
    color: isMobilePlatform
        ? scheme.onSurface.withAlpha(0x14)
        : scheme.primary.withAlpha(0x28),
    borderRadius: BorderRadius.circular(10),
  ),
  child: Icon(
    icon,
    size: 19,
    color: isMobilePlatform ? scheme.onSurface : scheme.primary,
  ),
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
  Navigator.of(context).push(
    MaterialPageRoute(
      allowSnapshotting: false,
      builder: (_) =>
          _SettingsSubPageShell(title: title, contentBuilder: contentBuilder),
    ),
  );
}

/// 设置二级 / 三级页的**静态外壳**：壁纸 + 玻璃标题栏 + 内容列表。
///
/// 这个组件本身不订阅任何配置，[Consumer] 只包住列表里的那一项内容。旧写法把
/// `Consumer<AppState>` 放在路由 builder 的最外层、`withWallpaper(...)` 写在它的
/// builder 里，于是「在这一页点任意开关 → updateConfig → notifyListeners」都会把
/// 整个路由子树重建一遍：壁纸层重新解码/重建 Image、玻璃标题栏重新做一次
/// BackdropFilter 采样、`WallpaperWindowScope` 重新建作用域——表现为「点任何元素
/// 背景都会闪一下 / 变一下」（高级页已按同一思路修过，这里补齐）。
///
/// 把外壳提到 Consumer 外面后，点击只重建 `children` 里的那一个 Widget，背景层与
/// 标题栏的 Element 一直存活。
///
/// 包裹顺序：`WindowChrome` 必须在 `withWallpaper` 的**内层**。标题栏玻璃用
/// BackdropFilter 采样「同一棵树里更早绘制的内容」；若写成
/// `WindowChrome(child: withWallpaper(...))`，标题栏下方没有任何已绘制的像素
/// （本路由不透明、旧路由不再绘制），玻璃只会透出窗口底色。
///
/// `WindowChrome` 不传 title / onBack：页面自己的 [MobileSubPageTopBar] 已经承担
/// 返回与标题，避免出现「两层标题 / 两个返回」。
class _SettingsSubPageShell extends StatelessWidget {
  final String title;
  final Widget Function(BuildContext, AppState) contentBuilder;

  const _SettingsSubPageShell({
    required this.title,
    required this.contentBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return withWallpaper(
      context,
      WindowChrome(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // Keep the list in the same slot when the bar changes shape.
          body: AppTopBarLayout(
            builder: (context, compact) => ImmersiveTopBar(
              bar: compact
                  ? MobileSubPageTopBar(
                      title: Text(title),
                      onBack: () => Navigator.of(context).maybePop(),
                    )
                  : GlassTopBar(
                      title: Row(
                        children: [
                          BackButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
              child: ListView(
                // addRepaintBoundaries:false —— 见移动端主列表同款注释：
                // 壁纸开窗 painter 必须每帧按当前变换重算，不能被子项缓存平移。
                // 左右间距与设置主界面卡片对齐（主界面 = ListView + 分区卡内边距 14）。
                // 此前为 0：MCP/AI 等二级页卡片通顶通底，比主界面卡片明显更宽。
                addRepaintBoundaries: false,
                // Cards in this page already own the shared 12px inset via
                // _glass/_AiSectionCard. Do not add another 12px here: that
                // made every secondary-page card narrower than the provider
                // card on the MCP/AI page.
                //
                // top 用 ImmersiveTopBar.insetOf：预留顶栏（含状态栏）高度，
                // 首屏第一张卡正好落在药丸下沿，往下滑就钻进去。
                padding: EdgeInsets.only(
                  top:
                      (compact
                          ? ImmersiveTopBar.insetOf(context)
                          : GlassTopBar.defaultExtent) +
                      4,
                  bottom: 48,
                ),
                children: [
                  Consumer<AppState>(
                    builder: (ctx, state, _) => contentBuilder(ctx, state),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _glass(
  BuildContext ctx,
  AppState state,
  String title,
  List<Widget> children,
) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeading(title: title),
        _cardShell(
          ctx,
          state,
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
          radius: 20,
        ),
      ],
    ),
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
      child: Row(
        children: [
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: clr, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  scope,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SettingsTypography.description.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: scheme.outline),
        ],
      ),
    ),
  );
}

/// 路径字段（标签 + 输入框 + 浏览按钮）
Widget _pf(
  BuildContext ctx,
  String label,
  String value,
  ValueChanged<String> onChange,
  VoidCallback onBrowse,
) {
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: clr)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _PathField(
                value: value,
                label: '',
                scheme: scheme,
                onChange: onChange,
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: onBrowse,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              child: const Icon(Icons.folder_open, size: 16),
            ),
          ],
        ),
      ],
    ),
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
Widget _infoRow(
  String label,
  String value,
  ColorScheme scheme, {
  Widget? trailing,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      ?trailing,
      Flexible(
        child: Tooltip(
          message: value,
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    ],
  ),
);

/// iOS 风格按钮
Widget _iosButton({
  required IconData icon,
  required String label,
  required Color color,
  required Color bg,
  required VoidCallback onTap,
}) => Material(
  color: bg,
  borderRadius: BorderRadius.circular(14),
  child: InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  ),
);

/// 主题色圆点
Widget _dot(
  BuildContext context,
  ColorScheme sc,
  bool sel,
  Color c,
  String tip,
  VoidCallback onTap,
) => Tooltip(
  message: tip,
  child: Semantics(
    button: true,
    selected: sel,
    label: tip,
    child: InkResponse(
      onTap: onTap,
      radius: 24,
      child: SizedBox.square(
        dimension: 48,
        child: Center(
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: sel ? sc.onSurface : sc.outlineVariant,
                width: 3,
              ),
            ),
            child: sel
                ? Icon(
                    Icons.check,
                    size: 16,
                    color: c.computeLuminance() > 0.45
                        ? Colors.black
                        : Colors.white,
                  )
                : null,
          ),
        ),
      ),
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
    super.key,
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

  /// [ _SettingSlider.liveCommit] 的节流：拖动时每 80ms 至多写一次配置。
  /// **首帧立即写**（拖动即生效），窗口内的后续 tick 只暂存最新值、窗口
  /// 到期补写一次 —— 旧实现「每个 tick 都 cancel+重建 Timer」在连续拖动时
  /// 永远等不到触发，配置只在停顿/松手才写，表现为「不随拖动自然跟随」。
  Timer? _liveTimer;
  double? _livePending;
  static const Duration _liveThrottle = Duration(milliseconds: 80);

  double get _current => _dragValue ?? widget.value;

  void _onChanged(double v) {
    setState(() => _dragValue = v);
    // 仅本地更新不触发父级重建，确保滑动全程流畅无中断
    if (!widget.liveCommit) return;
    _livePending = v;
    // 窗口内只暂存；窗口的尾沿定时器会统一补写，不要按 tick 重置窗口。
    if (_liveTimer != null) return;
    _flushLive();
  }

  /// 立即写一次配置并开启 80ms 窗口；窗口到期时若有暂存值再补写一次。
  void _flushLive() {
    final double v = _livePending ?? _current;
    _livePending = null;
    widget.onCommit(v);
    _liveTimer = Timer(_liveThrottle, () {
      _liveTimer = null;
      final double? pending = _livePending;
      _livePending = null;
      if (pending != null && mounted) widget.onCommit(pending);
    });
  }

  void _onChangeEnd(double v) {
    _liveTimer?.cancel();
    _liveTimer = null;
    _livePending = null;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label(_current),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.labelStyle,
          ),
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
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 各设置卡片
// ═══════════════════════════════════════════

const _presets = [
  ('Linear Purple', 0xFF5E6AD2),
  ('Ocean Blue', 0xFF3B82F6),
  ('Emerald', 0xFF10B981),
  ('Amber', 0xFFF59E0B),
  ('Rose', 0xFFEF4444),
  ('Cyan', 0xFF06B6D4),
  ('Violet', 0xFF8B5CF6),
];

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
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (isMobilePlatform) ...[
        _glass(ctx, state, s.isZh ? '移动端主题' : 'Mobile theme', [
          Text(
            s.isZh
                ? '全站中性表面 + 更大圆角（菜单 20 / 气泡 20）；主题色、字体与材质保持独立。'
                : 'Neutral surfaces and larger radii (menus 20 / bubbles 20) across the whole app; accent, fonts and materials stay independent.',
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          OptionMenuBar<String>(
            value: cfg.mobileTheme,
            triggerHeight: 44,
            items: [
              OptionItem('follow', s.isZh ? '跟随现有主题' : 'Follow existing theme'),
              const OptionItem('miuix', 'ZeroUI / Miuix-inspired'),
            ],
            onChanged: (value) =>
                state.updateConfig((c) => c..mobileTheme = value),
          ),
        ]),
        const SizedBox(height: 8),
      ],
      _glass(ctx, state, s.isZh ? '模式' : 'Appearance mode', [
        // 亮 / 暗色切换
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(s.themeMode, style: TextStyle(color: clr)),
          subtitle: Text(
            state.darkMode ? s.darkMode : (s.isZh ? '浅色模式' : 'Light Mode'),
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          value: state.darkMode,
          onChanged: (v) => state.toggleDarkMode(v),
        ),
      ]),
      const SizedBox(height: 8),
      _glass(ctx, state, s.isZh ? '主题色' : 'Accent color', [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            s.isZh ? '启用全局主题色' : 'Enable global accent color',
            style: TextStyle(color: clr),
          ),
          subtitle: Text(
            s.isZh
                ? '关闭后恢复默认强调色，已选颜色会保留'
                : 'Use default accent colors; your selected colors are preserved',
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          value: cfg.useThemeColor,
          onChanged: (v) => state.updateConfig((c) => c..useThemeColor = v),
        ),
        // ── 主题色（预设 / 自定义 / 动态取色） ──
        Row(
          children: [
            Expanded(
              child: Text(
                s.accentColor,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: clr, fontSize: 12),
              ),
            ),
            if (dynamicOn) ...[
              Icon(Icons.auto_awesome, size: 12, color: scheme.primary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  s.themeDynamicOn,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: scheme.primary),
                ),
              ),
            ],
          ],
        ),
        // Android Monet 动态取色（跟随系统壁纸）；开启后自定义主题色不生效
        if (isMobilePlatform)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              s.themeDynamicColor,
              style: TextStyle(color: clr, fontSize: 12),
            ),
            subtitle: Text(
              s.themeDynamicColorHint,
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            value: cfg.useDynamicColor,
            onChanged: (v) => state.updateConfig((c) => c..useDynamicColor = v),
          ),
        const SizedBox(height: 8),
        // 预设色 + 自定义取色：动态取色开启时置灰禁用
        Opacity(
          opacity: dynamicOn ? 0.35 : 1.0,
          child: IgnorePointer(
            ignoring: dynamicOn,
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      itemCount: _presets.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 4),
                      itemBuilder: (context, index) {
                        final p = _presets[index];
                        return SizedBox(
                          width: 44,
                          child: Center(
                            child: _dot(
                              ctx,
                              scheme,
                              cfg.themeColor == p.$2 && cfg.themeColor2 < 0,
                              Color(p.$2),
                              p.$1,
                              () => state.updateConfig(
                                (c) => c
                                  ..themeColor = p.$2
                                  ..themeColor2 = -1,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: s.isZh ? '自定义颜色 / 渐变' : 'Custom color / gradient',
                    child: OutlinedButton(
                      onPressed: () => _pickColor(ctx, state),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(42, 42),
                        maximumSize: const Size(42, 42),
                        padding: EdgeInsets.zero,
                        side: BorderSide(color: scheme.outlineVariant),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Icon(Icons.add, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // ── 主题色协调度 ──
        // 「跟随主题色」大面积铺底时若直接用 scheme.primary（暗色下是 tone 80 的
        // 高亮色）非常刺眼 —— 用户反馈「选择主题色又很亮」。这里给一个 0~0.8 的
        // 混合系数：0% = 原色（与改动前一致），越大越并入表面色。由
        // liquid_glass_fallback.harmonizedAccent 统一应用到所有「跟随主题色」的
        // 玻璃/实色表面（AppCard / MobileGlassPill / MobileNavRail / GlassPanel）。
        _SettingSlider(
          value: cfg.themeTone,
          min: 0,
          max: 0.8,
          divisions: 16,
          label: (v) =>
              '${s.isZh ? '主题色协调度' : 'Accent harmony'}: ${(v * 100).round()}%',
          labelStyle: TextStyle(color: clr, fontSize: 12),
          onCommit: (v) => state.updateConfig((c) => c..themeTone = v),
        ),
        Text(
          s.isZh
              ? '仅作用于「跟随主题色」的卡片 / 底栏 / 药丸底色，0% 即原主题色'
              : 'Only affects accent-tinted cards, nav bar and pills; 0% = raw accent',
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ]),
    ],
  );
}

/// 「外观 → 背景」卡片：壁纸选择 + 不透明度（原 _ThemeBackgroundSection）。
Widget _buildBackgroundCard(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.isZh ? '背景' : 'Background', const [
    _ThemeBackgroundSection(),
  ]);
}

/// General surface controls, per-component overrides and fine tuning.
Widget _buildSurfaceStyleCard(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final zh = s.isZh;
  final scheme = Theme.of(ctx).colorScheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      _glass(
        ctx,
        state,
        zh ? '样式预设' : 'Style presets',
        _buildStylePresets(ctx, state),
      ),
      _glass(ctx, state, zh ? '卡片与弹窗' : 'Cards and popups', [
        _styleRow(
          ctx,
          icon: Icons.view_carousel_outlined,
          label: s.cardStyleLabel,
          scope: s.cardStyleScope,
          value: cfg.cardStyle,
          onSelected: (v) => state.updateConfig((c) => c..cardStyle = v),
        ),
        _optionRow(
          ctx,
          icon: Icons.dashboard_customize_outlined,
          label: zh ? '设置卡片样式' : 'Settings card style',
          scope: zh ? '覆盖设置页的卡片样式' : 'Overrides the card style in Settings',
          value: cfg.settingsGlassMode,
          items: [
            OptionItem(
              'follow',
              zh ? '跟随卡片样式' : 'Follow card style',
              icon: Icons.link,
            ),
            OptionItem(
              'frosted',
              zh ? '毛玻璃' : 'Frosted glass',
              icon: Icons.blur_on_outlined,
            ),
            OptionItem(
              'solid',
              zh ? '主题色实心' : 'Solid theme color',
              icon: Icons.format_color_fill,
            ),
          ],
          onSelected: (v) =>
              state.updateConfig((c) => c..settingsGlassMode = v),
        ),
        _optionRow(
          ctx,
          icon: Icons.blur_on_outlined,
          label: zh ? '弹窗与面板样式' : 'Popup and panel style',
          scope: zh
              ? '应用于遵循全局样式的弹窗和面板'
              : 'Applies to popups and panels using the global style',
          value: switch (cfg.glassEffect) {
            'blur' || 'none' => cfg.glassEffect,
            _ => 'liquid',
          },
          items: [
            OptionItem(
              'liquid',
              s.surfaceStyleLiquid,
              icon: Icons.water_drop_outlined,
            ),
            OptionItem('blur', s.glassBlur, icon: Icons.blur_on_outlined),
            OptionItem(
              'none',
              s.surfaceStyleTheme,
              icon: Icons.format_color_fill,
            ),
          ],
          onSelected: (v) => state.updateConfig((c) => c..glassEffect = v),
        ),
        _optionRow(
          ctx,
          icon: Icons.arrow_drop_down_circle_outlined,
          label: zh ? '下拉菜单样式' : 'Dropdown style',
          value: cfg.dropdownAppearance,
          items: [
            OptionItem(
              'theme',
              zh ? '跟随主题（不透明）' : 'Follow theme (opaque)',
              icon: Icons.palette_outlined,
            ),
            OptionItem(
              'liquid',
              s.surfaceStyleLiquid,
              icon: Icons.water_drop_outlined,
            ),
            OptionItem(
              'frosted',
              zh ? '主题色毛玻璃' : 'Theme-tinted frosted glass',
              icon: Icons.blur_on_outlined,
            ),
            OptionItem(
              'highlight',
              zh ? '高光玻璃' : 'Highlight glass',
              icon: Icons.auto_awesome_outlined,
            ),
            OptionItem(
              'gray',
              zh ? '极简灰（不透明）' : 'Minimal gray (opaque)',
              icon: Icons.layers_outlined,
            ),
          ],
          onSelected: (v) =>
              state.updateConfig((c) => c..dropdownAppearance = v),
        ),
      ]),
      _glass(ctx, state, zh ? '玻璃与边框' : 'Glass and borders', [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(zh ? '玻璃使用主题色' : 'Tint glass with theme color'),
          subtitle: Text(zh ? '关闭时使用表面灰' : 'Uses surface gray when off'),
          value: cfg.glassFollowTheme,
          onChanged: (v) => state.updateConfig((c) => c..glassFollowTheme = v),
        ),
        _SettingSlider(
          key: const ValueKey('settings_surface_blur'),
          value: cfg.glassBlur,
          min: 0,
          max: 30,
          divisions: 30,
          liveCommit: true,
          label: (v) =>
              '${zh ? '玻璃与表面模糊度' : 'Glass and surface blur'}: ${v.round()}',
          labelStyle: TextStyle(color: scheme.onSurface, fontSize: 12),
          onCommit: (v) => state.updateConfig((c) => c..glassBlur = v),
        ),
        Text(
          zh ? '玻璃样式与模糊样式共用此强度。' : 'Shared by glass and blur styles.',
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        ..._buildBorderItems(ctx, state),
        if (isMobilePlatform)
          _subPageEntry(
            ctx,
            scheme,
            scheme.onSurface,
            icon: Icons.blur_on_outlined,
            label: zh ? '玻璃细节' : 'Glass details',
            scope: zh ? '通透度、高光与边缘光' : 'Clarity, highlights and edge light',
            onTap: () => _pushSettingsSubPage(
              ctx,
              zh ? '玻璃细节' : 'Glass details',
              _buildGlassDetailCard,
            ),
          )
        else
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(zh ? '玻璃细节' : 'Glass details'),
            subtitle: Text(
              zh ? '通透度、高光与边缘光' : 'Clarity, highlights and edge light',
            ),
            children: _glassDetailItems(ctx, state),
          ),
      ]),
      _glass(ctx, state, zh ? '动效' : 'Effects', _buildEffectItems(ctx, state)),
    ],
  );
}

List<Widget> _buildBorderItems(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  final zh = cfg.language == 'zh';
  return [
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(zh ? '添加边框' : 'Add borders'),
      subtitle: Text(
        zh ? '为卡片和药丸添加实线边框' : 'Draw solid borders around cards and pills',
      ),
      value: cfg.borderEnabled,
      onChanged: (v) => state.updateConfig((c) => c..borderEnabled = v),
    ),
    if (cfg.borderEnabled) ...[
      Row(
        children: [
          Expanded(
            child: Text(
              zh ? '边框颜色' : 'Border color',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: clr, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          // 色块即按钮：复用主题色取色面板，仅显示纯色控件。
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
          Text(
            '#${(cfg.borderColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      _SettingSlider(
        value: cfg.borderWidth,
        min: 0.5,
        max: 4.0,
        divisions: 7,
        label: (v) =>
            '${zh ? '边框宽度' : 'Border width'}: ${v.toStringAsFixed(1)}',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..borderWidth = v),
      ),
    ],
  ];
}

/// 「特效」卡：全局彗星拖尾（自 [_buildSurfaceStyleCard] 的 ④ 使用）。
///
/// 单独成卡（而不是并进「玻璃与材质」）：它是动画项，跟玻璃材质不是一个主题。
/// 关闭后彗星层连 Ticker / 绘制层都不建，是低配设备换帧率的开关
/// （见 widgets/app_slider.dart 的性能约定）。
///
/// 现在是**全局**开关：滑块、确定 / 不确定进度条、开屏加载条共用
/// widgets/app_slider.dart 里唯一的 [_drawComet]；旧版「粒子喷射」实现已删除。
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
      key: const ValueKey('settings_disable_animations'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(zh ? '关闭所有动画效果' : 'Disable all animations'),
      subtitle: Text(
        zh
            ? '立即关闭界面转场、菜单动效、加载动画和动态壁纸；保留各项特效设置'
            : 'Immediately disable transitions, menu effects, loading animations '
                  'and animated wallpapers; keep individual effect preferences',
      ),
      value: cfg.disableAnimations,
      onChanged: (v) => state.updateConfig((c) => c..disableAnimations = v),
    ),
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        zh ? '彗星拖尾' : 'Comet trail',
        style: TextStyle(color: clr, fontSize: 13),
      ),
      subtitle: Text(
        zh
            ? '全局特效：滑块、进度条、开屏加载条统一使用同一套彗星光带（开屏效果为准，PC 与移动端一致）；关闭后不再绘制，零帧开销'
            : 'One comet for sliders, progress bars and the splash loader '
                  '(PC and mobile alike); off = nothing is painted',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      value: cfg.sliderParticles,
      onChanged: (v) => state.updateConfig((c) => c..sliderParticles = v),
    ),
  ];
}

// ═══════════════════════════════════════════════════════════════════
// 样式预设
// ═══════════════════════════════════════════════════════════════════

/// 一套样式预设控制的全局材质参数。
///
/// 主题色与晨雾需要启用主题配色，其他方案保留用户此前的开关选择。
/// 壁纸、取色来源、显卡兼容选项和移动端独立主题均由各自的设置控制。
@immutable
final class _StyleValues {
  final String cardStyle;
  final String navStyle;
  final String? selectionIndicatorStyle;
  final String pillStyle;
  final String menuStyle;
  final String dropdownAppearance;
  final String canvasBg;
  final String glassEffect;
  final bool glassFollowTheme;
  final bool? useThemeColor;
  final double cardOpacity;
  final double glassBlur;
  final double glassClarity;
  final double glassHighlight;
  final double glassLightPos;
  final double glassEdge;
  final double themeTone;

  const _StyleValues({
    required this.cardStyle,
    required this.navStyle,
    this.selectionIndicatorStyle,
    required this.pillStyle,
    required this.menuStyle,
    required this.dropdownAppearance,
    required this.canvasBg,
    required this.glassEffect,
    required this.glassFollowTheme,
    this.useThemeColor,
    required this.cardOpacity,
    required this.glassBlur,
    required this.glassClarity,
    required this.glassHighlight,
    required this.glassLightPos,
    required this.glassEdge,
    required this.themeTone,
  });

  AppConfig applyTo(AppConfig config) => config
    ..cardStyle = cardStyle
    ..navStyle = navStyle
    ..selectionIndicatorStyle =
        selectionIndicatorStyle ?? config.selectionIndicatorStyle
    ..pillStyle = pillStyle
    ..menuStyle = menuStyle
    ..dropdownAppearance = dropdownAppearance
    ..canvasBg = canvasBg
    ..glassEffect = glassEffect
    ..glassFollowTheme = glassFollowTheme
    ..cardOpacity = cardOpacity
    ..glassBlur = glassBlur
    ..glassClarity = glassClarity
    ..glassHighlight = glassHighlight
    ..glassLightPos = glassLightPos
    ..glassEdge = glassEdge
    ..themeTone = themeTone
    ..useThemeColor = useThemeColor ?? config.useThemeColor
    // 旧版的实心与磨砂开关都从 settingsGlassMode 派生。
    ..settingsGlassMode = 'follow'
    ..borderEnabled = false;

  bool matches(AppConfig config) =>
      config.cardStyle == cardStyle &&
      config.navStyle == navStyle &&
      (selectionIndicatorStyle == null ||
          config.selectionIndicatorStyle == selectionIndicatorStyle) &&
      config.pillStyle == pillStyle &&
      config.menuStyle == menuStyle &&
      config.dropdownAppearance == dropdownAppearance &&
      config.canvasBg == canvasBg &&
      config.glassEffect == glassEffect &&
      config.glassFollowTheme == glassFollowTheme &&
      (useThemeColor == null || config.useThemeColor == useThemeColor) &&
      _near(config.cardOpacity, cardOpacity) &&
      _near(config.glassBlur, glassBlur) &&
      _near(config.glassClarity, glassClarity) &&
      _near(config.glassHighlight, glassHighlight) &&
      _near(config.glassLightPos, glassLightPos) &&
      _near(config.glassEdge, glassEdge) &&
      _near(config.themeTone, themeTone) &&
      config.settingsGlassMode == 'follow' &&
      !config.borderEnabled;

  // 容纳滑块刻度的浮点舍入误差。
  bool _near(double actual, double expected) =>
      (actual - expected).abs() < 0.000001;
}

@immutable
final class _StylePreset {
  const _StylePreset(
    this.zhName,
    this.enName,
    this.zhDescription,
    this.enDescription,
    this.values,
  );

  final String zhName;
  final String enName;
  final String zhDescription;
  final String enDescription;
  final _StyleValues values;

  String name(bool zh) => zh ? zhName : enName;
  String description(bool zh) => zh ? zhDescription : enDescription;
}

const _stylePresets = [
  _StylePreset(
    '液态玻璃',
    'Liquid glass',
    '中性折射玻璃，带明显高光和亮边。',
    'Neutral refractive glass with defined highlights and edges.',
    _StyleValues(
      cardStyle: SurfaceStyle.liquid,
      navStyle: SurfaceStyle.liquid,
      selectionIndicatorStyle: 'liquid',
      pillStyle: SurfaceStyle.liquid,
      menuStyle: SurfaceStyle.liquid,
      dropdownAppearance: 'liquid',
      canvasBg: 'global',
      glassEffect: 'liquid',
      glassFollowTheme: false,
      cardOpacity: 0.70,
      glassBlur: 16,
      glassClarity: 0.45,
      glassHighlight: 1.2,
      glassLightPos: 0.0,
      glassEdge: 1.3,
      themeTone: 0.45,
    ),
  ),
  _StylePreset(
    '轻薄通透',
    'Airy',
    '底色更淡、模糊更少，保留细亮边。',
    'Light tint, less blur, and a fine luminous edge.',
    _StyleValues(
      cardStyle: SurfaceStyle.liquid,
      navStyle: SurfaceStyle.liquid,
      pillStyle: SurfaceStyle.liquid,
      menuStyle: SurfaceStyle.liquid,
      dropdownAppearance: 'highlight',
      canvasBg: 'global',
      glassEffect: 'liquid',
      glassFollowTheme: false,
      cardOpacity: 0.52,
      glassBlur: 6,
      glassClarity: 0.80,
      glassHighlight: 0.5,
      glassLightPos: 0.15,
      glassEdge: 0.5,
      themeTone: 0.45,
    ),
  ),
  _StylePreset(
    '主题色',
    'Accent',
    '不透明的主题色表面，保留已选主题配色。',
    'Opaque surfaces in your selected theme colors.',
    _StyleValues(
      cardStyle: SurfaceStyle.theme,
      navStyle: SurfaceStyle.theme,
      pillStyle: SurfaceStyle.theme,
      menuStyle: SurfaceStyle.theme,
      dropdownAppearance: 'theme',
      canvasBg: 'global',
      glassEffect: 'none',
      glassFollowTheme: true,
      useThemeColor: true,
      cardOpacity: 0.70,
      glassBlur: 0,
      glassClarity: 0.0,
      glassHighlight: 0.0,
      glassLightPos: 0.0,
      glassEdge: 0.0,
      themeTone: 0.55,
    ),
  ),
  _StylePreset(
    '扁平模糊',
    'Flat blur',
    '柔化背景的平面磨砂玻璃，没有折射和亮边。',
    'Flat frosted glass softens the backdrop without refraction.',
    _StyleValues(
      cardStyle: SurfaceStyle.blur,
      navStyle: SurfaceStyle.blur,
      pillStyle: SurfaceStyle.blur,
      menuStyle: SurfaceStyle.blur,
      dropdownAppearance: 'frosted',
      canvasBg: 'global',
      glassEffect: 'blur',
      glassFollowTheme: false,
      cardOpacity: 0.82,
      glassBlur: 10,
      glassClarity: 0.55,
      glassHighlight: 0.0,
      glassLightPos: 0.0,
      glassEdge: 0.0,
      themeTone: 0.45,
    ),
  ),
  _StylePreset(
    '晨雾',
    'Morning mist',
    '淡主题色毛玻璃，浓雾般的模糊柔化背景。',
    'Dense frosted glass with a soft tint from your theme.',
    _StyleValues(
      cardStyle: SurfaceStyle.blur,
      navStyle: SurfaceStyle.blur,
      pillStyle: SurfaceStyle.blur,
      menuStyle: SurfaceStyle.blur,
      dropdownAppearance: 'frosted',
      canvasBg: 'global',
      glassEffect: 'blur',
      glassFollowTheme: true,
      useThemeColor: true,
      cardOpacity: 0.86,
      glassBlur: 28,
      glassClarity: 0.35,
      glassHighlight: 0.0,
      glassLightPos: 0.25,
      glassEdge: 0.0,
      themeTone: 0.75,
    ),
  ),
  _StylePreset(
    '极简灰',
    'Minimal gray',
    '中性灰卡片和导航，搭配不透明下拉菜单。',
    'Neutral gray cards and navigation with opaque dropdowns.',
    _StyleValues(
      cardStyle: SurfaceStyle.gray,
      navStyle: SurfaceStyle.gray,
      pillStyle: SurfaceStyle.gray,
      menuStyle: SurfaceStyle.gray,
      dropdownAppearance: 'gray',
      canvasBg: 'gray',
      glassEffect: 'none',
      glassFollowTheme: false,
      cardOpacity: 0.70,
      glassBlur: 0,
      glassClarity: 0.0,
      glassHighlight: 0.0,
      glassLightPos: 0.0,
      glassEdge: 0.0,
      themeTone: 0.45,
    ),
  ),
];

/// 根据当前材质显示预设，手工修改后显示「自定义」。
List<Widget> _buildStylePresets(BuildContext ctx, AppState state) {
  final zh = state.config.language == 'zh';
  return [
    Selector<AppState, _StylePreset?>(
      selector: (_, app) => _stylePresets
          .where((preset) => preset.values.matches(app.config))
          .firstOrNull,
      builder: (context, current, _) {
        final description =
            current?.description(zh) ??
            (zh
                ? '当前材质与预设不同。选择预设可套用整套材质。'
                : 'Current materials differ from the presets.');

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OptionMenuBar<_StylePreset?>(
              value: current,
              leadingIcon: Icons.palette_outlined,
              triggerHeight: 48,
              items: [
                if (current == null) OptionItem(null, zh ? '自定义' : 'Custom'),
                for (final preset in _stylePresets)
                  OptionItem(
                    preset,
                    preset.name(zh),
                    subtitle: preset.description(zh),
                  ),
              ],
              onChanged: (preset) {
                if (preset != null) {
                  state.updateConfig(preset.values.applyTo);
                }
              },
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: SettingsTypography.description.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    ),
  ];
}

Widget _buildGlassDetailCard(BuildContext ctx, AppState state) => _glass(
  ctx,
  state,
  state.config.language == 'zh' ? '玻璃细节' : 'Glass details',
  _glassDetailItems(ctx, state),
);

List<Widget> _glassDetailItems(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final clr = Theme.of(ctx).colorScheme.onSurface;
  final zh = cfg.language == 'zh';
  return [
    _SettingSlider(
      value: cfg.glassClarity,
      min: 0,
      max: 1,
      divisions: 20,
      label: (v) => '${zh ? '通透度' : 'Clarity'}: ${(v * 100).round()}%',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassClarity = v),
    ),
    _SettingSlider(
      value: cfg.glassHighlight,
      min: 0,
      max: 1.6,
      divisions: 16,
      label: (v) => '${zh ? '高光强度' : 'Highlight'}: ${v.toStringAsFixed(1)}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassHighlight = v),
    ),
    _SettingSlider(
      value: cfg.glassLightPos,
      min: 0,
      max: 1,
      divisions: 20,
      label: (v) =>
          '${zh ? '高光位置' : 'Light position'}: ${zh ? (v <= 0.05
                    ? '左上'
                    : v >= 0.95
                    ? '右下'
                    : '${(v * 100).round()}%') : '${(v * 100).round()}%'}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassLightPos = v),
    ),
    _SettingSlider(
      value: cfg.glassEdge,
      min: 0,
      max: 2,
      divisions: 20,
      label: (v) => '${zh ? '边缘光' : 'Edge light'}: ${v.toStringAsFixed(1)}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..glassEdge = v),
    ),
    const SizedBox(height: 4),
    Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => state.updateConfig(
          (c) => c
            ..glassBlur = 16.0
            ..glassClarity = 0.45
            ..glassHighlight = 1.0
            ..glassLightPos = 0.0
            ..glassEdge = 1.0,
        ),
        icon: const Icon(Icons.restart_alt, size: 15),
        label: Text(
          zh ? '重置玻璃参数' : 'Reset glass parameters',
          style: const TextStyle(fontSize: 12),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    ),
  ];
}

/// 边框颜色选择：复用主题色面板，仅允许纯色。
Future<void> _pickBorderColor(BuildContext ctx, AppState state) async {
  final isZh = state.config.language == 'zh';
  final res = await showThemeColorPicker(
    ctx,
    initial: Color(state.config.borderColor),
    isZh: isZh,
    useBottomSheet: isMobilePlatform,
    allowGradient: false,
    title: isZh ? '边框颜色' : 'Border color',
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
    // 元素布局：兼容已有的传统芯片布局；列表为另一种编辑器排布。
    Row(
      children: [
        Expanded(
          child: Text(
            s.isZh ? '元素布局' : 'Element layout',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: clr, fontSize: 12),
          ),
        ),
        SizedBox(
          width: _kMenuWidth,
          child: OptionMenuBar<String>(
            expandable: true,
            value: cfg.nodeEditorElementLayout,
            items: [
              OptionItem(
                'traditional',
                s.isZh ? '传统' : 'Traditional',
                icon: Icons.view_module_outlined,
              ),
              OptionItem(
                'list',
                s.isZh ? '列表' : 'List',
                icon: Icons.view_list_outlined,
              ),
            ],
            onChanged: (value) => state.updateConfig(
              (config) => config..nodeEditorElementLayout = value,
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: 10),
    // 画布背景：下拉菜单样式（跟随全局 / 灰色 / 黑色 / 白色）
    Row(
      children: [
        Expanded(
          child: Text(
            s.canvasBgLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: clr, fontSize: 12),
          ),
        ),
        SizedBox(
          width: _kMenuWidth,
          child: OptionMenuBar<String>(
            expandable: true,
            value: cfg.canvasBg,
            items: [
              OptionItem(
                'global',
                s.canvasFollowGlobal,
                icon: Icons.public_outlined,
              ),
              OptionItem('gray', s.canvasGray, icon: Icons.grid_4x4),
              OptionItem(
                'black',
                s.canvasBlack,
                icon: Icons.dark_mode_outlined,
              ),
              OptionItem(
                'white',
                s.canvasWhite,
                icon: Icons.light_mode_outlined,
              ),
            ],
            onChanged: (v) => state.updateConfig((c) => c..canvasBg = v),
          ),
        ),
      ],
    ),
    const SizedBox(height: 10),
    // 逻辑门符号标准：ANSI/IEEE 或 IEC
    // 统一「左 = 图标+文字描述，右 = 调节选项」：标签在左、分段药丸在右，
    // 不再让标签独占一行把控件挤到下一行。
    Row(
      children: [
        Expanded(
          child: Text(
            s.gateStdLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: clr, fontSize: 12),
          ),
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
      ],
    ),
    const SizedBox(height: 6),
    // 小地图开关：右下角缩略图会压在画布上，画布本来就不大时可以关掉。
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        s.isZh ? '画布小地图' : 'Canvas mini map',
        style: TextStyle(color: clr, fontSize: 12),
      ),
      subtitle: Text(
        s.isZh
            ? '右下角显示全图缩略图与当前视口框，点击可跳转'
            : 'Show an overview with the current viewport in the bottom-right corner',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      value: cfg.nodeMiniMap,
      onChanged: (v) => state.updateConfig((c) => c..nodeMiniMap = v),
    ),
    // 网格吸附：拖动节点时对齐到 40px 网格。关掉后可做像素级摆放。
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        s.isZh ? '拖动对齐网格' : 'Snap to grid',
        style: TextStyle(color: clr, fontSize: 12),
      ),
      subtitle: Text(
        s.isZh
            ? '拖动节点时吸附到背景网格，方便对齐成一排'
            : 'Snap dragged nodes onto the background grid',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      value: cfg.nodeSnap,
      onChanged: (v) => state.updateConfig((c) => c..nodeSnap = v),
    ),

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
        child: Row(
          children: [
            Text(
              s.isZh ? '界面尺寸' : 'UI size',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Divider(
                height: 1,
                color: scheme.outlineVariant.withAlpha(70),
              ),
            ),
          ],
        ),
      ),
      _SettingSlider(
        value: cfg.editorToolbarScale.clamp(0.5, 1.6),
        min: 0.5,
        max: 1.6,
        divisions: 11,
        liveCommit: true,
        label: (v) =>
            '${s.isZh ? '顶部菜单栏大小' : 'Top toolbar size'}: ${(v * 100).round()}%',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..editorToolbarScale = v),
      ),
      _SettingSlider(
        value: cfg.editorZoomScale.clamp(0.5, 1.6),
        min: 0.5,
        max: 1.6,
        divisions: 11,
        liveCommit: true,
        label: (v) =>
            '${s.isZh ? '放大镜（缩放药丸）大小' : 'Zoom pill size'}: ${(v * 100).round()}%',
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
      _subPageEntry(
        ctx,
        scheme,
        clr,
        icon: Icons.account_tree_outlined,
        label: s.cardEditorMode,
        scope: s.isZh ? '节点编辑器 / 快速模式' : 'Node editor / Quick mode',
        onTap: () =>
            _pushSettingsSubPage(ctx, s.cardEditorMode, _buildEditorMode),
      ),
      _subPageEntry(
        ctx,
        scheme,
        clr,
        icon: Icons.save_outlined,
        label: s.cardAutosave,
        scope: s.isZh ? '草稿自动保存与保存间隔' : 'Draft autosave and save interval',
        onTap: () => _pushSettingsSubPage(ctx, s.cardAutosave, _buildAutosave),
      ),
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
  final textScaler = MediaQuery.textScalerOf(ctx);
  final pickerHeight = math.max(
    72.0,
    (textScaler.scale(18) * 1.25).ceilToDouble() +
        (textScaler.scale(11) * 1.4).ceilToDouble() +
        24,
  );
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(s.qWeight, style: TextStyle(color: clr, fontSize: 13)),
      const SizedBox(height: 10),
      SizedBox(
        height: pickerHeight,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < _kFontWeights.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Semantics(
                  selected: cfg.fontWeightIndex == i,
                  button: true,
                  label: '${labels[i]} ${AppConfig.fontWeightValues[i]}',
                  child: OutlinedButton(
                    onPressed: () =>
                        state.updateConfig((c) => c..fontWeightIndex = i),
                    style: OutlinedButton.styleFrom(
                      minimumSize: Size(100, pickerHeight),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      backgroundColor: cfg.fontWeightIndex == i
                          ? scheme.primaryContainer
                          : null,
                      foregroundColor: cfg.fontWeightIndex == i
                          ? scheme.onPrimaryContainer
                          : clr,
                      side: BorderSide(
                        color: cfg.fontWeightIndex == i
                            ? scheme.primary
                            : scheme.outlineVariant,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.isZh ? '字 Aa' : 'Aa',
                          style: TextStyle(
                            fontSize: 18,
                            height: 1.25,
                            fontFamily: family,
                            fontWeight: _kFontWeights[i],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${labels[i]} · ${AppConfig.fontWeightValues[i]}',
                          style: const TextStyle(fontSize: 11, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

/// Navigation surface, placement and selection feedback affect different parts
/// of the same controls, so they are configured together.
Widget _buildNavigationAppearance(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final zh = s.isZh;
  return _glass(ctx, state, zh ? '导航与选中样式' : 'Navigation & selection', [
    if (isMobilePlatform) ...[
      _optionRow(
        ctx,
        icon: Icons.vertical_split_outlined,
        label: s.navPlacementLabel,
        scope: s.navPlacementScope,
        value: cfg.mobileNavPlacement,
        items: [
          OptionItem('auto', s.navPlacementAuto, icon: Icons.auto_mode),
          OptionItem(
            'bottom',
            s.navPlacementBottom,
            icon: Icons.align_vertical_bottom,
          ),
          OptionItem(
            'left',
            s.navPlacementLeft,
            icon: Icons.align_horizontal_left,
          ),
          OptionItem(
            'right',
            s.navPlacementRight,
            icon: Icons.align_horizontal_right,
          ),
        ],
        onSelected: (v) => state.updateConfig((c) => c..mobileNavPlacement = v),
      ),
      _styleRow(
        ctx,
        icon: Icons.view_sidebar_outlined,
        label: zh ? '侧边导航样式' : 'Side navigation style',
        value: cfg.navStyle,
        onSelected: (v) => state.updateConfig((c) => c..navStyle = v),
      ),
      _styleRow(
        ctx,
        icon: Icons.crop_landscape_outlined,
        label: s.pillStyleLabel,
        value: cfg.pillStyle,
        onSelected: (v) => state.updateConfig((c) => c..pillStyle = v),
      ),
    ] else
      _styleRow(
        ctx,
        icon: Icons.view_sidebar_outlined,
        label: zh ? '侧栏与顶栏样式' : 'Sidebar and top bar style',
        value: cfg.menuStyle,
        onSelected: (v) => state.updateConfig((c) => c..menuStyle = v),
      ),
    _optionRow(
      ctx,
      menuKey: const ValueKey('settings_selection_indicator_style'),
      icon: Icons.highlight_alt_outlined,
      label: zh ? '选中遮罩' : 'Selection highlight',
      scope: zh
          ? '用于主导航、设置导航和分段选项的选中项'
          : 'Marks the active item in navigation and segmented controls',
      value: cfg.selectionIndicatorStyle,
      items: [
        OptionItem(
          'theme',
          zh ? '主题色' : 'Theme accent',
          icon: Icons.palette_outlined,
        ),
        OptionItem(
          'liquid',
          s.surfaceStyleLiquid,
          icon: Icons.water_drop_outlined,
        ),
        OptionItem(
          'blur',
          zh ? '毛玻璃' : 'Frosted glass',
          icon: Icons.blur_on_outlined,
        ),
        OptionItem('outline', zh ? '描边' : 'Outline', icon: Icons.crop_square),
      ],
      onSelected: (v) =>
          state.updateConfig((c) => c..selectionIndicatorStyle = v),
    ),
    if (isMobilePlatform) ...[
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(zh ? '滑动时自动收起底部导航' : 'Auto-hide bottom navigation'),
        subtitle: Text(zh ? '上滑收起，下滑展开' : 'Swipe up to hide and down to show'),
        value: cfg.navAutoHide,
        onChanged: (v) => state.updateConfig((c) => c..navAutoHide = v),
      ),
      _optionRow(
        ctx,
        icon: Icons.swap_horiz,
        label: s.bottomActionSideLabel,
        scope: s.bottomActionSideScope,
        value: cfg.mobileBottomActionSide,
        items: [
          OptionItem(
            'left',
            s.bottomActionSideLeft,
            icon: Icons.align_horizontal_left,
          ),
          OptionItem(
            'right',
            s.bottomActionSideRight,
            icon: Icons.align_horizontal_right,
          ),
        ],
        onSelected: (v) =>
            state.updateConfig((c) => c..mobileBottomActionSide = v),
      ),
    ],
  ]);
}

/// A settings label and its menu stack when space is limited.
Widget _optionRow(
  BuildContext ctx, {
  Key? menuKey,
  required IconData icon,
  required String label,
  String? scope,
  required String value,
  required List<OptionItem<String>> items,
  required ValueChanged<String> onSelected,
}) {
  final scheme = Theme.of(ctx).colorScheme;
  final heading = Row(
    children: [
      Icon(icon, size: 15, color: scheme.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: scheme.onSurface, fontSize: 13),
            ),
            if (scope != null)
              Text(
                scope,
                style: SettingsTypography.description.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    ],
  );
  final menu = Semantics(
    label: label,
    child: OptionMenuBar<String>(
      key: menuKey,
      value: value,
      items: items,
      triggerHeight: 44,
      triggerMaxLines: 2,
      itemLabelMaxLines: null,
      onChanged: onSelected,
    ),
  );
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = MediaQuery.textScalerOf(context).scale(13);
        final minLabelWidth = unit * 13;
        final menuWidth = unit * 15;
        if (constraints.maxWidth < menuWidth + minLabelWidth + 12) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: [heading, menu],
          );
        }
        return Row(
          spacing: 12,
          children: [
            Expanded(child: heading),
            SizedBox(width: menuWidth, child: menu),
          ],
        );
      },
    ),
  );
}

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
      OptionItem(
        'liquid',
        s.surfaceStyleLiquid,
        icon: Icons.water_drop_outlined,
      ),
      OptionItem('blur', s.glassBlur, icon: Icons.blur_on_outlined),
      OptionItem('gray', s.surfaceStyleGray, icon: Icons.grid_4x4),
    ],
    onSelected: onSelected,
  );
}

void _showWallpaperTooLarge(BuildContext ctx, AppState state) {
  if (!ctx.mounted) return;
  showToast(
    ctx,
    AppStrings.of(state.config.language).bgAnimationTooLarge,
    type: ToastType.warning,
  );
}

Future<void> _pickBackground(BuildContext ctx, AppState state) async {
  final view = View.of(ctx);
  final dpr = view.devicePixelRatio;
  final logical = view.physicalSize / dpr;
  final maxW = (logical.width * dpr).ceil();
  final maxH = (logical.height * dpr).ceil();
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
  );
  if (file == null) return;
  // v13 起 path 由 uri.scheme 推导：只有 file:// 才给真实路径，
  // content:// 这类 SAF URI 天然为 null，不必再比较字符串前缀。
  final path = file.path;
  try {
    if (path == null) {
      // SAF 大文件直接流式落盘，避免 picker.readAsBytes 建立整文件副本。
      final sourceBytes = await file.length();
      if (sourceBytes == null || sourceBytes > _maxWallpaperSourceBytes) {
        final saved = await _saveBackgroundStream(
          file.readAsByteStream(),
          file.name,
        );
        if (saved != null) {
          state.updateConfig((c) => c..backgroundImage = saved);
        }
      } else {
        final saved = await _saveBackgroundBytes(
          await file.readAsBytes(),
          file.name,
          maxW,
          maxH,
        );
        if (saved != null) {
          state.updateConfig((c) => c..backgroundImage = saved);
        }
      }
    } else {
      // 大图自动压缩到屏幕分辨率，避免体积过大导致卡死
      final copied = await _copyBackgroundOptimized(path, maxW, maxH);
      state.updateConfig((c) => c..backgroundImage = copied ?? path);
    }
  } on WallpaperImageTooLargeToResizeException {
    if (ctx.mounted) _showWallpaperTooLarge(ctx, state);
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
  State<_ThemeBackgroundSection> createState() =>
      _ThemeBackgroundSectionState();
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── ① 预览行 ──
        Row(
          children: [
            _bgThumb(context, scheme, cfg.backgroundImage),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.bgCurrent,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.outline,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hasBg ? name : s.bgEmptyHint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: hasBg ? clr : scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ── ② 操作行 ──
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickBackground(context, state),
                icon: Icon(
                  hasBg ? Icons.swap_horiz : Icons.add_photo_alternate_outlined,
                  size: 16,
                ),
                label: Text(
                  hasBg ? s.bgReplace : s.bgChoose,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  side: BorderSide(color: scheme.primary.withAlpha(90)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (hasBg) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    state.updateConfig((c) => c..backgroundImage = ''),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(s.remove),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  side: BorderSide(color: scheme.error.withAlpha(80)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
        Divider(height: 20, color: scheme.outlineVariant.withAlpha(60)),
        // ── ③ 两条不透明度滑块 ──
        // 直接平铺展示（原为「折叠 → 展开」的二级菜单，用户反馈不必要的折叠：
        // 这两个滑块是背景设置的核心项，展开后卡片还会被撑高。
        // 现在卡片高度在一帧内就是最终高度，不再有展开/收起动画）。
        _SettingSlider(
          value: cfg.backgroundOpacity,
          min: 0.0,
          max: 1.0,
          divisions: 100,
          label: (v) => '${s.bgOpacity}: ${(v * 100).round()}%',
          labelStyle: TextStyle(color: clr, fontSize: 11),
          onCommit: (v) => state.updateConfig((c) => c..backgroundOpacity = v),
        ),
        const SizedBox(height: 2),
        _SettingSlider(
          value: cfg.cardOpacity,
          min: 0.0,
          max: 1.0,
          divisions: 100,
          label: (v) => '${s.cardOpacity}: ${(v * 100).round()}%',
          labelStyle: TextStyle(color: clr, fontSize: 11),
          onCommit: (v) => state.updateConfig((c) => c..cardOpacity = v),
        ),
      ],
    );
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
                  disableAnimations: MediaQuery.disableAnimationsOf(context),
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
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.terminal_outlined, color: scheme.primary, size: 22),
      title: Text(
        s.isZh ? '手动执行 FFmpeg 命令' : 'Run custom FFmpeg commands',
        style: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      subtitle: Text(
        s.isZh
            ? '命令输入 + 快捷模板 + 参数参考'
            : 'Manual input + quick templates + parameter reference',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      // CommandPage 自带壁纸与安全区顶栏，不再外层重复包装（见 _mobileToolRow 注释）
      onTap: () => Navigator.of(ctx).push(
        MaterialPageRoute(
          allowSnapshotting: false,
          builder: (_) => const CommandPage(),
        ),
      ),
    ),
  ]);
}

/// 移动端设置 → 工具 → 日志：进入日志页
Widget _buildMobileLogsEntry(BuildContext ctx, AppState state) {
  final scheme = Theme.of(ctx).colorScheme;
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.qLogs, [
    ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.terminal, color: scheme.primary, size: 22),
      title: Text(
        s.isZh ? '查看运行日志' : 'View runtime logs',
        style: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      subtitle: Text(
        s.isZh
            ? '后端输出、FFmpeg 进度与错误信息'
            : 'Backend output, FFmpeg progress and errors',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      // LogPage 自带壁纸与安全区顶栏，不再外层重复包装（见 _mobileToolRow 注释）
      onTap: () => Navigator.of(ctx).push(
        MaterialPageRoute(
          allowSnapshotting: false,
          builder: (_) => const LogPage(),
        ),
      ),
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
      title: Text(
        s.isZh ? '启用预测式返回手势' : 'Enable predictive back gesture',
        style: TextStyle(color: clr, fontSize: 13),
      ),
      subtitle: Text(
        s.predictiveBackHint,
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      value: cfg.predictiveBack,
      onChanged: (v) => state.updateConfig((c) => c..predictiveBack = v),
    ),
  ]);
}

Widget _languageMenu(AppState state, String label) => Semantics(
  label: label,
  child: OptionMenuBar<String>(
    key: const ValueKey('settings_language_menu'),
    value: state.config.language,
    triggerHeight: 44,
    menuWidth: 176,
    items: const [OptionItem('zh', '简体中文'), OptionItem('en', 'English')],
    onChanged: (value) => state.updateConfig((c) => c..language = value),
  ),
);

Widget _buildLanguage(BuildContext ctx, AppState state) {
  final strings = AppStrings.of(state.config.language);
  return _glass(ctx, state, strings.language, [
    Row(
      children: [
        Expanded(child: Text(strings.languageInterface)),
        const SizedBox(width: 12),
        SizedBox(
          width: _kMenuWidth,
          child: _languageMenu(state, strings.languageInterface),
        ),
      ],
    ),
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
        minTileHeight: 48,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.text_fields,
          size: 18,
          applyTextScaling: false,
          color: scheme.onSurfaceVariant,
        ),
        title: Text(
          s.isZh ? '系统字体（默认）' : 'System font (default)',
          style: TextStyle(fontSize: 13, color: clr),
        ),
        trailing: cfg.fontFamily.isEmpty
            ? Icon(
                Icons.check_circle,
                size: 16,
                applyTextScaling: false,
                color: scheme.primary,
              )
            : const SizedBox(width: 16),
        onTap: () => state.updateConfig((c) => c..fontFamily = ''),
      ),
      ListTile(
        dense: true,
        minTileHeight: 48,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.upload_file_outlined,
          size: 18,
          applyTextScaling: false,
          color: scheme.onSurfaceVariant,
        ),
        title: Text(
          s.isZh ? '导入字体' : 'Import font',
          style: TextStyle(fontSize: 13, color: clr),
        ),
        subtitle: cfg.fontFamily.isEmpty
            ? null
            : Text(
                cfg.fontFamily,
                style: SettingsTypography.description.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: cfg.fontFamily.isNotEmpty
            ? Icon(
                Icons.check_circle,
                size: 16,
                applyTextScaling: false,
                color: scheme.primary,
              )
            : Icon(
                Icons.chevron_right,
                size: 16,
                applyTextScaling: false,
                color: scheme.outline,
              ),
        onTap: () => _pickFont(ctx, state),
      ),
      const SizedBox(height: 10),
      _fontWeightPicker(ctx, state, s, scheme),
      _fontPreview(ctx, state),
      const Divider(height: 12, color: Colors.transparent),
      _SettingSlider(
        value: cfg.fontSize,
        min: 10,
        max: 21,
        divisions: 11,
        // liveCommit：拖动过程中整页字号就跟着变（见 _SettingSlider.liveCommit）。
        // 松手才生效时，12~13px 的文字只差 1~2px，用户会以为「滑块没作用」。
        liveCommit: true,
        label: (v) => '${s.fontSize}: ${v.round()}',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..fontSize = v),
      ),
    ]);
  }

  return _glass(ctx, state, s.font, [
    Row(
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: IconTheme.merge(
              data: const IconThemeData(applyTextScaling: false),
              child: FontPicker(
                currentFont: cfg.fontFamily,
                language: cfg.language,
                onSelected: (v) => state.updateConfig((c) => c..fontFamily = v),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: s.isZh ? '导入字体' : 'Import font',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () => _pickFont(ctx, state),
          icon: Icon(
            Icons.upload_file_outlined,
            size: 18,
            applyTextScaling: false,
            color: scheme.primary,
          ),
        ),
      ],
    ),
    const SizedBox(height: 10),
    _SettingSlider(
      value: cfg.fontSize,
      min: 10,
      max: 21,
      divisions: 11,
      liveCommit: true, // 拖动即生效，理由同移动端分支
      label: (v) => '${s.fontSize}: ${v.round()}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..fontSize = v),
    ),
    // 字重：可视化样本（每个「Aa」用对应字重渲染，点选即生效）
    _fontWeightPicker(ctx, state, s, scheme),
    _fontPreview(ctx, state),
  ]);
}

Widget _fontPreview(BuildContext ctx, AppState state) {
  final cfg = state.config;
  return Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Text(
      cfg.language == 'zh'
          ? '字体预览 · 视频与音频\nFont preview 0123456789'
          : 'Font preview · Video & audio\n0123456789',
      style: TextStyle(
        fontSize: 16,
        height: 1.4,
        fontFamily: cfg.fontFamily.isEmpty ? null : cfg.fontFamily,
        fontWeight:
            _kFontWeights[cfg.fontWeightIndex.clamp(
              0,
              _kFontWeights.length - 1,
            )],
      ),
    ),
  );
}

Widget _buildOutput(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.output, [
    _pf(
      ctx,
      s.outputDir,
      cfg.defaultOutputDir,
      (v) => state.updateConfig((c) => c..defaultOutputDir = v),
      () async {
        final d = await pickLocalDirectory();
        if (d != null) state.updateConfig((c) => c..defaultOutputDir = d);
      },
    ),
    const SizedBox(height: 8),
    _pf(
      ctx,
      s.intermediateDir,
      cfg.intermediateDir,
      (v) => state.updateConfig((c) => c..intermediateDir = v),
      () async {
        final d = await pickLocalDirectory();
        if (d != null) state.updateConfig((c) => c..intermediateDir = d);
      },
    ),
    Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        s.intermediateHint,
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    ),
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
        OptionItem(
          0,
          s.isZh ? '节点编辑器' : 'Node Editor',
          icon: Icons.account_tree_outlined,
          subtitle: s.isZh
              ? '蓝图式节点画布，可处理复杂的多步骤逻辑'
              : 'Blueprint-style canvas for complex multi-step logic',
        ),
        OptionItem(
          1,
          s.isZh ? '快速模式' : 'Quick Mode',
          icon: Icons.bolt_outlined,
          subtitle: s.isZh
              ? '选择文件后快速配置处理参数，适配视频/图片/音频'
              : 'Quickly configure processing per file type (video/image/audio)',
        ),
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
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(
          s.isZh ? '节点编辑器横屏' : 'Landscape node editor',
          style: TextStyle(color: clr, fontSize: 13),
        ),
        subtitle: Text(
          s.isZh
              ? '进入节点编辑器时默认横屏显示，画布更宽（移动端）'
              : 'Open the node editor in landscape by default for a wider canvas (mobile)',
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        value: cfg.useNodeEditorLandscape,
        onChanged: (v) =>
            state.updateConfig((c) => c..useNodeEditorLandscape = v),
      ),
      const Divider(height: 4, color: Colors.transparent),
    ],
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        s.isZh ? '启用节点编辑器自动保存' : 'Enable editor autosave',
        style: TextStyle(color: clr, fontSize: 13),
      ),
      subtitle: Text(
        s.isZh
            ? '编辑节点画布时定期保存草稿，异常退出后可恢复'
            : 'Periodically save drafts while editing; restore after abnormal exit',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      value: cfg.autosaveEnabled,
      onChanged: (v) => state.updateConfig((c) => c..autosaveEnabled = v),
    ),
    const SizedBox(height: 6),
    // 左右布局：标签左、下拉右（固定宽度，不再整行拉满）
    Row(
      children: [
        Expanded(
          child: Text(
            s.isZh ? '保存间隔' : 'Save Interval',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: clr, fontSize: 12),
          ),
        ),
        // 「选项文字不跟随应用内字号」（用户要求）：下拉是固定宽度(104)的选项控件，
        // 字号一大，「30 秒 / 不限制」这类文字就被省略号截断。系统字号仍然生效，
        // 见 theme/app_text_scale.dart 的 withoutAppTextScale。
        withoutAppTextScale(
          ctx,
          SizedBox(
            width: 104,
            // 统一下拉样式：OptionMenuBar（圆角 14 浮层 + 200ms 缩放展开），
            // 替代 DropdownButtonFormField 的老式系统下拉。
            child: OptionMenuBar<int>(
              value: cfg.autosaveIntervalSec,
              triggerHeight: 34,
              items: [
                for (final sec in [10, 30, 60, 120, 300])
                  OptionItem(
                    sec,
                    sec < 60
                        ? (s.isZh ? '$sec 秒' : '$sec s')
                        : (s.isZh ? '${sec ~/ 60} 分钟' : '${sec ~/ 60} min'),
                  ),
              ],
              onChanged: (v) =>
                  state.updateConfig((c) => c..autosaveIntervalSec = v),
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: 4),
    Text(
      s.isZh ? '停止操作后多久自动保存一次' : 'How long after edits stop before autosaving',
      style: SettingsTypography.description.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
  ]);
}

Widget _buildShortcuts(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardShortcuts, [
    ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.keyboard, size: 20, color: scheme.primary),
      title: Text(
        s.isZh ? '快捷键配置' : 'Keyboard Shortcuts',
        style: TextStyle(color: clr, fontSize: 13),
      ),
      subtitle: Text(
        s.isZh ? '配置画布和基本操作快捷键' : 'Configure canvas and basic shortcuts',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
      onTap: () => showKeybindingDialog(ctx, isZh: s.isZh),
    ),
  ]);
}

Widget _buildTasks(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  // 二级页「按主题分开」：拆成 ① 并发与解析（性能）② 通知。
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _glass(ctx, state, s.isZh ? '并发与解析' : 'Concurrency & probing', [
        // 左右布局：标签左、下拉右（固定宽度，不再整行拉满）
        Row(
          children: [
            Expanded(
              child: Text(
                s.isZh ? '同时启用任务数' : 'Concurrent Tasks',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: clr, fontSize: 12),
              ),
            ),
            withoutAppTextScale(
              ctx,
              SizedBox(
                width: 104,
                // 统一下拉样式：OptionMenuBar（圆角 14 浮层 + 200ms 缩放展开）
                child: OptionMenuBar<int>(
                  value: cfg.maxConcurrentTasks,
                  triggerHeight: 34,
                  items: [
                    for (var i = 1; i <= 8; i++) OptionItem(i, '$i'),
                    OptionItem(
                      0,
                      s.isZh
                          ? '自动（最多${isMobilePlatform ? 2 : 4}）'
                          : 'Auto (max ${isMobilePlatform ? 2 : 4})',
                    ),
                  ],
                  onChanged: (v) =>
                      state.updateConfig((c) => c..maxConcurrentTasks = v),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          s.isZh
              ? '自动模式按设备限制并发；手动档位最多可设为 8 个任务'
              : 'Auto mode caps concurrency by platform; manual mode allows up to 8 tasks',
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                s.isZh ? '解析线程数' : 'Probe Threads',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: clr, fontSize: 12),
              ),
            ),
            withoutAppTextScale(
              ctx,
              SizedBox(
                width: 104,
                // 统一下拉样式：OptionMenuBar（圆角 14 浮层 + 200ms 缩放展开）
                child: OptionMenuBar<int>(
                  value: cfg.probeThreads,
                  triggerHeight: 34,
                  items: [for (var i = 1; i <= 8; i++) OptionItem(i, '$i')],
                  onChanged: (v) =>
                      state.updateConfig((c) => c..probeThreads = v),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          s.isZh
              ? '添加文件时同时解析的线程数，增大可加快批量导入速度'
              : 'Number of concurrent probe threads when importing files',
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ]),
      const SizedBox(height: 8),
      _glass(ctx, state, s.isZh ? '通知' : 'Notifications', [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            s.isZh ? '任务完成系统通知' : 'Task completion notification',
            style: TextStyle(color: clr, fontSize: 13),
          ),
          subtitle: Text(
            s.isZh
                ? '每个任务完成时发送系统通知'
                : 'Send system notification when each task finishes',
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          value: cfg.enableSystemNotification,
          onChanged: (v) =>
              state.updateConfig((c) => c..enableSystemNotification = v),
        ),
        // 通知健康状态（权限 / 系统开关）：解释「为什么没有通知」并给出补救入口。
        _NotificationHealthTile(clr: clr, scheme: scheme, s: s),
        // ColorOS 流体云：满足条件才显示（见 _buildFluidCloudProgressTile）。
        _buildFluidCloudProgressTile(ctx, state, clr),
        // 小米「超级岛」进度：能力不满足时禁用开关 + 说明原因，不再整体隐藏。
        _IslandProgressTile(clr: clr, scheme: scheme, s: s, state: state),
        // 「发送测试通知」：仅 Android。点击后按当前系统自动选路
        // （澎湃 OS → 小米超级岛 / ColorOS → 流体云 / 其它 → 普通通知），
        // 验证通知能否真正送达 —— MIUI/澎湃 OS 未进白名单时会静默丢弃。
        if (isAndroidPlatform) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _sendTestNotification(ctx, s),
              icon: const Icon(Icons.notification_add, size: 14),
              label: Text(
                s.isZh ? '发送测试通知' : 'Send test notification',
                style: const TextStyle(fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.isZh
                ? '按当前系统自动选路：澎湃 OS → 小米超级岛，ColorOS → 流体云，'
                      '其它 → 普通通知。MIUI/澎湃 OS 需将本应用加入「通知」与'
                      '「自启动」白名单（部分版本需 root），否则通知会被静默丢弃。'
                : 'Routes automatically: HyperOS → Super Island, ColorOS → Fluid '
                      'Cloud, others → plain notification. On MIUI/HyperOS the app '
                      'must be in the notification & autostart whitelists (root may '
                      'be required), otherwise notifications are silently dropped.',
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ]),
    ],
  );
}

/// 「通知」卡片 →「发送测试通知」：调原生按系统选路发送一条测试通知，
/// 并把「走了哪条路」回显出来。返回值见 [AndroidPlatformBridge.testNotification]。
Future<void> _sendTestNotification(BuildContext ctx, AppStrings s) async {
  final path = await AndroidPlatformBridge.testNotification();
  if (!ctx.mounted) return;
  // 无论走哪条路都带白名单引导：MIUI/澎湃 OS 对未进白名单应用的通知是
  // 静默丢弃（不报错），用户只会看到「什么都没发生」。
  final hint = s.isZh
      ? '。若未出现在通知栏/岛上，请在系统设置中将本应用加入「通知」与'
            '「自启动」白名单（部分 MIUI 版本需 root）'
      : '. If nothing appears, add this app to the notification & autostart '
            'whitelists in system settings (root may be required on some MIUI versions)';
  switch (path) {
    case 'island':
      showToast(
        ctx,
        (s.isZh
                ? '已通过小米超级岛发送测试通知'
                : 'Test notification sent via Xiaomi Super Island') +
            hint,
        type: ToastType.success,
      );
    case 'fluidcloud':
      showToast(
        ctx,
        (s.isZh
                ? '已通过 ColorOS 流体云发送测试通知'
                : 'Test notification sent via ColorOS Fluid Cloud') +
            hint,
        type: ToastType.success,
      );
    case 'notification':
      showToast(
        ctx,
        (s.isZh
                ? '已通过普通系统通知发送测试'
                : 'Test notification sent as a plain notification') +
            hint,
        type: ToastType.success,
      );
    case 'no_permission':
      // 通知总开关 / 运行时权限没开：系统会静默丢弃一切通知（超级岛也一样），
      // 必须先去系统设置开启，否则「发了也白发」。
      showToast(
        ctx,
        s.isZh
            ? '系统通知权限未开启：请到 系统设置→通知→FFmpeg++ 允许通知后重试'
            : 'Notifications are disabled for this app: enable them in '
                  'System Settings → Notifications → FFmpeg++, then retry',
        type: ToastType.error,
      );
    default:
      showToast(
        ctx,
        s.isZh
            ? '测试通知发送失败：系统版本过旧或通知被系统拒绝'
            : 'Test notification failed: system too old or notification rejected',
        type: ToastType.error,
      );
  }
}

/// ColorOS 流体云能力状态（进程内只查一次）。与 [_maxRateFuture] 同款
/// 「缓存同一个 Future 实例」手法：FutureBuilder 若在 build 里新建 Future，
/// 会在「完成 → 重建 → 又新建 → 又完成」之间自激循环。
Future<Map<String, Object?>?>? _fluidCloudStatusFuture;

/// 「允许将进度展示在流体云上」（设置→任务→通知，仅 ColorOS）。
///
/// 显示条件（不满足则整个不渲染，连占位高度都不留）：
///  1. ColorOS（含 OnePlus / realme 国行等 oplus 系，原生 SystemProperties 判定）；
///  2. 端侧意图共享 Provider 可达（Android 11+ 包可见性 + 系统支持流体云）。
/// 权限/系统开关层面是否真的能显示，运行时才知道 —— 创卡失败会静默退化，
/// 不影响任务本身（见 services/fluid_cloud_progress.dart）。
Widget _buildFluidCloudProgressTile(
  BuildContext ctx,
  AppState state,
  Color clr,
) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final future = _fluidCloudStatusFuture ??=
      AndroidPlatformBridge.fluidCloudStatus();
  return FutureBuilder<Map<String, Object?>?>(
    future: future,
    builder: (context, snap) {
      final st = snap.data;
      // 非 Android / 非 ColorOS / Provider 不可达 / 尚未查到：一律隐藏。
      if (!shouldShowFluidCloudProgressSetting(st)) {
        return const SizedBox.shrink();
      }
      final integrationConfigured = isFluidCloudIntegrationConfigured(st);
      return SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(
          s.isZh ? '允许将进度展示在流体云上' : 'Show progress in Fluid Cloud',
          style: TextStyle(color: clr, fontSize: 13),
        ),
        subtitle: Text(
          integrationConfigured
              ? (s.isZh
                    ? '转码进行中时，进度以 ColorOS 流体云胶囊/卡片展示'
                    : 'Show transcoding progress as a ColorOS Fluid Cloud capsule')
              : (s.isZh
                    ? '此版本尚未配置 ColorOS 正式接入标识，功能暂不可用'
                    : 'Official ColorOS integration identifiers are not configured for this build.'),
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        value: integrationConfigured && cfg.fluidCloudProgress,
        onChanged: integrationConfigured
            ? (v) => state.updateConfig((c) => c..fluidCloudProgress = v)
            : null,
      );
    },
  );
}

/// 通知健康状态（Android）：把「为什么没有通知」的三个前置条件摊开。
///
/// 背景：Android 13+ 的 POST_NOTIFICATIONS 被拒后 `NotificationManager.notify()`
/// 既不抛异常也不显示，用户只会看到「任务完成了，通知栏里什么都没有」。这里显示
/// 权限与系统总开关，并给出两个**唯一有效**的补救入口：当场请求权限、跳到系统
/// 「应用通知」页；回到前台时会自动重新查询（否则改完权限回来界面还停在旧状态）。
class _NotificationHealthTile extends StatefulWidget {
  const _NotificationHealthTile({
    required this.clr,
    required this.scheme,
    required this.s,
  });

  final Color clr;
  final ColorScheme scheme;
  final AppStrings s;

  @override
  State<_NotificationHealthTile> createState() =>
      _NotificationHealthTileState();
}

class _NotificationHealthTileState extends State<_NotificationHealthTile>
    with WidgetsBindingObserver {
  Map<String, Object?>? _status;
  bool _requesting = false;

  /// 是否已完成首次查询。
  ///
  /// 必须与 `_status == null` 区分开：非 Android 上 `notificationStatus()`
  /// 恒为 null，若只判断 null 就会永远停在「正在检查通知状态…」。
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final st = await AndroidPlatformBridge.notificationStatus();
    if (!mounted) return;
    setState(() {
      _status = st;
      _loading = false;
    });
  }

  Future<void> _request() async {
    setState(() => _requesting = true);
    await AndroidPlatformBridge.requestNotificationPermission();
    if (!mounted) return;
    // 系统对话框刚弹出时权限还没落定：稍等一下再查（回前台也会再刷一次）。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _requesting = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    final s = widget.s;
    final scheme = widget.scheme;
    // 非 Android（查询返回 null）与首次查询中：都不占位。
    if (_loading || st == null) return const SizedBox.shrink();
    final granted = st['postNotificationsGranted'] == true;
    final enabled = st['notificationsEnabled'] == true;

    Widget statusRow(IconData icon, String label, String value, bool good) {
      final color = good ? scheme.primary : scheme.error;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: widget.clr),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          statusRow(
            Icons.shield_outlined,
            s.isZh ? '通知权限（Android 13+）' : 'Notification permission (13+)',
            granted
                ? (s.isZh ? '已允许' : 'Allowed')
                : (s.isZh ? '未允许' : 'Denied'),
            granted,
          ),
          statusRow(
            Icons.notifications_active_outlined,
            s.isZh ? '系统通知开关' : 'System notification switch',
            enabled ? (s.isZh ? '已开启' : 'On') : (s.isZh ? '已关闭' : 'Off'),
            enabled,
          ),
          Wrap(
            spacing: 4,
            children: [
              if (!granted)
                TextButton(
                  onPressed: _requesting ? null : _request,
                  child: Text(
                    _requesting
                        ? (s.isZh ? '请求中…' : 'Requesting…')
                        : (s.isZh ? '请求权限' : 'Grant permission'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              TextButton(
                onPressed: () =>
                    AndroidPlatformBridge.openNotificationSettings(),
                child: Text(
                  s.isZh ? '去系统设置' : 'Open settings',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: _refresh,
                child: Text(
                  s.isZh ? '重新检查' : 'Recheck',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「允许将进度展示在超级岛上」。
///
/// 与旧实现的差别：**能力不满足时不再整体隐藏**，而是禁用开关 + 在副标题里
/// 说明缺哪一项，并给「重新检测」。旧实现只要三项里任一不满足就
/// `SizedBox.shrink()` —— 用户根本不知道有这个功能，也无从知道怎么开。
class _IslandProgressTile extends StatefulWidget {
  const _IslandProgressTile({
    required this.clr,
    required this.scheme,
    required this.s,
    required this.state,
  });

  final Color clr;
  final ColorScheme scheme;
  final AppStrings s;
  final AppState state;

  @override
  State<_IslandProgressTile> createState() => _IslandProgressTileState();
}

class _IslandProgressTileState extends State<_IslandProgressTile> {
  Map<String, Object?>? _status;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    final st = await AndroidPlatformBridge.islandStatus();
    if (!mounted) return;
    setState(() {
      _status = st;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final st = _status;
    // 查询失败或 ROM 不支持时不渲染；只有支持岛的设备才显示其控制项。
    if (!shouldShowSuperIslandProgressSetting(st)) {
      return const SizedBox.shrink();
    }

    final s = widget.s;
    final scheme = widget.scheme;
    final status = st!;
    final supported = status['islandSupported'] == true;
    final protocol = (status['focusProtocolVersion'] as num?)?.toInt() ?? 0;
    final focus = status['hasFocusPermission'] == true;
    final available = supported && protocol >= 3 && focus;

    final String reason;
    if (protocol < 3) {
      reason = s.isZh
          ? '焦点通知协议版本为 $protocol（需要 3 / OS3）'
          : 'Focus protocol is $protocol (OS3 / 3 required)';
    } else {
      reason = s.isZh
          ? '尚未获得「焦点通知」权限：请在系统设置 → 通知 → FFmpeg++ 中开启焦点通知'
          : 'Focus notification permission is off: enable it in System Settings → '
                'Notifications → FFmpeg++';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            s.isZh ? '允许将进度展示在超级岛上' : 'Show progress on Super Island',
            style: TextStyle(color: widget.clr, fontSize: 13),
          ),
          subtitle: Text(
            available
                ? (s.isZh
                      ? '转码进行中时，进度以小米超级岛焦点卡片展示'
                      : 'Show transcoding progress as a Xiaomi Super Island card')
                : reason,
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          value: available && widget.state.config.islandProgress,
          onChanged: available
              ? (v) => widget.state.updateConfig((c) => c..islandProgress = v)
              : null,
        ),
        if (!available)
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () =>
                      AndroidPlatformBridge.openNotificationSettings(),
                  child: Text(
                    s.isZh ? '去系统设置' : 'Open settings',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _refresh,
                  child: Text(
                    s.isZh ? '重新检测' : 'Recheck',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
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
      title: Text(
        s.highRefreshRateLabel,
        style: TextStyle(color: clr, fontSize: 13),
      ),
      subtitle: Text(
        s.highRefreshRateHint,
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
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
          child: Row(
            children: [
              Icon(Icons.speed_outlined, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: SettingsTypography.description.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
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
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        s.isZh ? '关闭预加载' : 'Disable Preload',
        style: TextStyle(color: scheme.onSurface, fontSize: 13),
      ),
      // 文案要与实际被跳过的项目对齐：此前只写了「其他页面切换时才绘制」，
      // 而实测这条开关同时管着字体列表枚举与壁纸解码（见 main.dart 的
      // warmupEnabled），说明与实际不符。
      // 唯一不受它管的是「自定义字体加载」—— 那是功能不是预热，不做就缺字体。
      subtitle: Text(
        s.isZh
            ? '启动时只绘制当前页面：跳过后台页面构建、字体列表枚举与壁纸解码预热。\n注意：首次切换到某个页面时会现场构建，可能短暂增加 CPU 占用。'
            : 'At startup only the current page is drawn: background page builds, font-list enumeration and wallpaper decode are skipped.\nNote: the first visit to a page builds it on the spot, which may briefly raise CPU usage.',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      value: cfg.noPreload,
      onChanged: (v) => state.updateConfig((c) => c..noPreload = v),
    ),
  ]);
}

Widget _buildDebug(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final clr = Theme.of(ctx).colorScheme.onSurface;
  return _glass(ctx, state, s.dDebug, [
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(s.dDebugMode, style: TextStyle(color: clr, fontSize: 13)),
      value: cfg.debugMode,
      onChanged: (v) => state.updateConfig((c) => c..debugMode = v),
    ),
    SwitchListTile(
      key: const ValueKey('settings_very_verbose_logs'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        s.isZh ? '非常详细的日志' : 'Very verbose logs',
        style: TextStyle(color: clr, fontSize: 13),
      ),
      subtitle: Text(
        s.isZh
            ? '在日志页记录底层操作，仅建议调试时开启。'
            : 'Records low-level operations in Logs. Enable only while debugging.',
      ),
      value: cfg.veryVerboseLogs,
      onChanged: (value) => _setVeryVerboseLogs(ctx, state, s, value),
    ),
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(s.dSaveLogs, style: TextStyle(color: clr, fontSize: 13)),
      value: cfg.saveLogs,
      onChanged: (v) => state.updateConfig((c) => c..saveLogs = v),
    ),
    if (cfg.saveLogs)
      _pf(
        ctx,
        s.dLogPath,
        cfg.logSavePath,
        (v) => state.updateConfig((c) => c..logSavePath = v),
        () async {
          final d = await pickLocalDirectory();
          if (d != null) state.updateConfig((c) => c..logSavePath = d);
        },
      ),
    Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton.icon(
        icon: const Icon(Icons.receipt_long_outlined),
        label: Text(s.isZh ? '查看日志' : 'Open logs'),
        onPressed: () => Navigator.of(ctx).push(
          MaterialPageRoute(
            allowSnapshotting: false,
            builder: (_) => const LogPage(),
          ),
        ),
      ),
    ),
  ]);
}

Future<void> _setVeryVerboseLogs(
  BuildContext context,
  AppState state,
  AppStrings strings,
  bool value,
) async {
  if (!value) {
    await state.setVeryVerboseLogs(false);
    return;
  }
  final zh = strings.isZh;
  final confirmed = await showDialog<bool>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dialogContext) => AppAlertDialog(
      title: Text(zh ? '开启非常详细的日志？' : 'Enable very verbose logs?'),
      content: Text(
        zh
            ? '探针会记录大量底层操作，可能增加资源开销和日志体积。除非正在调试，否则不建议开启。'
            : 'Probes record many low-level operations and can increase resource '
                  'usage and log size. Enable this only while debugging.',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(zh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(zh ? '开启' : 'Enable'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await state.setVeryVerboseLogs(true);
  }
}

/// Usage statistics shared by desktop settings and the mobile detail route.
class NodeUsageSettingsCard extends StatelessWidget {
  const NodeUsageSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    // Snapshot derived values: execution can update the existing map in place.
    final (language, types, uses, hasData) = context
        .select<AppState, (String, int, int, bool)>((state) {
          final counts = state.config.nodeUsageCount.values.where((n) => n > 0);
          return (
            state.config.language,
            counts.length,
            counts.fold<int>(0, (sum, count) => sum + count),
            state.config.nodeUsageCount.isNotEmpty,
          );
        });
    final state = context.read<AppState>();
    final zh = AppStrings.of(language).isZh;
    final scheme = Theme.of(context).colorScheme;
    return _glass(context, state, zh ? '节点使用频次' : 'Node usage frequency', [
      Text(
        zh
            ? '统计范围：本机将节点添加至画布的次数（含 AI 与独立窗口新增），按节点类型汇总，用于节点菜单的频次排序。'
            : 'Scope: node additions to the canvas on this device, including AI and '
                  'detached windows. Counts are grouped by type for frequency sorting.',
        key: const ValueKey('node-usage-scope'),
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 10),
      Semantics(
        liveRegion: true,
        child: Text(
          zh
              ? '已记录 $types 种节点，共 $uses 次使用'
              : '$types node ${types == 1 ? 'type' : 'types'} · '
                    '$uses ${uses == 1 ? 'use' : 'uses'}',
          key: const ValueKey('node-usage-summary'),
          style: TextStyle(color: scheme.onSurface, fontSize: 13),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        zh
            ? '仅清除使用次数，保留收藏、最近使用、项目和其他设置。'
            : 'Only usage counts are cleared. Favorites, recent nodes, '
                  'projects and other settings are kept.',
        style: SettingsTypography.description.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          key: const ValueKey('reset-node-usage'),
          onPressed: hasData ? () => _resetNodeUsage(context, state, zh) : null,
          icon: const Icon(Icons.restart_alt, size: 18),
          label: Text(zh ? '重置使用次数' : 'Reset usage counts'),
        ),
      ),
    ]);
  }
}

Future<void> _resetNodeUsage(
  BuildContext context,
  AppState state,
  bool zh,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dialogContext) => AppAlertDialog(
      scrollable: true,
      icon: const Icon(Icons.restart_alt),
      title: Text(zh ? '重置节点使用频次？' : 'Reset node usage frequency?'),
      content: Text(
        zh
            ? '将清除本机记录的全部节点使用次数，之后的使用将重新累计。'
                  '收藏、最近使用、项目和其他设置不会改变。此操作无法撤销。'
            : 'Clear all locally recorded node usage counts and start counting '
                  'again. Favorites, recent nodes, projects and other settings '
                  'will not change. This cannot be undone.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancel-reset-node-usage'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(zh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          key: const ValueKey('confirm-reset-node-usage'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(zh ? '重置' : 'Reset'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await state.updateConfig(
    (config) => config..nodeUsageCount = <String, int>{},
  );
}

Widget _buildCache(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.cardCache, [
    SizedBox(
      width: double.infinity,
      child: Material(
        color: scheme.errorContainer.withAlpha(100),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => _clearCache(ctx, state, scheme, s),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.delete_sweep_rounded, size: 20, color: scheme.error),
                const SizedBox(width: 8),
                Text(
                  s.isZh ? '清除缓存' : 'Clear Cache',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    const SizedBox(height: 6),
    // 说明两个子选项各自的代价：图片/字体删掉要重新导入，导入缓存删掉只是回收空间
    Text(
      s.isZh
          ? '点击后选择：清除「图片 / 字体」，或清除缓存（导入副本、缩略图、帧预览）'
          : 'Choose: clear images/fonts, or clear cache (copies, thumbnails, frame previews)',
      style: TextStyle(fontSize: 10, height: 1.35, color: scheme.outline),
    ),
  ]);
}

/// 打开「广告」三级页面（设置 → 关于 → 广告）。
/// AdsPage 与 CreditsPage 一样自带壁纸与安全区顶栏，这里不再包 SafeArea
/// （外层 SafeArea 会把 MediaQuery.padding.top 清零，顶栏会被状态栏压住）。
void _openAds(BuildContext ctx) {
  Navigator.of(ctx).push(
    MaterialPageRoute(
      allowSnapshotting: false,
      builder: (_) => const AdsPage(),
    ),
  );
}

void _openCredits(BuildContext ctx) {
  // CreditsPage 自带壁纸与安全区顶栏（MobileSubPageTopBar 读取 padding.top），
  // 外层再套 SafeArea 会把 padding.top 清零 → 顶栏被状态栏压住。
  // 桌面端 padding 恒为 0，去掉 SafeArea 无影响。
  Navigator.of(ctx).push(
    MaterialPageRoute(
      allowSnapshotting: false,
      builder: (_) => const CreditsPage(),
    ),
  );
}

/// 关于页展示的编译日期（发布时更新）。
///
/// 抽成常量：此前移动端与桌面端两个分支里各写一份字面量，改一处必漏另一处。
const String kAboutBuildDate = '2026-11-15';

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
    Center(
      child: Column(
        children: [
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(mobile ? 16 : 12),
            child: Image.asset(
              'rele/icon.png',
              width: iconSize,
              height: iconSize,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.play_circle_fill,
                size: iconSize,
                color: scheme.primary,
              ),
            ),
          ),
          SizedBox(height: mobile ? 10 : 8),
          Text(
            'FFmpeg++',
            style: TextStyle(
              fontSize: mobile ? 20 : 16,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            version,
            style: TextStyle(fontSize: mobile ? 13 : 12, color: scheme.outline),
          ),
          const SizedBox(height: 4),
        ],
      ),
    ),
  ]);

  // ── 卡 2：版本与更新 ──
  // 版本信息 / 更新入口 / 外部链接 / 赞助 / 引用 / 广告。
  final String infoTitle = s.isZh ? '版本与更新' : 'Version & Updates';
  final Widget infoCard = mobile
      // 移动端统一用整行可点的 ListTile 形态（副标题写清作用），
      // 「编译日期」是纯信息行，同样用 ListTile 但无 onTap，与相邻行对齐。
      ? _glass(ctx, state, infoTitle, [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline, size: 20, color: scheme.primary),
            title: Text(
              s.aboutVersion,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            trailing: Text(
              version,
              style: TextStyle(
                fontSize: 13,
                color: scheme.outline,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.event_outlined,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              s.aboutBuildDate,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            trailing: Text(
              kAboutBuildDate,
              style: TextStyle(
                fontSize: 13,
                color: scheme.outline,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.system_update_alt,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              s.cardUpdate,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            subtitle: Text(
              s.isZh
                  ? '点按在线检查新版本；长按直达发布页'
                  : 'Tap to check online; long-press to open the release page',
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 16),
            // 移动端也走在线检查：发现新版本弹窗展示（APK 分发，下载动作
            // 自动降级为浏览器打开发布页/下载链接，见 _showUpdateDialog）
            onTap: () => _checkForUpdate(ctx, s),
            onLongPress: () => openExternalUrl(
              'https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases',
            ),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.code, size: 20, color: scheme.primary),
            title: Text(
              s.aboutGithub,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => openExternalUrl(
              'https://github.com/lvbaoshigao/FFmpeg_plus_plus',
            ),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.article_outlined,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              s.aboutBlog,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => openExternalUrl('https://blog-clstone.netlify.app/'),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.volunteer_activism,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              s.aboutSponsor,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showSponsor(ctx, scheme, s),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.favorite_outline,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              s.aboutReferences,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openCredits(ctx),
          ),
          // 广告入口（三级页面）：当前没有广告投放 → 页面显示「哦先生目前并没有放广告」空状态
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.campaign_outlined,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(
              s.isZh ? '广告' : 'Ads',
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            subtitle: Text(
              s.isZh ? '查看广告内容' : 'View sponsored content',
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openAds(ctx),
          ),
        ])
      : _glass(ctx, state, infoTitle, [
          _infoRow(s.aboutVersion, version, scheme),
          _infoRow(s.aboutBuildDate, kAboutBuildDate, scheme),
          _infoRow(s.aboutBlog, 'blog-clstone.netlify.app', scheme),
          _infoRow(
            s.aboutGithub,
            'github.com/lvbaoshigao/FFmpeg_plus_plus',
            scheme,
          ),
          const SizedBox(height: 8),
          // 「检查更新」入口（原独立「更新」卡片已并入这里）：自动检查开关 + 手动检查按钮
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              s.isZh ? '启动时自动检查更新' : 'Auto-check updates on startup',
              style: TextStyle(color: scheme.onSurface, fontSize: 13),
            ),
            subtitle: Text(
              s.isZh
                  ? '静默检查，仅在有新版本时通知'
                  : 'Silent check, notifies only when new version available',
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            value: state.config.autoCheckUpdate,
            onChanged: (v) => state.updateConfig((c) => c..autoCheckUpdate = v),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _iosButton(
                  icon: Icons.volunteer_activism,
                  label: s.aboutSponsorBtn,
                  color: scheme.primary,
                  bg: scheme.primaryContainer,
                  onTap: () => _showSponsor(ctx, scheme, s),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _iosButton(
                  icon: Icons.system_update,
                  label: s.checkUpdate,
                  color: scheme.onSecondaryContainer,
                  bg: scheme.secondaryContainer,
                  onTap: () => _checkForUpdate(ctx, s),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: _iosButton(
              icon: Icons.favorite_outline,
              label: s.aboutReferences,
              color: scheme.onSurface,
              bg: scheme.surfaceContainerHighest.withAlpha(100),
              onTap: () => _openCredits(ctx),
            ),
          ),
          const SizedBox(height: 8),
          // 广告入口（三级页面）：与「引用」同一套按钮/页面样式
          SizedBox(
            width: double.infinity,
            child: _iosButton(
              icon: Icons.campaign_outlined,
              label: s.isZh ? '广告' : 'Ads',
              color: scheme.onSurface,
              bg: scheme.surfaceContainerHighest.withAlpha(100),
              onTap: () => _openAds(ctx),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _link(s.aboutBlogLink, 'https://blog-clstone.netlify.app/'),
              _link(
                'GitHub',
                'https://github.com/lvbaoshigao/FFmpeg_plus_plus',
              ),
            ],
          ),
        ]);

  // 两张卡纵向排布。**必须** CrossAxisAlignment.stretch：默认的 center 会让
  // 每张卡各取自身固有宽度 —— 卡 2 内容多、卡 1 内容少，宽度就对不上，
  // 而「两张卡宽度保持一致」正是本次改造的硬要求。
  // 两张 _glass 之间自己补 12 的间距：网格的 runSpacing 只作用在网格项之间，
  // 不会管网格项内部的这两张卡。
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [headerCard, const SizedBox(height: 12), infoCard],
  );
}

/// 对 AiProfile 应用供应商预设（一键填充端点/模型/上下文）。
/// 公开供移动端提供商详情页复用。
void applyProfilePreset(AiProfile c, String preset) {
  // Presets configure endpoints only. Model IDs must be explicitly fetched or entered by the user.
  void pickModel() {
    c.model = c.models.isNotEmpty ? c.models.first.id : '';
  }

  switch (preset) {
    case 'openai':
      c.provider = 'openai';
      c.apiUrl = 'https://api.openai.com/v1';
      c.apiPath = '/chat/completions';
      c.useResponsesApi = false;
      pickModel();
      c.contextWindow = 128000;
    case 'anthropic':
      c.provider = 'anthropic';
      c.apiUrl = 'https://api.anthropic.com/v1';
      c.apiPath = '/messages';
      c.useResponsesApi = false;
      pickModel();
      c.contextWindow = 200000;
    case 'deepseek':
      c.provider = 'openai';
      c.apiUrl = 'https://api.deepseek.com/v1';
      c.apiPath = '/chat/completions';
      c.useResponsesApi = false;
      pickModel();
      c.contextWindow = 64000;
    case 'ollama':
      c.provider = 'openai';
      c.apiUrl = 'http://localhost:11434/v1';
      c.apiPath = '/chat/completions';
      c.useResponsesApi = false;
      pickModel();
      c.contextWindow = 8192;
  }
}

/// 右侧配置详情：编辑选中配置的全部字段（含供应商预设）。
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
  final baseUrl = cfg.aiApiUrl.replaceAll(
    RegExp(r'/chat/completions$|/messages$'),
    '',
  );
  final modelsUrl = baseUrl.endsWith('/v1')
      ? '$baseUrl/models'
      : '$baseUrl/v1/models';
  final span = state.diagnosticTrace.begin(
    'ai.ping',
    details: {
      'protocol': cfg.aiProvider == 'anthropic' ? 'anthropic' : 'openai',
    },
  );
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
    final resp = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 10));
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    final ok = resp.statusCode >= 200 && resp.statusCode < 400;
    span?.finish(success: ok, details: {'httpStatus': resp.statusCode});
    state.addLog(
      '[AI] Ping ${ok ? "OK" : "FAIL"}: ${resp.statusCode}, ${ms}ms',
      category: ok ? 'info' : 'error',
    );
    if (ctx.mounted) {
      showToast(
        ctx,
        ok
            ? '${resp.statusCode} OK — ${ms}ms'
            : 'HTTP ${resp.statusCode} ${_httpReason(resp.statusCode)}',
        type: ok ? ToastType.success : ToastType.error,
      );
    }
  } catch (e) {
    span?.finish(success: false, error: e);
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
Future<void> listAiModels(
  BuildContext ctx,
  AppState state,
  AppStrings s, {
  required ValueChanged<String> onPicked,
  ValueChanged<List<String>>? onListed,
}) async {
  final cfg = state.config;
  if (cfg.aiApiKey.isEmpty) {
    if (ctx.mounted) showToast(ctx, s.aiNotConfigured, type: ToastType.warning);
    return;
  }
  final span = state.diagnosticTrace.begin(
    'ai.models',
    details: {
      'protocol': cfg.aiProvider == 'anthropic' ? 'anthropic' : 'openai',
    },
  );
  state.addLog('[AI] 获取模型列表...', category: 'info');
  try {
    final headers = <String, String>{};
    if (cfg.aiProvider == 'anthropic') {
      final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/messages$'), '');
      final modelsUrl = baseUrl.endsWith('/v1')
          ? '$baseUrl/models'
          : '$baseUrl/v1/models';
      headers['x-api-key'] = cfg.aiApiKey;
      headers['anthropic-version'] = '2023-06-01';
      final resp = await http
          .get(Uri.parse(modelsUrl), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final models =
            (data['data'] as List?)?.map((m) => m['id'] as String).toList() ??
            [];
        models.sort();
        span?.finish(
          success: true,
          details: {'httpStatus': resp.statusCode, 'itemCount': models.length},
        );
        state.addLog(
          '[AI] Anthropic 获取到 ${models.length} 个模型',
          category: 'info',
        );
        onListed?.call(models);
        if (ctx.mounted) _showModelPicker(ctx, state, models, s, onPicked);
      } else {
        state.addLog(
          '[AI] Anthropic models endpoint unavailable (${resp.statusCode}), using known models',
          category: 'info',
        );
        final known = List.of(_kKnownAnthropicModels);
        span?.finish(
          success: false,
          details: {
            'httpStatus': resp.statusCode,
            'fallback': true,
            'itemCount': known.length,
          },
        );
        onListed?.call(known);
        if (ctx.mounted) _showModelPicker(ctx, state, known, s, onPicked);
      }
      return;
    }
    // OpenAI-compatible: GET /v1/models
    final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/chat/completions$'), '');
    headers['Authorization'] = 'Bearer ${cfg.aiApiKey}';
    final resp = await http
        .get(Uri.parse('$baseUrl/models'), headers: headers)
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      final models =
          (data['data'] as List?)?.map((m) => m['id'] as String).toList() ?? [];
      models.sort();
      span?.finish(
        success: true,
        details: {'httpStatus': resp.statusCode, 'itemCount': models.length},
      );
      state.addLog('[AI] 获取到 ${models.length} 个模型', category: 'info');
      onListed?.call(models);
      if (ctx.mounted) _showModelPicker(ctx, state, models, s, onPicked);
    } else {
      span?.finish(success: false, details: {'httpStatus': resp.statusCode});
      state.addLog('[AI] 获取模型失败: ${resp.statusCode}', category: 'error');
      if (ctx.mounted) {
        showToast(ctx, 'HTTP ${resp.statusCode}', type: ToastType.error);
      }
    }
  } catch (e) {
    span?.finish(success: false, error: e);
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
Future<String?> fetchAiBalance(
  AiProfile profile, {
  DiagnosticTrace? trace,
}) async {
  final span = trace?.begin(
    'ai.balance',
    details: {
      'protocol': profile.provider == 'anthropic' ? 'anthropic' : 'openai',
    },
  );
  try {
    final result = await _fetchAiBalance(profile, span);
    span?.finish(success: result != null);
    return result;
  } catch (error) {
    span?.finish(success: false, error: error);
    rethrow;
  }
}

Future<String?> _fetchAiBalance(AiProfile profile, DiagnosticSpan? span) async {
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
        .get(
          Uri.parse('$base/dashboard/billing/credit_grants'),
          headers: headers,
        )
        .timeout(timeout);
    span?.record(
      'ai.balance.endpoint',
      details: {'endpoint': 'credit_grants', 'httpStatus': resp.statusCode},
    );
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final total = (data['total_granted'] as num?)?.toDouble();
      final used = (data['total_used'] as num?)?.toDouble();
      final available = (data['total_available'] as num?)?.toDouble();
      if (available != null || total != null) {
        final parts = <String>[];
        if (available != null) {
          parts.add('可用 \$${available.toStringAsFixed(2)}');
        }
        if (used != null) parts.add('已用 \$${used.toStringAsFixed(2)}');
        if (total != null) parts.add('总额 \$${total.toStringAsFixed(2)}');
        return parts.join(' · ');
      }
    }
  } catch (error) {
    span?.record(
      'ai.balance.endpoint',
      details: {
        'endpoint': 'credit_grants',
        'failureType': error.runtimeType.toString(),
      },
    );
    // 端点不存在/网络问题 → 继续尝试下一个
  }

  // 2) one-api / new-api 面板的 /user/info（quota 单位为 500000 = $1）
  try {
    final resp = await http
        .get(Uri.parse('$base/user/info'), headers: headers)
        .timeout(timeout);
    span?.record(
      'ai.balance.endpoint',
      details: {'endpoint': 'user_info', 'httpStatus': resp.statusCode},
    );
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
  } catch (error) {
    span?.record(
      'ai.balance.endpoint',
      details: {
        'endpoint': 'user_info',
        'failureType': error.runtimeType.toString(),
      },
    );
    // 同上
  }

  return null;
}

void _showModelPicker(
  BuildContext ctx,
  AppState state,
  List<String> models,
  AppStrings s,
  ValueChanged<String> onPicked,
) {
  if (models.isEmpty) {
    showToast(
      ctx,
      s.isZh ? '未找到模型' : 'No models found',
      type: ToastType.warning,
    );
    return;
  }
  showDialog(
    context: ctx,
    animationStyle: MediaQuery.disableAnimationsOf(ctx)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dCtx) {
      final scheme = Theme.of(dCtx).colorScheme;
      return AppAlertDialog(
        title: Text(
          s.aiListModels,
          style: TextStyle(color: scheme.onSurface, fontSize: 15),
        ),
        content: SizedBox(
          width: 300,
          height: 400,
          child: ListView.builder(
            itemCount: models.length,
            itemBuilder: (_, i) => ListTile(
              dense: true,
              title: Text(
                models[i],
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
              ),
              selected: models[i] == state.config.aiModel,
              selectedTileColor: scheme.primaryContainer.withAlpha(60),
              onTap: () {
                state.addLog('[AI] 已选择模型: ${models[i]}', category: 'info');
                Navigator.pop(dCtx);
                onPicked(models[i]);
                showToast(
                  ctx,
                  '${s.isZh ? "已选择" : "Selected"}: ${models[i]}',
                  type: ToastType.success,
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(s.close),
          ),
        ],
      );
    },
  );
}

Future<void> _pickFont(BuildContext ctx, AppState state) async {
  final isZh = state.config.language == 'zh';
  // Android：SAF/content:// URI 常常拿不到真实磁盘路径（path 为 null），
  // 必须同时取内存字节兜底 —— 之前只认 path，HyperOS/MIUI 上会出现
  // 「选了字体却毫无反应」的静默失败。
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['ttf', 'otf'],
  );
  if (picked == null) return;
  final fileName = picked.name;
  if (!fileName.toLowerCase().endsWith('.ttf') &&
      !fileName.toLowerCase().endsWith('.otf')) {
    if (ctx.mounted) {
      showToast(
        ctx,
        isZh ? '请选择 .ttf 或 .otf 字体文件' : 'Please pick a .ttf/.otf font file',
        type: ToastType.error,
      );
    }
    return;
  }
  final fontName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  // 落盘目录必须先确定：_ensureAndroidAppDir 是 initState 里 fire-and-forget 的，
  // 之前这里不 await，一旦它还没解析完就把字体写进了 systemTemp/FFmpeg++/fonts
  // （安卓上即应用缓存目录），而启动加载只认「应用文档目录/FFmpeg++/fonts」
  // → 表现为「导入的字体重启后不见了」（用户反馈的「导入后不显示」）。
  await _ensureAndroidAppDir();
  try {
    // 1) 取得字体字节：优先磁盘路径，content:// 等非 file:// 用内存字节
    String? srcPath = picked.path;
    if (srcPath != null && !await File(srcPath).exists()) srcPath = null;
    // v13：content:// 等来源的 path 恒为 null，只能走 readAsBytes()；
    // 两者都可能抛异常（权限/IO），由外层 catch 统一报「字体加载失败」。
    final Uint8List bytes = srcPath != null
        ? await File(srcPath).readAsBytes()
        : await picked.readAsBytes();
    // 2) 先落盘到应用数据目录 fonts/（重启后由 main.dart 重新加载）
    String? fontFilePath;
    if (srcPath != null) {
      fontFilePath = await _copyToAppDir(srcPath, 'fonts');
    }
    if (fontFilePath == null) {
      // 字节来源或复制失败：手动写入
      final dir = Directory(
        '${_userDataDir()}$_s'
        'fonts',
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      fontFilePath = '${dir.path}$_s$fileName';
      await File(fontFilePath).writeAsBytes(bytes, flush: true);
    }
    // 3) 注册进引擎并应用（FontLoader 注册的族名 = 文件名去扩展名）
    final fontLoader = FontLoader(fontName);
    fontLoader.addFont(Future.value(ByteData.sublistView(bytes)));
    await fontLoader.load();
    state.updateConfig((c) => c..fontFamily = fontName);
    if (ctx.mounted) {
      showToast(
        ctx,
        isZh ? '字体 "$fontName" 已加载并应用' : 'Font "$fontName" loaded and applied',
        type: ToastType.success,
      );
    }
  } catch (e) {
    // 加载失败不设置 fontFamily（否则全局文本回退到坏字体）
    if (ctx.mounted) {
      showToast(
        ctx,
        isZh ? '字体加载失败: $e' : 'Font load failed: $e',
        type: ToastType.error,
      );
    }
  }
}

/// 「清除缓存」的两个子选项（用户要求点按钮后先让用户选清哪一类）。
///
/// 两件事的代价完全不同，混在一起做并不合适：
/// * [assets] —— 删掉已导入的字体文件与背景图片，**之后要重新导入**；
/// * [caches] —— 删掉导入副本（file_picker 副本 / ffmpegpp_import_* / 缩略图 /
///   帧预览与整帧临时图），只是回收空间，项目内容不受影响，大文件可能释放几百 MB。
enum _CacheScope {
  /// 只清除已导入的字体文件与背景图片
  assets,

  /// 只清除导入缓存（不含字体与背景图片）
  caches,
}

/// 「清除缓存」入口：先弹出两个子选项，再执行对应清理。
Future<void> _clearCache(
  BuildContext ctx,
  AppState state,
  ColorScheme scheme,
  AppStrings s,
) async {
  final scope = await showDialog<_CacheScope>(
    context: ctx,
    animationStyle: MediaQuery.disableAnimationsOf(ctx)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dCtx) => AppAlertDialog(
      scrollable: true,
      icon: Icon(Icons.cleaning_services_outlined, color: scheme.primary),
      title: Text(
        s.isZh ? '清除缓存' : 'Clear Cache',
        style: TextStyle(color: scheme.onSurface),
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
                ? '删除导入副本（大文件可能占几百 MB）、缩略图与帧预览临时图；\n'
                      '仍被项目 / 队列引用的副本会保留'
                : 'Delete import copies (hundreds of MB possible), thumbnails and frame previews;\n'
                      'copies still referenced by projects/queue are kept',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dCtx),
          child: Text(s.isZh ? '取消' : 'Cancel'),
        ),
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
        showToast(
          ctx,
          s.isZh
              ? '已清除导入的图片和字体$freedText'
              : 'Images and fonts cleared$freedText',
          type: ToastType.success,
        );
      }
      return;
    }

    // ── 分支二：只清导入缓存 ──
    final freed = await state.purgeImportCachesNow();
    if (ctx.mounted) {
      final freedText = freed > 0 ? '（释放 ${_humanSize(freed)}）' : '';
      showToast(
        ctx,
        s.isZh ? '缓存已清除$freedText' : 'Cache cleared$freedText',
        type: ToastType.success,
      );
    }
  } catch (e) {
    if (ctx.mounted) {
      showToast(
        ctx,
        s.isZh ? '清除失败: $e' : 'Clear failed: $e',
        type: ToastType.error,
      );
    }
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.35,
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
        removedFonts.add(
          f.path
              .split(RegExp(r'[\\/]'))
              .last
              .replaceAll(RegExp(r'\.[^.]+$'), ''),
        );
      }
      try {
        freed += f.lengthSync();
        f.deleteSync();
      } catch (_) {}
    }
  }
  state.updateConfig((c) {
    c.backgroundImage = '';
    if (removedFonts.contains(c.fontFamily)) {
      c.fontFamily = AppConfig.defaultFontFamily;
    }
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
  final result = await updater.checkForUpdate(
    preferLanzou: s.isZh,
    trace: ctx.read<AppState>().diagnosticTrace,
  );
  if (!ctx.mounted) return;
  if (result.error != null && !result.hasUpdate) {
    showToast(ctx, s.updateFailed, type: ToastType.error);
    return;
  }
  if (!result.hasUpdate) {
    showToast(
      ctx,
      '${s.alreadyLatest} (v${updater.currentVersion})',
      type: ToastType.success,
    );
    return;
  }
  _showUpdateDialog(ctx, s, result);
}

void _showUpdateDialog(
  BuildContext ctx,
  AppStrings s,
  updater.UpdateResult result,
) {
  final scheme = Theme.of(ctx).colorScheme;
  // 移动端为 APK 分发：桌面那套「下载 exe + 替换重启」不适用，
  // 一律走「前往下载」（浏览器打开发布页/下载链接）。
  final allowAutoUpdate =
      !isMobilePlatform &&
      result.source == updater.UpdateSource.github &&
      result.downloadUrl != null;
  showDialog(
    context: ctx,
    animationStyle: MediaQuery.disableAnimationsOf(ctx)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dCtx) => AppAlertDialog(
      scrollable: true,
      icon: Icon(Icons.system_update, color: scheme.primary, size: 32),
      title: Text(s.updateAvailable, style: TextStyle(color: scheme.onSurface)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.isZh
                  ? '新版本: v${result.remoteVersion}\n当前版本: v${updater.currentVersion}'
                  : 'New: v${result.remoteVersion}\nCurrent: v${updater.currentVersion}',
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            if (result.password != null && result.password!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.key, size: 14, color: scheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    s.isZh ? '提取密码: ' : 'Password: ',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SelectableText(
                    result.password!,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              s.isZh ? '更新日志:' : 'Release Notes:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            if (result.releaseNotes != null && result.releaseNotes!.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(
                    result.releaseNotes!,
                    style: TextStyle(fontSize: 11, color: scheme.onSurface),
                  ),
                ),
              )
            else
              Text(
                result.releaseNotesError
                    ? (s.isZh
                          ? '无法获取更新日志 (GitHub 连接失败)'
                          : 'Failed to get release notes (GitHub connection failed)')
                    : (s.isZh ? '暂无更新日志' : 'No release notes available'),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.outline,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dCtx),
          child: Text(s.aboutClose),
        ),
        if (allowAutoUpdate)
          FilledButton(
            onPressed: () {
              Navigator.pop(dCtx);
              _downloadAndInstall(
                ctx,
                s,
                result.downloadUrl!,
                result.downloadSha256,
              );
            },
            child: Text(s.isZh ? '自动更新' : 'Auto Update'),
          )
        else
          FilledButton(
            onPressed: () {
              Navigator.pop(dCtx);
              openExternalUrl(
                result.downloadUrl ??
                    'https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases/latest',
              );
            },
            child: Text(s.goDownload),
          ),
      ],
    ),
  );
}

Future<void> _downloadAndInstall(
  BuildContext ctx,
  AppStrings s,
  String url, [
  String? expectedSha256,
]) async {
  final scheme = Theme.of(ctx).colorScheme;
  final trace = ctx.read<AppState>().diagnosticTrace;
  final progressNotifier = ValueNotifier<double>(0);
  final statusNotifier = ValueNotifier<String>(
    s.isZh ? '准备下载...' : 'Preparing...',
  );
  var dialogOpen = true;
  showDialog(
    context: ctx,
    animationStyle: MediaQuery.disableAnimationsOf(ctx)
        ? AnimationStyle.noAnimation
        : null,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AppAlertDialog(
        title: Text(
          s.isZh ? '下载更新' : 'Downloading Update',
          style: TextStyle(color: scheme.onSurface),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: progressNotifier,
              // 统一进度条：与全应用滑动条同一规格（圆角轨道 + 主题色）
              builder: (_, v, _) => AppProgressBar(value: v > 0 ? v : null),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: statusNotifier,
              builder: (_, v, _) => Text(
                v,
                style: SettingsTypography.description.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(() => dialogOpen = false);
  try {
    final filePath = await updater.downloadUpdate(
      url,
      trace: trace,
      onProgress: (received, total) {
        if (total > 0) {
          progressNotifier.value = received / total;
          statusNotifier.value =
              '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
        }
      },
      expectedSha256: expectedSha256,
    );
    if (!ctx.mounted) return;
    // 未提供校验文件时给出明确警示，避免用户误以为已做过完整性校验（H-4）
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      showToast(
        ctx,
        s.isZh
            ? '提示：发布方未提供 SHA-256，安装包未做完整性校验'
            : 'Note: publisher provided no SHA-256; package integrity was not verified',
        type: ToastType.warning,
      );
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
  final res = await showThemeColorPicker(
    ctx,
    initial: Color(state.config.themeColor),
    initial2: state.config.themeColor2 >= 0
        ? Color(state.config.themeColor2)
        : null,
    isZh: isZh,
    useBottomSheet: isMobilePlatform,
  );
  if (res == null) return;
  state.updateConfig(
    (c) => c
      ..themeColor = res.c1
      ..themeColor2 = res.c2 ?? -1,
  );
}

void _showSponsor(BuildContext ctx, ColorScheme scheme, AppStrings s) {
  showDialog(
    context: ctx,
    animationStyle: MediaQuery.disableAnimationsOf(ctx)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dCtx) => AppAlertDialog(
      title: Text(
        s.aboutSponsor,
        style: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.aboutThanks,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
            const SizedBox(height: 12),
            Text(
              s.aboutZoomHint,
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: _qrImage(ctx, 'rele/wx.png', s.aboutWxTitle, scheme),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _qrImage(ctx, 'rele/zfb.jpg', s.aboutZfbTitle, scheme),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dCtx),
          child: Text(s.aboutClose),
        ),
      ],
    ),
  );
}

Widget _qrImage(
  BuildContext ctx,
  String asset,
  String label,
  ColorScheme scheme,
) => GestureDetector(
  onTap: () => _showFullImage(ctx, asset, scheme),
  child: Column(
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        // 缩略图固定高 160 逻辑像素，而 wx.png / zfb.jpg 是 1220x1563 / 1170x1755
        // 的原图 —— 不设 cacheHeight 会按原始分辨率解码（单张约 7~8MB RGBA，
        // 且 Image.asset 不会自动套 ResizeImage）。全屏查看走 _showFullImage，
        // 那条路径刻意不设 cap，以保留 InteractiveViewer 4x 缩放的清晰度。
        child: Image.asset(
          asset,
          height: 160,
          cacheHeight: (160 * MediaQuery.devicePixelRatioOf(ctx)).round(),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Container(
            height: 160,
            alignment: Alignment.center,
            child: Text('加载失败', style: TextStyle(color: scheme.outline)),
          ),
        ),
      ),
    ],
  ),
);

void _showFullImage(BuildContext ctx, String asset, ColorScheme scheme) {
  showDialog(
    context: ctx,
    animationStyle: MediaQuery.disableAnimationsOf(ctx)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dCtx) => Dialog(
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        onTap: () => Navigator.pop(dCtx),
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              asset,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Container(
                padding: const EdgeInsets.all(32),
                child: Text('加载失败', style: TextStyle(color: scheme.outline)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
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
  void initState() {
    super.initState();
    _syncState();
  }

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
    widget.state.addLog(
      _found ? 'FFmpeg detected: $_version' : 'FFmpeg not found',
      category: _found ? 'ffmpeg' : 'error',
    );
  }

  Future<void> _browseFfmpeg() async {
    final isZh = widget.state.config.language == 'zh';
    final picked = await FilePicker.pickFile(
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? ['exe'] : null,
      dialogTitle: isZh ? '选择 ffmpeg' : 'Select ffmpeg',
    );
    final exePath = picked?.path;
    if (exePath == null) return;
    setState(() => _checking = true);
    try {
      final result = await Process.run(exePath, [
        '-version',
      ], runInShell: false);
      if (result.exitCode == 0 &&
          result.stdout.toString().contains('ffmpeg version')) {
        final versionLine = result.stdout.toString().split('\n').first;
        final dir = exePath.replaceAll(RegExp(r'[\\/][^\\/]+$'), '');
        final ffprobeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
        if (!mounted) return;
        setState(() {
          _found = true;
          _version = versionLine;
          _path = exePath;
          _checking = false;
        });
        widget.state.updateConfig(
          (c) => c
            ..ffmpegPath = exePath
            ..ffprobePath = '$dir${Platform.pathSeparator}$ffprobeName',
        );
        widget.state.backend.setPaths(
          ffmpeg: exePath,
          ffprobe: '$dir${Platform.pathSeparator}$ffprobeName',
        );
        if (Platform.isWindows) await _addToPath(dir);
        widget.state.addLog('FFmpeg configured: $_version', category: 'ffmpeg');
        if (mounted) {
          showToast(context, 'FFmpeg found at: $dir', type: ToastType.success);
        }
      } else {
        if (!mounted) return;
        setState(() => _checking = false);
        showToast(
          context,
          isZh ? '所选文件不是有效的 ffmpeg' : 'Selected file is not a valid ffmpeg',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      showToast(
        context,
        isZh ? '检测失败: $e' : 'Detection failed: $e',
        type: ToastType.error,
      );
    }
  }

  Future<void> _addToPath(String dir) async {
    if (!Platform.isWindows) return;
    final isZh = widget.state.config.language == 'zh';
    try {
      final regResult = await Process.run('cmd', ['/c', 'echo %PATH%']);
      if (regResult.stdout.toString().contains(dir)) return;
      final regResult2 = await Process.run('reg', [
        'query',
        r'HKCU\Environment',
        '/v',
        'Path',
      ]);
      var existingPath = '';
      if (regResult2.exitCode == 0) {
        for (final line in regResult2.stdout.toString().split('\n')) {
          if (line.contains('Path') && line.contains('REG_')) {
            existingPath = line
                .split('REG_')
                .last
                .trim()
                .replaceFirst(RegExp(r'^\w+\s+'), '');
            break;
          }
        }
      }
      existingPath = existingPath.trim();
      if (existingPath.contains(dir)) return;
      // 只有 reg 查询成功且现有 PATH 非空时才追加；否则跳过，避免覆盖用户 PATH
      if (regResult2.exitCode != 0 || existingPath.isEmpty) {
        if (mounted) {
          showToast(
            context,
            isZh
                ? '读取 PATH 失败，已跳过添加到系统 PATH'
                : 'Failed to read PATH, skipped adding',
            type: ToastType.error,
          );
        }
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
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "[Environment]::SetEnvironmentVariable('Path','$escaped','User')",
      ]);
      if (ps.exitCode != 0) {
        throw Exception('设置用户 PATH 失败: ${ps.stderr}');
      }
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          isZh ? '添加到系统 PATH 失败: $e' : 'Failed to add to PATH: $e',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _confirmDelete(bool isZh) async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (ctx) {
        final s = Theme.of(ctx).colorScheme;
        return AppAlertDialog(
          icon: Icon(Icons.delete_forever, color: s.error, size: 32),
          title: Text(isZh ? '删除 FFmpeg' : 'Delete FFmpeg'),
          content: Text(
            isZh
                ? '将删除程序目录下的 ffmpeg.exe 和 ffprobe.exe，确定？'
                : 'Delete ffmpeg.exe and ffprobe.exe from the app directory?',
            style: TextStyle(fontSize: 13, color: s.onSurface),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: s.error,
                foregroundColor: s.onError,
              ),
              child: Text(isZh ? '删除' : 'Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    FfmpegInstaller.uninstall();
    widget.state.updateConfig(
      (c) => c
        ..ffmpegPath = ''
        ..ffprobePath = '',
    );
    setState(() {
      _found = false;
      _version = '';
      _path = '';
    });
    widget.state.addLog('已删除程序目录下的 FFmpeg', category: 'info');
    if (mounted) {
      showToast(
        context,
        isZh ? 'FFmpeg 已删除' : 'FFmpeg deleted',
        type: ToastType.info,
      );
    }
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
        Row(
          children: [
            Icon(
              Icons.check_circle,
              size: 16,
              color: _found ? scheme.sem.success : scheme.sem.warning,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _found
                    ? s.ffmpegFound
                    : (isZh ? '内置 FFmpeg 加载中…' : 'Bundled FFmpeg loading…'),
                style: TextStyle(
                  fontSize: 13,
                  color: _found ? scheme.sem.success : scheme.sem.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (_version.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text(
              _version,
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_path.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              _path,
              style: TextStyle(
                fontSize: 9,
                color: scheme.outline.withAlpha(150),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                label: Text(s.recheck, style: const TextStyle(fontSize: 11)),
                onPressed: _detect,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isZh
              ? '移动端已内置 FFmpeg 库，无需额外安装'
              : 'FFmpeg is bundled with the app on mobile — no installation needed',
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ]);
    }

    if (!_found && !_checking) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        Center(
          child: Column(
            children: [
              Icon(Icons.warning_amber, size: 32, color: scheme.sem.warning),
              const SizedBox(height: 8),
              Text(
                s.ffmpegNotFound,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.sem.warning,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.download, size: 18),
                label: Text(
                  isZh ? '自动安装 FFmpeg' : 'Install FFmpeg',
                  style: const TextStyle(fontSize: 13),
                ),
                onPressed: () async {
                  final ok = await FfmpegInstallDialog.show(context);
                  if (ok == true) _detect();
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.search, size: 16),
                    label: Text(
                      isZh ? '检测' : 'Detect',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: _detect,
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open, size: 14),
                    label: Text(
                      isZh ? '手动选择' : 'Manual',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: _browseFfmpeg,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: _ffmpegLinks,
        ),
      ]);
    }

    if (_checking) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        const SizedBox(height: 12),
        const Center(child: AppCircularProgressIndicator()),
        const SizedBox(height: 8),
        Center(
          child: Text(
            isZh ? '正在检测...' : 'Detecting...',
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ]);
    }

    final isBundled =
        FfmpegInstaller.isInstalled &&
        _path.isNotEmpty &&
        _path.startsWith(Directory(Platform.resolvedExecutable).parent.path);
    return _glass(context, widget.state, s.ffmpegSettings, [
      Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: scheme.sem.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.ffmpegFound,
              style: TextStyle(
                fontSize: 13,
                color: scheme.sem.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      if (_version.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Text(
            _version,
            style: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (_path.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            _path,
            style: TextStyle(fontSize: 9, color: scheme.outline.withAlpha(150)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 14),
              label: Text(s.recheck, style: const TextStyle(fontSize: 11)),
              onPressed: _detect,
            ),
          ),
          if (isBundled) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: Icon(Icons.delete_outline, size: 14, color: scheme.error),
              label: Text(
                isZh ? '删除' : 'Delete',
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: scheme.error.withAlpha(120)),
              ),
              onPressed: () => _confirmDelete(isZh),
            ),
          ],
        ],
      ),
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

class _PathField extends StatefulWidget {
  final String value;
  final String label;
  final ColorScheme scheme;
  final ValueChanged<String> onChange;
  const _PathField({
    required this.value,
    required this.label,
    required this.scheme,
    required this.onChange,
  });
  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(_PathField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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
