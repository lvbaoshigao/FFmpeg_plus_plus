import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/app_card.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/toast.dart';
import 'settings_page.dart'
    show
        applyProfilePreset,
        fetchAiBalance,
        listAiModels,
        pingAi,
        withWallpaperBg;

/// 询问模式下可选「无需确认」的操作（显示名, 内部 key）—— 与桌面端一致。
const _askSkipOptions = <(String, String)>[
  ('保存', 'save'),
  ('撤销/重做', 'undo_redo'),
  ('错误检查', 'error_check'),
  ('清空画布', 'clear_all'),
  ('工具执行', 'tools'),
];

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
        AppCard(
          style: cfg.cardStyle,
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 10),
            child: Column(children: [
              Row(children: [
                Icon(Icons.auto_awesome_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.aiChatTitle,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: clr)),
                ),
                Switch(
                  value: cfg.aiEnabled,
                  onChanged: (v) => state.updateConfig((c) => c..aiEnabled = v),
                ),
              ]),
              if (cfg.aiEnabled) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: Text(s.aiProviders, style: TextStyle(fontSize: 11, color: scheme.outline)),
                ),
                const SizedBox(height: 4),
                if (cfg.aiProfiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 4, 16, 8),
                    child: Text(s.aiNoProviders, style: TextStyle(fontSize: 12, color: scheme.outline)),
                  )
                else
                  for (final p in cfg.aiProfiles)
                    _MobileProviderRow(
                      s: s,
                      scheme: scheme,
                      profile: p,
                      active: cfg.activeAiProfileId == p.id,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => MobileAiProviderDetailPage(profileId: p.id)),
                      ),
                    ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(s.aiNewProvider, style: const TextStyle(fontSize: 12)),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const MobileAiProviderDetailPage()),
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 10),
        // ── 权限 ──
        AppCard(
          style: cfg.cardStyle,
          radius: 18,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
              child: Row(children: [
                Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Text(s.aiPermissions,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: clr)),
              ]),
            ),
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
          ]),
        ),
        const SizedBox(height: 10),
        // ── 高级（三级菜单） ──
        AppCard(
          style: cfg.cardStyle,
          radius: 18,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            leading: Icon(Icons.tune, size: 20, color: scheme.primary),
            title: Text(s.aiAdvanced, style: TextStyle(fontSize: 13, color: clr)),
            trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MobileAiAdvancedPage()),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // ── MCP 服务 ──
        AppCard(
          style: cfg.cardStyle,
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 10),
            child: Column(children: [
              Row(children: [
                Icon(Icons.hardware, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.mcpTitle,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: clr)),
                ),
              ]),
              const SizedBox(height: 2),
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
                                ? scheme.error
                                : state.mcpRunning ? Colors.green : scheme.outline),
                      )
                    : null,
                value: cfg.mcpEnabled,
                onChanged: (v) => state.toggleMcpServer(v),
              ),
              if (cfg.mcpEnabled) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(children: [
                    Text('${s.mcpPort}: ', style: TextStyle(fontSize: 12, color: clr)),
                    SizedBox(
                      width: 90,
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
                      height: 40,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.refresh, size: 14),
                        label: Text(s.isZh ? '应用' : 'Apply', style: const TextStyle(fontSize: 11)),
                        onPressed: () async {
                          state.mcpError = null;
                          await state.stopMcpServer();
                          await state.startMcpServer();
                        },
                      ),
                    ),
                  ]),
                ),
                if (state.mcpRunning && state.mcpToken != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                    child: SelectableText(
                      '${s.isZh ? '局域网访问令牌' : 'LAN access token'}: ${state.mcpToken}',
                      style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 4),
                SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8),
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
              ],
            ]),
          ),
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
        padding: const EdgeInsets.fromLTRB(28, 9, 14, 9),
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
      contentPadding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
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
    final cfg = state.config;
    final s = AppStrings.of(cfg.language);
    final scheme = Theme.of(context).colorScheme;

    return withWallpaperBg(
      context,
      state,
      Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(children: [
            MobileSubPageTopBar(
              title: Text(_isNew ? s.aiNewProvider : s.aiProviderDetail,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15)),
              onBack: () => Navigator.of(context).maybePop(),
              actions: [
                // 保存
                IconButton(
                  tooltip: s.save,
                  icon: const Icon(Icons.check_rounded, size: 20),
                  onPressed: _save,
                ),
                // 删除（仅已有提供商）
                if (!_isNew)
                  IconButton(
                    tooltip: s.remove,
                    icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                    onPressed: _delete,
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
            // 底部分栏切换
            _buildTabBar(s, scheme, cfg.cardStyle),
          ]),
        ),
      ),
    );
  }

  /// 底部「配置 / 模型」切换栏。
  Widget _buildTabBar(AppStrings s, ColorScheme scheme, String cardStyle) {
    Widget item(int index, IconData icon, String label) {
      final selected = _tab == index;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _tab = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // 选中态用主题色 + 轻微放大，无选中态为次要色
              AnimatedScale(
                scale: selected ? 1.0 : 0.92,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: Icon(icon,
                    size: 19,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? scheme.primary : scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: AppCard(
        style: cardStyle,
        radius: 18,
        child: Row(children: [
          item(0, Icons.tune_rounded, s.isZh ? '配置' : 'Config'),
          item(1, Icons.widgets_outlined, s.isZh ? '模型' : 'Models'),
        ]),
      ),
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
            // 多 Key 模式：开启后展开 Key 列表编辑
            _AiSwitchRow(
              label: s.isZh ? '多 Key 模式' : 'Multi-Key Mode',
              desc: s.isZh ? '多个 Key 轮换请求，规避单 Key 限流' : 'Rotate keys to avoid rate limits',
              value: _draft.multiKeyEnabled,
              onChanged: (v) => _mutateDraft((d) => d..multiKeyEnabled = v),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _draft.multiKeyEnabled
                  ? _buildMultiKeyEditor(context, s, scheme)
                  : const SizedBox(width: double.infinity, height: 0),
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
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: 'openai', label: 'OpenAI'),
                    DropdownMenuEntry(value: 'anthropic', label: 'Anthropic (Claude)'),
                    DropdownMenuEntry(value: 'deepseek', label: 'DeepSeek'),
                    DropdownMenuEntry(value: 'ollama', label: 'Ollama (本地)'),
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
        const SizedBox(height: 10),
        // ── 生成参数 ──
        _AiSectionCard(
          cardStyle: cfg.cardStyle,
          icon: Icons.tune_outlined,
          title: s.isZh ? '生成参数' : 'Generation',
          children: [
            field(s.aiModel, _AiField(
              value: _draft.model,
              scheme: scheme,
              onCommit: (v) => _mutateDraft((d) => d..model = v),
            )),
            field(s.aiContextWindow, _AiField(
              value: _draft.contextWindow.toString(),
              scheme: scheme,
              keyboardType: TextInputType.number,
              onCommit: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) _mutateDraft((d) => d..contextWindow = n);
              },
            )),
            field(s.aiMaxTokens, _AiField(
              value: _draft.maxTokens.toString(),
              scheme: scheme,
              keyboardType: TextInputType.number,
              onCommit: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) _mutateDraft((d) => d..maxTokens = n);
              },
            )),
            field(s.aiTemperature, _TemperatureSlider(
              value: _draft.temperature,
              scheme: scheme,
              onCommit: (v) => _mutateDraft((d) => d..temperature = v),
            )),
          ],
        ),
        const SizedBox(height: 12),
        // 设为当前
        if (!_isNew && !isActive)
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.radio_button_off, size: 17),
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
        SizedBox(
          width: double.infinity,
          height: 42,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.wifi_tethering, size: 15),
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
  Widget _buildMultiKeyEditor(
      BuildContext context, AppStrings s, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < _draft.apiKeys.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(
                child: _AiField(
                  // key 绑定索引与内容，删除中间项时不会串位
                  key: ValueKey('multikey_${i}_${_draft.apiKeys[i].hashCode}'),
                  value: _draft.apiKeys[i],
                  scheme: scheme,
                  obscure: true,
                  hint: 'sk-...',
                  onCommit: (v) => _mutateDraft((d) => d.apiKeys[i] = v),
                ),
              ),
              IconButton(
                icon: Icon(Icons.remove_circle_outline, size: 18, color: scheme.error),
                tooltip: s.remove,
                onPressed: () => _mutateDraft((d) => d.apiKeys.removeAt(i)),
              ),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: Text(s.isZh ? '添加 Key' : 'Add Key',
                style: const TextStyle(fontSize: 12)),
            onPressed: () => _mutateDraft((d) => d.apiKeys.add('')),
          ),
        ),
      ]),
    );
  }

  // ── Tab 2：模型 ──

  Widget _buildModelsTab(
      BuildContext context, AppState state, AppStrings s, ColorScheme scheme) {
    final cfg = state.config;
    final models = _draft.models;

    return ListView(
      key: const ValueKey('ai_provider_models'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: [
        if (models.isEmpty)
          _AiSectionCard(
            cardStyle: cfg.cardStyle,
            icon: Icons.widgets_outlined,
            title: s.isZh ? '模型' : 'Models',
            children: [
              Text(
                s.isZh
                    ? '还没有模型。点下方「获取」从供应商拉取列表，或「添加新…」手动填写。'
                    : 'No models yet. Use "Fetch" to load from the provider, or "Add new…".',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          )
        else
          for (var i = 0; i < models.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _AiModelCard(
                cardStyle: cfg.cardStyle,
                entry: models[i],
                isActive: models[i].id == _draft.model,
                isZh: s.isZh,
                onUse: () => _mutateDraft((d) => d..model = models[i].id),
                onToggleCapability: (cap, on) => _mutateDraft((d) {
                  final caps = d.models[i].capabilities;
                  if (on) {
                    if (!caps.contains(cap)) caps.add(cap);
                  } else {
                    caps.remove(cap);
                  }
                }),
                onRemove: () => _mutateDraft((d) => d.models.removeAt(i)),
              ),
            ),
        const SizedBox(height: 4),
        // 获取 / 添加新 / 清空
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 42,
              child: OutlinedButton.icon(
                icon: _fetchingModels
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_download_outlined, size: 15),
                label: Text(s.isZh ? '获取' : 'Fetch',
                    style: const TextStyle(fontSize: 12)),
                onPressed: _fetchingModels ? null : () => _fetchModels(context, state, s),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 42,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.add, size: 16),
                label: Text(s.isZh ? '添加新…' : 'Add new…',
                    style: const TextStyle(fontSize: 12)),
                onPressed: () => _addModel(context, s),
              ),
            ),
          ),
          if (models.isNotEmpty) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 42,
              child: IconButton(
                tooltip: s.isZh ? '清空模型列表' : 'Clear models',
                icon: Icon(Icons.delete_outline, size: 19, color: scheme.error),
                onPressed: () => _mutateDraft((d) => d.models.clear()),
              ),
            ),
          ],
        ]),
      ],
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
          for (final id in ids) {
            if (id.trim().isEmpty) continue;
            if (d.models.any((m) => m.id == id)) continue;
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
  final void Function(String capability, bool enabled) onToggleCapability;
  final VoidCallback onRemove;

  const _AiModelCard({
    required this.cardStyle,
    required this.entry,
    required this.isActive,
    required this.isZh,
    required this.onUse,
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

        return withWallpaperBg(
          context,
          state,
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                MobileSubPageTopBar(
                  title: Text(s.aiAdvanced, style: const TextStyle(fontSize: 15)),
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
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
                            for (final op in _askSkipOptions)
                              FilterChip(
                                label: Text(op.$1, style: const TextStyle(fontSize: 11)),
                                selected: cfg.aiAskSkipTools.contains(op.$2),
                                visualDensity: VisualDensity.compact,
                                onSelected: (sel) {
                                  state.updateConfig((c) {
                                    final set = c.aiAskSkipTools.toSet();
                                    if (sel) {
                                      set.add(op.$2);
                                    } else {
                                      set.remove(op.$2);
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
class _AiSectionCard extends StatelessWidget {
  final String cardStyle;
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _AiSectionCard({
    required this.cardStyle,
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      style: cardStyle,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 17, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface)),
            ),
          ]),
          const SizedBox(height: 10),
          ...children,
        ]),
      ),
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
  bool _visible = false;

  @override
  void didUpdateWidget(_AiField old) {
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
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final clr = scheme.onSurface;
    return TextField(
      controller: _ctrl,
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(100)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(100)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(_visible ? Icons.visibility : Icons.visibility_off,
                    size: 16, color: scheme.outline),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => setState(() => _visible = !_visible),
              )
            : null,
      ),
      onSubmitted: widget.onCommit,
      onEditingComplete: () => widget.onCommit(_ctrl.text),
    );
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
        child: Slider(
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
