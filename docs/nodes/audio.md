# 2.7 音频节点及参数

“音频”类别包含14个节点，均接收音频数据。源媒体为视频时，须先连接“提取音频”，再连接音频处理节点。视频源直接连接仅接受音频的节点会被类型检查拒绝。

## 基础处理流程

需要降低录音音量并裁剪首尾静音时，可使用以下流程：

**开始 → 静音裁剪 → 调整音量 → 输出**

每次调整一个参数，并使用短素材试听结果。同时提高降噪、动态压缩和响度标准化的处理强度，会增加定位音质变化来源的难度。

## 音质调整

1. 选中节点，选择码率预设或“自定义”。
2. 仅在有采样率要求时修改采样率，否则保持原始值。
3. 更换文件格式或音频编码器须使用[通用“格式转换”](image-common.md)；本节点仅管理码率和采样率。

默认码率为“保持原样”，采样率为“保持原始”。码率预设为64、96、128、192、256、320 kbps，自定义输入框初值为128。采样率可选22.05、44.1、48、96 kHz。提高码率不能恢复已丢失的细节；“保持”选项也不保证整条处理链无损。

## 调整速度与调整音量

| 节点 | 操作 | 默认与范围 |
| --- | --- | --- |
| 调整速度 | 拖动速度滑块或选预设；重置回1倍 | 默认1倍，0.5–4倍，使用atempo保留音高 |
| 调整音量 | 调整dB值，负值减小、正值增大 | 默认0 dB，−30到+30 dB，可重置 |

例如需要降低音量时，可先设为−3 dB并试听。“+6 dB”仅表示增益提升，不表示音质改善；过度提升会产生削波失真。

## 压缩动态范围

本节点用于缩小高低电平之间的动态差异。连接后先保留默认值，确认需要压缩动态范围后，再逐步调整阈值和压缩比。

| 参数 | 默认 | 界面范围 |
| --- | --- | --- |
| 阈值threshold | −20 dB | −60–0 dB |
| 压缩比ratio | 3:1 | 1:1–20:1 |
| 启动attack | 10 ms | 0.1–200 ms |
| 释放release | 100 ms | 10–1000 ms |
| 补偿增益makeup | 4倍 | 1–16倍，单位不是dB |
| 拐点knee | 2.8 | 1–10 |

比较压缩效果前，应先降低补偿增益并试听，分别评估音量变化和音质变化。点击“恢复默认”可恢复上述初值。

## 元信息编辑

本节点主要处理封面和歌词：可选择JPG/PNG封面或LRC/TXT歌词，也可勾选删除现有封面、删除现有歌词。默认未选择文件，删除选项未勾选。

选择文件后须核对文件名和封面预览；启用删除开关会清空对应的新文件选择。目标格式能否携带封面/歌词取决于容器和编码支持。本节点不提供任意标签字段的通用编辑功能。

## 音频淡入淡出

默认淡入2秒、淡出2秒、淡出起始0（自动），曲线为线性tri。

1. 设置淡入、淡出时长，范围为0–60秒；0表示关闭对应效果。
2. 淡出起始位置留空或填0时，由后端推算；手动指定时，填写相对于当前输入起点的秒数。
3. 按需选择正弦、指数、对数等曲线，并试听实际过渡效果。

本节点仅处理声音的淡入淡出；[视频淡入淡出](video.md)仅处理画面。

## 响度标准化

默认目标响度−16 LUFS、真峰值上限−1.5 dBTP、响度范围11 LU。范围分别为−70到−5 LUFS、−9到0 dBTP、1–50 LU。

目标平台明确规定响度要求时，应按要求设置；未规定时，可先保留默认值并处理短片段检查。本节点使用loudnorm处理，不保证输出满足所有平台的验收要求。

## 音频噪声门

用于压低低于阈值的背景声。默认阈值−30 dB、压缩比2:1、启动20 ms、释放250 ms。

| 参数 | 范围 | 调整说明 |
| --- | --- | --- |
| 阈值 | −80–0 dB | 在抑制背景声的同时，检查是否误抑制低音量的语音尾部 |
| 压缩比 | 1–20 | 数值越大，抑制程度越高 |
| 启动 | 0.01–500 ms | 启动过慢可能抑制声音起始部分 |
| 释放 | 10–2000 ms | 释放过快可能造成声音断续或增益反复变化 |

先调整阈值，再调整启动和释放时间。噪声门不等同于持续降噪，不能单独分离说话期间的噪声。

## 音频降噪

默认降噪量12 dB、噪声底−30 dB；范围分别为0.01–40 dB和−80到−20 dB。

先保留噪声底默认值，再逐步调整降噪量。界面建议从6–15 dB开始；超过25 dB可能损失人声细节。试听时须同时检查背景噪声和语音细节，不能仅以背景是否完全静音评价结果。

## 静音裁剪

默认模式为“首尾都裁”，静音阈值为−40 dB，最短静音时长为0.1秒。也可仅裁剪开头或结尾；阈值范围为−60到−20 dB，时长范围为0–5秒。

例如录音结尾存在较长静音时，可选择“只裁结尾”，并先使用默认阈值处理短素材。本节点仅裁剪首尾静音，不自动删除音频内部的每次停顿。

## 音频频谱图与音频波形图

两个节点均将音频转换为**单张静态图片**：频谱图表示频率分布，波形图表示振幅随时间的变化。输出不含音频，不属于带声音的可视化视频。

1. 添加一个可视化节点并连到音频源。
2. 设置宽高和图像格式。默认1280×720、PNG；宽高均64–4096像素，格式PNG/JPG/WebP。
3. 继续缩放、调色或压缩时，连接图片处理节点；输出媒体类型为静态图片，不能继续连接音量节点。

示例：**开始 → 音频波形图 → 图片压缩 → 输出**。

## 音频倒放

本节点无专用参数，接入数据链后从结尾倒放至开头。处理需要缓存完整素材，内存需求随音频长度增加。可先在外部准备短片段；源媒体为视频时，也可先执行“片段截取 → 提取音频”，再倒放。

## 音频均衡器

三个频段分别为低频100 Hz、中频1 kHz、高频8 kHz，默认增益均为0 dB；每段范围为−12到+12 dB，支持“重置为原声”。

例如需要减弱低频轰鸣时，可先将低频设为−2 dB，其他两段保持0，再试听。正值表示增强，负值表示衰减；增益大小不代表音质优劣。

## 源码核对

默认与范围来自[音质](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_quality_step_editor.dart#L14-L27)、[速度](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_speed_step_editor.dart#L16-L41)、[音量](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_volume_step_editor.dart#L16-L41)、[压缩器](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_compressor_step_editor.dart#L16-L55)、[元信息](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_metadata_step_editor.dart#L17-L53)、[淡入淡出](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_fade_step_editor.dart#L22-L80)、[响度](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_normalize_step_editor.dart#L23-L69)、[噪声门](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_noise_gate_step_editor.dart#L37-L89)、[降噪](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_denoise_step_editor.dart#L23-L55)、[静音裁剪](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_silence_trim_step_editor.dart#L24-L69)、[静态可视化](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_visualization_step_editor.dart#L40-L113)、[倒放](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_reverse_step_editor.dart#L20-L33)、[均衡器](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/audio_equalizer_step_editor.dart#L22-L41)。

[上一节：视频节点](video.md) · [下一节：图片与通用节点](image-common.md)
