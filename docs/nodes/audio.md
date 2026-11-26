# 2.7 音频节点：先听清目标，再调参数

“音频”类别有14项。它们接收音频数据；如果源是视频，先接“提取音频”，再接这里的节点。直接从视频源连到只接受音频的处理节点会被类型检查拒绝。

## 常用起步流程

想让录音轻一点、头尾干净一点，可以先试：

**开始 → 静音裁剪 → 调整音量 → 输出**

先只调一个参数，运行短素材听结果；不要同时把降噪、压缩器和响度标准化全调到很强，之后很难判断是哪一步影响了声音。

## 音质调整

1. 选中节点，选择码率预设或“自定义”。
2. 有采样率要求时再改采样率，否则先保持原始。
3. 需要更换文件格式或音频编码器时，用[通用“格式转换”](image-common.md)，本节点专门管理码率和采样率。

默认码率“保持原样”、采样率“保持原始”。码率预设64、96、128、192、256、320 kbps；自定义框初始显示128。采样率可选22.05、44.1、48、96 kHz。提高码率不会恢复已经丢失的细节，“保持”也不能单独保证整条处理链无损。

## 调整速度与调整音量

| 节点 | 操作 | 默认与范围 |
| --- | --- | --- |
| 调整速度 | 拖动速度滑块或选预设；重置回1倍 | 默认1倍，0.5–4倍，使用atempo保留音高 |
| 调整音量 | 调整dB值，负值减小、正值增大 | 默认0 dB，−30到+30 dB，可重置 |

例如声音稍响，先试−3 dB；不要把“+6 dB”理解为无条件更好。过度提升会产生削波失真。

## 压缩动态范围

适合缩小大声与小声之间的差别。连接后先保留默认，确认目标是让动态更均匀，再逐步改阈值和压缩比。

| 参数 | 默认 | 界面范围 |
| --- | --- | --- |
| 阈值threshold | −20 dB | −60–0 dB |
| 压缩比ratio | 3:1 | 1:1–20:1 |
| 启动attack | 10 ms | 0.1–200 ms |
| 释放release | 100 ms | 10–1000 ms |
| 补偿增益makeup | 4倍 | 1–16倍，单位不是dB |
| 拐点knee | 2.8 | 1–10 |

先降低补偿增益再试听，避免把“压缩更响”错当成“质量更好”。可以用“恢复默认”回到这组初值。

## 元信息编辑

它主要处理封面和歌词：选JPG/PNG封面，或LRC/TXT歌词；也可以勾选删除现有封面、删除现有歌词。默认不选文件、不勾删除。

选择后查看文件名和封面预览；删除开关会清空相应的新文件选择。目标格式能否携带封面/歌词仍受容器和编码支持限制。本节点不是任意标签字段的通用编辑器。

## 音频淡入淡出

默认淡入2秒、淡出2秒、淡出起始0（自动），曲线为线性tri。

1. 调淡入、淡出时长，范围0–60秒，0关闭对应效果。
2. 留空或填0让后端推算淡出位置；要指定时，填相对当前输入的秒数。
3. 按需换正弦、指数、对数等曲线，听实际过渡是否自然。

这是声音的淡入淡出；[视频淡入淡出](video.md)只改画面。

## 响度标准化

默认目标响度−16 LUFS、真峰值上限−1.5 dBTP、响度范围11 LU。范围分别为−70到−5 LUFS、−9到0 dBTP、1–50 LU。

如果目标平台给了明确的响度要求，就按要求填；没有时可先保留默认，处理短片段检查。它使用loudnorm处理，不要把它描述为保证通过任何平台验收的自动母带工具。

## 音频噪声门

用于压低低于阈值的背景声。默认阈值−30 dB、压缩比2:1、启动20 ms、释放250 ms。

| 参数 | 范围 | 怎么调 |
| --- | --- | --- |
| 阈值 | −80–0 dB | 让背景声被压低，同时别吞掉轻声结尾 |
| 压缩比 | 1–20 | 越大抑制越明显 |
| 启动 | 0.01–500 ms | 太慢可能漏掉开头 |
| 释放 | 10–2000 ms | 太快容易听到断续或“抽气” |

先调阈值再调时间。噪声门和持续降噪不同，它并不把说话期间的噪声单独分离出来。

## 音频降噪

默认降噪量12 dB、噪声底−30 dB；范围分别为0.01–40 dB和−80到−20 dB。

先保留噪声底，逐步调降噪量。界面建议6–15 dB作为起点；超过25 dB容易伤到人声细节。以听感为准，不要只追求背景完全静音。

## 静音裁剪

默认“首尾都裁”、静音阈值−40 dB、最短静音0.1秒。也能只裁开头或只裁结尾；阈值范围−60到−20 dB，时长0–5秒。

比如录音结尾留白很长，先选“只裁结尾”，保留默认阈值处理一小段。它用于头尾，不是自动删除整段音频里每一次停顿。

## 音频频谱图与音频波形图

两者都把音频生成**单张静态图片**：频谱图看频率分布，波形图看振幅随时间变化。结果不含音频，也不是带声音的可视化视频。

1. 添加一个可视化节点并连到音频源。
2. 设置宽高和图像格式。默认1280×720、PNG；宽高均64–4096像素，格式PNG/JPG/WebP。
3. 想继续缩放、调色或压缩，就接图片节点。需要的是静态图，不要再接音量节点。

示例：**开始 → 音频波形图 → 图片压缩 → 输出**。

## 音频倒放

没有专用参数，连上即可从结尾倒放到开头。会缓存完整素材，长音频更占内存。可以先在外部准备短片段，视频来源也可先“片段截取 → 提取音频”，再倒放。

## 音频均衡器

三段分别是低频100 Hz、中频1 kHz、高频8 kHz，默认均为0 dB；每段−12到+12 dB，支持“重置为原声”。

例如想减一点低频轰鸣，可先把低频调至−2 dB，其他两段保持0，然后试听。正值增强、负值衰减，不是三段越高越好。

## 源码核对

默认与范围来自[音质](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_quality_step_editor.dart#L14-L27)、[速度](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_speed_step_editor.dart#L16-L41)、[音量](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_volume_step_editor.dart#L16-L41)、[压缩器](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_compressor_step_editor.dart#L16-L55)、[元信息](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_metadata_step_editor.dart#L17-L53)、[淡入淡出](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_fade_step_editor.dart#L22-L80)、[响度](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_normalize_step_editor.dart#L23-L69)、[噪声门](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_noise_gate_step_editor.dart#L37-L89)、[降噪](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_denoise_step_editor.dart#L23-L55)、[静音裁剪](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_silence_trim_step_editor.dart#L24-L69)、[静态可视化](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_visualization_step_editor.dart#L40-L113)、[倒放](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_reverse_step_editor.dart#L20-L33)、[均衡器](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_equalizer_step_editor.dart#L22-L41)。

[上一节：视频节点](video.md) · [下一节：图片与通用节点](image-common.md)
