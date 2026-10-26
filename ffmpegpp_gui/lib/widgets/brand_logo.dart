import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// ════════════════════════════════════════════════════════════════════
/// AI 提供商品牌 logo（本地 SVG，无网络依赖）
/// ════════════════════════════════════════════════════════════════════
///
/// 之前 AI 设置里的提供商图标全部是 Material 图标近似（如 `waves` 代表
/// DeepSeek），用户无法一眼认出「这是哪家的模型」。这里改为**真实品牌
/// SVG**（取自 simple-icons，24×24 viewBox）：
///
///  * 资源在 `assets/brand_icons/`，由 pubspec.yaml 声明；
///  * 通过 [detectAiBrand] 按 名称 / provider / API 地址 / 模型 id 识别品牌；
///  * 渲染统一走 [BrandLogo]：`SvgPicture.asset` + `ColorFilter.srcIn` 着色，
///    不引入任何新的 pub 依赖（项目已有 flutter_svg ^2.3.0）；
///  * 未知品牌返回 null，调用方继续用通用 Material 图标兜底。
///
/// 品牌色只用于「46dp 图标块的低饱和底 + logo 着色」，不直接铺纯品牌色，
/// 深浅主题下都能读清。
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

/// 根据提供商配置识别品牌；识别不出时返回 null（调用方用通用图标）。
///
/// 判断顺序很重要：
///  * `openrouter` 必须早于 `openai`（前缀相同）；
///  * `ollama` 必须早于 `llama/meta`（"ollama" 里含子串 "llama"）。
AiBrand? detectAiBrand({
  required String name,
  required String provider,
  String apiUrl = '',
  String model = '',
}) {
  final key = '$name $provider $apiUrl $model'.toLowerCase();
  if (key.trim().isEmpty) return null;
  if (key.contains('openrouter')) return AiBrand.openrouter;
  if (key.contains('anthropic') || key.contains('claude')) {
    return AiBrand.anthropic;
  }
  if (key.contains('deepseek')) return AiBrand.deepseek;
  if (key.contains('ollama')) return AiBrand.ollama;
  if (key.contains('gemini') || key.contains('generativelanguage')) {
    return AiBrand.gemini;
  }
  if (key.contains('mistral')) return AiBrand.mistral;
  if (key.contains('qwen') ||
      key.contains('tongyi') ||
      key.contains('dashscope') ||
      key.contains('alibaba')) {
    return AiBrand.qwen;
  }
  if (key.contains('xai') || key.contains('grok')) return AiBrand.xai;
  if (key.contains('meta-llama') ||
      key.contains('meta llama') ||
      key.contains('llama') ||
      key.contains('meta.ai')) {
    return AiBrand.meta;
  }
  if (key.contains('google')) return AiBrand.gemini;
  if (key.contains('openai') ||
      key.contains('chatgpt') ||
      key.contains('gpt') ||
      key.contains('azure') ||
      key.contains('codex') ||
      key.contains('davinci')) {
    return AiBrand.openai;
  }
  return null;
}

/// 品牌 logo：本地 SVG + 单色着色。
///
/// * [size] 是 logo 的边长（提供商图标块 46dp 时取 25dp 左右）；
/// * [color] 由调用方按「深色主题提亮 / 浅色主题压暗」计算后传入，
///   `ColorFilter.srcIn` 会把 SVG 的所有不透明部分替换成该颜色。
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
