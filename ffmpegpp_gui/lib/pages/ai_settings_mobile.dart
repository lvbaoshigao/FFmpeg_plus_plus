import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
// 控件高度档位令牌：本页原有 34 / 40 / 42 / 44 四档按钮高度并存，
// 统一到 comfortable（卡片内表单/行内按钮）与 large（通栏主行动按钮）两档
import '../theme/app_control_size.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_strings.dart';
import '../widgets/app_card.dart';
import '../widgets/app_slider.dart';
import '../widgets/mobile_bottom_nav.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/toast.dart';
import '../widgets/wallpaper_background.dart';
import 'settings_page.dart'
    show
        applyProfilePreset,
        fetchAiBalance,
        listAiModels,
        pingAi;

/// 询问模式下可选「无需确认」的操作内部 key —— 与桌面端一致。
///
/// 只存 key，显示名在 build 时按当前语言取：此前常量里固化了中文显示名，
/// 英文界面下这几个 chip 仍是中文（与主设置语言不符）。
const _askSkipKeys = <String>[
  'save',
  'undo_redo',
  'error_check',
  'clear_all',
  'tools',
];

/// 无需确认的操作 key → 当前语言下的显示名。
String _askSkipLabel(String key, bool isZh) => switch (key) {
      'save' => isZh ? '保存' : 'Save',
      'undo_redo' => isZh ? '撤销/重做' : 'Undo/Redo',
      'error_check' => isZh ? '错误检查' : 'Error Check',
      'clear_all' => isZh ? '清空画布' : 'Clear Canvas',
      'tools' => isZh ? '工具执行' : 'Run Tools',
      // 未知 key（如后端新增）直接显示 key，避免出现空白 chip
      _ => key,
    };

/// 移动端「MCP / AI」设置内容（二级菜单，提供商列表式）。
///
/// 结构（移动端专属布局，不影响桌面端 _buildMcpAi）：
/// - AI 助手：启用开关 + 提供商列表（点行进入单独设置）+ 新建提供商
/// - 权限：读取 / 写入 / 自动执行 / 允许询问
/// - 高级：三级菜单（图生成模式、思考、自动命名、会话模式、系统提示词）
/// - MCP 服务：启用、端口、允许写入、访问令牌
Widget mobileAiSettingsContent(BuildContext ctx, AppState state) {
  return Consumer<AppState>(
    builder: (context, state, _) {
      final cfg = state.config;
      final s = AppStrings.of(cfg.language);
      final scheme = Theme.of(context).colorScheme;
      final clr = scheme.onSurface;

      return Column(children: [
        // ── AI 助手（提供商列表） ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.auto_awesome_outlined,
          title: s.aiChatTitle,
          trailing: Switch(
            value: cfg.aiEnabled,
            onChanged: (v) => state.updateConfig((c) => c..aiEnabled = v),
          ),
          children: [
            if (cfg.aiEnabled) ...[
              Text(s.aiProviders, style: TextStyle(fontSize: 11, color: scheme.outline)),
              const SizedBox(height: 2),
              if (cfg.aiProfiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(s.aiNoProviders,
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                )
              else
                for (final p in cfg.aiProfiles)
                  _MobileProviderRow(
                    s: s,
                    scheme: scheme,
                    profile: p,
                    active: cfg.activeAiProfileId == p.id,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(allowSnapshotting: false, 
                          builder: (_) => MobileAiProviderDetailPage(profileId: p.id)),
                    ),
                  ),
              const SizedBox(height: 4),
              // 「新建提供商」：与上面的提供商行同构（圆形图标槽 + 文字 + 箭头），
              // 不再用通栏 Material 实心按钮 —— 那是本页最跳的异类元素。
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(allowSnapshotting: false, 
                      builder: (_) => const MobileAiProviderDetailPage()),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(26),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.primary.withAlpha(90)),
                      ),
                      child: Icon(Icons.add, size: 17, color: scheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s.aiNewProvider,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary)),
                    ),
                    Icon(Icons.chevron_right, size: 20, color: scheme.outline),
                  ]),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        // ── 权限 ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.shield_outlined,
          title: s.aiPermissions,
          children: [
            _PermRow(
              s: s,
              icon: Icons.visibility_outlined,
              title: s.aiReadAccess,
              desc: s.aiReadAccessDesc,
              value: cfg.aiReadAccess,
              onChanged: (v) => state.updateConfig((c) => c..aiReadAccess = v),
            ),
            const Divider(height: 1),
            _PermRow(
              s: s,
              icon: Icons.edit_outlined,
              title: s.aiWriteAccess,
              desc: s.aiWriteAccessDesc,
              value: cfg.aiWriteAccess,
              onChanged: (v) => state.updateConfig((c) => c..aiWriteAccess = v),
            ),
            const Divider(height: 1),
            _PermRow(
              s: s,
              icon: Icons.play_circle_outline,
              title: s.aiAutoExecute,
              desc: s.aiAutoExecuteDesc,
              value: cfg.aiAutoExecute,
              onChanged: (v) => state.updateConfig((c) => c..aiAutoExecute = v),
            ),
            const Divider(height: 1),
            _PermRow(
              s: s,
              icon: Icons.question_answer_outlined,
              title: s.aiAllowAsk,
              desc: s.aiAllowAskDesc,
              value: cfg.aiAllowAsk,
              onChanged: (v) => state.updateConfig((c) => c..aiAllowAsk = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── 高级（三级菜单） ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.tune,
          title: s.aiAdvanced,
          subtitle: s.isZh
              ? '图生成模式 / 思考 / 自动命名 / 会话模式 / 系统提示词'
              : 'Image mode, thinking, auto-naming, session mode, system prompt',
          trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(allowSnapshotting: false, builder: (_) => const MobileAiAdvancedPage()),
          ),
        ),
        const SizedBox(height: 8),
        // ── MCP 服务 ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.hardware,
          title: s.mcpTitle,
          children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(s.mcpEnable, style: TextStyle(fontSize: 12, color: clr)),
                subtitle: cfg.mcpEnabled
                    ? Text(
                        state.mcpError != null
                            ? state.mcpError!
                            : state.mcpRunning
                                ? (s.isZh ? '运行中' : 'Running')
                                : (s.isZh ? '已停止' : 'Stopped'),
                        style: TextStyle(
                            fontSize: 10,
                            color: state.mcpError != null
                                ? scheme.sem.danger
                                : state.mcpRunning ? scheme.sem.success : scheme.sem.neutral),
                      )
                    : null,
                value: cfg.mcpEnabled,
                onChanged: (v) => state.toggleMcpServer(v),
              ),
              if (cfg.mcpEnabled) ...[
                // 与桌面设置页同一套比例：标签固定 76、输入框吃掉剩余宽度、
                // 动作固定 84、高度一律取 comfortable(36)。
                // 改造前输入框写死 90 宽、按钮写死 40 高，两个数字互不相干 ——
                // 按钮比输入框还高，一行的两半各说各话。
                Row(children: [
                  SizedBox(
                    width: AppControlSize.labelW,
                    child: Text('${s.mcpPort}:', style: TextStyle(fontSize: 12, color: clr)),
                  ),
                  Expanded(
                    child: _AiField(
                      value: cfg.mcpPort.toString(),
                      scheme: scheme,
                      keyboardType: TextInputType.number,
                      onCommit: (v) {
                        final port = int.tryParse(v);
                        if (port != null && port > 0 && port < 65536) {
                          state.updateConfig((c) => c..mcpPort = port);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: AppControlSize.actionW,
                    // 「应用」用描边按钮而非 Material 实心 tonal 按钮：与页面其余
                    // 玻璃 / 描边控件统一（原先那颗实心按钮是本页第二处割裂元素）。
                    child: OutlinedButton.icon(
                      style: AppControlSize.comfortable.buttonStyle(),
                      icon: Icon(Icons.refresh, size: AppControlSize.comfortable.iconSize),
                      label: Text(s.isZh ? '应用' : 'Apply', style: const TextStyle(fontSize: 11)),
                      onPressed: () async {
                        state.mcpError = null;
                        await state.stopMcpServer();
                        await state.startMcpServer();
                      },
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  SizedBox(
                    width: AppControlSize.labelW,
                    child: Text(s.isZh ? '监听地址:' : 'Bind host:',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: clr)),
                  ),
                  Expanded(
                    child: _AiField(
                      value: cfg.mcpHost,
                      scheme: scheme,
                      hint: '127.0.0.1',
                      onCommit: (v) {
                        final host = v.trim();
                        // 允许留空（回退 127.0.0.1）；其余只做基本字符校验，重启后生效
                        if (host.isEmpty || RegExp(r'^[A-Za-z0-9.:_-]+$').hasMatch(host)) {
                          state.updateConfig((c) => c..mcpHost = host);
                        }
                      },
                    ),
                  ),
                ]),
                Padding(
                  // 说明文字对齐到输入框左边缘（= 标签列宽），不再和标签挤在一行
                  padding: const EdgeInsets.only(top: 4, left: AppControlSize.labelW),
                  child: Text(
                    s.isZh ? '改后点「应用」。设为 0.0.0.0 将暴露到局域网并启用访问令牌' : 'Click Apply. 0.0.0.0 exposes to LAN and enables token',
                    style: TextStyle(fontSize: 10, color: scheme.outline),
                  ),
                ),
                if (state.mcpRunning && state.mcpToken != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      '${s.isZh ? '局域网访问令牌' : 'LAN access token'}: ${state.mcpToken}',
                      style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 4),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.isZh ? '允许 MCP 写入' : 'Allow MCP Write',
                      style: TextStyle(fontSize: 12, color: clr)),
                  subtitle: Text(
                      s.isZh
                          ? '关闭时 MCP 只能读取画布/文件，所有修改操作会被拒绝'
                          : 'When off, MCP can only read the canvas/files; all write actions are rejected',
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                  value: cfg.mcpAllowWrite,
                  onChanged: (v) => state.updateConfig((c) => c..mcpAllowWrite = v),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.isZh ? '允许 MCP 访问文件系统' : 'Allow MCP File Access',
                      style: TextStyle(fontSize: 12, color: clr)),
                  subtitle: Text(
                      s.isZh
                          ? '控制列目录/文件信息/媒体探测三个工具；本机任何程序都能调用 MCP，不依赖时可关闭'
                          : 'Gates list_directory / read_file_info / probe_video; any local program can call MCP — turn off when unused',
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                  value: cfg.mcpAllowFsAccess,
                  onChanged: (v) => state.updateConfig((c) => c..mcpAllowFsAccess = v),
                ),
              ],
          ],
        ),
      ]);
    },
  );
}

/// 提供商列表行：图标 + 名称/模型 + 「当前」徽标 + 箭头，点击进入单独设置。
class _MobileProviderRow extends StatelessWidget {
  final AppStrings s;
  final ColorScheme scheme;
  final AiProfile profile;
  final bool active;
  final VoidCallback onTap;
  const _MobileProviderRow({
    required this.s,
    required this.scheme,
    required this.profile,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final clr = scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        // 不再手工缩进 28：卡内左右留白现由 _AiSectionCard 统一提供（16）。
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              profile.provider == 'anthropic' ? Icons.chat_bubble_outline : Icons.cloud_outlined,
              size: 17,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: clr)),
              ),
              if (active) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(s.aiProviderCurrent,
                      style: TextStyle(fontSize: 9, color: scheme.primary, fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Text(
              profile.enabled
                  ? '${profile.provider} · ${profile.model}'
                  : (s.isZh ? '已停用 · ${profile.model}' : 'Disabled · ${profile.model}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ])),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 20, color: scheme.outline),
        ]),
      ),
    );
  }
}

/// 权限行：图标 + 标题/说明 + 开关。
class _PermRow extends StatelessWidget {
  final AppStrings s;
  final IconData icon;
  final String title;
  final String desc;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _PermRow({
    required this.s,
    required this.icon,
    required this.title,
    required this.desc,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clr = scheme.onSurface;
    return SwitchListTile(
      dense: true,
      // 左右留白交给 _AiSectionCard（16），这里只管行内上下间距。
      contentPadding: const EdgeInsets.symmetric(vertical: 2),
      secondary: Icon(icon, size: 18, color: scheme.primary),
      title: Text(title, style: TextStyle(fontSize: 12, color: clr)),
      subtitle: Text(desc, style: TextStyle(fontSize: 10, color: scheme.outline)),
      value: value,
      onChanged: onChanged,
    );
  }
}

// ═══════════════════════════════════════════
// 提供商详情页（单独设置某个提供商）
// ═══════════════════════════════════════════

/// 移动端提供商详情页：
/// - [profileId] 非空 = 编辑已有提供商（草稿副本，保存后写回）
/// - [profileId] 为空 = 新建提供商（预设一键填充 + 保存入库并设为当前）
class MobileAiProviderDetailPage extends StatefulWidget {
  final String? profileId;
  const MobileAiProviderDetailPage({super.key, this.profileId});

  @override
  State<MobileAiProviderDetailPage> createState() => _MobileAiProviderDetailPageState();
}

class _MobileAiProviderDetailPageState extends State<MobileAiProviderDetailPage> {
  bool _loaded = false;
  bool _forcedNew = false; // 打开时配置已被删除 → 按新建处理
  bool get _isNew => widget.profileId == null || _forcedNew;
  AiProfile _draft = AiProfile();

  /// 底部分栏：0 = 配置，1 = 模型。
  int _tab = 0;

  /// 「获取模型列表」进行中。
  bool _fetchingModels = false;

  /// 「获取账户余额」进行中。
  bool _fetchingBalance = false;

  @override
  void didUpdateWidget(MobileAiProviderDetailPage old) {
    super.didUpdateWidget(old);
    // 页面复用于另一个提供商时重新装载草稿
    if (old.profileId != widget.profileId) {
      _loaded = false;
      _forcedNew = false;
      _draft = AiProfile();
      _tab = 0;
    }
  }

  void _ensureLoaded(BuildContext context) {
    if (_loaded) return;
    _loaded = true;
    final state = context.read<AppState>();
    if (!_isNew) {
      final p = state.config.aiProfiles.where((e) => e.id == widget.profileId).firstOrNull;
      if (p != null) {
        // 编辑草稿副本：直接改配置会污染未保存状态，且触发字段抖动。
        // copyWith 会深拷贝 apiKeys/customHeaders/models，改草稿不影响原配置。
        _draft = p.copyWith();
      } else {
        _draft = AiProfile();
        _forcedNew = true;
      }
    }
  }

  void _mutateDraft(void Function(AiProfile) fn) {
    fn(_draft);
    setState(() {});
  }

  Future<void> _save() async {
    final context = this.context;
    final s = AppStrings.of(context.read<AppState>().config.language);
    if (_draft.name.trim().isEmpty) {
      showToast(context, s.aiProviderNeedName, type: ToastType.warning);
      return;
    }
    final state = context.read<AppState>();
    state.updateConfig((c) {
      final idx = c.aiProfiles.indexWhere((e) => e.id == _draft.id);
      if (idx >= 0) {
        c.aiProfiles[idx] = _draft;
      } else {
        c.aiProfiles.add(_draft);
      }
      // 首个提供商 / 当前指向已失效：自动设为当前
      final activeStillValid = c.aiProfiles.any((e) => e.id == c.activeAiProfileId);
      if (!activeStillValid || c.activeAiProfileId.isEmpty) {
        c.activeAiProfileId = _draft.id;
      }
      return c;
    });
    if (!mounted) return;
    showToast(context, s.aiProviderSaved, type: ToastType.success);
    Navigator.of(context).pop();
  }

  void _delete() {
    final context = this.context;
    final s = AppStrings.of(context.read<AppState>().config.language);
    final scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(s.aiDeleteProviderConfirm, style: TextStyle(color: scheme.onSurface, fontSize: 15)),
        content: Text(_draft.name, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dCtx);
              context.read<AppState>().updateConfig((c) {
                c.aiProfiles.removeWhere((e) => e.id == _draft.id);
                if (c.activeAiProfileId == _draft.id) c.activeAiProfileId = '';
                return c;
              });
              showToast(context, s.aiProviderDeleted, type: ToastType.success);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(s.remove, style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
  }

  /// 把当前草稿同步到 config 默认字段，供 pingAi/listAiModels 使用。
  ///
  /// 注意用 effectiveUrl / effectiveKeys：草稿里 Base URL 与 API 路径是分开的，
  /// 多 Key 模式下主 Key 可能为空——直接取 apiUrl/apiKey 会让测试连接打错地址
  /// 或报「未配置」。
  void _syncToDefaults() {
    final keys = _draft.effectiveKeys;
    context.read<AppState>().updateConfig((c) {
      c.aiApiKey = keys.isEmpty ? '' : keys.first;
      c.aiApiUrl = _draft.effectiveUrl;
      c.aiProvider = _draft.provider;
      return c;
    });
  }

  @override
  Widget build(BuildContext context) {
    _ensureLoaded(context);
    final state = context.read<AppState>();
    // 语言必须用 select 建立依赖：read/initState 只取一次快照，切语言后本页
    // 不会重建，会出现「底部分栏已跟随新语言、标题与表单仍是旧语言」的半中半英。
    final s = AppStrings.of(
        context.select<AppState, String>((st) => st.config.language));
    final scheme = Theme.of(context).colorScheme;

    return withWallpaper(
      context,
      Scaffold(
        backgroundColor: Colors.transparent,
        // bottom: false——底部切换栏（NavGlassShell）自带 bottomSafe padding
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            MobileSubPageTopBar(
              title: Text(_isNew ? s.aiNewProvider : s.aiProviderDetail,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onBack: () => Navigator.of(context).maybePop(),
              actions: [
                // 保存
                MobileGlassPillAction(
                  icon: Icons.check_rounded,
                  tooltip: s.save,
                  color: scheme.onSurface,
                  onTap: _save,
                ),
                // 删除（仅已有提供商）
                if (!_isNew)
                  MobileGlassPillAction(
                    icon: Icons.delete_outline,
                    tooltip: s.remove,
                    color: scheme.error,
                    onTap: _delete,
                  ),
              ],
            ),
            // 「配置 / 模型」两栏内容，切换带淡入+横向位移动画
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                            begin: Offset(_tab == 0 ? -0.04 : 0.04, 0), end: Offset.zero)
                        .animate(anim),
                    child: child,
                  ),
                ),
                child: _tab == 0
                    ? _buildConfigTab(context, state, s, scheme)
                    : _buildModelsTab(context, state, s, scheme),
              ),
            ),
            // 底部分栏切换（跟随全局 navStyle；自身带底部安全区 padding，
            // SafeArea 不再吃掉 bottom，避免双重留白）
            _buildTabBar(s),
          ]),
        ),
      ),
    );
  }

  /// 底部「配置 / 模型」切换栏 —— 跟随全局「底部菜单栏样式」（navStyle 四值：
  /// theme/liquid/blur/gray），与主界面 MobileBottomNav 同一套玻璃视觉。
  /// 此前为自绘 AppCard，只跟随卡片样式，切全局导航样式时这里不跟。
  Widget _buildTabBar(AppStrings s) {
    return MobileNavStyleTabBar(
      items: [
        (Icons.tune_rounded, s.isZh ? '配置' : 'Config'),
        (Icons.widgets_outlined, s.isZh ? '模型' : 'Models'),
      ],
      selectedIndex: _tab,
      onSelected: (i) => setState(() => _tab = i),
    );
  }

  // ── Tab 1：配置 ──

  Widget _buildConfigTab(
      BuildContext context, AppState state, AppStrings s, ColorScheme scheme) {
    final cfg = state.config;
    final clr = scheme.onSurface;
    final isActive = !_isNew && cfg.activeAiProfileId == _draft.id;

    Widget field(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, color: clr)),
            const SizedBox(height: 5),
            child,
          ]),
        );

    return ListView(
      key: const ValueKey('ai_provider_config'),
      // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
      addRepaintBoundaries: false,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: [
        // ── 管理：供应商类型 / 分组 / 启用 / 多Key / Response API / 余额 / 代理 / 自定义请求 ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.settings_outlined,
          title: s.isZh ? '管理' : 'Management',
          children: [
            // 供应商类型（请求协议）：原分段按钮改下拉，与其它设置行统一
            _AiDropdownRow(
              label: s.isZh ? '供应商类型' : 'Provider Type',
              value: _draft.provider,
              entries: [
                ('openai', s.isZh ? 'OpenAI 兼容' : 'OpenAI', Icons.hub_outlined),
                ('anthropic', 'Anthropic', Icons.psychology_outlined),
              ],
              onSelected: (v) => _mutateDraft((d) => d..provider = v),
            ),
            const Divider(height: 18),
            // 分组：自由文本（点击弹输入框）
            _AiNavRow(
              label: s.isZh ? '分组' : 'Group',
              value: _draft.group.isEmpty ? (s.isZh ? '未分组' : 'Ungrouped') : _draft.group,
              onTap: () => _editGroup(context, s),
            ),
            const Divider(height: 18),
            // 是否启用
            _AiSwitchRow(
              label: s.isZh ? '是否启用' : 'Enabled',
              value: _draft.enabled,
              onChanged: (v) => _mutateDraft((d) => d..enabled = v),
            ),
            // 多 Key 模式：开启后进入二级菜单管理 Key 列表
            _AiSwitchRow(
              label: s.isZh ? '多 Key 模式' : 'Multi-Key Mode',
              desc: s.isZh ? '多个 Key 轮换请求，规避单 Key 限流' : 'Rotate keys to avoid rate limits',
              value: _draft.multiKeyEnabled,
              onChanged: (v) {
                _mutateDraft((d) => d..multiKeyEnabled = v);
                if (v) {
                  // 首次开启：至少放一个空位，直接进二级菜单
                  if (_draft.apiKeys.isEmpty) {
                    _draft.apiKeys.add('');
                  }
                  _openMultiKeyPage(context, s);
                }
              },
            ),
            // Response API（/responses）
            _AiSwitchRow(
              label: s.isZh ? 'Response API (/responses)' : 'Response API (/responses)',
              desc: s.isZh ? '使用 /responses 端点而非 /chat/completions' : 'Use /responses instead of /chat/completions',
              value: _draft.useResponsesApi,
              onChanged: (v) => _mutateDraft((d) {
                d.useResponsesApi = v;
                // 切换端点时同步 API 路径，避免用户手改两处
                if (v && (d.apiPath.isEmpty || d.apiPath.contains('chat/completions'))) {
                  d.apiPath = '/responses';
                } else if (!v && d.apiPath.contains('responses')) {
                  d.apiPath = '/chat/completions';
                }
              }),
            ),
            const Divider(height: 18),
            // 获取账户余额
            _AiNavRow(
              label: s.isZh ? '获取账户余额' : 'Account Balance',
              value: _fetchingBalance ? (s.isZh ? '查询中…' : 'Loading…') : '',
              onTap: _fetchingBalance ? null : () => _fetchBalance(context, s),
            ),
            const Divider(height: 18),
            // 网络代理
            _AiNavRow(
              label: s.isZh ? '网络代理' : 'Network Proxy',
              value: _draft.proxyUrl.isEmpty ? (s.isZh ? '直连' : 'Direct') : _draft.proxyUrl,
              onTap: () => _editProxy(context, s),
            ),
            const Divider(height: 18),
            // 自定义请求头
            _AiNavRow(
              label: s.isZh ? '自定义请求' : 'Custom Request',
              value: _draft.customHeaders.isEmpty
                  ? (s.isZh ? '无' : 'None')
                  : (s.isZh ? '${_draft.customHeaders.length} 项' : '${_draft.customHeaders.length} items'),
              onTap: () => _editHeaders(context, s),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ── 连接：名称 / API Key / Base URL / API 路径 ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.link_outlined,
          title: s.isZh ? '连接' : 'Connection',
          children: [
            // 新建：供应商预设一键填充
            if (_isNew) ...[
              field(
                s.aiPreset,
                DropdownMenu<String>(
                  initialSelection: 'openai',
                  requestFocusOnTap: false,
                  width: double.infinity,
                  menuHeight: 240,
                  textStyle: TextStyle(fontSize: 12, color: clr),
                  // 「本地」标注要跟随语言，整表不能再是 const；
                  // 各条目本身仍是 const，避免每帧重建。
                  dropdownMenuEntries: [
                    const DropdownMenuEntry(value: 'openai', label: 'OpenAI'),
                    const DropdownMenuEntry(
                        value: 'anthropic', label: 'Anthropic (Claude)'),
                    const DropdownMenuEntry(value: 'deepseek', label: 'DeepSeek'),
                    DropdownMenuEntry(
                        value: 'ollama',
                        label: s.isZh ? 'Ollama (本地)' : 'Ollama (Local)'),
                  ],
                  onSelected: (preset) {
                    if (preset == null) return;
                    _mutateDraft((d) => applyProfilePreset(d, preset));
                  },
                ),
              ),
            ],
            field(s.isZh ? '名称' : 'Name', _AiField(
              value: _draft.name,
              scheme: scheme,
              onCommit: (v) => _mutateDraft((d) => d..name = v),
            )),
            // 多 Key 模式：不在连接卡片里放单 Key 输入，Keys 统一进二级菜单管理
            if (_draft.multiKeyEnabled)
              field(s.isZh ? 'API Keys' : 'API Keys', _AiNavRow(
                label: s.isZh
                    ? '管理 API Keys（${_draft.apiKeys.where((k) => k.isNotEmpty).length} 个）'
                    : 'Manage API Keys (${_draft.apiKeys.where((k) => k.isNotEmpty).length})',
                value: s.isZh ? '点按进入' : 'Tap to edit',
                onTap: () => _openMultiKeyPage(context, s),
              ))
            else
              field('API Key', _AiField(
                value: _draft.apiKey,
                scheme: scheme,
                obscure: true,
                onCommit: (v) => _mutateDraft((d) => d..apiKey = v),
              )),
            field('API Base URL', _AiField(
              value: _draft.apiUrl,
              scheme: scheme,
              keyboardType: TextInputType.url,
              onCommit: (v) => _mutateDraft((d) => d..apiUrl = v),
            )),
            field(s.isZh ? 'API 路径' : 'API Path', _AiField(
              value: _draft.apiPath,
              scheme: scheme,
              hint: '/chat/completions',
              onCommit: (v) => _mutateDraft((d) => d..apiPath = v),
            )),
            // 实际请求地址预览：Base + 路径拼接结果，避免用户猜
            Text(
              '${s.isZh ? '实际请求' : 'Effective'}: ${_draft.effectiveUrl}',
              style: TextStyle(fontSize: 10, color: scheme.outline),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 生成参数（上下文窗口/最大输出/温度）已移至「模型」选项卡：
        // 点击单个模型进入其设置页，按模型单独配置（未设置时继承提供商默认）。
        // 默认模型在模型列表里点「使用」选择。
        // 设为当前
        if (!_isNew && !isActive)
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              style: AppControlSize.large.buttonStyle(filled: true),
              icon: Icon(Icons.radio_button_off, size: AppControlSize.large.iconSize),
              label: Text(s.aiProviderUse, style: const TextStyle(fontSize: 13)),
              onPressed: () {
                state.updateConfig((c) => c..activeAiProfileId = _draft.id);
                setState(() {});
                showToast(context, s.aiProviderUse, type: ToastType.success);
              },
            ),
          ),
        const SizedBox(height: 8),
        // 测试连接
        // 通栏主行动按钮统一取 large(44)：改造前这两颗一颗 44 一颗 42、
        // 图标一颗 17 一颗 15，上下叠着看就是「差一点点」的错位感
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: AppControlSize.large.buttonStyle(),
            icon: Icon(Icons.wifi_tethering, size: AppControlSize.large.iconSize),
            label: Text(s.aiPing, style: const TextStyle(fontSize: 12)),
            onPressed: () {
              _syncToDefaults();
              pingAi(context, state, s);
            },
          ),
        ),
      ],
    );
  }

  /// 多 Key 编辑器：一行一个 Key，末尾「添加 Key」。
  /// 打开「多 Key 管理」二级菜单：列表增删改，逐项实时写回 [AiProfile.apiKeys]
  ///（详情页草稿），保存仍由顶栏「保存」统一落库。
  Future<void> _openMultiKeyPage(BuildContext context, AppStrings s) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(allowSnapshotting: false, 
      builder: (_) => MobileMultiKeyPage(
        keys: List<String>.of(_draft.apiKeys),
        onChanged: (list) => _mutateDraft((d) => d..apiKeys = list),
      ),
    ));
  }

  /// 打开单个模型的生成参数设置（二级菜单）。
  Future<void> _openModelSettings(
      BuildContext context, AppStrings s, int index) async {
    final defaults = (
      contextWindow: _draft.contextWindow,
      maxTokens: _draft.maxTokens,
      temperature: _draft.temperature,
    );
    await Navigator.of(context).push(MaterialPageRoute<void>(allowSnapshotting: false, 
      builder: (_) => MobileModelSettingsPage(
        entry: _draft.models[index],
        defaultContextWindow: defaults.contextWindow,
        defaultMaxTokens: defaults.maxTokens,
        defaultTemperature: defaults.temperature,
        onChanged: (e) => _mutateDraft((d) => d.models[index] = e),
      ),
    ));
  }

  // ── Tab 2：模型 ──

  Widget _buildModelsTab(
      BuildContext context, AppState state, AppStrings s, ColorScheme scheme) {
    final cfg = state.config;
    final models = _draft.models;
    final isZh = s.isZh;
    // 模型可能上百条（例如从 OpenRouter 拉取）：改用 builder 惰性构建，
    // 每帧只为视口内的卡片创建 widget。此前是 ListView(children: [...for...])，
    // 一次 build 就要 new 出全部卡片，列表一长就掉帧。
    final hasModels = models.isNotEmpty;
    // 空列表时 index 0 是占位卡；末位固定是操作行。
    final itemCount = (hasModels ? models.length : 1) + 1;

    // 列表尾部的操作行：获取 / 添加新 / 清空
    // 三颗统一到 comfortable(36)：改造前两颗按钮虽然都是 42，但图标一颗 15 一颗 16，
    // 右侧 IconButton 又带着 Material 默认的 48×48 最小点击框（比同排按钮高 6px），
    // 一行里出现三种高度 / 三种图标尺寸
    Widget buildActions() => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                style: AppControlSize.comfortable.buttonStyle(),
                icon: _fetchingModels
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.cloud_download_outlined,
                        size: AppControlSize.comfortable.iconSize),
                label: Text(isZh ? '获取' : 'Fetch',
                    style: const TextStyle(fontSize: 12)),
                onPressed:
                    _fetchingModels ? null : () => _fetchModels(context, state, s),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                style: AppControlSize.comfortable.buttonStyle(filled: true),
                icon: Icon(Icons.add, size: AppControlSize.comfortable.iconSize),
                label: Text(isZh ? '添加新…' : 'Add new…',
                    style: const TextStyle(fontSize: 12)),
                onPressed: () => _addModel(context, s),
              ),
            ),
            if (hasModels) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: AppControlSize.comfortable.height,
                height: AppControlSize.comfortable.height,
                child: IconButton(
                  tooltip: isZh ? '清空模型列表' : 'Clear models',
                  icon: Icon(Icons.delete_outline,
                      size: AppControlSize.comfortable.iconSize, color: scheme.error),
                  // 压掉默认的 48×48 最小点击框，否则整行被它顶高
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(
                      width: AppControlSize.comfortable.height,
                      height: AppControlSize.comfortable.height),
                  // 圆角与同排两个按钮一致（默认是圆形）
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppControlSize.comfortable.radius)),
                  ),
                  onPressed: () => _mutateDraft((d) => d.models.clear()),
                ),
              ),
            ],
          ]),
        );

    return ListView.builder(
      key: const ValueKey('ai_provider_models'),
      // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
      addRepaintBoundaries: false,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: itemCount,
      // 卡片自身无状态、不需要保活，关掉 keep-alive 省去每个条目的保活包装。
      // 不设 itemExtent/prototypeItem：行高随能力 chip 是否换行变化
      //（中英文标签宽度不同），固定行高会裁切内容。
      addAutomaticKeepAlives: false,
      itemBuilder: (_, index) {
        if (!hasModels && index == 0) {
          return _AiSectionCard(
            cardStyle: cfg.cardStyle,
            icon: Icons.widgets_outlined,
            title: isZh ? '模型' : 'Models',
            children: [
              Text(
                isZh
                    ? '还没有模型。点下方「获取」从供应商拉取列表，或「添加新…」手动填写。'
                    : 'No models yet. Use "Fetch" to load from the provider, or "Add new…".',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          );
        }
        if (index == itemCount - 1) return buildActions();
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _AiModelCard(
            cardStyle: cfg.cardStyle,
            entry: models[index],
            isActive: models[index].id == _draft.model,
            isZh: isZh,
            onUse: () => _mutateDraft((d) => d..model = models[index].id),
            // 点击模型卡片 → 进入该模型的生成参数设置（二级菜单）
            onOpen: () => _openModelSettings(context, s, index),
            onToggleCapability: (cap, on) => _mutateDraft((d) {
              final caps = d.models[index].capabilities;
              if (on) {
                if (!caps.contains(cap)) caps.add(cap);
              } else {
                caps.remove(cap);
              }
            }),
            onRemove: () => _mutateDraft((d) => d.models.removeAt(index)),
          ),
        );
      },
    );
  }

  // ── 编辑动作 ──

  /// 分组：单行文本输入。
  Future<void> _editGroup(BuildContext context, AppStrings s) async {
    final v = await _promptText(
      context,
      title: s.isZh ? '分组' : 'Group',
      initial: _draft.group,
      hint: s.isZh ? '例：白嫖 / 生产' : 'e.g. free / production',
      s: s,
    );
    if (v != null) _mutateDraft((d) => d..group = v.trim());
  }

  /// 网络代理：单行文本输入（空 = 直连）。
  Future<void> _editProxy(BuildContext context, AppStrings s) async {
    final v = await _promptText(
      context,
      title: s.isZh ? '网络代理' : 'Network Proxy',
      initial: _draft.proxyUrl,
      hint: 'http://127.0.0.1:7890',
      s: s,
    );
    if (v != null) _mutateDraft((d) => d..proxyUrl = v.trim());
  }

  /// 自定义请求头：一行一个 `Key: Value`，便于整体编辑。
  Future<void> _editHeaders(BuildContext context, AppStrings s) async {
    final initial = _draft.customHeaders.entries
        .map((e) => '${e.key}: ${e.value}')
        .join('\n');
    final v = await _promptText(
      context,
      title: s.isZh ? '自定义请求头' : 'Custom Headers',
      initial: initial,
      hint: 'X-Title: FFmpeg++\nHTTP-Referer: https://example.com',
      s: s,
      maxLines: 6,
    );
    if (v == null) return;
    final map = <String, String>{};
    for (final line in v.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim();
      final val = line.substring(idx + 1).trim();
      if (k.isNotEmpty) map[k] = val;
    }
    _mutateDraft((d) => d..customHeaders = map);
  }

  /// 手动添加模型。
  Future<void> _addModel(BuildContext context, AppStrings s) async {
    final v = await _promptText(
      context,
      title: s.isZh ? '添加模型' : 'Add Model',
      initial: '',
      hint: 'gpt-4o / claude-sonnet-4 / kimi-k2',
      s: s,
    );
    final id = v?.trim() ?? '';
    if (id.isEmpty) return;
    if (_draft.models.any((m) => m.id == id)) {
      if (!mounted) return;
      showToast(context, s.isZh ? '该模型已存在' : 'Model already exists',
          type: ToastType.warning);
      return;
    }
    _mutateDraft((d) => d.models.add(AiModelEntry(id: id)));
  }

  /// 从供应商拉取模型列表，合并进草稿（保留已有能力标记）。
  Future<void> _fetchModels(
      BuildContext context, AppState state, AppStrings s) async {
    setState(() => _fetchingModels = true);
    _syncToDefaults();
    try {
      // 复用设置页的模型列表拉取；onPicked 用于「顺带把选中的设为当前模型」。
      await listAiModels(context, state, s, onPicked: (m) {
        _mutateDraft((d) => d..model = m);
      }, onListed: (ids) {
        _mutateDraft((d) {
          // 供应商一次可能返回数百个模型：先把已有 id 收成 Set，
          // 逐条 any() 查重是 O(N²)，这里改成均摊 O(1)。
          final existing = d.models.map((m) => m.id).toSet();
          for (final id in ids) {
            if (id.trim().isEmpty) continue;
            // add 返回 false 表示已有，顺带过滤 ids 自身的重复项
            if (!existing.add(id)) continue;
            d.models.add(AiModelEntry(
              id: id,
              // 依据模型名推断能力，用户可再手动勾选
              capabilities: _guessCapabilities(id),
            ));
          }
        });
      });
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  /// 依据模型名推断能力标记（仅作为初值，用户可改）。
  static List<String> _guessCapabilities(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('embed')) return [AiModelCapability.embedding];
    final caps = <String>[AiModelCapability.chat, AiModelCapability.tools];
    if (lower.contains('vision') ||
        lower.contains('-vl') ||
        lower.contains('4o') ||
        lower.contains('gemini') ||
        lower.contains('claude')) {
      caps.add(AiModelCapability.vision);
    }
    if (lower.contains('think') ||
        lower.contains('reason') ||
        lower.startsWith('o1') ||
        lower.startsWith('o3') ||
        lower.contains('r1')) {
      caps.add(AiModelCapability.reasoning);
    }
    return caps;
  }

  /// 查询账户余额。不同供应商端点差异大，这里按协议尝试常见端点，
  /// 失败时明确告知「该供应商不支持/需手动查询」而不是静默失败。
  Future<void> _fetchBalance(BuildContext context, AppStrings s) async {
    setState(() => _fetchingBalance = true);
    try {
      final result = await fetchAiBalance(_draft);
      if (!mounted) return;
      showToast(
        context,
        result ?? (s.isZh
            ? '该供应商未提供余额查询接口，请在其控制台查看'
            : 'Provider has no balance endpoint; check its console'),
        type: result != null ? ToastType.success : ToastType.info,
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${s.isZh ? '查询失败' : 'Failed'}: $e',
          type: ToastType.error);
    } finally {
      if (mounted) setState(() => _fetchingBalance = false);
    }
  }

  /// 通用文本输入对话框。返回 null = 取消。
  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    required String initial,
    required String hint,
    required AppStrings s,
    int maxLines = 1,
  }) {
    final ctrl = TextEditingController(text: initial);
    final scheme = Theme.of(context).colorScheme;
    return showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(title, style: TextStyle(fontSize: 15, color: scheme.onSurface)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: maxLines,
          minLines: maxLines > 1 ? maxLines : 1,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, ctrl.text),
            child: Text(s.save),
          ),
        ],
      ),
    );
  }
}

/// 「标签 + 右侧值 + 箭头」导航行（点击进入子设置/执行动作）。
class _AiNavRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _AiNavRow({required this.label, this.value = '', this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: scheme.onSurface)),
          ),
          if (value.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ),
          const SizedBox(width: 2),
          Icon(Icons.chevron_right, size: 18, color: scheme.outline),
        ]),
      ),
    );
  }
}

/// 「标签(+说明) + 右侧开关」行。
class _AiSwitchRow extends StatelessWidget {
  final String label;
  final String? desc;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _AiSwitchRow({
    required this.label,
    this.desc,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
            if (desc != null) ...[
              const SizedBox(height: 2),
              Text(desc!,
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }
}

/// 模型条目卡：模型名 + 能力 chips + 「设为当前 / 移除」。
class _AiModelCard extends StatelessWidget {
  final String cardStyle;
  final AiModelEntry entry;
  final bool isActive;
  final bool isZh;
  final VoidCallback onUse;
  /// 点击卡片主体 → 打开该模型的生成参数设置（二级菜单）。
  final VoidCallback onOpen;
  final void Function(String capability, bool enabled) onToggleCapability;
  final VoidCallback onRemove;

  const _AiModelCard({
    required this.cardStyle,
    required this.entry,
    required this.isActive,
    required this.isZh,
    required this.onUse,
    required this.onOpen,
    required this.onToggleCapability,
    required this.onRemove,
  });

  /// 能力 → (显示名, 图标)。
  static (String, IconData) _capLabel(String cap, bool isZh) => switch (cap) {
        AiModelCapability.chat => (isZh ? '聊天' : 'Chat', Icons.chat_bubble_outline),
        AiModelCapability.vision => (isZh ? '视觉' : 'Vision', Icons.image_outlined),
        AiModelCapability.tools => (isZh ? '工具' : 'Tools', Icons.handyman_outlined),
        AiModelCapability.embedding => (isZh ? '嵌入' : 'Embed', Icons.scatter_plot_outlined),
        AiModelCapability.reasoning => (isZh ? '推理' : 'Reason', Icons.psychology_outlined),
        _ => (cap, Icons.label_outline),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      style: cardStyle,
      radius: 16,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(isActive ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: isActive ? scheme.primary : scheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(entry.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                        color: scheme.onSurface)),
              ),
              // 有独立生成参数时显示标记，提示已覆盖提供商默认
              if (entry.contextWindow != null ||
                  entry.maxTokens != null ||
                  entry.temperature != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Tooltip(
                    message: isZh ? '该模型已单独设置生成参数' : 'Per-model generation params set',
                    child: Icon(Icons.tune, size: 14, color: scheme.primary),
                  ),
                ),
              if (!isActive)
                TextButton(
                  onPressed: onUse,
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: Text(isZh ? '使用' : 'Use',
                      style: const TextStyle(fontSize: 11)),
                ),
              IconButton(
                icon: Icon(Icons.close, size: 16, color: scheme.outline),
                tooltip: isZh ? '移除' : 'Remove',
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
              ),
            ]),
            const SizedBox(height: 4),
            // 能力标记：可点选，反映该模型支持的调用方式
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final cap in AiModelCapability.all)
                _capChip(cap, entry.capabilities.contains(cap), scheme),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _capChip(String cap, bool selected, ColorScheme scheme) {
    final (label, icon) = _capLabel(cap, isZh);
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 10)),
      avatar: Icon(icon, size: 12),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (v) => onToggleCapability(cap, v),
    );
  }
}

// ═══════════════════════════════════════════
// 二级菜单：多 Key 管理 / 单模型生成参数
// ═══════════════════════════════════════════

/// 多 Key 管理二级菜单：Key 列表的增删改，逐项实时写回提供商草稿；
/// 落库仍由详情页顶栏「保存」统一完成。
class MobileMultiKeyPage extends StatefulWidget {
  final List<String> keys;
  final ValueChanged<List<String>> onChanged;
  const MobileMultiKeyPage({super.key, required this.keys, required this.onChanged});

  @override
  State<MobileMultiKeyPage> createState() => _MobileMultiKeyPageState();
}

class _MobileMultiKeyPageState extends State<MobileMultiKeyPage> {
  late final List<String> _keys = List<String>.of(widget.keys);

  void _commit() => widget.onChanged(List<String>.of(_keys));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 同详情页：语言要用 select 订阅，否则切语言后本页不重建。
    final s = AppStrings.of(
        context.select<AppState, String>((st) => st.config.language));
    final filled = _keys.where((k) => k.isNotEmpty).length;
    return withWallpaper(
      context,
      Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(children: [
            MobileSubPageTopBar(
              title: Text(s.isZh ? 'API Keys 管理（$filled）' : 'API Keys ($filled)'),
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
                addRepaintBoundaries: false,
                padding: MobileUi.subListPadding(top: 4, bottom: 16),
                children: [
                  _AiSectionCard(
                    cardStyle: context.read<AppState>().config.cardStyle,
                    icon: Icons.vpn_key_outlined,
                    title: s.isZh ? 'Key 列表' : 'Key List',
                    children: [
                      Text(
                        s.isZh
                            ? '请求时按顺序轮换使用这些 Key。清空输入框再返回即删除该 Key。'
                            : 'Keys are rotated in order. Clear a field to remove it.',
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                      const SizedBox(height: 8),
                      for (var i = 0; i < _keys.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(children: [
                            Expanded(
                              child: _AiField(
                                // 绑定索引与内容，删除中间项时不会串位
                                key: ValueKey('mk_${i}_${_keys[i].hashCode}'),
                                value: _keys[i],
                                scheme: scheme,
                                obscure: true,
                                hint: 'sk-...',
                                onCommit: (v) {
                                  _keys[i] = v;
                                  _commit();
                                },
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.remove_circle_outline,
                                  size: 18, color: scheme.error),
                              tooltip: s.remove,
                              onPressed: () {
                                setState(() => _keys.removeAt(i));
                                _commit();
                              },
                            ),
                          ]),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: Text(s.isZh ? '添加 Key' : 'Add Key',
                              style: const TextStyle(fontSize: 12)),
                          onPressed: () => setState(() => _keys.add('')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 单模型生成参数设置（点击模型卡片进入）。
/// 留空 = 继承提供商默认值；填写后覆盖（请求时按当前模型取用）。
class MobileModelSettingsPage extends StatefulWidget {
  final AiModelEntry entry;
  final int defaultContextWindow;
  final int defaultMaxTokens;
  final double defaultTemperature;
  final ValueChanged<AiModelEntry> onChanged;

  const MobileModelSettingsPage({
    super.key,
    required this.entry,
    required this.defaultContextWindow,
    required this.defaultMaxTokens,
    required this.defaultTemperature,
    required this.onChanged,
  });

  @override
  State<MobileModelSettingsPage> createState() =>
      _MobileModelSettingsPageState();
}

class _MobileModelSettingsPageState extends State<MobileModelSettingsPage> {
  late final AiModelEntry _entry = widget.entry.copy();

  void _commit() => widget.onChanged(_entry.copy());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = context.read<AppState>().config;
    // 语言用 select 订阅：read 只在本次 build 取快照，切语言后本页不重建。
    final s = AppStrings.of(
        context.select<AppState, String>((st) => st.config.language));
    final clr = scheme.onSurface;
    final zh = s.isZh;
    final customTemp = _entry.temperature != null;

    Widget field(String label, Widget child, {String? hint}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, color: clr)),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint, style: TextStyle(fontSize: 10, color: scheme.outline)),
            ],
            const SizedBox(height: 5),
            child,
          ]),
        );

    return withWallpaper(
      context,
      Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(children: [
            MobileSubPageTopBar(
              title: Text(zh ? '模型设置' : 'Model Settings'),
              onBack: () => Navigator.of(context).maybePop(),
              actions: [
                // 恢复继承提供商默认
                if (customTemp ||
                    _entry.contextWindow != null ||
                    _entry.maxTokens != null)
                  MobileGlassPillAction(
                    icon: Icons.restart_alt,
                    tooltip: zh ? '恢复继承默认' : 'Inherit defaults',
                    color: scheme.onSurface,
                    onTap: () => setState(() {
                      _entry
                        ..contextWindow = null
                        ..maxTokens = null
                        ..temperature = null;
                      _commit();
                    }),
                  ),
              ],
            ),
            Expanded(
              child: ListView(
                // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
                addRepaintBoundaries: false,
                padding: MobileUi.subListPadding(top: 4, bottom: 16),
                children: [
                  _AiSectionCard(
                    cardStyle: cfg.cardStyle,
                    icon: Icons.widgets_outlined,
                    title: _entry.id,
                    children: [
                      field(zh ? '模型 ID' : 'Model ID', _AiField(
                        value: _entry.id,
                        scheme: scheme,
                        onCommit: (v) {
                          if (v.trim().isNotEmpty) {
                            _entry.id = v.trim();
                            _commit();
                          }
                        },
                      )),
                      field(s.aiContextWindow, _AiField(
                        value: _entry.contextWindow?.toString() ?? '',
                        scheme: scheme,
                        keyboardType: TextInputType.number,
                        hint: '${widget.defaultContextWindow}',
                        onCommit: (v) {
                          final n = int.tryParse(v);
                          _entry.contextWindow = (n != null && n > 0) ? n : null;
                          _commit();
                        },
                      )),
                      field(s.aiMaxTokens, _AiField(
                        value: _entry.maxTokens?.toString() ?? '',
                        scheme: scheme,
                        keyboardType: TextInputType.number,
                        hint: '${widget.defaultMaxTokens}',
                        onCommit: (v) {
                          final n = int.tryParse(v);
                          _entry.maxTokens = (n != null && n > 0) ? n : null;
                          _commit();
                        },
                      )),
                      field(s.aiTemperature,
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(
                              child: Text(
                                customTemp
                                    ? '${s.aiTemperature}: ${_entry.temperature!.toStringAsFixed(1)}'
                                    : '${s.aiTemperature}: ${zh ? '继承默认' : 'Inherit'} (${widget.defaultTemperature.toStringAsFixed(1)})',
                                style: TextStyle(fontSize: 12, color: clr),
                              ),
                            ),
                            // 有自定义值时给一个快捷「回到继承默认」
                            if (customTemp)
                              TextButton(
                                onPressed: () => setState(() {
                                  _entry.temperature = null;
                                  _commit();
                                }),
                                style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 6)),
                                child: Text(zh ? '默认' : 'Default',
                                    style: const TextStyle(fontSize: 11)),
                              ),
                          ]),
                          _TemperatureSlider(
                            // 显示有效值；拖动即产生该模型的自定义温度
                            value: _entry.temperature ?? widget.defaultTemperature,
                            scheme: scheme,
                            onCommit: (v) {
                              setState(() => _entry.temperature = v);
                              _commit();
                            },
                          ),
                        ]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    zh
                        ? '留空的项沿用提供商默认值；设置的值仅对当前选中的这个模型生效。'
                        : 'Empty fields inherit provider defaults; overrides apply only to this model.',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 高级设置页（三级菜单）
// ═══════════════════════════════════════════

/// 移动端 AI 高级设置：图生成模式、思考、自动命名、会话模式、
/// 询问跳过项、自定义系统提示词。
class MobileAiAdvancedPage extends StatelessWidget {
  const MobileAiAdvancedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final cfg = state.config;
        final s = AppStrings.of(cfg.language);
        final scheme = Theme.of(context).colorScheme;
        final clr = scheme.onSurface;

        return withWallpaper(
          context,
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                MobileSubPageTopBar(
                  title: Text(s.aiAdvanced),
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: ListView(
                    // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
                    addRepaintBoundaries: false,
                    padding: MobileUi.subListPadding(top: 4, bottom: 16),
                    children: [
                      // ── 生成（图生成模式 + 思考过程） ──
                      // 原先这张卡把 图生成/思考/自动命名/标题提示词 全塞在一起，
                      // 现按关注点拆成「生成」「命名」两张卡，层级更清晰。
                      _AiSectionCard(
                        cardStyle: cfg.cardStyle,
                        icon: Icons.auto_fix_high_outlined,
                        title: s.isZh ? '生成' : 'Generation',
                        children: [
                          // 图生成模式改为下拉菜单（自带展开动画，避免分段按钮
                          // 在窄屏下两个长标签挤压换行）
                          Row(children: [
                            Expanded(
                              child: Text(s.aiGraphModeLabel,
                                  style: TextStyle(fontSize: 12, color: clr)),
                            ),
                            const SizedBox(width: 8),
                            _AiDropdown(
                              value: cfg.aiGraphMode,
                              entries: [
                                (
                                  'redo',
                                  s.aiGraphModeRedo,
                                  Icons.refresh,
                                ),
                                (
                                  'modify',
                                  s.aiGraphModeModify,
                                  Icons.edit_outlined,
                                ),
                              ],
                              onSelected: (v) =>
                                  state.updateConfig((c) => c..aiGraphMode = v),
                            ),
                          ]),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.aiShowThinking, style: TextStyle(fontSize: 12, color: clr)),
                            subtitle: Text(s.aiShowThinkingDesc,
                                style: TextStyle(fontSize: 10, color: scheme.outline)),
                            value: cfg.aiShowThinking,
                            onChanged: (v) => state.updateConfig((c) => c..aiShowThinking = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // ── 会话命名 ──
                      _AiSectionCard(
                        cardStyle: cfg.cardStyle,
                        icon: Icons.label_outline,
                        title: s.isZh ? '会话命名' : 'Conversation Title',
                        children: [
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.aiAutoTitleLabel, style: TextStyle(fontSize: 12, color: clr)),
                            subtitle: Text(s.aiAutoTitleDesc,
                                style: TextStyle(fontSize: 10, color: scheme.outline)),
                            value: cfg.aiAutoTitle,
                            onChanged: (v) => state.updateConfig((c) => c..aiAutoTitle = v),
                          ),
                          // 展开/收起带动画，避免提示词输入框「瞬间出现」的割裂感
                          AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: cfg.aiAutoTitle
                                ? Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: _AiField(
                                      value: cfg.aiTitlePrompt,
                                      scheme: scheme,
                                      minLines: 2,
                                      maxLines: 4,
                                      onCommit: (v) =>
                                          state.updateConfig((c) => c..aiTitlePrompt = v),
                                    ),
                                  )
                                : const SizedBox(width: double.infinity, height: 0),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // ── 会话模式 + 询问跳过 ──
                      _AiSectionCard(
                        cardStyle: cfg.cardStyle,
                        icon: Icons.forum_outlined,
                        title: s.aiApproveModeLabel,
                        children: [
                          _AiDropdownRow(
                            label: s.aiApproveModeLabel,
                            value: cfg.aiApproveMode,
                            entries: [
                              ('ask', s.aiApproveModeAsk, Icons.help_outline),
                              ('auto', s.aiApproveModeAuto, Icons.bolt_outlined),
                            ],
                            onSelected: (v) =>
                                state.updateConfig((c) => c..aiApproveMode = v),
                          ),
                          const SizedBox(height: 6),
                          Text(s.aiApproveModeDesc,
                              style: TextStyle(fontSize: 10, color: scheme.outline)),
                          const SizedBox(height: 12),
                          Text(s.aiAskSkipLabel, style: TextStyle(fontSize: 12, color: clr)),
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
                                    if (sel) {
                                      set.add(key);
                                    } else {
                                      set.remove(key);
                                    }
                                    c.aiAskSkipTools = set.toList();
                                    return c;
                                  });
                                },
                              ),
                          ]),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // ── 自定义系统提示词 ──
                      _AiSectionCard(
                        cardStyle: cfg.cardStyle,
                        icon: Icons.article_outlined,
                        title: s.aiCustomPrompt,
                        children: [
                          _AiField(
                            value: cfg.aiSystemPrompt,
                            scheme: scheme,
                            hint: s.aiCustomPromptHint,
                            minLines: 3,
                            maxLines: 6,
                            onCommit: (v) => state.updateConfig((c) => c..aiSystemPrompt = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════
// 通用小部件
// ═══════════════════════════════════════════

/// 移动端 AI 设置的分组卡片：图标 + 标题 + 内容。
///
/// 统一各二级/三级页面的分层结构：一张卡只承载一个主题的设置项，
/// 避免此前「一张卡塞十几项」导致的滑动疲劳。
/// AI 设置页的卡片外壳：与设置页的 `_glass(...)` **逐项对齐**。
///
/// 用户反馈「移动端的 AI 功能比较割裂，布局不合适，样式不受设置控制」以及
/// 「MCP/AI 设置界面的 AI 助手比较丑」。原因很具体：这些卡此前是**裸 AppCard**
/// （radius 18、完全没有左右留白），于是比其它二级页的卡宽 24px、圆角也不同；
/// 标题字号 13 也与设置页的 12 不一致。现在统一为：
/// 圆角 20 / 左右留白 12 / 内边距 16·12 / 标题 12·w600·onSurfaceVariant。
class _AiSectionCard extends StatelessWidget {
  final String cardStyle;
  final IconData icon;
  final String title;
  /// 标题下的说明行（可选）。
  final String? subtitle;
  /// 标题右侧控件（如整卡开关 / 箭头）。
  final Widget? trailing;
  /// 整卡点按（如「高级」入口）。
  final VoidCallback? onTap;
  final List<Widget> children;

  const _AiSectionCard({
    required this.cardStyle,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.children = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 17, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
          // 空值元素（null-aware element）：trailing 为空时不占位。
          ?trailing,
        ]),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(subtitle!,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: scheme.outline)),
        ],
        if (children.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...children,
        ],
      ]),
    );
    if (onTap != null) {
      body = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: body,
      );
    }
    return Padding(
      // 左右 12：与设置页 _glass 的卡片留白一致（二级页 = ListView 12 + 卡片 12）。
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: AppCard(style: cardStyle, radius: 20, child: body),
    );
  }
}

/// 移动端 AI 设置下拉菜单宽度上限。
/// 显式给 DropdownMenu width，避免展开面板按最长条目撑开（窄屏溢出、
/// 桌面端「宽度极大」）。
const double _kAiMenuWidth = 156;

/// AI 设置用下拉菜单（自带展开/收起动画）。
/// entries 为 (值, 显示文案, 图标) 三元组。
class _AiDropdown extends StatelessWidget {
  final String value;
  final List<(String, String, IconData)> entries;
  final ValueChanged<String> onSelected;

  const _AiDropdown({
    required this.value,
    required this.entries,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kAiMenuWidth + 8),
      child: DropdownMenu<String>(
        // key 绑定当前值：配置被外部改动后重建时显示最新选中项
        key: ValueKey('aiDropdown_${entries.length}_$value'),
        initialSelection: value,
        requestFocusOnTap: false,
        width: _kAiMenuWidth,
        menuHeight: 240,
        textStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
        dropdownMenuEntries: [
          for (final e in entries)
            DropdownMenuEntry(
              value: e.$1,
              label: e.$2,
              leadingIcon: Icon(e.$3, size: 14),
            ),
        ],
        onSelected: (v) {
          if (v != null) onSelected(v);
        },
      ),
    );
  }
}

/// 「标签 + 右侧下拉」一行。
class _AiDropdownRow extends StatelessWidget {
  final String label;
  final String value;
  final List<(String, String, IconData)> entries;
  final ValueChanged<String> onSelected;

  const _AiDropdownRow({
    required this.label,
    required this.value,
    required this.entries,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Expanded(
        child: Text(label,
            style: TextStyle(fontSize: 12, color: scheme.onSurface)),
      ),
      const SizedBox(width: 8),
      _AiDropdown(value: value, entries: entries, onSelected: onSelected),
    ]);
  }
}

/// 移动端 AI 设置用的文本输入框（全宽圆角、失焦提交）。
class _AiField extends StatefulWidget {
  final String value;
  final ColorScheme scheme;
  final bool obscure;
  final String? hint;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final ValueChanged<String> onCommit;

  /// 控件高度档位：全页固定 [AppControlSize.comfortable]（36）。本页改造前
  /// 输入框纵向内边距写死 `v10`，算出来约 40，且带「眼睛」后缀图标的字段会被
  /// [InputDecorator] 默认的 48×48 图标约束进一步顶高（移动端 48），于是
  /// 同一张卡里 API Key 字段比端口字段高出近 10px。
  ///
  /// 用「常量 + 同名 getter」而不用可选的构造参数：全页每一处 `_AiField` 都吃
  /// 同一档，可选参数从未被显式传过，等于「看着能改、其实哪都没改」的死参数
  /// （analyzer 报 `UNUSED_ELEMENT_PARAMETER`）。保留 getter 是为了不动 build
  /// 里既有的 `size.xxx` 写法。
  static const AppControlSize _size = AppControlSize.comfortable;
  AppControlSize get size => _size;

  const _AiField({
    super.key,
    required this.value,
    required this.scheme,
    required this.onCommit,
    this.obscure = false,
    this.hint,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
  });

  @override
  State<_AiField> createState() => _AiFieldState();
}

class _AiFieldState extends State<_AiField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChanged);
  bool _visible = false;

  /// 关键修复：焦点丢失时也提交。此前只在键盘「完成」时触发 onCommit，
  /// 移动端用户输入完 API Key 后直接点顶栏「保存」——TextField 仅失焦、
  /// 不触发 onSubmitted/onEditingComplete，最后一次输入丢失（表现为
  /// 「API Key 不保存」）。
  void _onFocusChanged() {
    if (!_focus.hasFocus && _ctrl.text != widget.value) {
      widget.onCommit(_ctrl.text);
    }
  }

  @override
  void didUpdateWidget(_AiField old) {
    super.didUpdateWidget(old);
    // 外部值变化同步进输入框（如新建时供应商预设一键填充）；
    // 正在聚焦=用户输入中，不覆盖。
    if (old.value != widget.value && _ctrl.text != widget.value && !_focus.hasFocus) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final clr = scheme.onSurface;
    final size = widget.size;
    final Widget field = TextField(
      controller: _ctrl,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      obscureText: widget.obscure && !_visible,
      style: TextStyle(fontSize: 13, color: clr),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: TextStyle(fontSize: 12, color: scheme.outline),
        filled: true,
        fillColor: scheme.surfaceContainerLow.withAlpha(isDark ? 160 : 190),
        contentPadding: size.fieldPadding,
        // 压平桌面端的 -8px 密度偏移，否则同一份 contentPadding 在两端高度不同
        visualDensity: AppControlSize.fieldDensity,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(size.radius),
          borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(100)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(size.radius),
          borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(100)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(size.radius),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
        // 不带这个约束，带「眼睛」后缀图标的字段会被 InputDecorator 默认的
        // 48×48 图标盒顶高（移动端 48 / 桌面折算后 40），比同卡其它字段高一截
        suffixIconConstraints: AppControlSize.iconSlot,
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(_visible ? Icons.visibility : Icons.visibility_off,
                    size: 16, color: scheme.outline),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => setState(() => _visible = !_visible),
              )
            : null,
      ),
      onSubmitted: widget.onCommit,
      onEditingComplete: () => widget.onCommit(_ctrl.text),
    );
    // 多行字段（标题提示词 2~4 行、系统提示词 3~6 行）不能钉高度，否则只剩一行高
    return widget.maxLines > 1 ? field : size.fieldBox(field);
  }
}

/// 温度滑块（0-2，0.1 步进），提交式更新。
class _TemperatureSlider extends StatefulWidget {
  final double value;
  final ColorScheme scheme;
  final ValueChanged<double> onCommit;
  const _TemperatureSlider({required this.value, required this.scheme, required this.onCommit});

  @override
  State<_TemperatureSlider> createState() => _TemperatureSliderState();
}

class _TemperatureSliderState extends State<_TemperatureSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final v = (_drag ?? widget.value).clamp(0.0, 2.0);
    return Row(children: [
      SizedBox(
        width: 42,
        child: Text(v.toStringAsFixed(1),
            style: TextStyle(fontSize: 12, color: scheme.onSurface, fontWeight: FontWeight.w600)),
      ),
      Expanded(
        // 统一滑杆样式；「拖动只改本地 _drag、松手 onChangeEnd 才提交」的节流语义
        // 保持不变（这正是 AppSlider 推荐的用法）。
        child: AppSlider(
          value: v,
          min: 0,
          max: 2,
          divisions: 20,
          onChanged: (nv) => setState(() => _drag = nv),
          onChangeEnd: (nv) {
            widget.onCommit(nv);
            setState(() => _drag = null);
          },
        ),
      ),
    ]);
  }
}
