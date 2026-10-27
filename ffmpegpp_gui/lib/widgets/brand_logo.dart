import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// ════════════════════════════════════════════════════════════════════
/// AI 提供商 / 模型品牌 logo（本地 SVG，无网络依赖）
/// ════════════════════════════════════════════════════════════════════
///
/// 图标判定规则（用户要求）：
///  * **模型**：按模型 id 正则匹配品牌 —— id 里出现 gpt 就是 OpenAI 图标、
///    出现 deepseek 就是 DeepSeek 图标，以此类推（见 brandForModelId）。
///    供应商叫什么名字不影响模型图标：自建中转站下的 gpt-4o 依然显示 OpenAI。
///  * **供应商**：只有当供应商名字**全字匹配**某个品牌名时才替换
///    （OpenAI / DeepSeek / Anthropic…，见 brandForProviderName）；
///    「我的 OpenAI 中转」这类名字不匹配，继续用通用 Material 图标。
///
/// 资源在 assets/brand_icons/（pubspec.yaml 已声明），渲染统一走
/// BrandLogo：SvgPicture.asset + ColorFilter.srcIn 单色着色。
enum AiBrand {
  openai,
  anthropic,
  deepseek,
  gemini,
  ollama,
  openrouter,
  mistral,
  meta,
  xai,
  qwen,
}

extension AiBrandInfo on AiBrand {
  /// 本地 SVG 路径（文件名与枚举名一致，见 assets/brand_icons/）。
  String get asset => 'assets/brand_icons/$name.svg';

  /// 无障碍 / Tooltip 用的品牌名。
  String get label => switch (this) {
    AiBrand.openai => 'OpenAI',
    AiBrand.anthropic => 'Anthropic Claude',
    AiBrand.deepseek => 'DeepSeek',
    AiBrand.gemini => 'Google Gemini',
    AiBrand.ollama => 'Ollama',
    AiBrand.openrouter => 'OpenRouter',
    AiBrand.mistral => 'Mistral AI',
    AiBrand.meta => 'Meta Llama',
    AiBrand.xai => 'xAI Grok',
    AiBrand.qwen => 'Qwen',
  };

  /// 品牌强调色（低饱和底 / logo 着色的色相来源）。
  Color get accent => switch (this) {
    AiBrand.openai => const Color(0xFF10A37F),
    AiBrand.anthropic => const Color(0xFFD97757),
    AiBrand.deepseek => const Color(0xFF4D6BFE),
    AiBrand.gemini => const Color(0xFF4285F4),
    AiBrand.ollama => const Color(0xFF9A7BFF),
    AiBrand.openrouter => const Color(0xFF6467F2),
    AiBrand.mistral => const Color(0xFFFF7000),
    AiBrand.meta => const Color(0xFF0866FF),
    AiBrand.xai => const Color(0xFF5C5C5C),
    AiBrand.qwen => const Color(0xFF615CED),
  };
}

/// 模型 id → 品牌的正则表（**顺序敏感**，先命中先返回）。
///
/// 说明：
///  * deepseek 必须在宽泛规则之前；claude 与 anthropic 合并一条；
///  * gpt / chatgpt 合并成一条；o1/o3/o4（OpenAI 推理模型）单独列出，
///    用 \b 边界避免误伤无关串；
///  * meta-llama 与 llama 同归 Meta；ollama 是**供应商**名，但模型 id 里
///    出现 ollama 通常表示本地拉取的模型名，归 Ollama 品牌合理，故排在 llama 前。
final List<(RegExp, AiBrand)> _modelBrandRules = [
  (RegExp(r'openrouter'), AiBrand.openrouter),
  (RegExp(r'deepseek'), AiBrand.deepseek),
  (RegExp(r'claude|anthropic'), AiBrand.anthropic),
  (RegExp(r'ollama'), AiBrand.ollama),
  (RegExp(r'gemini|gemma|palm|generativelanguage'), AiBrand.gemini),
  (RegExp(r'mistral|mixtral|codestral|magistral|pixtral'), AiBrand.mistral),
  (RegExp(r'meta[-_ ]?llama|llama|code[-_ ]?llama'), AiBrand.meta),
  (RegExp(r'qwen|qwq|tongyi|dashscope'), AiBrand.qwen),
  (RegExp(r'grok|\bx[-_]?ai\b'), AiBrand.xai),
  (
    RegExp(r'gpt|chatgpt|davinci|codex|whisper|dall[-_ ]?e|\bo[134]\b'),
    AiBrand.openai,
  ),
];

/// 模型 id → 品牌（正则匹配，大小写不敏感）。
///
/// 用户要求：模型图标看**模型 id**，不看供应商。例如供应商叫「我的中转站」，
/// 但模型是 gpt-4o，仍应显示 OpenAI 图标。
///
/// 兼容「供应商/模型」形式（OpenRouter 风格 openai/gpt-4o）：整串参与匹配，
/// 因此 openai/gpt-4o 命中 gpt → OpenAI，
/// anthropic/claude-3.5-sonnet 命中 claude → Anthropic。
AiBrand? brandForModelId(String modelId) {
  final id = modelId.trim().toLowerCase();
  if (id.isEmpty) return null;
  for (final rule in _modelBrandRules) {
    if (rule.$1.hasMatch(id)) return rule.$2;
  }
  return null;
}

/// 供应商名字归一化：小写，并去掉**分隔符**（空格 / 点 / 下划线 / 连字符）。
///
/// 这样 Open AI、open-ai、x.ai 都能落到同一张表的 key 上。
///
/// 注意：**不能**把「非字母数字」整类删掉 —— 那样「我的 OpenAI 中转」
/// 会被归一成 openai 而误命中 OpenAI，与「只有名字全字匹配才替换图标」
/// 的契约相反（中文、额外单词必须保留，从而自然不匹配）。
String _normalizeBrandName(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s._\-]'), '');

/// 供应商名字 → 品牌（**仅全字匹配**）。
///
/// 用户要求：只有当供应商名字正好是品牌名（OpenAI、DeepSeek…）时才替换
/// 供应商图标；「我的 OpenAI 中转」「Company GPT Gateway」这类名字不匹配，
/// 继续用通用 Material 图标。
AiBrand? brandForProviderName(String name) {
  final key = _normalizeBrandName(name);
  if (key.isEmpty) return null;
  return _providerBrandNames[key];
}

const Map<String, AiBrand> _providerBrandNames = {
  'openai': AiBrand.openai,
  'chatgpt': AiBrand.openai,
  'azureopenai': AiBrand.openai,
  'anthropic': AiBrand.anthropic,
  'anthropicclaude': AiBrand.anthropic,
  'claude': AiBrand.anthropic,
  'deepseek': AiBrand.deepseek,
  'deepseekai': AiBrand.deepseek,
  'google': AiBrand.gemini,
  'googleai': AiBrand.gemini,
  'googlegemini': AiBrand.gemini,
  'gemini': AiBrand.gemini,
  'ollama': AiBrand.ollama,
  'openrouter': AiBrand.openrouter,
  'mistral': AiBrand.mistral,
  'mistralai': AiBrand.mistral,
  'meta': AiBrand.meta,
  'metallama': AiBrand.meta,
  'llama': AiBrand.meta,
  'xai': AiBrand.xai,
  'grok': AiBrand.xai,
  'qwen': AiBrand.qwen,
  'alibaba': AiBrand.qwen,
  'alibabacloud': AiBrand.qwen,
  'tongyi': AiBrand.qwen,
  'dashscope': AiBrand.qwen,
};

/// 品牌 logo：本地 SVG + 单色着色。
///
/// * size 是 logo 的边长（提供商图标块 46dp 时取 25dp 左右）；
/// * color 由调用方按「深色主题提亮 / 浅色主题压暗」计算后传入，
///   ColorFilter.srcIn 会把 SVG 的所有不透明部分替换成该颜色。
class BrandLogo extends StatelessWidget {
  final AiBrand brand;
  final double size;
  final Color color;

  const BrandLogo({
    super.key,
    required this.brand,
    required this.color,
    this.size = 25,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        brand.asset,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        semanticsLabel: brand.label,
        // 资源尚未解码完成时保持同尺寸空盒，避免图标块内内容跳动。
        placeholderBuilder: (_) => const SizedBox.shrink(),
      ),
    );
  }
}
