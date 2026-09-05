import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/app_card.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/toast.dart';
import 'settings_page.dart'
    show applyProfilePreset, listAiModels, pingAi, withWallpaperBg;

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

  @override
  void didUpdateWidget(MobileAiProviderDetailPage old) {
    super.didUpdateWidget(old);
    // 页面复用于另一个提供商时重新装载草稿
    if (old.profileId != widget.profileId) {
      _loaded = false;
      _forcedNew = false;
      _draft = AiProfile();
    }
  }

  void _ensureLoaded(BuildContext context) {
    if (_loaded) return;
    _loaded = true;
    final state = context.read<AppState>();
    if (!_isNew) {
      final p = state.config.aiProfiles.where((e) => e.id == widget.profileId).firstOrNull;
      if (p != null) {
        // 编辑草稿副本：直接改配置会污染未保存状态，且触发字段抖动
        _draft = AiProfile(
          id: p.id,
          name: p.name,
          enabled: p.enabled,
          provider: p.provider,
          apiKey: p.apiKey,
          apiUrl: p.apiUrl,
          model: p.model,
          contextWindow: p.contextWindow,
          maxTokens: p.maxTokens,
          temperature: p.temperature,
        );
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
  void _syncToDefaults() {
    context.read<AppState>().updateConfig((c) {
      c.aiApiKey = _draft.apiKey;
      c.aiApiUrl = _draft.apiUrl;
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

    return withWallpaperBg(
      context,
      state,
      Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(children: [
            MobileSubPageTopBar(
              title: Text(_isNew ? s.aiNewProvider : s.aiProviderDetail,
                  style: const TextStyle(fontSize: 15)),
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                children: [
                  AppCard(
                    style: cfg.cardStyle,
                    radius: 18,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                      child: Column(children: [
                        // 新建：供应商预设一键填充
                        if (_isNew) ...[
                          field(s.aiPreset,
                              DropdownMenu<String>(
                                initialSelection: 'openai',
                                requestFocusOnTap: false,
                                width: double.infinity,
                                textStyle: TextStyle(fontSize: 12, color: clr),
                                dropdownMenuEntries: const [
                                  DropdownMenuEntry(value: 'openai', label: 'OpenAI'),
                                  DropdownMenuEntry(value: 'anthropic', label: 'Anthropic (Claude)'),
                                  DropdownMenuEntry(value: 'deepseek', label: 'DeepSeek'),
                                  DropdownMenuEntry(value: 'ollama', label: 'Ollama (本地)'),
                                ],
                                onSelected: (preset) {
                                  if (preset == null) return;
                                  _mutateDraft((d) {
                                    applyProfilePreset(d, preset);
                                  });
                                },
                              )),
                          const SizedBox(height: 4),
                        ],
                        // 配置名
                        field(s.aiName, _AiField(
                          value: _draft.name,
                          scheme: scheme,
                          onCommit: (v) => _mutateDraft((d) => d..name = v),
                        )),
                        // 请求协议
                        field(s.aiProtocol, SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(value: 'openai',
                                label: Text(s.isZh ? 'OpenAI 兼容' : 'OpenAI',
                                    style: const TextStyle(fontSize: 11))),
                            ButtonSegment(value: 'anthropic',
                                label: Text('Anthropic', style: const TextStyle(fontSize: 11))),
                          ],
                          selected: {_draft.provider},
                          onSelectionChanged: (v) => _mutateDraft((d) => d..provider = v.first),
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                        )),
                        const SizedBox(height: 4),
                        // API Key
                        field(s.aiApiKey, _AiField(
                          value: _draft.apiKey,
                          scheme: scheme,
                          obscure: true,
                          onCommit: (v) => _mutateDraft((d) => d..apiKey = v),
                        )),
                        // API 地址
                        field(s.aiApiUrl, _AiField(
                          value: _draft.apiUrl,
                          scheme: scheme,
                          keyboardType: TextInputType.url,
                          onCommit: (v) => _mutateDraft((d) => d..apiUrl = v),
                        )),
                        // 模型
                        field(s.aiModel, _AiField(
                          value: _draft.model,
                          scheme: scheme,
                          onCommit: (v) => _mutateDraft((d) => d..model = v),
                        )),
                        // 上下文窗口
                        field(s.aiContextWindow, _AiField(
                          value: _draft.contextWindow.toString(),
                          scheme: scheme,
                          keyboardType: TextInputType.number,
                          onCommit: (v) {
                            final n = int.tryParse(v);
                            if (n != null && n > 0) _mutateDraft((d) => d..contextWindow = n);
                          },
                        )),
                        // 最大输出 token
                        field(s.aiMaxTokens, _AiField(
                          value: _draft.maxTokens.toString(),
                          scheme: scheme,
                          keyboardType: TextInputType.number,
                          onCommit: (v) {
                            final n = int.tryParse(v);
                            if (n != null && n > 0) _mutateDraft((d) => d..maxTokens = n);
                          },
                        )),
                        // 温度
                        field(s.aiTemperature, _TemperatureSlider(
                          value: _draft.temperature,
                          scheme: scheme,
                          onCommit: (v) => _mutateDraft((d) => d..temperature = v),
                        )),
                        // 启用开关（仅编辑已有提供商）
                        if (!_isNew)
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.isZh ? '启用此提供商' : 'Enable this provider',
                                style: TextStyle(fontSize: 12, color: clr)),
                            value: _draft.enabled,
                            onChanged: (v) => _mutateDraft((d) => d..enabled = v),
                          ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 保存
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.save_outlined, size: 17),
                      label: Text(s.save, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      onPressed: _save,
                    ),
                  ),
                  // 设为当前
                  if (!_isNew && !isActive) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: FilledButton.tonalIcon(
                        icon: Icon(
                          isActive ? Icons.radio_button_checked : Icons.radio_button_off,
                          size: 17,
                        ),
                        label: Text(s.aiProviderUse, style: const TextStyle(fontSize: 13)),
                        onPressed: () {
                          state.updateConfig((c) => c..activeAiProfileId = _draft.id);
                          setState(() {});
                          showToast(context, s.aiProviderUse, type: ToastType.success);
                        },
                      ),
                    ),
                  ],
                  // 测试连接 / 获取模型列表
                  Row(children: [
                    Expanded(
                      child: SizedBox(
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
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 42,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.list, size: 15),
                          label: Text(s.aiListModels, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            _syncToDefaults();
                            listAiModels(context, state, s, onPicked: (m) {
                              _mutateDraft((d) => d..model = m);
                            });
                          },
                        ),
                      ),
                    ),
                  ]),
                  // 删除（仅已有提供商）
                  if (!_isNew)
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: Text(s.isZh ? '删除此提供商' : 'Delete this provider',
                            style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(foregroundColor: scheme.error),
                        onPressed: _delete,
                      ),
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
                      // 图生成模式 / 思考 / 自动命名
                      AppCard(
                        style: cfg.cardStyle,
                        radius: 18,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                          child: Column(children: [
                            Text(s.aiGraphModeLabel, style: TextStyle(fontSize: 12, color: clr)),
                            const SizedBox(height: 6),
                            SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: 'redo', label: Text(s.aiGraphModeRedo)),
                                ButtonSegment(value: 'modify', label: Text(s.aiGraphModeModify)),
                              ],
                              selected: {cfg.aiGraphMode},
                              onSelectionChanged: (v) {
                                state.updateConfig((c) => c..aiGraphMode = v.first);
                              },
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            ),
                            const SizedBox(height: 8),
                            SwitchListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(s.aiShowThinking, style: TextStyle(fontSize: 12, color: clr)),
                              subtitle: Text(s.aiShowThinkingDesc,
                                  style: TextStyle(fontSize: 10, color: scheme.outline)),
                              value: cfg.aiShowThinking,
                              onChanged: (v) => state.updateConfig((c) => c..aiShowThinking = v),
                            ),
                            SwitchListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(s.aiAutoTitleLabel, style: TextStyle(fontSize: 12, color: clr)),
                              subtitle: Text(s.aiAutoTitleDesc,
                                  style: TextStyle(fontSize: 10, color: scheme.outline)),
                              value: cfg.aiAutoTitle,
                              onChanged: (v) => state.updateConfig((c) => c..aiAutoTitle = v),
                            ),
                            if (cfg.aiAutoTitle)
                              Padding(
                                padding: const EdgeInsets.only(top: 6, left: 8),
                                child: _AiField(
                                  value: cfg.aiTitlePrompt,
                                  scheme: scheme,
                                  minLines: 2,
                                  maxLines: 4,
                                  onCommit: (v) => state.updateConfig((c) => c..aiTitlePrompt = v),
                                ),
                              ),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // 会话模式 + 询问跳过
                      AppCard(
                        style: cfg.cardStyle,
                        radius: 18,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                          child: Column(children: [
                            Text(s.aiApproveModeLabel, style: TextStyle(fontSize: 12, color: clr)),
                            const SizedBox(height: 6),
                            SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: 'ask',
                                    label: Text(s.aiApproveModeAsk, style: const TextStyle(fontSize: 11))),
                                ButtonSegment(value: 'auto',
                                    label: Text(s.aiApproveModeAuto, style: const TextStyle(fontSize: 11))),
                              ],
                              selected: {cfg.aiApproveMode},
                              onSelectionChanged: (v) {
                                state.updateConfig((c) => c..aiApproveMode = v.first);
                              },
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            ),
                            const SizedBox(height: 6),
                            Text(s.aiApproveModeDesc, style: TextStyle(fontSize: 10, color: scheme.outline)),
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
                          ]),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // 自定义系统提示词
                      AppCard(
                        style: cfg.cardStyle,
                        radius: 18,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.aiCustomPrompt, style: TextStyle(fontSize: 12, color: clr)),
                            const SizedBox(height: 6),
                            _AiField(
                              value: cfg.aiSystemPrompt,
                              scheme: scheme,
                              hint: s.aiCustomPromptHint,
                              minLines: 3,
                              maxLines: 6,
                              onCommit: (v) => state.updateConfig((c) => c..aiSystemPrompt = v),
                            ),
                          ]),
                        ),
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
