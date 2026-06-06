#!/usr/bin/env python
"""
FFmpeg++ CLI — 命令行入口脚本（阶段1 验证用）

用法:
    # 环境检测
    python cli.py check

    # 探测视频文件信息
    python cli.py probe <video_file>

    # 视频转码
    python cli.py transcode <input> <output> [--gpu CPU|NVIDIA|AMD|Intel]
              [--resolution 1920x1080] [--bitrate 3000] [--fps 30]

    # 字幕烧录
    python cli.py subtitle <input> <output> --sub <subtitle_file>

示例:
    python cli.py check
    python cli.py probe C:/videos/demo.mp4
    python cli.py transcode C:/videos/demo.mp4 C:/videos/out.mp4 --gpu NVIDIA --bitrate 3000
"""

import sys
import argparse
from pathlib import Path


def cmd_check():
    """检测 ffmpeg 环境"""
    from backend.installer import ensure_ffmpeg, get_install_guide, format_check_report

    result = ensure_ffmpeg()
    print(format_check_report(result))

    if not result["all_ok"]:
        print()
        guide = get_install_guide()
        print(f"平台: {guide.platform}")
        print(f"下载: {guide.download_url}")
    else:
        print()
        print("环境就绪，可以开始使用。")


def cmd_probe(args):
    """探测视频文件信息"""
    from backend.probe import probe_video

    filepath = args.file
    if not Path(filepath).exists():
        print(f"错误: 文件不存在 — {filepath}")
        sys.exit(1)

    print(f"正在探测: {filepath}")
    print("-" * 50)

    result = probe_video(filepath)

    if not result.success:
        print(f"探测失败: {result.error}")
        sys.exit(1)

    info = result.info
    print(f"文件名:       {info['filename']}")
    print(f"格式:         {info['format_long_name']}")
    print(f"大小:         {info['size_mb']} MB")
    print(f"时长:         {info['duration_str']} ({info['duration']:.1f}s)")
    print(f"总码率:       {info['bit_rate_kbps']} kbps")
    print()
    print(f"视频编码:     {info['codec']} ({info['codec_long_name']})")
    print(f"分辨率:       {info['resolution']}")
    print(f"帧率:         {info['fps']} fps")
    print(f"像素格式:     {info['pix_fmt']}")
    print(f"HDR:          {'是' if info['is_hdr'] else '否'}")
    print()
    print(f"音频编码:     {info['audio_codec']}")
    print(f"声道数:       {info['audio_channels']}")
    print(f"采样率:       {info['audio_sample_rate']}")
    print()
    if info['has_subtitles']:
        print(f"内嵌字幕:     {info['subtitle_count']} 条")
        for sub in info['subtitles']:
            flags = []
            if sub['forced']:
                flags.append("forced")
            if sub['default']:
                flags.append("default")
            flag_str = f" [{' '.join(flags)}]" if flags else ""
            print(f"  #{sub['index']}: {sub['language']} ({sub['codec']}){flag_str}")
    else:
        print("内嵌字幕:     无")


def cmd_transcode(args):
    """执行视频转码"""
    from backend.transcoder import transcode

    input_path = args.input
    output_path = args.output

    if not Path(input_path).exists():
        print(f"错误: 输入文件不存在 — {input_path}")
        sys.exit(1)

    # 构建 options
    options = {
        "gpu": args.gpu,
        "video_codec": args.codec,
        "preset": args.preset,
        "audio_codec": args.audio_codec,
        "audio_bitrate": args.audio_bitrate,
    }

    if args.resolution:
        try:
            w, h = args.resolution.split("x")
            options["resolution"] = (int(w), int(h))
        except ValueError:
            print(f"错误: 分辨率格式应为 WIDTHxHEIGHT，如 1920x1080")
            sys.exit(1)

    if args.bitrate:
        options["video_bitrate"] = args.bitrate

    if args.fps:
        options["framerate"] = args.fps

    if args.crf is not None:
        options["crf"] = args.crf

    # 显示命令预览
    from backend.transcoder import build_transcode_command
    try:
        cmd = build_transcode_command(input_path, output_path, options)
        print("执行命令:")
        print("  " + " ".join(f'"{a}"' if " " in a else a for a in cmd))
        print("-" * 50)
    except Exception as e:
        print(f"命令构建失败: {e}")
        sys.exit(1)

    # 执行
    result = transcode(input_path, output_path, options)

    if result.success:
        output_size = Path(output_path).stat().st_size / (1024 * 1024)
        print(f"[OK] 转码完成! 耗时 {result.duration:.1f}s")
        print(f"  输出文件: {result.output_path}")
        print(f"  文件大小: {output_size:.2f} MB")
    else:
        print(f"[FAIL] 转码失败: {result.error}")
        if result.warnings:
            print(f"  警告: {'; '.join(result.warnings)}")
        if result.log_lines:
            print("  最后几行输出:")
            for line in result.log_lines[-5:]:
                print(f"    {line}")
        sys.exit(1)


def cmd_subtitle(args):
    """执行字幕烧录"""
    from backend.subtitle import burn_subtitles

    input_path = args.input
    output_path = args.output
    sub_file = args.sub

    if not Path(input_path).exists():
        print(f"错误: 输入文件不存在 — {input_path}")
        sys.exit(1)

    if sub_file and not Path(sub_file).exists():
        print(f"错误: 字幕文件不存在 — {sub_file}")
        sys.exit(1)

    subtitle_options = {
        "source": "external" if sub_file else "embedded",
    }

    if sub_file:
        subtitle_options["subtitle_file"] = sub_file
    if args.sub_index is not None:
        subtitle_options["subtitle_index"] = args.sub_index
        if not sub_file:
            subtitle_options["source"] = "embedded"

    # 视频选项（可选压缩）
    video_options = None
    if args.bitrate or args.resolution:
        video_options = {}
        if args.bitrate:
            video_options["video_bitrate"] = args.bitrate
        if args.resolution:
            try:
                w, h = args.resolution.split("x")
                video_options["resolution"] = (int(w), int(h))
            except ValueError:
                print(f"错误: 分辨率格式应为 WIDTHxHEIGHT")
                sys.exit(1)

    # 显示命令预览
    from backend.subtitle import build_subtitle_command
    try:
        cmd = build_subtitle_command(input_path, output_path, subtitle_options, video_options)
        print("执行命令:")
        print("  " + " ".join(f'"{a}"' if " " in a else a for a in cmd))
        print("-" * 50)
    except Exception as e:
        print(f"命令构建失败: {e}")
        sys.exit(1)

    # 执行
    result = burn_subtitles(input_path, output_path, subtitle_options,
                            video_options=video_options)

    if result.success:
        print(f"[OK] 字幕烧录完成! 耗时 {result.duration:.1f}s")
        print(f"  输出文件: {result.output_path}")
    else:
        print(f"[FAIL] 烧录失败: {result.error}")
        if result.log_lines:
            print("  最后几行输出:")
            for line in result.log_lines[-5:]:
                print(f"    {line}")
        sys.exit(1)


# ─────────────────────────────────────────────
# argparse 主入口
# ─────────────────────────────────────────────

def main():
    # 强制 UTF-8 标准输出，避免 GBK 终端乱码
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    parser = argparse.ArgumentParser(
        description="FFmpeg++ CLI — 视频处理命令行工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python cli.py check
  python cli.py probe C:/videos/demo.mp4
  python cli.py transcode C:/videos/demo.mp4 C:/videos/out.mp4 --gpu NVIDIA --bitrate 3000
  python cli.py subtitle C:/videos/demo.mkv C:/videos/out.mkv --sub C:/subs/cn.ass
        """,
    )

    subparsers = parser.add_subparsers(dest="command", help="子命令")

    # ── check ──
    subparsers.add_parser("check", help="检测 ffmpeg 环境")

    # ── probe ──
    probe_parser = subparsers.add_parser("probe", help="探测视频文件信息")
    probe_parser.add_argument("file", help="视频文件路径")

    # ── transcode ──
    transcode_parser = subparsers.add_parser("transcode", help="视频转码/压缩")
    transcode_parser.add_argument("input", help="输入视频路径")
    transcode_parser.add_argument("output", help="输出视频路径")
    transcode_parser.add_argument("--gpu", default="CPU",
                                  choices=["CPU", "NVIDIA", "AMD", "Intel"],
                                  help="硬件加速 (默认: CPU)")
    transcode_parser.add_argument("--codec", default="h264",
                                  choices=["h264", "h265", "vp9"],
                                  help="视频编码器 (默认: h264)")
    transcode_parser.add_argument("--resolution", default=None,
                                  help="输出分辨率 WxH (如 1920x1080)")
    transcode_parser.add_argument("--bitrate", type=int, default=None,
                                  help="视频码率 kbps (如 3000)")
    transcode_parser.add_argument("--crf", type=int, default=None,
                                  help="CRF 质量模式 (0-51)")
    transcode_parser.add_argument("--fps", type=float, default=None,
                                  help="帧率 (如 30)")
    transcode_parser.add_argument("--preset", default="medium",
                                  help="CPU 编码预设 (默认: medium)")
    transcode_parser.add_argument("--audio-codec", default="aac",
                                  help="音频编码器 (默认: aac)")
    transcode_parser.add_argument("--audio-bitrate", type=int, default=128,
                                  help="音频码率 kbps (默认: 128)")

    # ── subtitle ──
    sub_parser = subparsers.add_parser("subtitle", help="字幕烧录")
    sub_parser.add_argument("input", help="输入视频路径")
    sub_parser.add_argument("output", help="输出视频路径")
    sub_parser.add_argument("--sub", default=None, help="外挂字幕文件路径")
    sub_parser.add_argument("--sub-index", type=int, default=None,
                            help="内嵌字幕轨道索引")
    sub_parser.add_argument("--bitrate", type=int, default=None,
                            help="同时压缩的视频码率 kbps")
    sub_parser.add_argument("--resolution", default=None,
                            help="同时压缩的视频分辨率 WxH")

    args = parser.parse_args()

    if args.command == "check":
        cmd_check()
    elif args.command == "probe":
        cmd_probe(args)
    elif args.command == "transcode":
        cmd_transcode(args)
    elif args.command == "subtitle":
        cmd_subtitle(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
