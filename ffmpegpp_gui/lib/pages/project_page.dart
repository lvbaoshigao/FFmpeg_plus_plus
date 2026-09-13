import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../providers/app_state.dart';
import '../models/models.dart';
import '../services/fppx2_service.dart';
import '../theme/app_strings.dart';
import '../widgets/video_card.dart';
import '../widgets/container_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/toast.dart';
import '../platform/app_platform.dart';
import '../services/quick_config_storage.dart';
import '../services/quick_config_pipeline.dart';
import '../app.dart' show smoothRoute;
import 'quick_config_page.dart';
import '../widgets/app_search_overlay.dart';
import 'pipeline_editor_page.dart';

/// 快速配置选择器「现场编辑」的哨兵返回值（区别于 QuickConfig 预设与 null 取消）。
class _QuickPickLiveEdit {
  const _QuickPickLiveEdit();
}

const _quickPickLiveEdit = _QuickPickLiveEdit();

class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key});
  @override
  State<ProjectPage> createState() => ProjectPageState();
}

class ProjectPageState extends State<ProjectPage> {
  static const _videoExts = ['mp4', 'avi', 'mkv', 'mov', 'flv', 'wmv', 'webm', 'm4v', 'mpg', 'mpeg', '3gp', 'ts', 'm2ts'];
  static final _audioExts = kAudioExts.toList();
  static const _imageExts = ['png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif'];
  static final _exts = [..._videoExts, ..._audioExts, ..._imageExts];

  String _searchQuery = '';
  bool _searchVisible = false;
  final Set<String> _selectedIds = {};
  final Set<String> _selectedContainerIds = {};
  bool _dragging = false;
  /// 移动端多选模式：长按单个项目进入，选中项高亮（左侧不再常驻复选框）。
  bool _selectionMode = false;

  /// 当前活动实例。项目页常驻在页面缓存里（IndexedStack / PageView），同一时刻只有
  /// 一个实例；全局搜索跳转到某个项目文件时需要拿到它来回填搜索框（见 build 里的注册）。
  static ProjectPageState? current;

  /// 供全局搜索调用：打开搜索框并按其文件名过滤，实现「跳转到那一条」。
  void applyGlobalSearch(String query) {
    if (!mounted) return;
    setState(() {
      _searchVisible = true;
      _searchQuery = query;
    });
  }

  @override
  void dispose() {
    // 只清掉「还指向自己」的注册，避免把新实例的回调误清。
    if (identical(onProjectSearchRequest, applyGlobalSearch)) {
      onProjectSearchRequest = null;
    }
    if (identical(ProjectPageState.current, this)) ProjectPageState.current = null;
    super.dispose();
  }

  void _enterSelectionMode() {
    if (_selectionMode) return;
    setState(() => _selectionMode = true);
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
    if (_selectionMode && _selectedIds.isEmpty && _selectedContainerIds.isEmpty) {
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
        if (!_selectedContainerIds.remove(c.id)) _selectedContainerIds.add(c.id);
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
    setState(() => _dragging = false);
    final paths = details.files
        .map((f) => f.path)
        .where((p) {
          final ext = p.split('.').last.toLowerCase();
          return _exts.contains(ext);
        })
        .toList();
    if (paths.isNotEmpty) {
      context.read<AppState>().addVideos(paths);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 注册「全局搜索 → 按文件名回填搜索框」的回调（幂等；dispose 时注销）。
    ProjectPageState.current = this;
    onProjectSearchRequest = applyGlobalSearch;
    final theme = Theme.of(context);
    final clr = theme.colorScheme.outline;
    final scheme = theme.colorScheme;

    // 只在媒体库相关状态变化时重建（视频/容器数量、探测状态、语言），
    // 不再订阅整个 AppState——进度心跳/日志/任务通知不会触发本页重建。
    return Selector<AppState, int>(
      selector: (_, state) => state.librarySignature,
      builder: (context, _, _) {
        final state = context.read<AppState>();
        final s = AppStrings.of(state.config.language);

        // 搜索过滤（查询串小写化一次，避免每项重复 toLowerCase）
        final q = _searchQuery.trim().toLowerCase();
        final videos = q.isEmpty
            ? state.videos
            : state.videos.where((v) => v.filename.toLowerCase().contains(q)).toList();

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(children: [
            // 全屏可滚动的内容（移动端顶部留出药丸空间）
            if (isMobilePlatform)
              Padding(
                padding: EdgeInsets.only(top: MobileUi.pageTopPadding(context)),
                child: _buildBody(context, state, videos, s, clr, scheme),
              )
            else
              Column(children: [
                GlassTopBar(
                  title: _searchVisible
                      ? TextField(
                          autofocus: true,
                          style: TextStyle(fontSize: 14, color: scheme.onSurface),
                          decoration: InputDecoration(
                            hintText: s.searchVideos,
                            hintStyle: TextStyle(color: scheme.outline, fontSize: 14),
                            border: InputBorder.none,
                            prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
                            prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          ),
                          onChanged: (v) => setState(() => _searchQuery = v),
                        )
                      : Text(s.navProjects),
                  actions: [
                    IconButton(
                      icon: Icon(_searchVisible ? Icons.close : Icons.search, size: 20),
                      tooltip: _searchVisible ? s.close : s.search,
                      onPressed: () => setState(() {
                        _searchVisible = !_searchVisible;
                        if (!_searchVisible) _searchQuery = '';
                      }),
                    ),
                    if (state.videos.isNotEmpty || state.containers.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          _selectedIds.length == state.videos.length && _selectedContainerIds.length == state.containers.length
                              ? Icons.deselect : Icons.select_all,
                          size: 20,
                        ),
                        tooltip: _selectedIds.isEmpty && _selectedContainerIds.isEmpty ? s.selectAll : s.deselectAll,
                        onPressed: () => setState(() {
                          if (_selectedIds.length == state.videos.length && _selectedContainerIds.length == state.containers.length) {
                            _selectedIds.clear();
                            _selectedContainerIds.clear();
                          } else {
                            _selectedIds.addAll(state.videos.map((v) => v.id));
                            _selectedContainerIds.addAll(state.containers.map((c) => c.id));
                          }
                        }),
                      ),
                    if (_selectedIds.isNotEmpty || _selectedContainerIds.isNotEmpty)
                      IconButton(
                        icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                        tooltip: s.deleteSelected,
                        onPressed: () => _deleteSelected(state),
                      ),
                    IconButton(
                      icon: const Icon(Icons.file_download_outlined, size: 20),
                      tooltip: s.isZh ? '导入配置' : 'Import Config',
                      onPressed: state.videos.isEmpty ? null : () => _importConfig(state, s),
                    ),
                    // 圆形图标按钮：新建容器（主题色描边玻璃圆底）+ 添加文件（主色圆底），无文字
                    if (state.config.editMode != 1) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: s.container,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => _showContainerMenu(context, state, s),
                          child: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer.withAlpha(160),
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.primary.withAlpha(90), width: 1.2),
                            ),
                            child: Icon(Icons.create_new_folder_outlined, size: 18, color: scheme.primary),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 10),
                    Tooltip(
                      message: s.addVideo,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => _pick(state),
                        child: Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.primary.withAlpha(90), width: 1.2),
                            boxShadow: [BoxShadow(color: scheme.primary.withAlpha(90), blurRadius: 8, offset: const Offset(0, 2))],
                          ),
                          child: Icon(Icons.add, size: 24, color: scheme.onPrimary),
                        ),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: DropTarget(
                    onDragDone: _onDrop,
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    child: _buildBody(context, state, videos, s, clr, scheme),
                  ),
                ),
              ]),
            // 移动端顶栏浮层（不影响滚动）
            if (isMobilePlatform)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildMobileTopBar(context, state, s, scheme, clr),
              ),
          ]),
        );
      },
    );
  }

  /// 移动端顶栏：统一走 [MobilePillTopBar]（主界面基准的唯一实现）——
  /// 左标题药丸（多选时变成「已选 N 项 + 关闭」）+ 右动作药丸；
  /// 搜索时标题/动作层整体淡出缩放，同一颗搜索药丸「变长」到 200px 并居中。
  Widget _buildMobileTopBar(
      BuildContext context, AppState state, AppStrings s, ColorScheme scheme, Color clr) {
    final inSelection = _selectionMode;
    final selectedCount = _selectedIds.length + _selectedContainerIds.length;

    final Widget titleChild = inSelection
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(
                '${s.isZh ? '已选' : 'Selected'} $selectedCount ${s.isZh ? '项' : 'items'}',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface),
              ),
            ),
            const SizedBox(width: 6),
            // 关闭多选：统一使用 34×34 圆形动作按钮（与主界面一致）
            MobileGlassPillAction(
              icon: Icons.close,
              tooltip: s.isZh ? '退出多选' : 'Exit selection',
              color: scheme.onSurfaceVariant,
              onTap: _exitSelectionMode,
            ),
          ])
        : Text(s.navProjects);

    return MobilePillTopBar(
      title: titleChild,
      actions: _buildMobileActions(context, state, s, scheme, inSelection),
      searching: _searchVisible,
      // 搜索药丸：搜索时从 44px 变长到 200px 并水平居中（与设置页同一实现）
      searchChild: MobileSearchPill(
        hint: s.searchVideos,
        onChanged: (v) => setState(() => _searchQuery = v),
        onClose: () => setState(() {
          _searchVisible = false;
          _searchQuery = '';
        }),
      ),
    );
  }

  /// 移动端顶栏右侧动作（长药丸内）：多选=全选/反选/删除；普通=搜索/导入/容器/添加。
  /// 全部使用统一的 [MobileGlassPillAction]（34×34 圆形、透明涟漪），
  /// 取代此前本页私有 _pillAction（各页各写一份，尺寸/内边距却各不相同）。
  List<Widget> _buildMobileActions(BuildContext context, AppState state, AppStrings s,
      ColorScheme scheme, bool inSelection) {
    if (inSelection) {
      return [
        MobileGlassPillAction(
          icon: Icons.select_all,
          tooltip: s.selectAll,
          color: scheme.onSurface,
          onTap: () => setState(() {
            _selectedIds.addAll(state.videos.map((v) => v.id));
            _selectedContainerIds.addAll(state.containers.map((c) => c.id));
          }),
        ),
        MobileGlassPillAction(
          icon: Icons.flip,
          tooltip: s.isZh ? '反选' : 'Invert',
          color: scheme.onSurface,
          onTap: () => _invertSelection(state),
        ),
        MobileGlassPillAction(
          icon: Icons.delete_outline,
          tooltip: s.deleteSelected,
          color: scheme.error,
          onTap: () => _deleteSelected(state),
        ),
      ];
    }
    return [
      // 搜索引擎式全局搜索（跨页面：设置项 / 项目文件 / 容器 / 快捷配置 / 快捷键），
      // 与下面「搜索文件」不同：那个只过滤当前项目列表。
      MobileGlassPillAction(
        icon: Icons.travel_explore,
        tooltip: s.isZh ? '全局搜索' : 'Global search',
        color: scheme.onSurface,
        onTap: () => showAppSearch(context),
      ),
      MobileGlassPillAction(
        icon: Icons.search,
        tooltip: s.search,
        color: scheme.onSurface,
        onTap: () => setState(() {
          _searchVisible = !_searchVisible;
          if (!_searchVisible) _searchQuery = '';
        }),
      ),
      // 导入配置：修复“点击无任何响应”——原先视频列表为空时 onTap 直接传 null，
      // 按钮可点但毫无反馈。空列表时给出明确的操作引导提示。
      MobileGlassPillAction(
        icon: Icons.file_download_outlined,
        tooltip: s.isZh ? '导入配置' : 'Import Config',
        color: scheme.onSurface,
        onTap: state.videos.isEmpty
            ? () => showToast(context,
                s.isZh ? '请先用「+」添加文件，再导入配置并应用' : 'Add files with "+" first, then import a config to apply',
                type: ToastType.info)
            : () => _importConfig(state, s),
      ),
      if (state.config.editMode != 1)
        MobileGlassPillAction(
          icon: Icons.create_new_folder_outlined,
          tooltip: s.container,
          color: scheme.onSurface,
          onTap: () => _showContainerMenu(context, state, s),
        ),
      // 主题色实心「+」CTA
      MobileGlassPillAction(
        icon: Icons.add,
        tooltip: s.addVideo,
        color: scheme.onPrimary,
        bg: scheme.primary,
        onTap: () => _pick(state),
      ),
    ];
  }

  Widget _buildBody(BuildContext context, AppState state, List videos, AppStrings s, Color clr, ColorScheme scheme) {
    // 探测进度提示：导入大文件时 ffprobe 可能要数十秒，
    // 顶部贴一个明显的"探测中"提示，避免用户以为卡死而关掉 app 触发 ANR。
    final probingBanner = state.probingVideos && !_dragging
        ? _ProbingBanner(text: s.probingVideo, hint: s.probingHint, scheme: scheme)
        : null;

    if (_dragging) {
      return Container(
        color: scheme.primary.withAlpha(30),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_upload_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: 16),
          Text(s.dropToAdd, style: TextStyle(fontSize: 18, color: scheme.primary, fontWeight: FontWeight.w600)),
        ])),
      );
    }

    if (state.videos.isEmpty && state.containers.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.video_library_outlined, size: 64, color: clr),
        const SizedBox(height: 16),
        Text(s.noVideos, style: TextStyle(fontSize: 16, color: clr)),
        const SizedBox(height: 8),
        Text(s.clickAdd, style: TextStyle(fontSize: 13, color: clr)),
        if (!isMobilePlatform) ...[
          const SizedBox(height: 8),
          Text(s.dragDropHint, style: TextStyle(fontSize: 12, color: clr.withAlpha(150))),
        ],
      ]));
    }

    final standalone = state.standaloneVideos;
    final filteredStandalone = _searchQuery.isEmpty ? standalone
        : standalone.where((v) => v.filename.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    final containerCount = state.containers.length;
    final totalCount = containerCount + filteredStandalone.length;

    if (totalCount == 0 && _searchQuery.isNotEmpty) {
      return Center(child: Text(s.noMatch, style: TextStyle(fontSize: 14, color: clr)));
    }

    return Column(children: [
      ?probingBanner,
      Expanded(child: ListView.builder(
        // 移动端走统一内边距令牌（左右 8 + 底部让出悬浮导航）；桌面端保持 16
        padding: isMobilePlatform
            ? MobileUi.mainListPadding(top: probingBanner != null ? 4 : 16)
            : EdgeInsets.fromLTRB(16, probingBanner != null ? 4 : 16, 16, 16),
        itemCount: totalCount,
        itemBuilder: (_, i) {
        if (i < containerCount) {
          final c = state.containers[i];
          final isSelected = _selectedContainerIds.contains(c.id);
          if (!isMobilePlatform) {
            return Row(children: [
              Checkbox(
                value: isSelected,
                onChanged: (v) => setState(() {
                  if (v == true) { _selectedContainerIds.add(c.id); }
                  else { _selectedContainerIds.remove(c.id); }
                }),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(child: ContainerCard(container: c)),
            ]);
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
                  if (!_selectedContainerIds.remove(c.id)) _selectedContainerIds.add(c.id);
                  _refreshSelectionMode();
                });
              }
            },
            child: ContainerCard(container: c),
          );
        }
        final video = filteredStandalone[i - containerCount];
        final isSelected = _selectedIds.contains(video.id);
        if (!isMobilePlatform) {
          return Row(children: [
            Checkbox(
              value: isSelected,
              onChanged: (v) => setState(() {
                if (v == true) { _selectedIds.add(video.id); }
                else { _selectedIds.remove(video.id); }
              }),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: state.config.editMode == 1
                  ? GestureDetector(
                      onTap: () => _showQuickConfigDialog(context, state, video, s),
                      child: VideoCard(video: video, onEdit: () => _showQuickConfigDialog(context, state, video, s)),
                    )
                  : VideoCard(video: video),
            ),
          ]);
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
                if (!_selectedIds.remove(video.id)) _selectedIds.add(video.id);
                _refreshSelectionMode();
              });
            } else if (state.config.editMode == 1) {
              _showQuickConfigDialog(context, state, video, s);
            }
          },
          child: state.config.editMode == 1
              ? VideoCard(video: video, onEdit: () => _showQuickConfigDialog(context, state, video, s))
              : VideoCard(video: video),
        );
      },
    )),
    ]);
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
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primaryContainer.withAlpha(80) : Colors.transparent,
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
    final r = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: zh ? '选择配置文件' : 'Select Config File',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final name = r.files.first.name;
    if (!name.endsWith('.fppx')) {
      if (mounted) showToast(context, zh ? '请选择 .fppx 文件' : 'Please select a .fppx file', type: ToastType.warning);
      return;
    }
    final path = r.files.first.path!;

    // 新旧格式均由 C++ 端解析/校验（第 5 字节 0xFF = 新版）；未知节点需用户确认强制导入
    final svc = FppxService(state.backend);
    var imported = await svc.importFile(path);
    if (!mounted) return;
    if (imported.needsForceConfirm) {
      final ids = imported.unknownTypeIds.join(', ');
      final scheme = Theme.of(context).colorScheme;
      final goOn = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.help_outline, size: 20, color: Colors.orange),
            const SizedBox(width: 8),
            Text(zh ? '发现未知节点' : 'Unknown Node Type', style: TextStyle(color: scheme.onSurface)),
          ]),
          content: Text(
            zh
                ? '程序找不到ID为$ids节点的具体含义，可能是因为版本太旧，你可以尝试强制导入，但这可能会发生意料之外的事情'
                : 'The program cannot resolve node ID $ids (possibly created by a newer version). You can force-import, but unexpected behavior may occur.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(zh ? '强制导入' : 'Force Import')),
          ],
        ),
      );
      if (!mounted) return;
      if (goOn == true) {
        imported = await svc.importFile(path, force: true);
        if (!mounted) return;
      }
    }

    if (!imported.success) {
      if (mounted) {
        final detail = imported.errors.isNotEmpty
            ? imported.errors.join('\n')
            : (imported.error ?? '');
        showToast(context, zh ? '配置加载失败: $detail' : 'Load failed: $detail', type: ToastType.error);
      }
      return;
    }
    final fppx = _FppxView.fromImport(imported);

    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final selectedVideos = <String>{};

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlgState) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.file_download_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(zh ? '导入配置' : 'Import Config', style: TextStyle(color: scheme.onSurface)),
          ]),
          content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 兼容性错误
              if (fppx.errors.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.error_outline, size: 16, color: scheme.error),
                      const SizedBox(width: 6),
                      Text(zh ? '加载失败' : 'Load Failed',
                          style: TextStyle(fontSize: 13, color: scheme.error, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 6),
                    ...fppx.errors.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('• ', style: TextStyle(color: scheme.error)),
                        Expanded(child: Text(e, style: TextStyle(fontSize: 12, color: scheme.onErrorContainer))),
                      ]),
                    )),
                  ]),
                ),

              // 高版本警告
              if (fppx.warnings.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.orange.withAlpha(30), borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withAlpha(60))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                      const SizedBox(width: 6),
                      Text(zh ? '版本警告' : 'Version Warning',
                          style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 6),
                    ...fppx.warnings.map((w) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text('• $w', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    )),
                  ]),
                ),

              // 信息
              _infoRow(scheme, zh ? '配置版本' : 'Config Version', fppx.configVersionStr),
              _infoRow(scheme, zh ? '兼容软件' : 'Compatible', fppx.softwareRangeStr),
              _infoRow(scheme, zh ? '模式' : 'Mode', fppx.isNodeEditor
                  ? (zh ? '节点编辑器' : 'Node Editor')
                  : (fppx.isQuick ? (zh ? '快速模式' : 'Quick Mode') : (zh ? '传统模式' : 'Legacy'))),
              if (fppx.graph != null)
                _infoRow(scheme, zh ? '内容' : 'Content',
                    '${fppx.graph!.nodes.length} ${zh ? '节点' : 'nodes'}, ${fppx.graph!.connections.length} ${zh ? '连线' : 'links'}')
              else if (fppx.isQuick)
                _infoRow(scheme, zh ? '内容' : 'Content',
                    '${fppx.quickItems.length} ${zh ? '项参数' : 'param items'}'),
              _infoRow(scheme, zh ? '适用类型' : 'Media Type', fppx.detectedMediaLabel(zh)),
              // 旧版（legacy 模式）配置没有节点图，无法应用到视频
              if (fppx.showLegacyNote) ...[
                const SizedBox(height: 8),
                Text(
                  zh ? '旧版配置暂不支持直接应用到视频，仅可查看信息。'
                     : 'Legacy configs cannot be applied to videos directly.',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],

              // 介绍
              if (fppx.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(zh ? '介绍' : 'Description', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withAlpha(80),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(fppx.description, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                ),
              ],

              // 选择视频
              const SizedBox(height: 16),
              Text(zh ? '应用到哪些文件？' : 'Apply to which files?',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              if (fppx.detectedMediaTypes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    zh ? '仅显示与配置兼容的${fppx.detectedMediaLabel(zh)}文件' : 'Showing only compatible ${fppx.detectedMediaLabel(zh)} files',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ),
              const SizedBox(height: 8),
              ...state.videos.where((v) {
                if (!v.parsed) return false;
                final configTypes = fppx.detectedMediaTypes;
                if (configTypes.isEmpty) return true;
                return configTypes.contains(v.fileMediaType);
              }).map((v) => CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(v.filename, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                subtitle: Text(v.resolution, style: TextStyle(fontSize: 11, color: scheme.outline)),
                value: selectedVideos.contains(v.id),
                onChanged: (checked) => setDlgState(() {
                  if (checked == true) { selectedVideos.add(v.id); } else { selectedVideos.remove(v.id); }
                }),
              )),
              if (state.videos.where((v) {
                if (!v.parsed) return false;
                final configTypes = fppx.detectedMediaTypes;
                if (configTypes.isEmpty) return true;
                return configTypes.contains(v.fileMediaType);
              }).isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(zh ? '没有兼容的文件' : 'No compatible files',
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                ),
            ],
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
            FilledButton(
              // 无图且非快速模式的配置（旧版 legacy）无法应用到视频 → 禁用应用按钮
              onPressed: (selectedVideos.isEmpty || !fppx.isCompatible || (fppx.graph == null && !fppx.isQuick)) ? null : () {
                for (final vid in selectedVideos) {
                  final video = state.videos.firstWhere((v) => v.id == vid);
                  if (fppx.graph != null) {
                    final graphCopy = fppx.graph!.copy();
                    for (final n in graphCopy.nodes) {
                      if (n.type == PipelineStepType.start) {
                        n.params['file_media_type'] = video.fileMediaType.name;
                      }
                    }
                    state.updateVideoPipeline(vid, graphCopy);
                  } else if (fppx.isQuick) {
                    // 快速模式：命令参数 → 生成节点图 → 应用
                    final qc = QuickConfig(
                      id: 'fppx_quick_import',
                      fileType: _inferQuickFileType(fppx.quickItems),
                      name: '',
                      items: [for (final item in fppx.quickItems)
                        QuickConfigItem(
                          key: item['key'] as String? ?? '',
                          params: (item['params'] as Map<String, dynamic>?) ?? {},
                          enabled: item['enabled'] != false,
                        )],
                    );
                    final result = buildGraphFromQuickConfig(qc, isZh: zh);
                    state.updateVideoPipeline(vid, result.graph);
                  }
                }
                Navigator.pop(ctx);
                showToast(context, zh ? '已应用到 ${selectedVideos.length} 个视频' : 'Applied to ${selectedVideos.length} videos', type: ToastType.success);
              },
              child: Text(zh ? '应用' : 'Apply'),
            ),
          ],
        );
      }),
    );
  }

  Widget _infoRow(ColorScheme scheme, String label, String value) {
    // 标签列随字号缩放（固定 90px 在大字号下会裁切标签/挤掉取值），
    // 取值用 Expanded + 省略号兜底，长路径不再撑破 Row
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(width: (90 * scale).clamp(90.0, 130.0), child: Text(label, style: TextStyle(fontSize: 12, color: scheme.outline), overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        Expanded(child: Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Future<void> _pick(AppState state) async {
    // Android/iOS：用 withReadStream 走流式拷贝——file_picker 把 SAF/UIDocumentPicker
    // 的文件分块（典型 64KB/chunk）通过 Stream<List<int>> 喂给 IOSink，
    // IOSink.addStream 自带 back-pressure（sink 缓冲满时暂停 source）。
    // 整个过程**不会**把整个文件读进 Dart 堆，避免 >100MB 文件直接 OOM 闪退。
    //
    // Desktop：withReadStream 在 macOS 不支持，Linux/Windows 仍可用；本分支
    // 退回到 withData（桌面 4GB+ heap 不会 OOM）。
    final useStream = isMobilePlatform;
    final r = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _exts,
      withReadStream: useStream,
      withData: !useStream,
    );
    if (r != null && r.files.isNotEmpty) {
      final paths = <String>[];
      for (final f in r.files) {
        final ext = f.name.contains('.') ? f.name.substring(f.name.lastIndexOf('.')) : '';
        final stem = f.name.contains('.') ? f.name.substring(0, f.name.lastIndexOf('.')) : f.name;
        final isContentUri = f.path != null && f.path!.startsWith('content://');

        // Android/iOS 走流式拷贝（避免 f.bytes! 一次性把整文件读进堆）。
        // Linux/Windows 桌面：优先用流式，没有 readStream 再回退 f.path 或 f.bytes。
        if (useStream && f.readStream != null && isContentUri) {
          try {
            final destPath = '${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
            final dest = File(destPath);
            // IOSink.addStream 把 readStream 的每个 chunk 直接写到 file descriptor，
            // 不在 Dart 堆累积；即便 1GB 文件也只占 ~64KB 中间缓冲。
            final sink = dest.openWrite();
            try {
              await sink.addStream(f.readStream!);
            } finally {
              await sink.close();
            }
            paths.add(destPath);
          } catch (e) {
            // 流式失败回退到原始 path（content:// URI 在 fork 出的 ffprobe
            // 子进程里读不到，所以这个回退也只是兜底；详见 AndroidPlatformBridge
            // 的 ensureReadableImport 兜底逻辑）
            if (f.path != null) paths.add(f.path!);
          }
        } else if (f.path != null && !isContentUri) {
          // 桌面/非 content URI：直接用路径（FilePicker 已写入临时目录）
          paths.add(f.path!);
        } else if (f.readStream != null) {
          // 兜底：有 readStream 但不是 content URI（罕见），也走流式
          try {
            final destPath = '${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
            final sink = File(destPath).openWrite();
            try {
              await sink.addStream(f.readStream!);
            } finally {
              await sink.close();
            }
            paths.add(destPath);
          } catch (_) {
            if (f.bytes != null) {
              try {
                await File('${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext').writeAsBytes(f.bytes!);
              } catch (_) {}
            }
          }
        } else if (f.bytes != null) {
          // 最后兜底：桌面 + withData 路径，小文件可接受
          try {
            await File('${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext').writeAsBytes(f.bytes!);
          } catch (_) {}
        }
      }
      if (paths.isNotEmpty) state.addVideos(paths);
    }
  }

  /// 快速模式：选择文件后弹出快速配置选择对话框。
  /// - 选预设 → 参数编辑 → 保存并把启用项翻译成节点图应用到该文件；
  /// - 「现场编辑」→ 直接打开节点编辑器（PipelineEditorPage）。
  Future<void> _showQuickConfigDialog(BuildContext context, AppState state, VideoFile video, AppStrings s) async {
    final zh = s.isZh;
    final fileType = _fileTypeForMediaType(video.fileMediaType);
    final configs = await QuickConfigStorage.loadAll(fileType);
    if (!context.mounted) return;
    final selected = await showDialog<Object>(
      context: context,
      builder: (ctx) => _QuickConfigPicker(
        configs: configs,
        fileType: fileType,
        scheme: Theme.of(context).colorScheme,
        isZh: zh,
      ),
    );
    if (!context.mounted) return;
    if (selected is QuickConfig) {
      final saved = await showDialog<QuickConfig>(
        context: context,
        barrierDismissible: false,
        builder: (_) => QuickConfigPage(
          config: selected,
          onSave: (updated) async {
            await QuickConfigStorage.save(updated);
          },
        ),
      );
      if (saved == null || !context.mounted) return;
      // 关键修复：此前预设保存后与视频毫无关联，任务入队时 pipelineGraph
      // 为空 → 图片输出与输入完全相同。这里把启用项翻译成节点图再应用。
      final result = buildGraphFromQuickConfig(saved, isZh: zh);
      if (result.isEmpty) {
        showToast(context,
          zh ? '该预设没有可应用的处理项。${result.skippedNotes.join(' ')}' : 'No applicable items. ${result.skippedNotes.join(' ')}',
          type: ToastType.warning);
        return;
      }
      state.updateVideoPipeline(video.id, result.graph);
      final note = result.skippedNotes.isEmpty ? '' : (zh ? '；${result.skippedNotes.join('；')}' : '; ${result.skippedNotes.join('; ')}');
      showToast(context,
        zh ? '已应用 ${result.appliedKeys.length} 项设置，加入队列后生效$note'
           : 'Applied ${result.appliedKeys.length} settings, effective when queued$note',
        type: ToastType.success);
    } else if (identical(selected, _quickPickLiveEdit)) {
      _openLiveEditor(context, state, video, s);
    }
  }

  /// 现场编辑：打开节点编辑器自由编排处理流程。
  void _openLiveEditor(BuildContext context, AppState state, VideoFile video, AppStrings s) {
    Navigator.of(context).push(smoothRoute(PipelineEditorPage(
      video: video,
      onSave: (graph) {
        state.updateVideoPipeline(video.id, graph);
      },
    )));
  }

  QuickFileType _fileTypeForMediaType(MediaType? mt) {
    if (mt == null) return QuickFileType.video;
    switch (mt) {
      case MediaType.image: return QuickFileType.image;
      case MediaType.audio: return QuickFileType.audio;
      default: return QuickFileType.video;
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
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(zh ? '容器名称' : 'Container Name', style: TextStyle(color: scheme.onSurface)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: ''),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(zh ? '创建' : 'Create')),
          ],
        ),
      ).whenComplete(() => ctrl.dispose());
      if (name == null || name.isEmpty) return;
      if (empty) {
        state.addEmptyContainer(name);
      } else {
        final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: _exts);
        if (r != null && r.files.isNotEmpty) {
          final paths = r.files.where((f) => f.path != null).map((f) => f.path!).toList();
          if (paths.isNotEmpty) state.addContainer(name, paths);
        }
      }
    }

    // 液态玻璃菜单
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            radius: 22,
            blur: 16,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(children: [
                Icon(Icons.create_new_folder_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(zh ? '新建容器' : 'New Container',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              ]),
            ),
            ListTile(
              leading: Icon(Icons.create_new_folder_outlined, color: scheme.primary),
              title: Text(zh ? '创建空容器' : 'Empty Container'),
              subtitle: Text(zh ? '先创建容器，稍后再添加文件（存于程序临时目录）' : 'Create an empty container, add files later',
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                promptCreate(zh ? '新容器' : 'New Container', empty: true);
              },
            ),
            ListTile(
              leading: Icon(Icons.folder_open, color: scheme.primary),
              title: Text(s.containerFromFolder),
              subtitle: Text(zh ? '选择一个文件夹，其中的媒体文件将作为容器内容' : 'Select a folder, media files inside become container items',
                  style: const TextStyle(fontSize: 12)),
              onTap: () async {
                Navigator.pop(ctx);
                final dir = await FilePicker.platform.getDirectoryPath();
                if (dir != null) state.addContainerFromFolder(dir);
              },
            ),
            ListTile(
              leading: Icon(Icons.file_copy_outlined, color: scheme.primary),
              title: Text(s.containerFromFiles),
              subtitle: Text(zh ? '手动选择多个文件放入新容器' : 'Manually select files for a new container',
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                promptCreate(zh ? '新容器' : 'New Container');
              },
            ),
            const SizedBox(height: 6),
          ]),
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
  const _ProbingBanner({required this.text, required this.hint, required this.scheme});

  @override
  State<_ProbingBanner> createState() => _ProbingBannerState();
}

class _ProbingBannerState extends State<_ProbingBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

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
        border: Border.all(color: widget.scheme.primary.withAlpha(80), width: 1),
      ),
      child: Row(children: [
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
              Text(widget.text,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: widget.scheme.onPrimaryContainer)),
              Text(widget.hint,
                  style: TextStyle(
                      fontSize: 11,
                      color: widget.scheme.onPrimaryContainer.withAlpha(160))),
            ],
          ),
        ),
      ]),
    );
  }
}

/// 快速模式配置选择器对话框
class _QuickConfigPicker extends StatelessWidget {
  final List<QuickConfig> configs;
  final QuickFileType fileType;
  final ColorScheme scheme;
  final bool isZh;

  const _QuickConfigPicker({
    required this.configs,
    required this.fileType,
    required this.scheme,
    required this.isZh,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(Icons.tune, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(isZh ? '选择快速配置' : 'Select Quick Config',
            style: TextStyle(color: scheme.onSurface, fontSize: 16)),
      ]),
      content: SizedBox(
        width: 400,
        child: configs.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.inbox_outlined, size: 48, color: scheme.outlineVariant),
                  const SizedBox(height: 12),
                  Text(isZh ? '暂无匹配的快速配置' : 'No matching quick configs',
                      style: TextStyle(fontSize: 14, color: scheme.outline)),
                  const SizedBox(height: 4),
                  Text(isZh ? '请先在设置中创建快速配置' : 'Create one in Settings first',
                      style: TextStyle(fontSize: 12, color: scheme.outline.withAlpha(150))),
                ]),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: configs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final cfg = configs[i];
                  return ListTile(
                    leading: _fileTypeIcon(cfg.fileType),
                    title: Text(cfg.name.isNotEmpty ? cfg.name : '(unnamed)',
                        style: TextStyle(fontSize: 14, color: scheme.onSurface, fontWeight: FontWeight.w500)),
                    subtitle: cfg.description.isNotEmpty
                        ? Text(cfg.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: scheme.outline))
                        : Text(
                            isZh ? '${cfg.items.where((i) => i.enabled).length} 项已启用' : '${cfg.items.where((i) => i.enabled).length} items enabled',
                            style: TextStyle(fontSize: 11, color: scheme.outline.withAlpha(150))),
                    trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
                    onTap: () => Navigator.pop(context, cfg),
                  );
                },
              ),
      ),
      actions: [
        // 快速模式「现场编辑」：不选预设直接进入节点编辑器（Bug 修复：
        // 之前快速模式只能选预设，无法对该文件做自由编辑）。
        TextButton.icon(
          onPressed: () => Navigator.pop(context, _quickPickLiveEdit),
          icon: Icon(Icons.tune, size: 16, color: scheme.primary),
          label: Text(isZh ? '现场编辑' : 'Live Edit',
              style: TextStyle(color: scheme.primary)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
      ],
    );
  }

  Widget _fileTypeIcon(QuickFileType ft) {
    return Container(
      width: 32, height: 32,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        switch (ft) {
          QuickFileType.video => Icons.videocam_outlined,
          QuickFileType.image => Icons.image_outlined,
          QuickFileType.audio => Icons.audiotrack_outlined,
        },
        size: 16, color: scheme.primary,
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
        if (n.type == PipelineStepType.start || n.type == PipelineStepType.output) continue;
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
    return detectedMediaTypes.map((t) => switch (t) {
      MediaType.video => isZh ? '视频' : 'Video',
      MediaType.image => isZh ? '图片' : 'Image',
      MediaType.audio => isZh ? '音频' : 'Audio',
    }).join(' / ');
  }
}

/// 根据快速参数 key 推断媒体类型（0x02 文件不存文件类型）
QuickFileType _inferQuickFileType(List<Map<String, dynamic>> items) {
  final keys = items.map((e) => e['key'] as String? ?? '').toSet();
  if (keys.contains('resize')) return QuickFileType.image;
  if (keys.intersection({'channels', 'normalize', 'sample_rate'}).isNotEmpty) {
    return QuickFileType.audio;
  }
  return QuickFileType.video;
}
