import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart' show smoothRoute;
import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../services/directory_picker.dart';
import '../services/fppx2_service.dart';
import '../services/quick_config_pipeline.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_strings.dart';
import '../widgets/adaptive_top_bar.dart';
import '../widgets/app_alert_dialog.dart';
import '../widgets/container_card.dart';
import '../widgets/fppx_password.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
// 生效的菜单栏位置（底部 ↔ 左右竖排导轨）：列表底部留白随之在 96 / 20 间切换
import '../widgets/mobile_nav_scope.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/toast.dart';
import '../widgets/video_card.dart';
import 'pipeline_editor_page.dart';
import 'quick_config_page.dart';

class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key});
  @override
  State<ProjectPage> createState() => ProjectPageState();
}

class ProjectPageState extends State<ProjectPage> {
  static const _videoExts = [
    'mp4',
    'avi',
    'mkv',
    'mov',
    'flv',
    'wmv',
    'webm',
    'm4v',
    'mpg',
    'mpeg',
    '3gp',
    'ts',
    'm2ts',
  ];
  static final _audioExts = kAudioExts.toList();
  static const _imageExts = [
    'png',
    'jpg',
    'jpeg',
    'bmp',
    'webp',
    'tiff',
    'tif',
  ];
  static final _exts = [..._videoExts, ..._audioExts, ..._imageExts];

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _searchVisible = false;
  final Set<String> _selectedIds = {};
  final Set<String> _selectedContainerIds = {};
  bool _dragging = false;
  bool _quickConfigOpen = false;

  /// 移动端多选模式：长按单个项目进入，选中项高亮（左侧不再常驻复选框）。
  bool _selectionMode = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _enterSelectionMode() {
    if (_selectionMode) return;
    setState(() {
      _selectionMode = true;
      _searchVisible = false;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
      _selectedContainerIds.clear();
    });
  }

  /// 多选模式下若已无任何选中项，自动退出多选界面。
  void _refreshSelectionMode() {
    if (_selectionMode &&
        _selectedIds.isEmpty &&
        _selectedContainerIds.isEmpty) {
      _selectionMode = false;
    }
  }

  /// 反选：每个视频/容器的「选中↔未选中」互换。
  void _invertSelection(AppState state) {
    setState(() {
      for (final v in state.videos) {
        if (!_selectedIds.remove(v.id)) _selectedIds.add(v.id);
      }
      for (final c in state.containers) {
        if (!_selectedContainerIds.remove(c.id)) {
          _selectedContainerIds.add(c.id);
        }
      }
      _refreshSelectionMode();
    });
  }

  void _deleteSelected(AppState state) {
    setState(() {
      for (final id in _selectedIds) {
        state.removeVideo(id);
      }
      for (final id in _selectedContainerIds) {
        state.removeContainer(id);
      }
      _selectedIds.clear();
      _selectedContainerIds.clear();
      _selectionMode = false;
    });
  }

  /// 打开顶栏搜索框（供全局快捷键 project_search 调用）。
  ///
  /// [FIX C2] keyBindings['project_search'] 此前只声明在 defaultKeyBindings 与
  /// 快捷键设置页里，**没有任何消费者** —— 用户绑了键也毫无反应。这里补上入口，
  /// 与工具栏那颗放大镜按钮（_searchVisible 的切换）走同一份状态。
  void openSearch() {
    if (!mounted || _searchVisible) return;
    setState(() => _searchVisible = true);
  }

  void selectAll(List videos) {
    setState(() {
      if (_selectedIds.length == videos.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(videos.map((v) => v.id));
      }
    });
  }

  void _onDrop(DropDoneDetails details) {
    if (mounted && _dragging) setState(() => _dragging = false);
    // Use the basename's final extension: paths may contain dots in parent
    // directories, and extension-less paths must not be mistaken for media.
    final paths = details.files.map((file) => file.path).where((path) {
      final normalizedPath = path.replaceAll('\\', '/');
      final name = normalizedPath.substring(
        normalizedPath.lastIndexOf('/') + 1,
      );
      final dot = name.lastIndexOf('.');
      if (dot <= 0 || dot == name.length - 1) return false;
      return _exts.contains(name.substring(dot + 1).toLowerCase());
    }).toList();
    if (paths.isNotEmpty && mounted) {
      context.read<AppState>().addVideos(paths);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clr = theme.colorScheme.outline;
    final scheme = theme.colorScheme;

    // 只在媒体库相关状态变化时重建（视频/容器数量、探测状态、语言），
    // 不再订阅整个 AppState——进度心跳/日志/任务通知不会触发本页重建。
    return AppTopBarLayout(
      builder: (context, compact) {
        return _buildProjectContent(
          context,
          compact: compact,
          scheme: scheme,
          clr: clr,
        );
      },
    );
  }

  Widget _buildProjectContent(
    BuildContext context, {
    required bool compact,
    required ColorScheme scheme,
    required Color clr,
  }) {
    return Selector<AppState, int>(
      selector: (_, state) => Object.hash(
        state.librarySignature,
        state.config.editMode,
        state.config.menuStyle,
        state.config.pillStyle,
      ),
      builder: (context, _, _) {
        final state = context.read<AppState>();
        final s = AppStrings.of(state.config.language);

        final library = _buildBody(
          context,
          state,
          s,
          clr,
          scheme,
          compact: compact,
        );
        final content = isMobilePlatform
            ? library
            : DropTarget(
                onDragDone: _onDrop,
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                child: library,
              );
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // Wrapping actions determine their own height at large text sizes.
              if (compact)
                Column(
                  children: [
                    _buildMobileTopBar(context, state, s, scheme, clr),
                    Expanded(child: content),
                  ],
                )
              else
                Column(
                  children: [
                    GlassTopBar(
                      title: _searchVisible
                          ? TextField(
                              controller: _searchController,
                              autofocus: true,
                              style: TextStyle(
                                fontSize: 14,
                                color: scheme.onSurface,
                              ),
                              decoration: InputDecoration(
                                hintText: s.searchVideos,
                                hintStyle: TextStyle(
                                  color: scheme.outline,
                                  fontSize: 14,
                                ),
                                border: InputBorder.none,
                                prefixIcon: Icon(
                                  Icons.search,
                                  size: 18,
                                  color: scheme.outline,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              onChanged: (v) =>
                                  setState(() => _searchQuery = v),
                            )
                          : Text(s.navProjects),
                      actions: [
                        IconButton(
                          icon: Icon(
                            _searchVisible ? Icons.close : Icons.search,
                            size: 20,
                          ),
                          tooltip: _searchVisible ? s.close : s.search,
                          onPressed: () => setState(() {
                            _searchVisible = !_searchVisible;
                            if (!_searchVisible) {
                              _searchQuery = '';
                              _searchController.clear();
                            }
                          }),
                        ),
                        if (state.videos.isNotEmpty ||
                            state.containers.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              _selectedIds.length == state.videos.length &&
                                      _selectedContainerIds.length ==
                                          state.containers.length
                                  ? Icons.deselect
                                  : Icons.select_all,
                              size: 20,
                            ),
                            tooltip:
                                _selectedIds.isEmpty &&
                                    _selectedContainerIds.isEmpty
                                ? s.selectAll
                                : s.deselectAll,
                            onPressed: () => setState(() {
                              if (_selectedIds.length == state.videos.length &&
                                  _selectedContainerIds.length ==
                                      state.containers.length) {
                                _selectedIds.clear();
                                _selectedContainerIds.clear();
                              } else {
                                _selectedIds.addAll(
                                  state.videos.map((v) => v.id),
                                );
                                _selectedContainerIds.addAll(
                                  state.containers.map((c) => c.id),
                                );
                              }
                            }),
                          ),
                        if (_selectedIds.isNotEmpty ||
                            _selectedContainerIds.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: scheme.error,
                            ),
                            tooltip: s.deleteSelected,
                            onPressed: () => _deleteSelected(state),
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.file_download_outlined,
                            size: 20,
                          ),
                          tooltip: s.isZh ? '导入配置' : 'Import Config',
                          onPressed: state.videos.isEmpty
                              ? null
                              : () => _importConfig(state, s),
                        ),
                        if (state.config.editMode != 1) ...[
                          const SizedBox(width: 6),
                          IconButton.outlined(
                            key: const ValueKey('project_container'),
                            tooltip: s.container,
                            onPressed: () =>
                                _showContainerMenu(context, state, s),
                            icon: const Icon(
                              Icons.create_new_folder_outlined,
                              size: 20,
                            ),
                            style: IconButton.styleFrom(
                              foregroundColor: scheme.onSurface,
                            ),
                          ),
                        ],
                        const SizedBox(width: 10),
                        _addFilesButton(state, s, scheme),
                      ],
                    ),
                    Expanded(child: content),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _addFilesButton(
    AppState state,
    AppStrings s,
    ColorScheme scheme, {
    Key key = const ValueKey('project_add_files'),
    bool compact = false,
  }) {
    const radius = 16.0;
    return GlassPanel(
      radius: radius,
      style: compact ? state.config.pillStyle : state.config.menuStyle,
      child: OutlinedButton.icon(
        key: key,
        onPressed: () => _pick(state),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: Colors.transparent,
          side: BorderSide.none,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radius)),
          ),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        icon: const Icon(Icons.add, size: 20),
        label: Text(s.addVideo, textAlign: TextAlign.center),
      ),
    );
  }

  void _importOrExplain(AppState state, AppStrings s) {
    if (state.videos.isEmpty) {
      showToast(
        context,
        s.isZh
            ? '请先添加文件，再导入配置并应用'
            : 'Add files first, then import a config to apply',
        type: ToastType.info,
      );
    } else {
      _importConfig(state, s);
    }
  }

  /// Keeps mobile actions in the corner; desktop narrow windows retain labels.
  Widget _buildMobileTopBar(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
    Color clr,
  ) {
    final inSelection = _selectionMode;
    final selectedCount = _selectedIds.length + _selectedContainerIds.length;
    if (isMobilePlatform) {
      return MobilePillTopBar(
        title: Text(
          inSelection
              ? '${s.isZh ? '已选' : 'Selected'} $selectedCount'
              : s.navProjects,
        ),
        actions: _buildMobilePillActions(context, state, s, scheme),
        collapseActions: false,
        searching: _searchVisible,
        searchChild: MobileSearchPill(
          controller: _searchController,
          hint: s.searchVideos,
          onChanged: (value) => setState(() => _searchQuery = value),
          onClose: () => setState(() {
            _searchVisible = false;
            _searchQuery = '';
            _searchController.clear();
          }),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MobilePillTopBar(
          title: inSelection
              ? Text(
                  '${s.isZh ? '已选' : 'Selected'} $selectedCount ${s.isZh ? '项' : 'items'}',
                )
              : Text(s.navProjects),
          actions: inSelection
              ? []
              : [
                  MobileGlassPillAction(
                    key: const ValueKey('project_search'),
                    icon: Icons.search,
                    tooltip: s.search,
                    color: scheme.onSurface,
                    size: 44,
                    padding: EdgeInsets.zero,
                    onTap: openSearch,
                  ),
                ],
          collapseActions: false,
          searching: _searchVisible,
          searchChild: MobileSearchPill(
            controller: _searchController,
            hint: s.searchVideos,
            onChanged: (v) => setState(() => _searchQuery = v),
            onClose: () => setState(() {
              _searchVisible = false;
              _searchQuery = '';
              _searchController.clear();
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Wrap(
            key: const ValueKey('project_actions'),
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: _buildMobileActions(
              context,
              state,
              s,
              scheme,
              inSelection,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildMobilePillActions(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
  ) {
    Widget action({
      required String id,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      Color? color,
      Color? background,
    }) => Semantics(
      button: true,
      child: MobileGlassPillAction(
        key: ValueKey(id),
        icon: icon,
        tooltip: label,
        color: color ?? scheme.onSurface,
        bg: background,
        size: MobileUi.pillHeight,
        padding: EdgeInsets.zero,
        onTap: onTap,
      ),
    );

    if (_selectionMode) {
      return [
        action(
          id: 'project_exit_selection',
          icon: Icons.close,
          label: s.isZh ? '退出多选' : 'Exit selection',
          onTap: _exitSelectionMode,
        ),
        // 分组：退出 | 选择范围（全选 / 反选）| 破坏性操作单独一颗。
        const MobileActionGroupBreak(),
        action(
          id: 'project_select_all',
          icon: Icons.select_all,
          label: s.selectAll,
          onTap: () => setState(() {
            _selectedIds.addAll(state.videos.map((video) => video.id));
            _selectedContainerIds.addAll(
              state.containers.map((container) => container.id),
            );
          }),
        ),
        action(
          id: 'project_invert_selection',
          icon: Icons.flip,
          label: s.isZh ? '反选' : 'Invert',
          onTap: () => _invertSelection(state),
        ),
        const MobileActionGroupBreak(),
        action(
          id: 'project_delete_selected',
          icon: Icons.delete_outline,
          label: s.deleteSelected,
          color: scheme.error,
          onTap: () => _deleteSelected(state),
        ),
      ];
    }

    return [
      // 分组：查找（搜索）| 往项目里添加东西（添加文件 / 导入配置 / 容器）。
      action(
        id: 'project_search',
        icon: Icons.search,
        label: s.search,
        onTap: openSearch,
      ),
      const MobileActionGroupBreak(),
      // Keep the primary action initially visible when the pill scrolls.
      action(
        id: 'project_add_files',
        icon: Icons.add,
        label: s.addVideo,
        color: scheme.onPrimaryContainer,
        background: scheme.primaryContainer,
        onTap: () => _pick(state),
      ),
      action(
        id: 'project_import_config',
        icon: Icons.file_download_outlined,
        label: s.isZh ? '导入配置' : 'Import Config',
        onTap: () => _importOrExplain(state, s),
      ),
      if (state.config.editMode != 1)
        action(
          id: 'project_container',
          icon: Icons.create_new_folder_outlined,
          label: s.container,
          onTap: () => _showContainerMenu(context, state, s),
        ),
    ];
  }

  List<Widget> _buildMobileActions(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
    bool inSelection,
  ) {
    final secondaryStyle = TextButton.styleFrom(
      foregroundColor: scheme.onSurface,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
    if (inSelection) {
      return [
        TextButton.icon(
          key: const ValueKey('project_exit_selection'),
          onPressed: _exitSelectionMode,
          style: secondaryStyle,
          icon: const Icon(Icons.close, size: 20),
          label: Text(s.isZh ? '退出多选' : 'Exit selection'),
        ),
        TextButton.icon(
          key: const ValueKey('project_select_all'),
          onPressed: () => setState(() {
            _selectedIds.addAll(state.videos.map((v) => v.id));
            _selectedContainerIds.addAll(state.containers.map((c) => c.id));
          }),
          style: secondaryStyle,
          icon: const Icon(Icons.select_all, size: 20),
          label: Text(s.selectAll),
        ),
        TextButton.icon(
          key: const ValueKey('project_invert_selection'),
          onPressed: () => _invertSelection(state),
          style: secondaryStyle,
          icon: const Icon(Icons.flip, size: 20),
          label: Text(s.isZh ? '反选' : 'Invert'),
        ),
        TextButton.icon(
          key: const ValueKey('project_delete_selected'),
          onPressed: () => _deleteSelected(state),
          style: secondaryStyle.copyWith(
            foregroundColor: WidgetStatePropertyAll(scheme.error),
          ),
          icon: const Icon(Icons.delete_outline, size: 20),
          label: Text(s.deleteSelected),
        ),
      ];
    }
    return [
      _addFilesButton(state, s, scheme, compact: true),
      TextButton.icon(
        key: const ValueKey('project_import_config'),
        onPressed: () => _importOrExplain(state, s),
        style: secondaryStyle,
        icon: const Icon(Icons.file_download_outlined, size: 20),
        label: Text(s.isZh ? '导入配置' : 'Import Config'),
      ),
      if (state.config.editMode != 1)
        TextButton.icon(
          key: const ValueKey('project_container'),
          onPressed: () => _showContainerMenu(context, state, s),
          style: secondaryStyle,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
          label: Text(s.container),
        ),
    ];
  }

  Widget _buildBody(
    BuildContext context,
    AppState state,
    AppStrings s,
    Color clr,
    ColorScheme scheme, {
    required bool compact,
  }) {
    // 探测进度提示：导入大文件时 ffprobe 可能要数十秒，
    // 顶部贴一个明显的"探测中"提示，避免用户以为卡死而关掉 app 触发 ANR。
    final probingBanner = state.probingVideos && !_dragging
        ? _ProbingBanner(
            text: s.probingVideo,
            hint: s.probingHint,
            scheme: scheme,
          )
        : null;

    if (_dragging) {
      return Container(
        color: scheme.primary.withAlpha(30),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_upload_outlined,
                size: 64,
                color: scheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                s.dropToAdd,
                style: TextStyle(
                  fontSize: 18,
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (state.videos.isEmpty && state.containers.isEmpty) {
      // 移动端：提示文字垫一块中性半透明底（无实时模糊，零额外开销），
      // 亮壁纸 / 暗壁纸上都能看清（用户反馈「空状态提示在浅色壁纸上看不清」）。
      final dark = scheme.brightness == Brightness.dark;
      Widget plate(Widget child) => !isMobilePlatform
          ? child
          : DecoratedBox(
              decoration: BoxDecoration(
                color:
                    (dark ? const Color(0xFF1A1A1A) : const Color(0xFFFAFAFA))
                        .withValues(alpha: dark ? 0.72 : 0.80),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withValues(alpha: dark ? 0.14 : 0.40),
                  width: 0.7,
                ),
              ),
              child: child,
            );
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: isMobilePlatform
                ? const EdgeInsets.symmetric(horizontal: 24)
                : EdgeInsets.zero,
            child: plate(
              Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 用户要求：空状态只保留媒体图标，不要主题色矩形底/描边。
                    // 移动端图标用中性前景色，不混入莫奈动态色。
                    Icon(
                      Icons.movie_creation_outlined,
                      size: 56,
                      color: isMobilePlatform
                          ? scheme.onSurface
                          : scheme.primary,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      s.noVideos,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isMobilePlatform
                          ? (s.isZh
                                ? '轻点右上角 ＋ 添加视频、音频或图片'
                                : 'Tap + at the top right to add media')
                          : s.clickAdd,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isMobilePlatform ? scheme.onSurface : clr,
                      ),
                    ),
                    if (!isMobilePlatform) ...[
                      const SizedBox(height: 8),
                      Text(
                        s.dragDropHint,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: clr.withAlpha(170),
                        ),
                      ),
                    ],
                    if (!isMobilePlatform) ...[
                      const SizedBox(height: 22),
                      _addFilesButton(
                        state,
                        s,
                        scheme,
                        key: const ValueKey('project_empty_add_files'),
                        compact: compact,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final standalone = state.standaloneVideos;
    final query = _searchQuery.trim().toLowerCase();
    final filteredStandalone = query.isEmpty
        ? standalone
        : standalone
              .where((v) => v.filename.toLowerCase().contains(query))
              .toList();
    final containerCount = state.containers.length;
    final totalCount = containerCount + filteredStandalone.length;

    if (totalCount == 0 && query.isNotEmpty) {
      return Center(
        child: Text(s.noMatch, style: TextStyle(fontSize: 14, color: clr)),
      );
    }

    return Column(
      children: [
        ?probingBanner,
        Expanded(
          child: ListView.builder(
            // 开窗卡所在列表必须关：子项若被自动套上 RepaintBoundary，
            // 滚动时会直接复用旧图层平移，卡内壁纸跟着卡走（见 app_card 的
            // _WallpaperWindowPainter）。
            addRepaintBoundaries: false,
            // 移动端走统一内边距令牌（左右 8 + 底部按菜单栏位置让出：底部悬浮胶囊
            // 让出 96px，左右竖排导轨只留 20px）；桌面端保持 16
            padding: compact
                ? MobileUi.mainListPadding(
                    context: context,
                    top: probingBanner != null ? 4 : 16,
                    placement: isMobilePlatform
                        ? MobileNavPlacementScope.of(context)
                        : MobileNavPlacement.left,
                  )
                : EdgeInsets.fromLTRB(
                    16,
                    probingBanner != null ? 4 : 16,
                    16,
                    16,
                  ),
            itemCount: totalCount,
            itemBuilder: (_, i) {
              if (i < containerCount) {
                final c = state.containers[i];
                final isSelected = _selectedContainerIds.contains(c.id);
                if (!compact) {
                  return Row(
                    children: [
                      Checkbox(
                        value: isSelected,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selectedContainerIds.add(c.id);
                          } else {
                            _selectedContainerIds.remove(c.id);
                          }
                        }),
                        visualDensity: VisualDensity.compact,
                      ),
                      Expanded(child: ContainerCard(container: c)),
                    ],
                  );
                }
                return _mobileSelectableItem(
                  isSelected: isSelected,
                  scheme: scheme,
                  onLongPress: () {
                    _enterSelectionMode();
                    setState(() => _selectedContainerIds.add(c.id));
                  },
                  onTap: () {
                    if (_selectionMode) {
                      setState(() {
                        if (!_selectedContainerIds.remove(c.id)) {
                          _selectedContainerIds.add(c.id);
                        }
                        _refreshSelectionMode();
                      });
                    }
                  },
                  child: ContainerCard(container: c),
                );
              }
              final video = filteredStandalone[i - containerCount];
              final isSelected = _selectedIds.contains(video.id);
              if (!compact) {
                return Row(
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selectedIds.add(video.id);
                        } else {
                          _selectedIds.remove(video.id);
                        }
                      }),
                      visualDensity: VisualDensity.compact,
                    ),
                    Expanded(
                      child: state.config.editMode == 1
                          ? GestureDetector(
                              onTap: () => _showQuickConfigDialog(
                                context,
                                state,
                                video,
                                s,
                              ),
                              child: VideoCard(
                                video: video,
                                onEdit: (current) => _showQuickConfigDialog(
                                  context,
                                  state,
                                  current,
                                  s,
                                ),
                              ),
                            )
                          : VideoCard(video: video),
                    ),
                  ],
                );
              }
              return _mobileSelectableItem(
                isSelected: isSelected,
                scheme: scheme,
                onLongPress: () {
                  _enterSelectionMode();
                  setState(() => _selectedIds.add(video.id));
                },
                onTap: () {
                  if (_selectionMode) {
                    setState(() {
                      if (!_selectedIds.remove(video.id)) {
                        _selectedIds.add(video.id);
                      }
                      _refreshSelectionMode();
                    });
                  } else if (state.config.editMode == 1) {
                    _showQuickConfigDialog(context, state, video, s);
                  }
                },
                child: state.config.editMode == 1
                    ? VideoCard(
                        video: video,
                        onEdit: (current) =>
                            _showQuickConfigDialog(context, state, current, s),
                      )
                    : VideoCard(video: video),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 移动端可多选条目：长按进入多选模式，选中项高亮（不显示常驻复选框）。
  Widget _mobileSelectableItem({
    required bool isSelected,
    required ColorScheme scheme,
    required Widget child,
    required VoidCallback onLongPress,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.primaryContainer.withAlpha(80)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
    );
  }

  Future<void> _importConfig(AppState state, AppStrings s) async {
    final zh = s.isZh;
    // Android 上 fppx 无 MIME 映射，FileType.custom 会失效。
    final picked = await FilePicker.pickFile(
      type: FileType.any,
      dialogTitle: zh ? '选择配置文件' : 'Select Config File',
    );
    if (picked?.path == null) return;
    final name = picked!.name;
    if (!name.endsWith('.fppx')) {
      if (mounted) {
        showToast(
          context,
          zh ? '请选择 .fppx 文件' : 'Please select a .fppx file',
          type: ToastType.warning,
        );
      }
      return;
    }
    final path = picked.path!;
    if (!mounted) return; // pickFile 异步间隙后 context 的首个使用点

    // 新旧格式均由 C++ 端解析/校验（第 5 字节 0xFF = 新版）；未知节点需用户确认强制导入
    final svc = FppxService(state.backend);
    // 加密文件的口令流程交给共享组件（首次不带口令 → need_password → 弹框重试）
    var imported = await importFppxWithPassword(context, svc, path, zh: zh);
    if (!mounted) return;
    if (imported == null) return;
    if (imported.needsForceConfirm) {
      final ids = imported.unknownTypeIds.join(', ');
      final scheme = Theme.of(context).colorScheme;
      final goOn = await showDialog<bool>(
        context: context,
        animationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (ctx) => AppAlertDialog(
          // 去掉 shape 覆盖：原来写死 radius 16 会把主题 dialogTheme 的
          // 圆角(22) 和 0.6px 细描边一起盖掉（RoundedRectangleBorder.side 默认 none），
          // 导致这个对话框比全局其他对话框「方一块、还没边框」。
          title: Row(
            children: [
              Icon(Icons.help_outline, size: 20, color: scheme.sem.warning),
              const SizedBox(width: 8),
              Text(
                zh ? '发现未知节点' : 'Unknown Node Type',
                style: TextStyle(color: scheme.onSurface),
              ),
            ],
          ),
          content: Text(
            zh
                ? '程序找不到ID为$ids节点的具体含义，可能是因为版本太旧，你可以尝试强制导入，但这可能会发生意料之外的事情'
                : 'The program cannot resolve node ID $ids (possibly created by a newer version). You can force-import, but unexpected behavior may occur.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '强制导入' : 'Force Import'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (goOn == true) {
        final retry = await importFppxWithPassword(
          context,
          svc,
          path,
          force: true,
          zh: zh,
        );
        if (!mounted) return;
        if (retry == null) return;
        imported = retry;
      }
    }

    if (!imported.success) {
      if (mounted) {
        final detail = imported.errors.isNotEmpty
            ? imported.errors.join('\n')
            : (imported.error ?? '');
        showToast(
          context,
          zh ? '配置加载失败: $detail' : 'Load failed: $detail',
          type: ToastType.error,
        );
      }
      return;
    }
    final fppx = _FppxView.fromImport(imported);

    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final selectedVideos = <String>{};

    await showDialog(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AppAlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  zh ? '导入配置' : 'Import Config',
                  style: TextStyle(color: scheme.onSurface),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 兼容性错误
                    if (fppx.errors.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  size: 16,
                                  color: scheme.error,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  zh ? '加载失败' : 'Load Failed',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.error,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ...fppx.errors.map(
                              (e) => Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '• ',
                                      style: TextStyle(color: scheme.error),
                                    ),
                                    Expanded(
                                      child: Text(
                                        e,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: scheme.onErrorContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // 高版本警告
                    if (fppx.warnings.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 12),
                        // 警告条：底色/描边/文字全部改用语义色 warning 的 container
                        // 配对。原先 `Colors.orange.withAlpha(30)` 在深色主题下几乎不可见，
                        // 且这个橙与主题种子色毫无关系。
                        decoration: BoxDecoration(
                          color: scheme.sem.warningContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: scheme.sem.warning.withAlpha(60),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber,
                                  size: 16,
                                  color: scheme.sem.onWarningContainer,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  zh ? '版本警告' : 'Version Warning',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.sem.onWarningContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ...fppx.warnings.map(
                              (w) => Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  '• $w',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // 信息
                    _infoRow(
                      scheme,
                      zh ? '配置版本' : 'Config Version',
                      fppx.configVersionStr,
                    ),
                    _infoRow(
                      scheme,
                      zh ? '兼容软件' : 'Compatible',
                      fppx.softwareRangeStr,
                    ),
                    _infoRow(
                      scheme,
                      zh ? '模式' : 'Mode',
                      fppx.isNodeEditor
                          ? (zh ? '节点编辑器' : 'Node Editor')
                          : (fppx.isQuick
                                ? (zh ? '快速模式' : 'Quick Mode')
                                : (zh ? '传统模式' : 'Legacy')),
                    ),
                    if (fppx.graph != null)
                      _infoRow(
                        scheme,
                        zh ? '内容' : 'Content',
                        '${fppx.graph!.nodes.length} ${zh ? '节点' : 'nodes'}, ${fppx.graph!.connections.length} ${zh ? '连线' : 'links'}',
                      )
                    else if (fppx.isQuick)
                      _infoRow(
                        scheme,
                        zh ? '内容' : 'Content',
                        '${fppx.quickItems.length} ${zh ? '项参数' : 'param items'}',
                      ),
                    _infoRow(
                      scheme,
                      zh ? '适用类型' : 'Media Type',
                      fppx.detectedMediaLabel(zh),
                    ),
                    // 旧版（legacy 模式）配置没有节点图，无法应用到视频
                    if (fppx.showLegacyNote) ...[
                      const SizedBox(height: 8),
                      Text(
                        zh
                            ? '旧版配置暂不支持直接应用到视频，仅可查看信息。'
                            : 'Legacy configs cannot be applied to videos directly.',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ],

                    // 介绍
                    if (fppx.description.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        zh ? '介绍' : 'Description',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest.withAlpha(80),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          fppx.description,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ],

                    // 选择视频
                    const SizedBox(height: 16),
                    Text(
                      zh ? '应用到哪些文件？' : 'Apply to which files?',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (fppx.detectedMediaTypes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Text(
                          zh
                              ? '仅显示与配置兼容的${fppx.detectedMediaLabel(zh)}文件'
                              : 'Showing only compatible ${fppx.detectedMediaLabel(zh)} files',
                          style: TextStyle(fontSize: 11, color: scheme.outline),
                        ),
                      ),
                    const SizedBox(height: 8),
                    ...state.videos
                        .where((v) {
                          if (!v.parsed) return false;
                          final configTypes = fppx.detectedMediaTypes;
                          if (configTypes.isEmpty) return true;
                          return configTypes.contains(v.fileMediaType);
                        })
                        .map(
                          (v) => CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              v.filename,
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurface,
                              ),
                            ),
                            subtitle: Text(
                              v.resolution,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.outline,
                              ),
                            ),
                            value: selectedVideos.contains(v.id),
                            onChanged: (checked) => setDlgState(() {
                              if (checked == true) {
                                selectedVideos.add(v.id);
                              } else {
                                selectedVideos.remove(v.id);
                              }
                            }),
                          ),
                        ),
                    if (state.videos.where((v) {
                      if (!v.parsed) return false;
                      final configTypes = fppx.detectedMediaTypes;
                      if (configTypes.isEmpty) return true;
                      return configTypes.contains(v.fileMediaType);
                    }).isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          zh ? '没有兼容的文件' : 'No compatible files',
                          style: TextStyle(fontSize: 12, color: scheme.outline),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(s.cancel),
              ),
              FilledButton(
                // 无图且非快速模式的配置（旧版 legacy）无法应用到视频 → 禁用应用按钮
                onPressed:
                    (selectedVideos.isEmpty ||
                        !fppx.isCompatible ||
                        (fppx.graph == null && !fppx.isQuick))
                    ? null
                    : () {
                        for (final vid in selectedVideos) {
                          final video = state.videos.firstWhere(
                            (v) => v.id == vid,
                          );
                          if (fppx.graph != null) {
                            final graphCopy = fppx.graph!.copy();
                            for (final n in graphCopy.nodes) {
                              if (n.type == PipelineStepType.start) {
                                n.params['file_media_type'] =
                                    video.fileMediaType.name;
                              }
                            }
                            state.updateVideoPipeline(vid, graphCopy);
                          } else if (fppx.isQuick) {
                            // 快速模式：命令参数 → 生成节点图 → 应用
                            final qc = QuickConfig(
                              id: 'fppx_quick_import',
                              fileType: inferQuickFileTypeFromMaps(
                                fppx.quickItems,
                              ),
                              name: '',
                              items: [
                                for (final item in fppx.quickItems)
                                  QuickConfigItem(
                                    key: item['key'] as String? ?? '',
                                    params:
                                        (item['params']
                                            as Map<String, dynamic>?) ??
                                        {},
                                    enabled: item['enabled'] != false,
                                  ),
                              ],
                            );
                            final result = buildGraphFromQuickConfig(
                              qc,
                              isZh: zh,
                            );
                            state.updateVideoPipeline(vid, result.graph);
                          }
                        }
                        Navigator.pop(ctx);
                        showToast(
                          context,
                          zh
                              ? '已应用到 ${selectedVideos.length} 个视频'
                              : 'Applied to ${selectedVideos.length} videos',
                          type: ToastType.success,
                        );
                      },
                child: Text(zh ? '应用' : 'Apply'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _infoRow(ColorScheme scheme, String label, String value) {
    // 标签列随字号缩放（固定 90px 在大字号下会裁切标签/挤掉取值），
    // 取值用 Expanded + 省略号兜底，长路径不再撑破 Row
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: (90 * scale).clamp(90.0, 130.0),
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(AppState state) async {
    // v13 起 withReadStream / withData 已被移除，改为拿到 PlatformFile 后
    // 按需调用 readAsByteStream() / readAsBytes()。
    //
    // 判定依据也从「path 是否以 content:// 开头」换成更可靠的 `path == null`：
    // v13 的 PlatformFile.path 由 uri.scheme 推导（只有 file:// 才给真实路径），
    // SAF 的 content:// URI 天然为 null，不必再靠字符串前缀猜。
    final r = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _exts,
    );
    await importPickedFiles(state, r);
  }

  /// Processes picker results without substituting previously cached content.
  @visibleForTesting
  Future<void> importPickedFiles(
    AppState state,
    List<PlatformFile> files,
  ) async {
    if (files.isEmpty) return;
    final paths = <String>[];
    for (final f in files) {
      final ext = f.name.contains('.')
          ? f.name.substring(f.name.lastIndexOf('.'))
          : '';
      final stem = f.name.contains('.')
          ? f.name.substring(0, f.name.lastIndexOf('.'))
          : f.name;

      // 非 file:// 来源（Android SAF 的 content://、iOS 的 UIDocumentPicker 等）
      // 走流式拷贝：IOSink.addStream 自带 back-pressure（sink 缓冲满时暂停 source），
      // 每个 chunk 直接写到 file descriptor，**不会**把整个文件读进 Dart 堆，
      // 避免 >100MB 文件直接 OOM 闪退（即便 1GB 也只占 ~64KB 中间缓冲）。
      if (f.path == null) {
        try {
          final destPath =
              '${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
          final sink = File(destPath).openWrite();
          try {
            await sink.addStream(f.readAsByteStream());
          } finally {
            await sink.close();
          }
          paths.add(destPath);
        } catch (_) {
          // 流式失败无处可退：content:// URI 在 fork 出的 ffprobe 子进程里读不到，
          // 详见 AndroidPlatformBridge 的 ensureReadableImport 兜底逻辑。
        }
      } else {
        // Names and lengths do not identify content. Always retain the file
        // selected this time; it may also be an external original, not a cache.
        paths.add(f.path!);
      }
    }
    if (paths.isNotEmpty) await state.addVideos(paths);
  }

  /// 为当前文件直接打开串行向导，并从已保存的节点链恢复配置。
  Future<void> _showQuickConfigDialog(
    BuildContext context,
    AppState state,
    VideoFile video,
    AppStrings s,
  ) async {
    if (_quickConfigOpen) return;
    _quickConfigOpen = true;
    try {
      final current = state.videoById(video.id);
      if (current == null) return;
      final zh = s.isZh;
      final fileType = _fileTypeForMediaType(current.fileMediaType);
      final QuickConfig config;
      try {
        config = quickConfigFromGraph(
          graph: current.pipelineGraph,
          fileType: fileType,
          id: current.id,
          name: current.filename,
        );
      } on FormatException {
        final openEditor = await showDialog<bool>(
          context: context,
          animationStyle: MediaQuery.disableAnimationsOf(context)
              ? AnimationStyle.noAnimation
              : null,
          builder: (ctx) => AppAlertDialog(
            title: Text(
              zh ? '此流程需要节点编辑器' : 'Open this workflow in the node editor',
            ),
            content: Text(
              zh
                  ? '现有流程含有分支、逻辑或不支持串行编辑的节点。请使用节点编辑器继续编辑。'
                  : 'This workflow contains branches, logic, or nodes that require the node editor.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(zh ? '取消' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(zh ? '打开节点编辑器' : 'Open node editor'),
              ),
            ],
          ),
        );
        if (openEditor == true && context.mounted) {
          _openLiveEditor(context, state, current, s);
        }
        return;
      }
      if (!context.mounted) return;
      var queued = false;
      final saved = await showDialog<QuickConfig>(
        context: context,
        animationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        barrierDismissible: false,
        builder: (_) => QuickConfigPage(
          config: config,
          video: current,
          isZh: zh,
          onSave: (updated) async {
            if (!mounted || state.videoById(current.id) == null) {
              throw StateError(
                zh ? '文件已移除，请重新选择' : 'This file was removed. Select it again.',
              );
            }
            final result = buildGraphFromQuickConfig(updated, isZh: zh);
            if (result.isEmpty || result.skippedNotes.isNotEmpty) {
              throw FormatException(result.skippedNotes.join(' '));
            }
            state.updateVideoPipeline(current.id, result.graph);
          },
          onExecute: (updated, graph) async {
            if (!mounted || state.videoById(current.id) == null) {
              throw StateError(
                zh ? '文件已移除，请重新选择' : 'This file was removed. Select it again.',
              );
            }
            final before = state.tasks.length;
            state.addTask(current.id);
            if (state.tasks.length == before) {
              throw StateError(
                zh
                    ? '无法加入队列，请检查节点配置'
                    : 'Could not queue this workflow. Check the node settings.',
              );
            }
            queued = true;
          },
        ),
      );
      if (saved == null || !context.mounted) return;
      showToast(
        context,
        queued
            ? (zh ? '串行流程已保存并加入队列' : 'Serial workflow saved and queued')
            : (zh
                  ? '串行流程已保存，加入队列后生效'
                  : 'Serial workflow saved, ready to queue'),
        type: ToastType.success,
      );
    } finally {
      _quickConfigOpen = false;
    }
  }

  /// 现场编辑：打开节点编辑器自由编排处理流程。
  void _openLiveEditor(
    BuildContext context,
    AppState state,
    VideoFile video,
    AppStrings s,
  ) {
    Navigator.of(context).push(
      smoothRoute(
        PipelineEditorPage(
          video: video,
          onSave: (graph) {
            state.updateVideoPipeline(video.id, graph);
          },
        ),
      ),
    );
  }

  QuickFileType _fileTypeForMediaType(MediaType? mt) {
    if (mt == null) return QuickFileType.video;
    switch (mt) {
      case MediaType.image:
        return QuickFileType.image;
      case MediaType.audio:
        return QuickFileType.audio;
      default:
        return QuickFileType.video;
    }
  }

  void _showContainerMenu(BuildContext context, AppState state, AppStrings s) {
    final scheme = Theme.of(context).colorScheme;
    final zh = s.isZh;
    // 创建/重命名容器共用：弹出命名框
    Future<void> promptCreate(String defaultName, {bool empty = false}) async {
      final ctrl = TextEditingController(text: defaultName);
      final name = await showDialog<String>(
        context: context,
        animationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (ctx) => AppAlertDialog(
          title: Text(
            zh ? '容器名称' : 'Container Name',
            style: TextStyle(color: scheme.onSurface),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: ''),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(zh ? '创建' : 'Create'),
            ),
          ],
        ),
      ).whenComplete(() => ctrl.dispose());
      if (name == null || name.isEmpty) return;
      if (empty) {
        state.addEmptyContainer(name);
      } else {
        final r = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: _exts,
        );
        if (r.isNotEmpty) {
          final paths = r
              .where((f) => f.path != null)
              .map((f) => f.path!)
              .toList();
          if (paths.isNotEmpty) state.addContainer(name, paths);
        }
      }
    }

    // 液态玻璃菜单
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: SingleChildScrollView(
            child: GlassPanel(
              radius: 22,
              blur: 16,
              // Ink must paint above the glass decoration, not behind it.
              child: Material(
                key: const ValueKey('project_container_menu_material'),
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(22),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.create_new_folder_outlined,
                            size: 18,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              zh ? '新建容器' : 'New Container',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.create_new_folder_outlined,
                        color: scheme.primary,
                      ),
                      title: Text(zh ? '创建空容器' : 'Empty Container'),
                      subtitle: Text(
                        zh
                            ? '先创建容器，稍后再添加文件（存于程序临时目录）'
                            : 'Create an empty container, add files later',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        promptCreate(zh ? '新容器' : 'New Container', empty: true);
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.folder_open, color: scheme.primary),
                      title: Text(s.containerFromFolder),
                      subtitle: Text(
                        zh
                            ? '选择一个文件夹，其中的媒体文件将作为容器内容'
                            : 'Select a folder, media files inside become container items',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        final dir = await pickLocalDirectory();
                        if (dir != null) state.addContainerFromFolder(dir);
                      },
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.file_copy_outlined,
                        color: scheme.primary,
                      ),
                      title: Text(s.containerFromFiles),
                      subtitle: Text(
                        zh
                            ? '手动选择多个文件放入新容器'
                            : 'Manually select files for a new container',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        promptCreate(zh ? '新容器' : 'New Container');
                      },
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 导入探测中的顶部提示横幅。
/// 大文件（>100MB）的 ffprobe 首调可达数十秒，UI 一直没反馈时用户可能以为
/// 卡死而关 app 触发 ANR；这里给一个持续旋转的图标 + 文字，让用户知道还在跑。
/// 设计上不阻断用户交互（仍可滚动列表、取消多选），仅作状态可见性。
class _ProbingBanner extends StatefulWidget {
  final String text;
  final String hint;
  final ColorScheme scheme;
  const _ProbingBanner({
    required this.text,
    required this.hint,
    required this.scheme,
  });

  @override
  State<_ProbingBanner> createState() => _ProbingBannerState();
}

class _ProbingBannerState extends State<_ProbingBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl
        ..stop()
        ..value = 0;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: widget.scheme.primaryContainer.withAlpha(160),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.scheme.primary.withAlpha(80),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          RotationTransition(
            turns: _ctrl,
            child: Icon(Icons.sync, size: 18, color: widget.scheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: widget.scheme.onPrimaryContainer,
                  ),
                ),
                Text(
                  widget.hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.scheme.onPrimaryContainer.withAlpha(160),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// C++ 导入结果 → 应用配置对话框所需的视图适配（保留原对话框结构，最小改动）
class _FppxView {
  final List<String> errors;
  final List<String> warnings;
  final String configVersionStr;
  final String softwareRangeStr;
  final String description;
  final bool isNodeEditor;
  final bool isQuick;
  final bool isCompatible;
  final PipelineGraph? graph;
  final List<Map<String, dynamic>> quickItems;
  final Set<MediaType> detectedMediaTypes;

  const _FppxView({
    required this.errors,
    required this.warnings,
    required this.configVersionStr,
    required this.softwareRangeStr,
    required this.description,
    required this.isNodeEditor,
    required this.isQuick,
    required this.isCompatible,
    required this.graph,
    required this.quickItems,
    required this.detectedMediaTypes,
  });

  factory _FppxView.fromImport(FppxImportResult r) {
    final graph = r.graph;
    final types = <MediaType>{};
    if (graph != null) {
      for (final n in graph.nodes) {
        if (n.type == PipelineStepType.start ||
            n.type == PipelineStepType.output) {
          continue;
        }
        types.addAll(n.inputTypes);
      }
    }
    final isV2 = r.isNewFormat;
    return _FppxView(
      errors: r.errors,
      warnings: r.warnings,
      configVersionStr: isV2 ? 'v2 (新版)' : 'v1.2 (旧版)',
      softwareRangeStr: isV2 ? '不依赖版本号（模块化自描述）' : 'v3.x ~ v5.x',
      description: r.description,
      isNodeEditor: r.mode == FppxService.modeNodeEditor && graph != null,
      isQuick: r.mode == FppxService.modeQuick,
      // C++ 端校验通过（errors 为空）即可应用；旧版软件版本区间检查也在其中
      isCompatible: r.success && r.errors.isEmpty,
      graph: graph,
      quickItems: r.quickItems,
      detectedMediaTypes: types,
    );
  }

  /// 旧版 legacy 模式（非节点、非快速）只可查看信息
  bool get showLegacyNote => !isNodeEditor && !isQuick;

  String detectedMediaLabel(bool isZh) {
    if (detectedMediaTypes.isEmpty) return isZh ? '通用' : 'Generic';
    return detectedMediaTypes
        .map(
          (t) => switch (t) {
            MediaType.video => isZh ? '视频' : 'Video',
            MediaType.image => isZh ? '图片' : 'Image',
            MediaType.audio => isZh ? '音频' : 'Audio',
          },
        )
        .join(' / ');
  }
}
