import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_control_size.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_strings.dart';
import '../theme/settings_typography.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/liquid_modality_pills.dart';
import '../widgets/liquid_stretch_tabs.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/model_editor_sheet.dart';
import '../widgets/option_menu_bar.dart';
import '../widgets/toast.dart';
import '../widgets/wallpaper_background.dart';
import 'settings_page.dart'
    show applyProfilePreset, fetchAiBalance, listAiModels, pingAi;

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

/// 提供商图标 / 品牌色的统一映射。
///
/// 品牌色只作为图标块的点缀：块本身仍用主题的玻璃/表面色，因此切主题、
/// 切亮暗时不会出现「一整块固定绿色贴在深色界面上」的割裂感。
class _ProviderLook {
  final IconData icon;
  final Color color;
  const _ProviderLook(this.icon, this.color);
}

_ProviderLook _providerLook(AiProfile p, ColorScheme scheme) {
  final key = '${p.name} ${p.provider}'.toLowerCase();
  if (key.contains('anthropic') || key.contains('claude')) {
    return const _ProviderLook(
      Icons.psychology_alt_outlined,
      Color(0xFFD97757),
    );
  }
  if (key.contains('deepseek')) {
    return const _ProviderLook(Icons.waves, Color(0xFF5B7CFF));
  }
  if (key.contains('ollama')) {
    return const _ProviderLook(Icons.dns_outlined, Color(0xFF9A7BFF));
  }
  if (key.contains('google') || key.contains('gemini')) {
    return const _ProviderLook(Icons.auto_awesome, Color(0xFF4285F4));
  }
  if (key.contains('openai') || key.contains('gpt')) {
    return const _ProviderLook(Icons.blur_on, Color(0xFF10A37F));
  }
  return _ProviderLook(Icons.view_in_ar_outlined, scheme.tertiary);
}

bool _useMobileAiLayout(BuildContext context) =>
    isMobilePlatform || MediaQuery.sizeOf(context).width < 700;

/// 提供商下所有模型 id（去重，含当前选中的 [AiProfile.model]）。
List<String> _allModelIds(AiProfile p) {
  final ids = <String>[];
  final seen = <String>{};
  void add(String id) {
    final v = id.trim();
    if (v.isEmpty) return;
    if (!seen.add(v.toLowerCase())) return;
    ids.add(v);
  }

  for (final m in p.models) {
    add(m.id);
  }
  add(p.model);
  return ids;
}

int _modelCount(AiProfile p) => _allModelIds(p).length;

/// 搜索归一化：忽略空格、连字符、点、下划线、冒号与斜杠。
///
/// 设计稿里输入 "gpt4" 能命中 "GPT-4o"、"claude35" 能命中
/// "claude-3.5-sonnet" —— 用户不会严格复刻模型 id 的分隔符。
String _normSearch(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[ \-_.:/]+'), '');

bool _providerMatches(AiProfile p, String query) {
  final q = _normSearch(query.trim());
  if (q.isEmpty) return true;
  if (_normSearch(p.name).contains(q)) return true;
  if (_normSearch(p.group).contains(q)) return true;
  if (_normSearch(p.provider).contains(q)) return true;
  if (_normSearch(p.apiUrl).contains(q)) return true;
  if (_normSearch(p.model).contains(q)) return true;
  for (final m in p.models) {
    if (_normSearch(m.id).contains(q)) return true;
    for (final cap in m.capabilities) {
      if (_normSearch(cap).contains(q)) return true;
    }
  }
  return false;
}

/// 搜索时显示在卡片底部的模型 chip：优先展示命中关键词的模型，
/// 只命中提供商名称时退化为前 3 个模型。
List<String> _chipModels(AiProfile p, String query) {
  final q = _normSearch(query.trim());
  if (q.isEmpty) return const [];
  final all = _allModelIds(p);
  final hits = [
    for (final id in all)
      if (_normSearch(id).contains(q)) id,
  ];
  final picked = hits.isNotEmpty ? hits : all;
  return picked.take(3).toList();
}

/// PC 与移动端共用的「MCP / AI」设置内容。
///
/// 结构：
/// - 首屏 Hero：提供商标题 + 统计 + AI 助手开关；
/// - 玻璃搜索胶囊：支持名称 / 模型搜索，带筛选、清空、加载态与无结果态；
/// - 提供商卡片列表 + 添加提供商（全部走 AppCard，跟随全局卡片玻璃）；
/// - MCP 服务 / 权限 / 高级设置（搜索态下自动收起，专注结果）。
Widget aiSettingsContent(BuildContext ctx, AppState state) {
  if (!_useMobileAiLayout(ctx)) {
    return Consumer<AppState>(
      builder: (context, state, _) => _DesktopAiSettingsOverview(state: state),
    );
  }
  return Consumer<AppState>(
    builder: (context, state, _) => _MobileAiSettingsOverview(state: state),
  );
}

class _DesktopAiSettingsOverview extends StatelessWidget {
  final AppState state;

  const _DesktopAiSettingsOverview({required this.state});

  @override
  Widget build(BuildContext context) {
    final cfg = state.config;
    final s = AppStrings.of(cfg.language);
    final scheme = Theme.of(context).colorScheme;
    final totalModels = cfg.aiProfiles.fold<int>(
      0,
      (count, profile) => count + _modelCount(profile),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final left = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AiProviderEntry(cfg: cfg, state: state, s: s, scheme: scheme),
            const SizedBox(height: 12),
            _PermissionsSection(cfg: cfg, s: s, state: state),
          ],
        );
        final right = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _McpSection(cfg: cfg, s: s, state: state, scheme: scheme),
            const SizedBox(height: 12),
            _AdvancedSection(cfg: cfg, s: s, scheme: scheme),
          ],
        );

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: _AiProvidersHero(
                    cfg: cfg,
                    s: s,
                    scheme: scheme,
                    providerCount: cfg.aiProfiles.length,
                    modelCount: totalModels,
                    onAiEnabledChanged: (enabled) => state.updateConfig(
                      (config) => config..aiEnabled = enabled,
                    ),
                    onMcpEnabledChanged: state.toggleMcpServer,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: left),
                            const SizedBox(width: 14),
                            Expanded(child: right),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [left, const SizedBox(height: 12), right],
                        ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 「MCP / AI」一级页：提供商只保留一个入口，点进去才是提供商列表二级页。
class MobileAiProvidersPage extends StatelessWidget {
  final AppState state;

  const MobileAiProvidersPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(state.config.language);
    final desktop = !_useMobileAiLayout(context);
    return withWallpaper(
      context,
      Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: Column(
                  children: [
                    if (desktop)
                      _DesktopProviderHeader(
                        title: s.aiProviders,
                        onBack: () => Navigator.of(context).maybePop(),
                      )
                    else
                      MobileSubPageTopBar(
                        title: Text(s.aiProviders),
                        onBack: () => Navigator.of(context).maybePop(),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: desktop ? 1120 : double.infinity,
                            ),
                            child: _MobileAiSettingsView(state: state),
                          ),
                        ),
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
}

class _DesktopProviderHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final List<Widget> actions;

  const _DesktopProviderHeader({
    required this.title,
    required this.onBack,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return GlassTopBar(
      title: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      actions: actions,
    );
  }
}

class _MobileAiSettingsOverview extends StatelessWidget {
  final AppState state;

  const _MobileAiSettingsOverview({required this.state});

  @override
  Widget build(BuildContext context) {
    final cfg = state.config;
    final s = AppStrings.of(cfg.language);
    final scheme = Theme.of(context).colorScheme;
    final totalModels = cfg.aiProfiles.fold<int>(
      0,
      (n, p) => n + _modelCount(p),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: _AiProvidersHero(
            cfg: cfg,
            s: s,
            scheme: scheme,
            providerCount: cfg.aiProfiles.length,
            modelCount: totalModels,
            onAiEnabledChanged: (v) =>
                state.updateConfig((c) => c..aiEnabled = v),
            onMcpEnabledChanged: state.toggleMcpServer,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _AiProviderEntry(cfg: cfg, state: state, s: s, scheme: scheme),
        ),
        const SizedBox(height: 16),
        // _AiSectionCard already applies the shared 12px horizontal inset.
        // Do not wrap these in another Padding: that made MCP/permissions/
        // advanced cards narrower than the provider entry above.
        _McpSection(cfg: cfg, s: s, state: state, scheme: scheme),
        const SizedBox(height: 12),
        _PermissionsSection(cfg: cfg, s: s, state: state),
        const SizedBox(height: 12),
        _AdvancedSection(cfg: cfg, s: s, scheme: scheme),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// 一级页的「提供商」入口；列表、搜索、添加全部在二级页。
class _AiProviderEntry extends StatelessWidget {
  final AppConfig cfg;
  final AppState state;
  final AppStrings s;
  final ColorScheme scheme;

  const _AiProviderEntry({
    required this.cfg,
    required this.state,
    required this.s,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final active = cfg.aiProfiles
        .where((p) => p.id == cfg.activeAiProfileId)
        .firstOrNull;
    final look = active == null
        ? _ProviderLook(Icons.auto_awesome_outlined, scheme.primary)
        : _providerLook(active, scheme);
    return AppCard(
      style: cfg.cardStyle,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 2, 8, 2),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: look.color.withAlpha(28),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(look.icon, size: 19, color: look.color),
        ),
        title: Text(
          s.aiProviders,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        subtitle: Text(
          active == null
              ? s.aiNoProviders
              : '${active.name} · ${s.aiModelCount(_modelCount(active))}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SettingsTypography.description.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              allowSnapshotting: false,
              builder: (_) => MobileAiProvidersPage(state: state),
            ),
          );
        },
      ),
    );
  }
}

class _MobileAiSettingsView extends StatefulWidget {
  final AppState state;
  const _MobileAiSettingsView({required this.state});

  @override
  State<_MobileAiSettingsView> createState() => _MobileAiSettingsViewState();
}

class _MobileAiSettingsViewState extends State<_MobileAiSettingsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'ai_provider_search');
  Timer? _debounce;
  String _query = '';
  bool _searching = false;
  bool _enabledOnly = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final query = value.trim();
    _debounce?.cancel();
    if (query.isEmpty) {
      // 无条件重建：清空 / 删除到空时哪怕查询本来就是空的，
      // 也要让搜索框右侧的「清空」按钮及时切回「筛选」。
      setState(() {
        _query = '';
        _searching = false;
      });
      return;
    }
    // 本地过滤也保留一个很短的去抖延迟：
    // 1) 连续输入时只处理最后一次，避免每个字符都重建整张提供商列表；
    // 2) 这段极短的时间正好把「正在搜索中…」的加载态呈现出来，
    //    与设计稿的搜索状态一致（而不是一闪而过的空帧）。
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() {
        _query = query;
        _searching = false;
      });
    });
  }

  void _clearSearch({bool unfocus = false}) {
    _debounce?.cancel();
    _searchCtrl.clear();
    setState(() {
      _query = '';
      _searching = false;
    });
    if (unfocus) _searchFocus.unfocus();
  }

  void _openProvider(AiProfile p) {
    _searchFocus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        allowSnapshotting: false,
        builder: (_) => MobileAiProviderDetailPage(profileId: p.id),
      ),
    );
  }

  void _openNewProvider() {
    _searchFocus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        allowSnapshotting: false,
        builder: (_) => const MobileAiProviderDetailPage(),
      ),
    );
  }

  List<AiProfile> _visibleProviders(String query) {
    final cfg = widget.state.config;
    final list = cfg.aiProfiles.where((p) {
      if (_enabledOnly && !p.enabled) return false;
      return _providerMatches(p, query);
    }).toList();
    list.sort((a, b) {
      int rank(AiProfile p) =>
          p.id == cfg.activeAiProfileId ? 0 : (p.enabled ? 1 : 2);
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cfg = state.config;
    final s = AppStrings.of(cfg.language);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 搜索态：有查询（或正在搜索）时收起 Hero 与下半屏设置，把空间让给结果；
    // 不按「输入框是否聚焦」收起 —— 否则用户聚焦后清空内容会找不到退出路径。
    final searchingMode = _searching || _query.isNotEmpty;
    final providers = _visibleProviders(_query);
    final totalModels = cfg.aiProfiles.fold<int>(
      0,
      (n, p) => n + _modelCount(p),
    );
    final showResultsHeader =
        _query.isNotEmpty && !_searching && providers.isNotEmpty;
    final noEnabled = _enabledOnly && providers.isEmpty && _query.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero：进入搜索态后收起，把纵向空间让给结果（设计稿的搜索态没有标题区）。
        AnimatedSize(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: searchingMode
              ? const SizedBox(width: double.infinity, height: 0)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
                  child: _AiProvidersHero(
                    cfg: cfg,
                    s: s,
                    scheme: scheme,
                    providerCount: cfg.aiProfiles.length,
                    modelCount: totalModels,
                    onAiEnabledChanged: (v) =>
                        state.updateConfig((c) => c..aiEnabled = v),
                    onMcpEnabledChanged: state.toggleMcpServer,
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _AiSearchBar(
            pillStyle: cfg.pillStyle,
            controller: _searchCtrl,
            focusNode: _searchFocus,
            s: s,
            scheme: scheme,
            showClear: _searchCtrl.text.isNotEmpty,
            filterActive: _enabledOnly,
            onChanged: _onQueryChanged,
            onFilter: () => setState(() => _enabledOnly = !_enabledOnly),
            onClear: () => _clearSearch(),
          ),
        ),
        const SizedBox(height: 14),
        if (showResultsHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(
              s.aiSearchResultsCount(providers.length),
              style: TextStyle(
                fontSize: 17.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
                color: scheme.onSurface,
              ),
            ),
          ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _AiSearchLoading(
              s: s,
              query: _searchCtrl.text.trim(),
              scheme: scheme,
            ),
          )
        else if (_query.isNotEmpty && providers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _AiEmptyState(
              icon: Icons.search_rounded,
              title: s.aiNoSearchResults,
              hint: s.aiNoSearchResultsHint(_query),
              action: _AiGlassActionButton(
                icon: Icons.cancel_outlined,
                label: s.aiClearSearch,
                onTap: () => _clearSearch(unfocus: true),
              ),
            ),
          )
        else if (cfg.aiProfiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _AiEmptyState(
              icon: Icons.auto_awesome_outlined,
              title: s.aiNoProviders,
              hint: s.aiNoProvidersHint,
            ),
          )
        else if (noEnabled)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _AiEmptyState(
              icon: Icons.filter_alt_off_outlined,
              title: s.aiNoEnabledProviders,
              hint: s.aiNoEnabledProvidersHint,
              action: _AiGlassActionButton(
                icon: Icons.filter_alt_off_outlined,
                label: s.aiShowAll,
                onTap: () => setState(() => _enabledOnly = false),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (var i = 0; i < providers.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: _AiProviderCard(
                      // 查询变化时换 key：卡片重新播放入场动画，
                      // 同时避免筛选前后同 id 卡片复用导致 chip 内容闪变。
                      key: ValueKey('${providers[i].id}|$_query|$_enabledOnly'),
                      cardStyle: cfg.cardStyle,
                      s: s,
                      scheme: scheme,
                      isDark: isDark,
                      profile: providers[i],
                      active: providers[i].id == cfg.activeAiProfileId,
                      chips: _chipModels(providers[i], _query),
                      index: i,
                      onTap: () => _openProvider(providers[i]),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _AiAddProviderCard(
            cardStyle: cfg.cardStyle,
            s: s,
            scheme: scheme,
            onTap: _openNewProvider,
          ),
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

// ═══════════════════════════════════════════
// 首屏：Hero / 搜索 / 提供商卡片 / 空态
// ═══════════════════════════════════════════

class _AiProvidersHero extends StatelessWidget {
  final AppConfig cfg;
  final AppStrings s;
  final ColorScheme scheme;
  final int providerCount;
  final int modelCount;
  final ValueChanged<bool> onAiEnabledChanged;
  final ValueChanged<bool> onMcpEnabledChanged;

  const _AiProvidersHero({
    required this.cfg,
    required this.s,
    required this.scheme,
    required this.providerCount,
    required this.modelCount,
    required this.onAiEnabledChanged,
    required this.onMcpEnabledChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sem = scheme.sem;
    Widget toggle({
      required Key key,
      required String label,
      required bool enabled,
      required ValueChanged<bool> onChanged,
    }) {
      return Expanded(
        child: SizedBox(
          height: 42,
          child: FilledButton.tonalIcon(
            key: key,
            onPressed: () => onChanged(!enabled),
            icon: Icon(
              enabled ? Icons.toggle_on_outlined : Icons.toggle_off_outlined,
              size: 18,
            ),
            label: Text(
              '$label · ${enabled ? (s.isZh ? '启用' : 'On') : (s.isZh ? '关闭' : 'Off')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: AppControlSize.comfortable.buttonStyle(filled: enabled),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            toggle(
              key: const ValueKey('ai_enabled_toggle'),
              label: 'AI',
              enabled: cfg.aiEnabled,
              onChanged: onAiEnabledChanged,
            ),
            const SizedBox(width: 8),
            toggle(
              key: const ValueKey('mcp_enabled_toggle'),
              label: 'MCP',
              enabled: cfg.mcpEnabled,
              onChanged: onMcpEnabledChanged,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 6,
          children: [
            _AiStatChip(
              icon: Icons.hub_outlined,
              label: s.aiProviderCount(providerCount),
              scheme: scheme,
            ),
            _AiStatChip(
              icon: Icons.widgets_outlined,
              label: s.aiModelCount(modelCount),
              scheme: scheme,
            ),
          ],
        ),
        if (!cfg.aiEnabled) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.power_settings_new, size: 13, color: sem.warning),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  s.aiAiDisabledHint,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: sem.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AiStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ColorScheme scheme;

  const _AiStatChip({
    required this.icon,
    required this.label,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(isDark ? 24 : 16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.primary.withAlpha(isDark ? 56 : 42),
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.5, color: scheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索胶囊：直接使用顶部药丸渲染器（AppConfig.pillStyle），与顶栏、
/// 提供商详情的「基本/模型」切换保持同一套玻璃语言。
class _AiSearchBar extends StatelessWidget {
  final String pillStyle;
  final TextEditingController controller;
  final FocusNode focusNode;
  final AppStrings s;
  final ColorScheme scheme;
  final bool showClear;
  final bool filterActive;
  final ValueChanged<String> onChanged;
  final VoidCallback onFilter;
  final VoidCallback onClear;

  const _AiSearchBar({
    required this.pillStyle,
    required this.controller,
    required this.focusNode,
    required this.s,
    required this.scheme,
    required this.showClear,
    required this.filterActive,
    required this.onChanged,
    required this.onFilter,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return MobileGlassPill(
      style: pillStyle,
      radius: 26,
      height: 52,
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 6),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const ValueKey('ai_provider_search'),
                  controller: controller,
                  focusNode: focusNode,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    color: scheme.onSurface,
                  ),
                  cursorColor: scheme.primary,
                  textInputAction: TextInputAction.search,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: s.aiProvidersSearchHint,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurfaceVariant.withAlpha(190),
                    ),
                  ),
                  onChanged: onChanged,
                  onTapOutside: (_) => focusNode.unfocus(),
                ),
              ),
              const SizedBox(width: 4),
              if (showClear)
                _SearchActionButton(
                  icon: Icons.cancel_outlined,
                  tooltip: s.aiClearSearch,
                  onTap: onClear,
                  color: scheme.onSurfaceVariant,
                  scheme: scheme,
                )
              else
                _SearchActionButton(
                  icon: Icons.tune,
                  tooltip: filterActive ? s.aiEnabledOnly : s.aiFilter,
                  onTap: onFilter,
                  active: filterActive,
                  color: filterActive
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  scheme: scheme,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final Color color;
  final ColorScheme scheme;

  const _SearchActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.color,
    required this.scheme,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: SizedBox(
          // 44×44：与移动端最小点按目标一致，而不是把 19px 图标
          // 塞进一个 34/40 的窄盒子里。
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 19, color: color),
              if (active)
                Positioned(
                  right: 9,
                  top: 9,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiProviderCard extends StatelessWidget {
  final String cardStyle;
  final AppStrings s;
  final ColorScheme scheme;
  final bool isDark;
  final AiProfile profile;
  final bool active;
  final List<String> chips;
  final int index;
  final VoidCallback onTap;

  const _AiProviderCard({
    super.key,
    required this.cardStyle,
    required this.s,
    required this.scheme,
    required this.isDark,
    required this.profile,
    required this.active,
    required this.chips,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final modelCount = _modelCount(profile);
    final countLabel = modelCount == 0
        ? s.aiNoModels
        : s.aiModelCount(modelCount);
    final duration = reduceMotion
        ? Duration.zero
        : Duration(milliseconds: 220 + index.clamp(0, 5).toInt() * 24);
    final card = AppCard(
      style: cardStyle,
      radius: 20,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ProviderIconTile(
                  profile: profile,
                  scheme: scheme,
                  isDark: isDark,
                  size: 46,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 6),
                            _CurrentBadge(
                              label: s.aiProviderCurrent,
                              scheme: scheme,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        profile.group.isEmpty
                            ? countLabel
                            : '$countLabel  ·  ${profile.group}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 状态胶囊最多占 92：超大字号时整体等比缩小，
                // 而不是把提供商名称挤成零宽 / 把卡片撑破。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 92),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: _AiStatusPill(
                      enabled: profile.enabled,
                      s: s,
                      scheme: scheme,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 20, color: scheme.outline),
              ],
            ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 11),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in chips)
                    _AiModelChip(label: id, scheme: scheme),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    if (duration == Duration.zero) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: card,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}

class _ProviderIconTile extends StatelessWidget {
  final AiProfile profile;
  final ColorScheme scheme;
  final bool isDark;
  final double size;

  const _ProviderIconTile({
    required this.profile,
    required this.scheme,
    required this.isDark,
    this.size = 46,
  });

  @override
  Widget build(BuildContext context) {
    final look = _providerLook(profile, scheme);
    final ink = isDark
        ? Color.lerp(look.color, Colors.white, 0.26)!
        : Color.lerp(look.color, Colors.black, 0.10)!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            look.color.withAlpha(isDark ? 58 : 42),
            look.color.withAlpha(isDark ? 28 : 22),
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(
          color: Colors.white.withAlpha(isDark ? 30 : 90),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: look.color.withAlpha(isDark ? 30 : 22),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(look.icon, size: size * 0.48, color: ink),
    );
  }
}

class _AiStatusPill extends StatelessWidget {
  final bool enabled;
  final AppStrings s;
  final ColorScheme scheme;

  const _AiStatusPill({
    required this.enabled,
    required this.s,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = enabled ? scheme.sem.success : scheme.onSurfaceVariant;
    final bg = enabled
        ? scheme.sem.success.withAlpha(isDark ? 26 : 18)
        : scheme.surfaceContainerHighest.withAlpha(isDark ? 80 : 110);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withAlpha(
            enabled ? (isDark ? 80 : 70) : (isDark ? 40 : 50),
          ),
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
          Text(
            enabled ? s.aiEnabledStatus : s.aiDisabledStatus,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _AiModelChip extends StatelessWidget {
  final String label;
  final ColorScheme scheme;

  const _AiModelChip({required this.label, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 170),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withAlpha(isDark ? 70 : 95),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: scheme.outlineVariant.withAlpha(isDark ? 60 : 80),
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.2,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _CurrentBadge extends StatelessWidget {
  final String label;
  final ColorScheme scheme;

  const _CurrentBadge({required this.label, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(isDark ? 36 : 24),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.primary.withAlpha(isDark ? 70 : 55),
          width: 0.6,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// 可点选的胶囊 chip（能力标记 / 询问跳过项共用）。
///
/// 不用 Material [FilterChip]：它的选中态、边框、内边距由框架接管，
/// 与本页其余自定义胶囊（模型 chip、状态胶囊）是两套视觉语言。
class _AiToggleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ColorScheme scheme;
  final bool isDark;
  final VoidCallback onTap;

  const _AiToggleChip({
    required this.label,
    required this.selected,
    required this.scheme,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withAlpha(isDark ? 42 : 26)
                : scheme.surfaceContainerHighest.withAlpha(isDark ? 55 : 80),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected
                  ? scheme.primary.withAlpha(95)
                  : scheme.outlineVariant.withAlpha(60),
              width: 0.6,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.15,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiAddProviderCard extends StatelessWidget {
  final String cardStyle;
  final AppStrings s;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _AiAddProviderCard({
    required this.cardStyle,
    required this.s,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppCard(
      style: cardStyle,
      radius: 20,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withAlpha(isDark ? 34 : 24),
                border: Border.all(
                  color: scheme.primary.withAlpha(isDark ? 100 : 80),
                  width: 0.8,
                ),
              ),
              child: Icon(Icons.add, size: 21, color: scheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                s.aiNewProvider,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 搜索加载 / 无结果 / 无提供商
// ═══════════════════════════════════════════

class _AiSearchLoading extends StatefulWidget {
  final AppStrings s;
  final String query;
  final ColorScheme scheme;

  const _AiSearchLoading({
    required this.s,
    required this.query,
    required this.scheme,
  });

  @override
  State<_AiSearchLoading> createState() => _AiSearchLoadingState();
}

class _AiSearchLoadingState extends State<_AiSearchLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 加载指示必须保留；只有「呼吸脉冲」这层装饰在减弱动态效果时停掉。
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse
        ..stop()
        ..value = 0.5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 30, 0, 30),
      child: Center(
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final t = Curves.easeInOut.transform(_pulse.value);
                return Transform.scale(scale: 0.96 + 0.05 * t, child: child);
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withAlpha(isDark ? 55 : 35),
                      blurRadius: 30,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: MobileGlassPill(
                  radius: 43,
                  height: 86,
                  padding: EdgeInsets.zero,
                  child: SizedBox(
                    width: 86,
                    height: 86,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 50,
                          height: 50,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: scheme.primary.withAlpha(170),
                          ),
                        ),
                        Icon(
                          Icons.auto_awesome,
                          size: 18,
                          color: scheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              widget.s.aiSearching,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.s.aiSearchingHint(widget.query),
              textAlign: TextAlign.center,
              style: SettingsTypography.description.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final Widget? action;

  const _AiEmptyState({
    required this.icon,
    required this.title,
    required this.hint,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 34, 8, 26),
      child: Column(
        children: [
          // 空态图标同样用液态玻璃药丸渲染：搜索/无结果时它悬浮在壁纸上，
          // 用真实折射比「实心渐变圆」更贴合设计稿的玻璃球。
          MobileGlassPill(
            radius: 38,
            height: 76,
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 76,
              height: 76,
              child: Icon(
                icon,
                size: 30,
                color: scheme.primary.withAlpha(isDark ? 210 : 190),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

/// 空态里的玻璃胶囊动作按钮（清空搜索 / 查看全部）。
class _AiGlassActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AiGlassActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MobileGlassPill(
      radius: 22,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      pressable: true,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 权限 / 高级 / MCP 分组
// ═══════════════════════════════════════════

class _PermissionsSection extends StatelessWidget {
  final AppConfig cfg;
  final AppStrings s;
  final AppState state;

  const _PermissionsSection({
    required this.cfg,
    required this.s,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    return _AiSectionCard(
      cardStyle: cfg.cardStyle,
      icon: Icons.shield_outlined,
      title: s.aiPermissions,
      children: [
        _AiSwitchTile(
          icon: Icons.visibility_outlined,
          title: s.aiReadAccess,
          desc: s.aiReadAccessDesc,
          value: cfg.aiReadAccess,
          onChanged: (v) => state.updateConfig((c) => c..aiReadAccess = v),
        ),
        const _AiDivider(),
        _AiSwitchTile(
          icon: Icons.edit_outlined,
          title: s.aiWriteAccess,
          desc: s.aiWriteAccessDesc,
          value: cfg.aiWriteAccess,
          onChanged: (v) => state.updateConfig((c) => c..aiWriteAccess = v),
        ),
        const _AiDivider(),
        _AiSwitchTile(
          icon: Icons.play_circle_outline,
          title: s.aiAutoExecute,
          desc: s.aiAutoExecuteDesc,
          value: cfg.aiAutoExecute,
          onChanged: (v) => state.updateConfig((c) => c..aiAutoExecute = v),
        ),
        const _AiDivider(),
        _AiSwitchTile(
          icon: Icons.question_answer_outlined,
          title: s.aiAllowAsk,
          desc: s.aiAllowAskDesc,
          value: cfg.aiAllowAsk,
          onChanged: (v) => state.updateConfig((c) => c..aiAllowAsk = v),
        ),
      ],
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  final AppConfig cfg;
  final AppStrings s;
  final ColorScheme scheme;

  const _AdvancedSection({
    required this.cfg,
    required this.s,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return _AiSectionCard(
      cardStyle: cfg.cardStyle,
      icon: Icons.tune,
      title: s.aiAdvanced,
      subtitle: s.isZh
          ? '图生成模式 / 思考 / 自动命名 / 会话模式 / 系统提示词'
          : 'Image mode, thinking, auto-naming, session mode, system prompt',
      trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          allowSnapshotting: false,
          builder: (_) => const MobileAiAdvancedPage(),
        ),
      ),
    );
  }
}

class _McpSection extends StatelessWidget {
  final AppConfig cfg;
  final AppStrings s;
  final AppState state;
  final ColorScheme scheme;

  const _McpSection({
    required this.cfg,
    required this.s,
    required this.state,
    required this.scheme,
  });

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      showToast(context, s.qCopied, type: ToastType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = cfg.mcpEnabled;
    final running = state.mcpRunning;
    final host = cfg.mcpHost.isEmpty ? '127.0.0.1' : cfg.mcpHost;
    final port = cfg.mcpPort;
    final url = 'http://$host:$port';
    return _AiSectionCard(
      cardStyle: cfg.cardStyle,
      icon: Icons.dns_outlined,
      title: s.mcpService,
      optionHeader: true,
      subtitle: enabled
          ? (s.isZh
                ? '外部 AI 工具可通过 MCP 协议访问本机能力'
                : 'External AI tools can access this machine over MCP')
          : s.mcpEnableDesc,
      children: enabled
          ? [
              _McpStatusRow(
                s: s,
                scheme: scheme,
                url: url,
                running: running,
                error: state.mcpError,
                onCopy: () => _copy(context, url),
              ),
              const SizedBox(height: 14),
              _AiLabeledField(
                label: s.mcpPort,
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
              _AiLabeledField(
                label: s.mcpBindHost,
                hint: s.mcpApplyHint,
                child: _AiField(
                  value: cfg.mcpHost,
                  scheme: scheme,
                  hint: '127.0.0.1',
                  onCommit: (v) {
                    final h = v.trim();
                    if (h.isEmpty ||
                        RegExp(r'^[A-Za-z0-9.:_-]+$').hasMatch(h)) {
                      state.updateConfig((c) => c..mcpHost = h);
                    }
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  style: AppControlSize.comfortable.buttonStyle(filled: true),
                  icon: Icon(
                    Icons.refresh,
                    size: AppControlSize.comfortable.iconSize,
                  ),
                  label: Text(s.mcpApply, style: const TextStyle(fontSize: 12)),
                  onPressed: () async {
                    state.mcpError = null;
                    await state.stopMcpServer();
                    await state.startMcpServer();
                  },
                ),
              ),
              if (running && state.mcpToken != null) ...[
                const SizedBox(height: 14),
                _McpTokenCard(
                  token: state.mcpToken!,
                  s: s,
                  scheme: scheme,
                  onCopy: () => _copy(context, state.mcpToken!),
                ),
              ],
              const SizedBox(height: 6),
              _AiSwitchTile(
                icon: Icons.edit_outlined,
                title: s.mcpAllowWrite,
                desc: s.mcpAllowWriteDesc,
                value: cfg.mcpAllowWrite,
                onChanged: (v) =>
                    state.updateConfig((c) => c..mcpAllowWrite = v),
              ),
              const _AiDivider(),
              _AiSwitchTile(
                icon: Icons.folder_open_outlined,
                title: s.mcpAllowFs,
                desc: s.mcpAllowFsDesc,
                value: cfg.mcpAllowFsAccess,
                onChanged: (v) =>
                    state.updateConfig((c) => c..mcpAllowFsAccess = v),
              ),
            ]
          : const <Widget>[],
    );
  }
}

class _McpStatusRow extends StatelessWidget {
  final AppStrings s;
  final ColorScheme scheme;
  final String url;
  final bool running;
  final String? error;
  final VoidCallback onCopy;

  const _McpStatusRow({
    required this.s,
    required this.scheme,
    required this.url,
    required this.running,
    required this.onCopy,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = error != null
        ? scheme.sem.danger
        : (running ? scheme.sem.success : scheme.sem.neutral);
    final text = error ?? (running ? s.mcpRunning : s.mcpStopped);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: color.withAlpha(isDark ? 22 : 14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withAlpha(isDark ? 62 : 48),
          width: 0.7,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: s.qCopy,
            icon: Icon(Icons.copy_rounded, size: 15, color: scheme.outline),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            visualDensity: VisualDensity.compact,
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _McpTokenCard extends StatelessWidget {
  final String token;
  final AppStrings s;
  final ColorScheme scheme;
  final VoidCallback onCopy;

  const _McpTokenCard({
    required this.token,
    required this.s,
    required this.scheme,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(isDark ? 22 : 14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.primary.withAlpha(isDark ? 58 : 46),
          width: 0.7,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.vpn_key_outlined, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.mcpLanToken,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  token,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: s.qCopy,
            icon: Icon(Icons.copy_rounded, size: 15, color: scheme.primary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            visualDensity: VisualDensity.compact,
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _AiSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _AiSwitchTile({
    required this.icon,
    required this.title,
    required this.desc,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(isDark ? 24 : 16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: scheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: SettingsTypography.description.fontSize,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}

class _AiDivider extends StatelessWidget {
  const _AiDivider();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 44),
      child: Divider(
        height: 1,
        thickness: 0.5,
        color: scheme.outlineVariant.withAlpha(60),
      ),
    );
  }
}

class _AiLabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  final String? hint;

  const _AiLabeledField({required this.label, required this.child, this.hint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 7),
          child,
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: scheme.outline,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EffectiveUrlPreview extends StatelessWidget {
  final AppStrings s;
  final ColorScheme scheme;
  final String url;

  const _EffectiveUrlPreview({
    required this.s,
    required this.scheme,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(isDark ? 54 : 70),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: scheme.outlineVariant.withAlpha(55),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link, size: 14, color: scheme.outline),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '${s.aiEffectiveRequest}: $url',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
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
  State<MobileAiProviderDetailPage> createState() =>
      _MobileAiProviderDetailPageState();
}

class _MobileAiProviderDetailPageState
    extends State<MobileAiProviderDetailPage> {
  bool _loaded = false;
  bool _forcedNew = false; // 打开时配置已被删除 → 按新建处理
  bool get _isNew => widget.profileId == null || _forcedNew;
  AiProfile _draft = AiProfile();

  /// 底部分栏：0 = 基本，1 = 模型。
  int _tab = 0;
  bool _desktopSidebarCollapsed = false;

  /// 「获取模型列表」进行中。
  bool _fetchingModels = false;

  /// 模型搜索：右上角搜索图标切换，输入即过滤列表。
  bool _showModelSearch = false;
  final TextEditingController _modelSearchCtrl = TextEditingController();

  /// 「获取账户余额」进行中。
  bool _fetchingBalance = false;

  /// 新建时选中的供应商预设（受控下拉的当前值）。
  String _selectedPreset = 'openai';

  @override
  void didUpdateWidget(MobileAiProviderDetailPage old) {
    super.didUpdateWidget(old);
    // 页面复用于另一个提供商时重新装载草稿
    if (old.profileId != widget.profileId) {
      _loaded = false;
      _forcedNew = false;
      _draft = AiProfile();
      _tab = 0;
      _showModelSearch = false;
      _modelSearchCtrl.clear();
      _selectedPreset = 'openai';
    }
  }

  @override
  void dispose() {
    _modelSearchCtrl.dispose();
    super.dispose();
  }

  void _ensureLoaded(BuildContext context) {
    if (_loaded) return;
    _loaded = true;
    final state = context.read<AppState>();
    if (!_isNew) {
      final p = state.config.aiProfiles
          .where((e) => e.id == widget.profileId)
          .firstOrNull;
      if (p != null) {
        // 编辑草稿副本：直接改配置会污染未保存状态，且触发字段抖动。
        // copyWith 会深拷贝 apiKeys/customHeaders/models，改草稿不影响原配置。
        _draft = p.copyWith();
      } else {
        _draft = AiProfile();
        _forcedNew = true;
        applyProfilePreset(_draft, _selectedPreset);
      }
    } else if (_draft.apiUrl.isEmpty) {
      // 新建提供商时直接带出常用端点和自动请求路径；用户仍可修改。
      applyProfilePreset(_draft, _selectedPreset);
    }
  }

  void _mutateDraft(void Function(AiProfile) fn) {
    fn(_draft);
    setState(() {});
  }

  void _commitProviderEnabled(bool enabled) {
    // Keep edits in the local draft; saving commits both enabled state and active fallback.
    _mutateDraft((draft) => draft.enabled = enabled);
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
      // Active providers must remain enabled; fall back to another enabled profile.
      final activeProfile = c.aiProfiles
          .where((e) => e.id == c.activeAiProfileId)
          .firstOrNull;
      if (activeProfile == null || !activeProfile.enabled) {
        c.activeAiProfileId =
            c.aiProfiles.where((e) => e.enabled).firstOrNull?.id ?? '';
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
        title: Text(
          s.aiDeleteProviderConfirm,
          style: TextStyle(color: scheme.onSurface, fontSize: 15),
        ),
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
                if (c.activeAiProfileId == _draft.id) {
                  c.activeAiProfileId =
                      c.aiProfiles
                          .where((profile) => profile.enabled)
                          .firstOrNull
                          ?.id ??
                      '';
                }
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
    final useMobileLayout = _useMobileAiLayout(context);
    final state = context.read<AppState>();
    // 语言必须用 select 建立依赖：read/initState 只取一次快照，切语言后本页
    // 不会重建，会出现「底部分栏已跟随新语言、标题与表单仍是旧语言」的半中半英。
    final s = AppStrings.of(
      context.select<AppState, String>((st) => st.config.language),
    );
    final scheme = Theme.of(context).colorScheme;
    final title = _isNew
        ? s.aiNewProvider
        : (_draft.name.trim().isEmpty
              ? s.aiProviderDetail
              : _draft.name.trim());

    return withWallpaper(
      context,
      Scaffold(
        backgroundColor: Colors.transparent,
        // bottom: false——底部切换栏（NavGlassShell）自带 bottomSafe padding
        body: SafeArea(
          child: Column(
            children: [
              if (useMobileLayout)
                MobileSubPageTopBar(
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onBack: () => Navigator.of(context).maybePop(),
                  inlineActionLimit: 3,
                  actions: [
                    if (!_isNew)
                      MobileGlassPillAction(
                        key: const ValueKey('provider_delete'),
                        icon: Icons.delete_outline,
                        tooltip: s.remove,
                        color: scheme.error,
                        onTap: _delete,
                      ),
                    if (_tab == 1)
                      MobileGlassPillAction(
                        key: const ValueKey('provider_model_search'),
                        icon: Icons.search,
                        tooltip: s.isZh ? '搜索模型' : 'Search models',
                        color: scheme.onSurface,
                        onTap: () => setState(() {
                          _showModelSearch = !_showModelSearch;
                          if (!_showModelSearch) _modelSearchCtrl.clear();
                        }),
                      ),
                    MobileGlassPillAction(
                      icon: Icons.check_rounded,
                      tooltip: s.save,
                      color: scheme.primary,
                      onTap: _save,
                    ),
                  ],
                )
              else
                _DesktopProviderHeader(
                  title: title,
                  onBack: () => Navigator.of(context).maybePop(),
                  actions: [
                    if (_tab == 1)
                      IconButton(
                        key: const ValueKey('provider_model_search'),
                        tooltip: s.isZh ? '搜索模型' : 'Search models',
                        onPressed: () => setState(() {
                          _showModelSearch = !_showModelSearch;
                          if (!_showModelSearch) _modelSearchCtrl.clear();
                        }),
                        icon: const Icon(Icons.search),
                      ),
                    if (!_isNew)
                      IconButton(
                        key: const ValueKey('provider_delete'),
                        tooltip: s.remove,
                        onPressed: _delete,
                        icon: Icon(Icons.delete_outline, color: scheme.error),
                      ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: Text(s.save),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              Expanded(
                child: useMobileLayout
                    ? Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: double.infinity,
                          ),
                          child: _buildProviderTabContent(
                            context,
                            state,
                            s,
                            scheme,
                          ),
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildDesktopProviderSidebar(
                            context,
                            state,
                            s,
                            scheme,
                          ),
                          Expanded(
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1120,
                                ),
                                child: _buildProviderTabContent(
                                  context,
                                  state,
                                  s,
                                  scheme,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
              if (useMobileLayout)
                _buildBottomTabBar(context, state, scheme, s),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProviderTabContent(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
  ) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(_tab == 0 ? -0.05 : 0.05, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      child: _tab == 0
          ? _buildBasicTab(context, state, s, scheme)
          : _buildModelsTab(context, state, s, scheme),
    );
  }

  Widget _buildDesktopProviderSidebar(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
  ) {
    final collapsed = _desktopSidebarCollapsed;
    final cardStyle = state.config.cardStyle;
    Widget item({
      required int index,
      required IconData icon,
      required String title,
    }) {
      final selected = _tab == index;
      return Tooltip(
        message: collapsed ? title : '',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Material(
            color: selected ? scheme.primary.withAlpha(24) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _tab = index),
              child: SizedBox(
                height: 42,
                child: Row(
                  mainAxisAlignment: collapsed
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: collapsed ? 0 : 12,
                      ),
                      child: Icon(
                        icon,
                        size: 18,
                        color: selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    if (!collapsed)
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected ? scheme.primary : scheme.onSurface,
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      key: const ValueKey('provider_desktop_sidebar'),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? 72 : 196,
      margin: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      child: AppCard(
        style: cardStyle,
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          children: [
            Align(
              alignment: collapsed ? Alignment.center : Alignment.centerRight,
              child: IconButton(
                key: const ValueKey('provider_desktop_sidebar_toggle'),
                tooltip: collapsed
                    ? (s.isZh ? '展开侧边栏' : 'Expand sidebar')
                    : (s.isZh ? '收起侧边栏' : 'Collapse sidebar'),
                onPressed: () =>
                    setState(() => _desktopSidebarCollapsed = !collapsed),
                icon: Icon(
                  collapsed
                      ? Icons.keyboard_double_arrow_right
                      : Icons.keyboard_double_arrow_left,
                  size: 18,
                ),
              ),
            ),
            item(index: 0, icon: Icons.tune_rounded, title: s.aiBasic),
            item(index: 1, icon: Icons.widgets_outlined, title: s.aiModelsTab),
          ],
        ),
      ),
    );
  }

  /// 底部「基本 / 模型」小药丸。
  ///
  /// 设计稿要求：两个分段本身只占一颗小药丸的宽度；切到模型页时，左右各
  /// 长出一颗圆形动作药丸（云端获取 / 添加自定义模型），而不是把整条底栏
  /// 拉满。基本页只保留中间的分段药丸。
  Widget _buildBottomTabBar(
    BuildContext context,
    AppState state,
    ColorScheme scheme,
    AppStrings s,
  ) {
    final cfg = state.config;
    Widget round({
      required Key key,
      required IconData icon,
      required String tooltip,
      required VoidCallback? onTap,
      Color? color,
    }) {
      return MobileGlassPill(
        radius: 22,
        padding: EdgeInsets.zero,
        child: MobileGlassPillAction(
          key: key,
          icon: icon,
          tooltip: tooltip,
          color: color ?? scheme.onSurface,
          size: 44,
          iconSize: 20,
          padding: EdgeInsets.zero,
          onTap: onTap,
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 切到模型页时，左右两颗圆形动作药丸从 0 宽度「长出来」，
            // 与中间小药丸的非线性拉伸同拍；不是瞬间出现。
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutBack,
              alignment: Alignment.centerRight,
              child: _tab == 1
                  ? round(
                      key: const ValueKey('provider_models_fetch_round'),
                      icon: _fetchingModels
                          ? Icons.cloud_sync_outlined
                          : Icons.cloud_download_outlined,
                      tooltip: s.isZh ? '从云端获取模型列表' : 'Fetch models',
                      onTap: _fetchingModels
                          ? null
                          : () => _fetchModels(context, state, s),
                    )
                  : const SizedBox(width: 0, height: 44),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              width: _tab == 1 ? 6 : 0,
              height: 1,
            ),
            SizedBox(
              width: 164,
              child: LiquidStretchTabs(
                key: const ValueKey('ai_provider_top_tabs'),
                style: cfg.pillStyle,
                height: 40,
                radius: 20,
                semanticsLabel: '${s.aiBasic} / ${s.aiModelsTab}',
                selectedIndex: _tab,
                onChanged: (index) {
                  if (_tab != index) setState(() => _tab = index);
                },
                tabs: [
                  LiquidStretchTab(icon: Icons.tune_rounded, label: s.aiBasic),
                  LiquidStretchTab(
                    icon: Icons.widgets_outlined,
                    label: s.aiModelsTab,
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              width: _tab == 1 ? 6 : 0,
              height: 1,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutBack,
              alignment: Alignment.centerLeft,
              child: _tab == 1
                  ? round(
                      key: const ValueKey('provider_models_add_round'),
                      icon: Icons.add,
                      tooltip: s.isZh ? '添加自定义模型' : 'Add custom model',
                      color: scheme.primary,
                      onTap: () => _openModelSheet(context, s, 0, isNew: true),
                    )
                  : const SizedBox(width: 0, height: 44),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab 1：基本 ──

  Widget _buildBasicTab(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
  ) {
    final cfg = state.config;
    final isZh = s.isZh;
    final isActive =
        !_isNew && _draft.enabled && cfg.activeAiProfileId == _draft.id;

    return SingleChildScrollView(
      key: const ValueKey('ai_provider_config'),
      // 基本页只有三张卡：一次性布局，避免浅滚动区里惰性构建导致
      // 页尾按钮在窄屏上暂时不存在（无障碍焦点 / 测试都更难命中）。
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 基本信息：名称 / 启用 / 请求格式 / Response API ──
          _AiSectionCard(
            cardStyle: cfg.cardStyle,
            icon: Icons.badge_outlined,
            title: s.aiBasicInfo,
            children: [
              if (_isNew)
                _AiLabeledField(
                  label: s.aiPreset,
                  // 与「设置-样式」同款选择框（OptionMenuBar 胶囊触发钮 + 浮层列表）
                  child: OptionMenuBar<String>(
                    triggerHeight: AppControlSize.large.height,
                    value: _selectedPreset,
                    items: [
                      const OptionItem<String>('openai', 'OpenAI'),
                      const OptionItem<String>(
                        'anthropic',
                        'Anthropic (Claude)',
                      ),
                      const OptionItem<String>('deepseek', 'DeepSeek'),
                      OptionItem<String>(
                        'ollama',
                        isZh ? 'Ollama (本地)' : 'Ollama (Local)',
                      ),
                    ],
                    onChanged: (preset) {
                      setState(() => _selectedPreset = preset);
                      _mutateDraft((d) => applyProfilePreset(d, preset));
                    },
                  ),
                ),
              _AiLabeledField(
                label: s.aiProviderName,
                child: _AiField(
                  value: _draft.name,
                  scheme: scheme,
                  onCommit: (v) => _mutateDraft((d) => d..name = v),
                ),
              ),
              _AiSwitchRow(
                icon: Icons.power_settings_new,
                label: s.aiProviderEnabled,
                desc: s.aiProviderEnabledDesc,
                value: _draft.enabled,
                onChanged: _commitProviderEnabled,
              ),
              const _AiDivider(),
              // 供应商类型（请求协议）：下拉，与其它设置行统一
              _AiDropdownRow(
                label: s.aiProviderFormat,
                value: _draft.provider,
                entries: [
                  ('openai', isZh ? 'OpenAI 兼容' : 'OpenAI', Icons.hub_outlined),
                  ('anthropic', 'Anthropic', Icons.psychology_outlined),
                ],
                onSelected: (v) => _mutateDraft((d) {
                  d.provider = v;
                  // 请求路径通常由供应商格式自动决定；只有用户手工填过特殊
                  // 路径时才保留，不覆盖自定义值。
                  const known = {
                    '',
                    '/chat/completions',
                    '/messages',
                    '/responses',
                  };
                  if (known.contains(d.apiPath.trim())) {
                    d.apiPath = v == 'anthropic'
                        ? '/messages'
                        : (d.useResponsesApi
                              ? '/responses'
                              : '/chat/completions');
                  }
                }),
              ),
              const _AiDivider(),
              // Response API（/responses）
              _AiSwitchRow(
                icon: Icons.api,
                label: 'Response API',
                desc: s.aiResponseApiDesc,
                value: _draft.useResponsesApi,
                onChanged: (v) => _mutateDraft((d) {
                  d.useResponsesApi = v;
                  // 切换端点时同步 API 路径，避免用户手改两处
                  if (v &&
                      (d.apiPath.isEmpty ||
                          d.apiPath.contains('chat/completions'))) {
                    d.apiPath = '/responses';
                  } else if (!v && d.apiPath.contains('responses')) {
                    d.apiPath = '/chat/completions';
                  }
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ── 连接：API 地址 / 路径 / Key ──
          _AiSectionCard(
            cardStyle: cfg.cardStyle,
            icon: Icons.link_outlined,
            title: s.aiConnection,
            children: [
              _AiLabeledField(
                label: isZh ? 'API 地址' : 'API Base URL',
                child: _AiField(
                  value: _draft.apiUrl,
                  scheme: scheme,
                  keyboardType: TextInputType.url,
                  onCommit: (v) => _mutateDraft((d) => d..apiUrl = v),
                ),
              ),
              _AiLabeledField(
                label: s.aiActivePath,
                child: _AiField(
                  key: const ValueKey('ai_request_path'),
                  value: _draft.apiPath,
                  scheme: scheme,
                  hint: '/chat/completions',
                  onCommit: (v) => _mutateDraft((d) => d..apiPath = v),
                ),
              ),
              // 实际请求地址预览：Base + 路径拼接结果，避免用户猜
              _EffectiveUrlPreview(
                s: s,
                scheme: scheme,
                url: _draft.effectiveUrl,
              ),
              // 测试连接属于辅助操作，收成一行小文字按钮，不再用整行
              // 主按钮压在页面底部；请求路径此时已经由预设自动填好。
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: const Size(0, 44),
                  ),
                  icon: const Icon(Icons.wifi_tethering, size: 14),
                  label: Text(s.aiPing, style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    _syncToDefaults();
                    pingAi(context, state, s);
                  },
                ),
              ),
              _AiLabeledField(
                label: 'API Key',
                child: _draft.multiKeyEnabled
                    ? _AiNavRow(
                        icon: Icons.vpn_key_outlined,
                        label: isZh
                            ? '管理 API Keys（${_draft.apiKeys.where((k) => k.isNotEmpty).length} 个）'
                            : 'Manage API Keys (${_draft.apiKeys.where((k) => k.isNotEmpty).length})',
                        value: isZh ? '点按进入' : 'Tap to edit',
                        onTap: () => _openMultiKeyPage(context, s),
                      )
                    : _AiField(
                        value: _draft.apiKey,
                        scheme: scheme,
                        obscure: true,
                        hint: 'sk-...',
                        onCommit: (v) => _mutateDraft((d) => d..apiKey = v),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ── 管理：分组 / 多 Key / 余额 / 代理 / 自定义请求 ──
          _AiSectionCard(
            cardStyle: cfg.cardStyle,
            icon: Icons.tune,
            title: s.aiManagement,
            children: [
              _AiNavRow(
                icon: Icons.label_outline,
                label: isZh ? '分组' : 'Group',
                value: _draft.group.isEmpty
                    ? (isZh ? '未分组' : 'Ungrouped')
                    : _draft.group,
                onTap: () => _editGroup(context, s),
              ),
              const _AiDivider(),
              // 多 Key 模式：开启后进入二级菜单管理 Key 列表
              _AiSwitchRow(
                icon: Icons.vpn_key_outlined,
                label: isZh ? '多 Key 模式' : 'Multi-Key Mode',
                desc: isZh
                    ? '多个 Key 轮换请求，规避单 Key 限流'
                    : 'Rotate keys to avoid rate limits',
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
              const _AiDivider(),
              _AiNavRow(
                icon: Icons.account_balance_wallet_outlined,
                label: isZh ? '获取账户余额' : 'Account Balance',
                value: _fetchingBalance ? (isZh ? '查询中…' : 'Loading…') : '',
                onTap: _fetchingBalance ? null : () => _fetchBalance(s),
              ),
              const _AiDivider(),
              _AiNavRow(
                icon: Icons.wifi_tethering,
                label: isZh ? '网络代理' : 'Network Proxy',
                value: _draft.proxyUrl.isEmpty
                    ? (isZh ? '直连' : 'Direct')
                    : _draft.proxyUrl,
                onTap: () => _editProxy(context, s),
              ),
              const _AiDivider(),
              _AiNavRow(
                icon: Icons.http,
                label: isZh ? '自定义请求' : 'Custom Request',
                value: _draft.customHeaders.isEmpty
                    ? (isZh ? '无' : 'None')
                    : (isZh
                          ? '${_draft.customHeaders.length} 项'
                          : '${_draft.customHeaders.length} items'),
                onTap: () => _editHeaders(context, s),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_isNew && _draft.enabled && !isActive) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                style: AppControlSize.large.buttonStyle(filled: true),
                icon: Icon(
                  Icons.radio_button_off,
                  size: AppControlSize.large.iconSize,
                ),
                label: Text(
                  s.aiProviderUse,
                  style: const TextStyle(fontSize: 13),
                ),
                onPressed: () {
                  state.updateConfig((c) => c..activeAiProfileId = _draft.id);
                  setState(() {});
                  showToast(context, s.aiProviderUse, type: ToastType.success);
                },
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  /// 打开「多 Key 管理」二级菜单：列表增删改，逐项实时写回 [AiProfile.apiKeys]
  ///（详情页草稿），保存仍由顶栏「保存」统一落库。
  Future<void> _openMultiKeyPage(BuildContext context, AppStrings s) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        allowSnapshotting: false,
        builder: (_) => MobileMultiKeyPage(
          keys: List<String>.of(_draft.apiKeys),
          onChanged: (list) => _mutateDraft((d) => d..apiKeys = list),
        ),
      ),
    );
  }

  /// 打开单个模型的底部编辑面板（替代旧的全屏二级页）。
  Future<void> _openModelSheet(
    BuildContext context,
    AppStrings s,
    int index, {
    bool isNew = false,
  }) async {
    final AiModelEntry original = isNew
        ? AiModelEntry(id: '')
        : _draft.models[index];
    final AppState state = context.read<AppState>();
    final AiModelEntry? result = await showModalBottomSheet<AiModelEntry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.45),
      builder: (_) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: ModelEditorSheet(
          entry: original.copy(),
          isNew: isNew,
          defaultContextWindow: _draft.contextWindow,
          defaultMaxTokens: _draft.maxTokens,
          defaultTemperature: _draft.temperature,
          isZh: s.isZh,
          cardStyle: state.config.cardStyle,
          pillStyle: state.config.pillStyle,
          takenIds: _draft.models
              .where((m) => isNew || m.id != original.id)
              .map((m) => m.id)
              .toSet(),
        ),
      ),
    );
    if (result == null || !mounted) return;
    final String oldId = original.id;
    _mutateDraft((d) {
      final int target = isNew ? -1 : d.models.indexWhere((m) => m.id == oldId);
      if (isNew || target < 0) {
        d.models.add(result);
      } else {
        d.models[target] = result;
        if (d.model == oldId) d.model = result.id;
      }
    });
  }

  /// 删除单个模型（行尾菜单触发；先确认再写入草稿）。
  Future<void> _removeModel(AppStrings s, AiModelEntry entry) async {
    final scheme = Theme.of(context).colorScheme;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(
          s.isZh ? '删除模型？' : 'Delete model?',
          style: TextStyle(color: scheme.onSurface, fontSize: 15),
        ),
        content: Text(entry.label, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(s.remove, style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final String id = entry.id;
    _mutateDraft((d) {
      d.models.removeWhere((m) => m.id == id);
      if (d.model == id) d.model = d.models.firstOrNull?.id ?? '';
    });
  }

  // ── Tab 2：模型 ──

  Widget _buildModelsTab(
    BuildContext context,
    AppState state,
    AppStrings s,
    ColorScheme scheme,
  ) {
    final cfg = state.config;
    final models = _draft.models;
    final isZh = s.isZh;
    final hasModels = models.isNotEmpty;
    final query = _modelSearchCtrl.text.trim().toLowerCase();
    final visibleModels = query.isEmpty
        ? models
        : models
              .where((m) {
                final label = m.label.toLowerCase();
                return label.contains(query) ||
                    m.id.toLowerCase().contains(query);
              })
              .toList(growable: false);
    // 头部（统计 + 云端获取） + 每个模型一行 + 「添加自定义模型 →」。
    // 模型可能上百条（例如从 OpenRouter 拉取）：仍用 builder 惰性构建，
    // 每帧只为视口内的行创建 widget。
    // 0 = header / 1 = 顶部「添加自定义模型」/ 2.. = 过滤后的模型行。
    final itemCount = visibleModels.length + 2;
    return ListView.builder(
      key: const ValueKey('ai_provider_models'),
      // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
      addRepaintBoundaries: false,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      itemCount: itemCount,
      addAutomaticKeepAlives: false,
      itemBuilder: (_, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSectionHeading(
                  title: isZh ? '模型' : 'Models',
                  icon: Icons.widgets_outlined,
                ),
                AppCard(
                  style: cfg.cardStyle,
                  radius: 20,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          hasModels
                              ? (isZh
                                    ? '共 ${models.length} 个模型'
                                    : '${models.length} ${models.length == 1 ? 'model' : 'models'}')
                              : (isZh
                                    ? '还没有模型。从云端获取，或手动添加一个。'
                                    : 'No models yet. Fetch from the cloud or add one.'),
                          style: SettingsTypography.description.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (_showModelSearch) ...[
                          const SizedBox(height: 10),
                          TextField(
                            key: const ValueKey('provider_model_search_field'),
                            controller: _modelSearchCtrl,
                            autofocus: true,
                            onChanged: (_) => setState(() {}),
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: isZh
                                  ? '搜索模型名称或 ID'
                                  : 'Search model or ID',
                              prefixIcon: const Icon(Icons.search, size: 18),
                              suffixIcon: _modelSearchCtrl.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: isZh ? '清空' : 'Clear',
                                      icon: const Icon(Icons.close, size: 16),
                                      onPressed: () =>
                                          setState(_modelSearchCtrl.clear),
                                    ),
                              filled: true,
                              fillColor: scheme.surfaceContainerHighest
                                  .withAlpha(50),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: scheme.outlineVariant.withAlpha(70),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: scheme.outlineVariant.withAlpha(70),
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: AppControlSize.comfortable.buttonStyle(),
                                icon: _fetchingModels
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        Icons.cloud_download_outlined,
                                        size:
                                            AppControlSize.comfortable.iconSize,
                                      ),
                                label: Text(
                                  isZh ? '从云端获取模型列表' : 'Fetch models',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: _fetchingModels
                                    ? null
                                    : () => _fetchModels(context, state, s),
                              ),
                            ),
                            if (hasModels) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: AppControlSize.comfortable.height,
                                height: AppControlSize.comfortable.height,
                                child: IconButton(
                                  tooltip: isZh ? '清空模型列表' : 'Clear models',
                                  icon: Icon(
                                    Icons.delete_sweep_outlined,
                                    size: AppControlSize.comfortable.iconSize,
                                    color: scheme.error,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: BoxConstraints.tightFor(
                                    width: AppControlSize.comfortable.height,
                                    height: AppControlSize.comfortable.height,
                                  ),
                                  onPressed: () => _clearModels(s),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _AddCustomModelRow(
              cardStyle: cfg.cardStyle,
              isZh: isZh,
              onTap: () => _openModelSheet(context, s, 0, isNew: true),
            ),
          );
        }
        if (index <= visibleModels.length + 1) {
          final int i = index - 2;
          final AiModelEntry entry = visibleModels[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _AiModelRow(
              cardStyle: cfg.cardStyle,
              entry: entry,
              isActive: entry.id == _draft.model,
              isZh: isZh,
              onOpen: () => _openModelSheet(context, s, i),
              onUse: () => _mutateDraft((d) => d..model = entry.id),
              onDelete: () => _removeModel(s, entry),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  /// 清空模型列表（先确认，避免误触把云端拉取的数百条一次清掉）。
  Future<void> _clearModels(AppStrings s) async {
    final scheme = Theme.of(context).colorScheme;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(
          s.isZh ? '清空模型列表？' : 'Clear all models?',
          style: TextStyle(color: scheme.onSurface, fontSize: 15),
        ),
        content: Text(
          s.aiModelCount(_draft.models.length),
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(s.remove, style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _mutateDraft((d) {
      d.models.clear();
      d.model = '';
    });
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

  /// 自定义请求头：一行一个 Key: Value，便于整体编辑。
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

  /// 从供应商拉取模型列表，合并进草稿（保留已有能力标记）。
  Future<void> _fetchModels(
    BuildContext context,
    AppState state,
    AppStrings s,
  ) async {
    setState(() => _fetchingModels = true);
    _syncToDefaults();
    try {
      // 复用设置页的模型列表拉取；onPicked 用于「顺带把选中的设为当前模型」。
      await listAiModels(
        context,
        state,
        s,
        onPicked: (m) {
          _mutateDraft((d) => d..model = m);
        },
        onListed: (ids) {
          _mutateDraft((d) {
            // 供应商一次可能返回数百个模型：先把已有 id 收成 Set，
            // 逐条 any() 查重是 O(N²)，这里改成均摊 O(1)。
            final existing = d.models.map((m) => m.id).toSet();
            for (final id in ids) {
              if (id.trim().isEmpty) continue;
              // add 返回 false 表示已有，顺带过滤 ids 自身的重复项
              if (!existing.add(id)) continue;
              // 依据模型名推断能力，作为初值；模态与能力保持兼容
              // （vision 能力同时把 image 放进输入模态）。
              final List<String> caps = _guessCapabilities(id);
              d.models.add(
                AiModelEntry(
                  id: id,
                  capabilities: caps,
                  inputModalities: caps.contains(AiModelCapability.vision)
                      ? const [LiquidModalities.text, LiquidModalities.image]
                      : const [LiquidModalities.text],
                  outputModalities: const [LiquidModalities.text],
                ),
              );
            }
          });
        },
      );
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
  Future<void> _fetchBalance(AppStrings s) async {
    setState(() => _fetchingBalance = true);
    try {
      final result = await fetchAiBalance(_draft);
      if (!mounted) return;
      showToast(
        context,
        result ??
            (s.isZh
                ? '该供应商未提供余额查询接口，请在其控制台查看'
                : 'Provider has no balance endpoint; check its console'),
        type: result != null ? ToastType.success : ToastType.info,
      );
    } catch (e) {
      if (!mounted) return;
      showToast(
        context,
        '${s.isZh ? '查询失败' : 'Failed'}: $e',
        type: ToastType.error,
      );
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
        title: Text(
          title,
          style: TextStyle(fontSize: 15, color: scheme.onSurface),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: maxLines,
          minLines: maxLines > 1 ? maxLines : 1,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: SettingsTypography.description.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, ctrl.text),
            child: Text(s.save),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }
}

/// 「标签 + 右侧值 + 箭头」导航行（点击进入子设置/执行动作）。
class _AiNavRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _AiNavRow({
    required this.label,
    this.value = '',
    this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(isDark ? 22 : 14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 15, color: scheme.primary),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: scheme.onSurface),
                ),
              ),
              if (value.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: SettingsTypography.description.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 18, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「标签(+说明) + 右侧开关」行。
class _AiSwitchRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String? desc;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _AiSwitchRow({
    required this.label,
    this.desc,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(!value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(isDark ? 22 : 14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 15, color: scheme.primary),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 13, color: scheme.onSurface),
                    ),
                    if (desc != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        desc!,
                        style: SettingsTypography.description.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模态 → (显示名, 图标)。模型行摘要与底部编辑面板共用。
(String, IconData) _modalityLabel(
  String modality,
  bool isZh,
) => switch (modality) {
  LiquidModalities.text => (isZh ? '文本' : 'Text', Icons.text_fields_rounded),
  LiquidModalities.image => (isZh ? '图像' : 'Image', Icons.image_outlined),
  LiquidModalities.voice => (isZh ? '语音' : 'Voice', Icons.graphic_eq_rounded),
  _ => (modality, Icons.label_outline),
};

String _modalitySummary(AiModelEntry entry, bool isZh) {
  String join(List<String> values) => values
      .map((value) => _modalityLabel(value, isZh).$1)
      .join(isZh ? ' · ' : ' · ');
  return '${join(entry.inputModalities)} → ${join(entry.outputModalities)}';
}

enum _ModelRowAction { use, edit, delete }

/// 模型行（设计稿的 GPT-6 / Claude-opus 样式）：
/// 显示名称（空则回退 id；两者都有时 id 作为副标题）+ 模态摘要 + kebab 菜单。
///
/// 不做成固定高度：显示名称、副标题、模态摘要都可缺省，行高由内容自然撑开，
/// 也兼容大字号 / 窄屏换行。
class _AiModelRow extends StatelessWidget {
  final String cardStyle;
  final AiModelEntry entry;
  final bool isActive;
  final bool isZh;
  final VoidCallback onOpen;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  const _AiModelRow({
    required this.cardStyle,
    required this.entry,
    required this.isActive,
    required this.isZh,
    required this.onOpen,
    required this.onUse,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final bool hasIdSubtitle = entry.displayName.trim().isNotEmpty;
    return AppCard(
      key: ValueKey('model_row_${entry.id}'),
      style: cardStyle,
      radius: 16,
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(isDark ? 26 : 16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isActive ? Icons.smart_toy : Icons.smart_toy_outlined,
                size: 17,
                color: isActive ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Opacity(
                opacity: entry.enabled ? 1 : 0.6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 5),
                          _CurrentBadge(
                            label: isZh ? '当前' : 'Current',
                            scheme: scheme,
                          ),
                        ],
                        if (!entry.enabled) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: scheme.outlineVariant.withAlpha(90),
                                width: 0.6,
                              ),
                            ),
                            child: Text(
                              isZh ? '已停用' : 'Off',
                              style: TextStyle(
                                fontSize: 9,
                                height: 1.1,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (hasIdSubtitle) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      _modalitySummary(entry, isZh),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: scheme.outline),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuButton<_ModelRowAction>(
              key: ValueKey('model_menu_${entry.id}'),
              tooltip: isZh ? '更多操作' : 'More actions',
              icon: Icon(
                Icons.more_vert,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              padding: EdgeInsets.zero,
              onSelected: (action) {
                switch (action) {
                  case _ModelRowAction.use:
                    onUse();
                  case _ModelRowAction.edit:
                    onOpen();
                  case _ModelRowAction.delete:
                    onDelete();
                }
              },
              itemBuilder: (context) => [
                if (!isActive)
                  PopupMenuItem<_ModelRowAction>(
                    value: _ModelRowAction.use,
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 17,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(isZh ? '设为当前模型' : 'Use as current'),
                      ],
                    ),
                  ),
                PopupMenuItem<_ModelRowAction>(
                  value: _ModelRowAction.edit,
                  child: Row(
                    children: [
                      Icon(
                        Icons.tune,
                        size: 17,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(isZh ? '编辑模型' : 'Edit model'),
                    ],
                  ),
                ),
                PopupMenuItem<_ModelRowAction>(
                  value: _ModelRowAction.delete,
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, size: 17, color: scheme.error),
                      const SizedBox(width: 8),
                      Text(
                        isZh ? '删除模型' : 'Delete model',
                        style: TextStyle(color: scheme.error),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 「添加自定义模型 →」行：打开空条目的底部编辑面板。
class _AddCustomModelRow extends StatelessWidget {
  final String cardStyle;
  final bool isZh;
  final VoidCallback onTap;

  const _AddCustomModelRow({
    required this.cardStyle,
    required this.isZh,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      key: const ValueKey('add_custom_model'),
      style: cardStyle,
      radius: 16,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isZh ? '添加自定义模型' : 'Add custom model',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: scheme.primary,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.primary),
          ],
        ),
      ),
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
  const MobileMultiKeyPage({
    super.key,
    required this.keys,
    required this.onChanged,
  });

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
      context.select<AppState, String>((st) => st.config.language),
    );
    final filled = _keys.where((k) => k.isNotEmpty).length;
    return withWallpaper(
      context,
      Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              MobileSubPageTopBar(
                title: Text(
                  s.isZh ? 'API Keys 管理（$filled）' : 'API Keys ($filled)',
                ),
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
                          style: SettingsTypography.description.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (var i = 0; i < _keys.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _AiField(
                                    // 绑定索引与内容，删除中间项时不会串位
                                    key: ValueKey(
                                      'mk_${i}_${_keys[i].hashCode}',
                                    ),
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
                                  icon: Icon(
                                    Icons.remove_circle_outline,
                                    size: 18,
                                    color: scheme.error,
                                  ),
                                  tooltip: s.remove,
                                  onPressed: () {
                                    setState(() => _keys.removeAt(i));
                                    _commit();
                                  },
                                ),
                              ],
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(Icons.add, size: 16),
                            label: Text(
                              s.isZh ? '添加 Key' : 'Add Key',
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () => setState(() => _keys.add('')),
                          ),
                        ),
                      ],
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
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final mobileLayout = _useMobileAiLayout(context);

        return withWallpaper(
          context,
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(
                children: [
                  if (mobileLayout)
                    MobileSubPageTopBar(
                      title: Text(s.aiAdvanced),
                      onBack: () => Navigator.of(context).maybePop(),
                    )
                  else
                    GlassTopBar(
                      title: Row(
                        children: [
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).backButtonTooltip,
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back),
                          ),
                          Text(s.aiAdvanced),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: mobileLayout ? double.infinity : 1120,
                        ),
                        child: ListView(
                          // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
                          addRepaintBoundaries: false,
                          padding: mobileLayout
                              ? MobileUi.subListPadding(top: 4, bottom: 16)
                              : const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          children: [
                            // ── 生成（图生成模式 + 思考过程） ──
                            // 原先这张卡把 图生成/思考/自动命名/标题提示词 全塞在一起，
                            // 现按关注点拆成「生成」「命名」两张卡，层级更清晰。
                            _AiSectionCard(
                              cardStyle: cfg.cardStyle,
                              icon: Icons.auto_fix_high_outlined,
                              title: s.isZh ? '生成' : 'Generation',
                              children: [
                                // 图生成模式改为下拉菜单（窄屏下自动换成「标签在上」）
                                _AiDropdownRow(
                                  label: s.aiGraphModeLabel,
                                  value: cfg.aiGraphMode,
                                  entries: [
                                    ('redo', s.aiGraphModeRedo, Icons.refresh),
                                    (
                                      'modify',
                                      s.aiGraphModeModify,
                                      Icons.edit_outlined,
                                    ),
                                  ],
                                  onSelected: (v) => state.updateConfig(
                                    (c) => c..aiGraphMode = v,
                                  ),
                                ),
                                const _AiDivider(),
                                _AiSwitchTile(
                                  icon: Icons.psychology_outlined,
                                  title: s.aiShowThinking,
                                  desc: s.aiShowThinkingDesc,
                                  value: cfg.aiShowThinking,
                                  onChanged: (v) => state.updateConfig(
                                    (c) => c..aiShowThinking = v,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // ── 会话命名 ──
                            _AiSectionCard(
                              cardStyle: cfg.cardStyle,
                              icon: Icons.label_outline,
                              title: s.isZh ? '会话命名' : 'Conversation Title',
                              children: [
                                _AiSwitchTile(
                                  icon: Icons.title,
                                  title: s.aiAutoTitleLabel,
                                  desc: s.aiAutoTitleDesc,
                                  value: cfg.aiAutoTitle,
                                  onChanged: (v) => state.updateConfig(
                                    (c) => c..aiAutoTitle = v,
                                  ),
                                ),
                                // 展开/收起带动画，避免提示词输入框「瞬间出现」的割裂感
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: cfg.aiAutoTitle
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            top: 10,
                                          ),
                                          child: _AiLabeledField(
                                            label: s.aiTitlePromptLabel,
                                            child: _AiField(
                                              value: cfg.aiTitlePrompt,
                                              scheme: scheme,
                                              minLines: 2,
                                              maxLines: 4,
                                              onCommit: (v) =>
                                                  state.updateConfig(
                                                    (c) => c..aiTitlePrompt = v,
                                                  ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox(
                                          width: double.infinity,
                                          height: 0,
                                        ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
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
                                    (
                                      'ask',
                                      s.aiApproveModeAsk,
                                      Icons.help_outline,
                                    ),
                                    (
                                      'auto',
                                      s.aiApproveModeAuto,
                                      Icons.bolt_outlined,
                                    ),
                                  ],
                                  onSelected: (v) => state.updateConfig(
                                    (c) => c..aiApproveMode = v,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  s.aiApproveModeDesc,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.outline,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  s.aiAskSkipLabel,
                                  style: TextStyle(fontSize: 12, color: clr),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final key in _askSkipKeys)
                                      _AiToggleChip(
                                        label: _askSkipLabel(key, s.isZh),
                                        selected: cfg.aiAskSkipTools.contains(
                                          key,
                                        ),
                                        scheme: scheme,
                                        isDark: isDark,
                                        onTap: () {
                                          state.updateConfig((c) {
                                            final set = c.aiAskSkipTools
                                                .toSet();
                                            if (set.contains(key)) {
                                              set.remove(key);
                                            } else {
                                              set.add(key);
                                            }
                                            c.aiAskSkipTools = set.toList();
                                            return c;
                                          });
                                        },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
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
                                  onCommit: (v) => state.updateConfig(
                                    (c) => c..aiSystemPrompt = v,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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

/// 移动端 AI 设置的分组卡片：图标 + 标题 + 说明 + 内容。
///
/// 统一各二级/三级页面的分层结构：一张卡只承载一个主题的设置项，避免
/// 「一张卡塞十几项」导致的滑动疲劳。几何规格与设置页 _glass、提供商卡片
/// 逐项对齐：圆角 20 / 左右留白 12 / 内边距 16 / 外置分组标题。
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
  final bool optionHeader;
  final List<Widget> children;

  const _AiSectionCard({
    required this.cardStyle,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.optionHeader = false,
    this.children = const <Widget>[],
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Navigation and whole-card switches are options, not group headings.
    final isOption = optionHeader || onTap != null || trailing is Switch;
    final header = Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: SettingsTypography.description.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Semantics(label: title, child: trailing!),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isOption)
            SettingsSectionHeading(
              title: title,
              icon: icon,
              trailing: trailing,
            ),
          AppCard(
            style: cardStyle,
            radius: 20,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isOption) header,
                  if (!isOption && subtitle != null)
                    Text(
                      subtitle!,
                      style: SettingsTypography.description.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if ((isOption || subtitle != null) && children.isNotEmpty)
                    const SizedBox(height: 14),
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 移动端 AI 设置下拉菜单宽度上限。
/// 约束 OptionMenuBar 触发钮的最大宽度，避免展开面板按最长条目撑开
/// （窄屏溢出、桌面端「宽度极大」）。
const double _kAiMenuWidth = 156;

/// AI 设置用下拉菜单。
/// entries 为 (值, 显示文案, 图标) 三元组。
/// 视觉与「设置-样式」的选择框完全同款：内部直接复用 OptionMenuBar
/// （胶囊触发钮 + OverlayPortal 浮层，宿主卡片高度不随展开变化）。
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kAiMenuWidth + 8),
      child: OptionMenuBar<String>(
        // key 绑定当前值：配置被外部改动后重建时显示最新选中项
        key: ValueKey('aiDropdown_${entries.length}_$value'),
        triggerHeight: AppControlSize.large.height,
        value: value,
        items: [
          for (final e in entries) OptionItem<String>(e.$1, e.$2, icon: e.$3),
        ],
        onChanged: onSelected,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // 412 宽的手机上卡片内容约 332：标签 + 下拉（164）完全放得下，
        // 沿用 380 的阈值会让「请求格式 / 图生成模式」在正常手机上也无谓换行。
        // 320 宽时内容约 240，才退回「标签在上」。
        final compact = constraints.maxWidth < 300;
        final dropdown = _AiDropdown(
          value: value,
          entries: entries,
          onSelected: onSelected,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    dropdown,
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 13, color: scheme.onSurface),
                      ),
                    ),
                    const SizedBox(width: 12),
                    dropdown,
                  ],
                ),
        );
      },
    );
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

  /// 控件高度档位：与下拉、导航行和通栏按钮共用 [AppControlSize.large]。本页改造前
  /// 输入框纵向内边距写死 `v10`，算出来约 40，且带「眼睛」后缀图标的字段会被
  /// [InputDecorator] 默认的 48×48 图标约束进一步顶高（移动端 48），于是
  /// 同一张卡里 API Key 字段比端口字段高出近 10px。
  ///
  /// 用「常量 + 同名 getter」而不用可选的构造参数：全页每一处 `_AiField` 都吃
  /// 同一档，可选参数从未被显式传过，等于「看着能改、其实哪都没改」的死参数
  /// （analyzer 报 `UNUSED_ELEMENT_PARAMETER`）。保留 getter 是为了不动 build
  /// 里既有的 `size.xxx` 写法。
  static const AppControlSize _size = AppControlSize.large;
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
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value,
  );
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
    if (old.value != widget.value &&
        _ctrl.text != widget.value &&
        !_focus.hasFocus) {
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
      // 输入即同步草稿：实际请求 URL = Base URL + 请求路径，不能等失焦才更新。
      onChanged: widget.onCommit,
      keyboardType: widget.keyboardType,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      obscureText: widget.obscure && !_visible,
      style: TextStyle(fontSize: 13.5, height: 1.2, color: clr),
      cursorColor: scheme.primary,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: TextStyle(
          fontSize: 12.5,
          color: scheme.onSurfaceVariant.withAlpha(170),
        ),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withAlpha(isDark ? 76 : 100),
        contentPadding: size.fieldPadding,
        // 压平桌面端的 -8px 密度偏移，否则同一份 contentPadding 在两端高度不同
        visualDensity: AppControlSize.fieldDensity,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withAlpha(isDark ? 64 : 95),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withAlpha(isDark ? 64 : 95),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.primary.withAlpha(210),
            width: 1.4,
          ),
        ),
        // 不带这个约束，带「眼睛」后缀图标的字段会被 InputDecorator 默认的
        // 48×48 图标盒顶高（移动端 48 / 桌面折算后 40），比同卡其它字段高一截
        suffixIconConstraints: BoxConstraints.tightFor(
          width: size.height,
          height: size.height,
        ),
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(
                  _visible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: size.height,
                  height: size.height,
                ),
                onPressed: () => setState(() => _visible = !_visible),
              )
            : null,
      ),
      onTapOutside: (_) => _focus.unfocus(),
      onSubmitted: widget.onCommit,
      onEditingComplete: () => widget.onCommit(_ctrl.text),
    );
    // 多行字段（标题提示词 2~4 行、系统提示词 3~6 行）不能钉高度，否则只剩一行高
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: size.height),
      child: field,
    );
  }
}
