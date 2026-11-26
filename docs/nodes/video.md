# 2.6 视频节点：按目标选操作

本页覆盖“视频”类别中当前可选的10个节点。先把节点串进数据链，再调整参数；只把节点摆在旁边不会参与处理。

## 先选对节点

| 你想做的事 | 优先使用 |
| --- | --- |
| 换编码、码率、分辨率、音轨编码 | 音视频处理 |
| 把字幕固定在画面上 | 字幕烧录 |
| 只留一段时间 | 片段截取 |
| 从视频取图片 | 帧提取 |
| 画面和声音一起快放/慢放 | 变速 |
| 把原视频的声音变成音频文件 | 提取音频 |
| 统一帧率 | 帧率转换 |
| 消除隔行素材的梳齿 | 视频去隔行 |
| 画面与原音轨一起倒放 | 视频倒放 |
| 只让画面从黑色淡入/淡出 | 视频淡入淡出 |

缩放、裁剪、旋转、调色、锐化和水印在[通用节点](image-common.md)里，选择“视频”媒体类型后使用。

## 音视频处理

操作：添加节点，选中它；先选编码器和质量控制方式，再决定是否改分辨率及帧率。想做常规兼容输出，可从CPU、H.264和AAC开始，最后在输出节点核对封装格式。

| 字段 | 新节点默认值/含义 |
| --- | --- |
| GPU | CPU；桌面还有NVIDIA/AMD/Intel，Android有Android选项，iOS使用CPU |
| 编码器 | libx264；可搜索，也可选“复制流（不重编码）” |
| 码率模式 | 保持；切到码率时初值2000 kbps，切到CRF时初值23 |
| Preset | medium，CPU时显示 |
| 像素格式 | 自动 |
| 分辨率 | 原始；可选2160p、1080p、720p、480p、360p或自定义宽高 |
| 帧率 | 保持；可选预设或自定义 |
| 音频编码 | AAC |
| 音频码率 | 不指定；可切预设、自定义或保持原样 |
| 声道 | 保持；还可选单声道、立体声、5.1、7.1 |

“码率保持”不等于“复制流”：默认编码器仍是libx264。真正不重编码要明确选择复制流，而且裁剪、字幕、变速等滤镜处理不能靠复制流完成。

> GPU选项表示请求的编码路径，不保证机器和FFmpeg一定支持。Android MediaCodec未指定码率时使用8 Mbps默认值，CRF会映射到硬件CQ；别把它和CPU的CRF当成完全相同的控制方式。

## 字幕烧录

1. 选择字幕来源：默认“外部”，可浏览SRT、ASS、SSA、SUB、VTT；已有内嵌轨道时也可切到“内嵌”并选轨道。
2. 确认字幕文件或轨道确实选中。
3. 设置字体、字号、描边和颜色，再跑一小段检验实际字体效果。

默认字体Arial、字号24、白字、黑色描边宽2。界面中的示例文字用于看样式，不是视频帧上的完整排版预览。烧录后的字幕成为画面的一部分，不能像独立字幕轨那样在播放器里关闭。

## 片段截取

1. 连接成“开始 → 片段截取 → 输出”。
2. 输入开始、结束时间，也可以拖范围滑块。默认从0到媒体时长。
3. 例如保留第10到30秒，填00:00:10.000与00:00:30.000。
4. 看显示时长是否符合预期，然后保存。

连续截取时，后面的时间是相对于上游片段的有效范围，别再照原片时长填写。负时间或超出上游截取范围会被校验拦截。

## 帧提取

| 模式 | 要设什么 | 结果 |
| --- | --- | --- |
| 单帧（默认） | 提取时间，默认0秒 | 一张图片 |
| 范围 | 起止时间、提取帧率，初值1 fps | 多张图放入文件夹 |
| 全部 | 提取帧率，初值1 fps | 对全时段按指定提取帧率取图，放入文件夹 |

格式可选PNG、JPG、BMP，默认PNG。比如想每5秒留一张图，提取帧率填0.2 fps；不要把“全部”误解成无视提取帧率、逐个保存原始每一帧。

“上一帧/下一帧”按钮当前按1/30秒步进，并非始终读取真实素材帧率。需要特定时间时直接输入并刷新。后续图片处理建议先从单帧模式练习；多帧目录不等同于一张普通图片输入。

## 变速

默认1倍。可用常规倍速滑块和预设，也可开启“自定义倍速”；自定义输入初值10倍，支持正数。

例如要快放为两倍，选2倍并把它接在截取之后：**开始 → 片段截取 → 变速 → 输出**。输出时长会改变；这是画面和声音一起变速，不是只改视频的帧率标签。该操作需要重新编码。

## 提取音频

默认完整提取、Copy编码、M4A格式。要取一段，切“片段提取”，设开始和结束时间，可试听选段。

- Copy表示复制原音频流，不替你把编码转换成目标格式要求的编码；容器不兼容时报错时，明确选AAC、MP3等合适编码。
- 输出变成音频，可以接[音质调整、音量等节点](audio.md)。
- 试听是临时提取选段，不代表已经生成最终文件，也不是整条后续音频链的效果。

## 帧率转换

默认30 fps。预设包含23.976、24、25、29.97、30、50、59.94、60，也能填自定义；界面标为1–240 fps，实际输入检查要求大于0且不超过240。

把目标帧率选为25后保存即可。节点会重新编码成恒定帧率，音频保持；升帧率只是补帧/重复帧处理，不会凭空得到真实拍摄细节。

## 视频去隔行

默认“逐帧（推荐）”、场序“自动检测”。先用默认值处理一小段；仍不对时，按源素材实际场序选上场优先或下场优先。“逐场”会使输出帧率翻倍，不是普通的画质增强开关。

## 视频倒放

接入链后即可用，没有专用参数。它会同时倒放画面和原有音轨。

> 倒放需要缓存完整素材，长视频可能占用大量内存。先用“片段截取”缩短到需要倒放的部分，再接倒放节点。

## 视频淡入淡出

默认淡入2秒、淡出2秒，淡出位置为“自动”。淡入从当前输入的0秒开始；自动淡出根据经过前面截取/变速后的输入时长推算。

1. 分别填淡入、淡出时长，范围0–60秒；0关闭对应效果。
2. 想精确定位淡出时，切“指定时间”，填写相对当前输入开头的开始时间。
3. 需要声音一起淡入淡出时，另走提取音频和音频处理方案；本节点只改画面，原音轨不变。

## 源码核对

字段和默认值来自[音视频处理](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L73-L101)、[字幕](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/subtitle_step_editor.dart#L27-L37)、[截取](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/clip_step_editor.dart#L38-L43)、[帧提取](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/frame_step_editor.dart#L36-L48)、[变速](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/speed_step_editor.dart#L18-L22)、[音频提取](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/extract_audio_step_editor.dart#L151-L169)、[帧率](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_frame_rate_step_editor.dart#L20-L80)、[去隔行](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_deinterlace_step_editor.dart#L30-L60)、[倒放](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_reverse_step_editor.dart#L20-L33)、[视频淡入淡出](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_fade_step_editor.dart#L37-L52)。

[上一节：画布](canvas.md) · [下一节：音频节点](audio.md)
