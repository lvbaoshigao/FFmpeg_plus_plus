"""
FFmpeg 命令解析器

将 ffmpeg 命令字符串拆解为结构化说明列表。
按参数类别分组，便于 UI 用树形或分组方式展示。

典型调用:
    from backend.parser import explain_command

    result = explain_command("ffmpeg -i input.mp4 -c:v libx264 -b:v 2000k output.mp4")
    # result = {
    #     "success": True,
    #     "explanations": [ {param, value, name, category, description}, ... ],
    #     "categories": { "输入/输出": [...], "视频": [...], ... },
    #     "error": None,
    # }

设计说明:
    - 使用 shlex.split 安全分割命令字符串（处理引号嵌套）
    - 通过 FFMPEG_PARAMS_DESCRIPTION 字典匹配参数说明
    - 未识别的参数也会返回，标记为 "未知参数"
"""

import shlex
from collections import namedtuple

from .utils.constants import FFMPEG_PARAMS_DESCRIPTION

# ─────────────────────────────────────────────
# 返回结构
# ─────────────────────────────────────────────
ParseResult = namedtuple("ParseResult", [
    "success",       # bool
    "explanations",  # list[dict] — 逐参数解释
    "categories",    # dict[str, list[dict]] — 按 category 分组
    "error",         # str | None
])


def _split_command(command_str: str) -> list[str]:
    """
    安全分割 ffmpeg 命令字符串

    使用 shlex.split:
      - 正确处理双引号/单引号嵌套
      - 正确处理反斜杠转义
      - 返回 token 列表，可直接传给 subprocess.run
    """
    return shlex.split(command_str)


def _is_ffmpeg_param(token: str) -> bool:
    """判断 token 是否为 ffmpeg 参数（以 '-' 开头）"""
    return token.startswith("-")


def explain_command(command_str: str) -> ParseResult:
    """
    解析 ffmpeg 命令字符串，返回逐项解释

    示例:
        输入: "ffmpeg -i input.mp4 -c:v libx264 -b:v 2000k -preset medium output.mp4"

        输出:
        {
            "success": True,
            "explanations": [
                {"param": "-i", "value": "input.mp4", "name": "输入文件",
                 "category": "输入/输出", "description": "指定输入文件路径"},
                {"param": "-c:v", "value": "libx264", "name": "视频编码器",
                 "category": "视频", "description": "指定视频编码器"},
                ...
            ],
            "categories": {
                "输入/输出": [...],
                "视频": [...],
            },
            "error": None,
        }

    说明:
        - 命令开头的 "ffmpeg" 本身会被跳过
        - 输出文件名（命令最后的无参数值）会被标记为 "输出文件"
    """
    if not command_str or not command_str.strip():
        return ParseResult(
            success=False,
            explanations=[],
            categories={},
            error="命令为空",
        )

    try:
        tokens = _split_command(command_str)
    except ValueError as e:
        return ParseResult(
            success=False,
            explanations=[],
            categories={},
            error=f"命令格式错误（引号不匹配？）: {e}",
        )

    # 跳过开头的 "ffmpeg"
    if tokens and tokens[0] == "ffmpeg":
        tokens = tokens[1:]

    if not tokens:
        return ParseResult(
            success=False,
            explanations=[],
            categories={},
            error="命令中未找到有效参数",
        )

    # 收集最后一个非参数 token 作为输出文件
    output_file = None
    if tokens and not _is_ffmpeg_param(tokens[-1]):
        output_file = tokens.pop()

    explanations = []
    i = 0
    while i < len(tokens):
        token = tokens[i]

        if not _is_ffmpeg_param(token):
            # 孤立的值（没有对应的参数名），跳过
            i += 1
            continue

        # 获取下一个 token 作为参数值（如果存在且不是参数名）
        value = ""
        if i + 1 < len(tokens) and not _is_ffmpeg_param(tokens[i + 1]):
            value = tokens[i + 1]
            i += 2
        else:
            i += 1

        # 查参数字典
        param_info = FFMPEG_PARAMS_DESCRIPTION.get(token)

        if param_info:
            explanations.append({
                "param":       token,
                "value":       value,
                "name":        param_info["name"],
                "category":    param_info["category"],
                "description": param_info["desc"],
            })
        else:
            explanations.append({
                "param":       token,
                "value":       value,
                "name":        "未知参数",
                "category":    "其他",
                "description": f"参数 '{token}' 未收录在参数库中",
            })

    # 追加输出文件
    if output_file:
        explanations.append({
            "param":       "(output)",
            "value":       output_file,
            "name":        "输出文件",
            "category":    "输入/输出",
            "description": "输出文件路径",
        })

    # 按 category 分组
    categories = {}
    for exp in explanations:
        cat = exp["category"]
        if cat not in categories:
            categories[cat] = []
        categories[cat].append(exp)

    return ParseResult(
        success=True,
        explanations=explanations,
        categories=categories,
        error=None,
    )


# ─────────────────────────────────────────────
# 便捷文本输出
# ─────────────────────────────────────────────

def format_explanations(result: ParseResult) -> str:
    """
    将 explain_command() 的结果格式化为可读文本

    输出示例:
        [输入/输出]
          -i input.mp4
            → 指定输入文件路径
          -y
            → 不询问直接覆盖输出文件
        [视频]
          -c:v libx264
            → 指定视频编码器
          -b:v 2000k
            → 设置视频码率
    """
    if not result.success:
        return f"解析失败: {result.error}"

    lines = []
    lines.append("=" * 60)
    lines.append(f"FFmpeg 命令解析结果（共 {len(result.explanations)} 个参数）")
    lines.append("=" * 60)

    for category, items in result.categories.items():
        lines.append("")
        lines.append(f"▎{category}")
        lines.append("-" * 40)
        for item in items:
            if item["value"]:
                lines.append(f"  {item['param']} {item['value']}")
            else:
                lines.append(f"  {item['param']}")
            lines.append(f"    → {item['description']}")

    return "\n".join(lines)
