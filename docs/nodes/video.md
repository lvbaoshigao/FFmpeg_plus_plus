# 2.6 视频节点及参数

本页说明“视频”类别中当前可选的10个节点。使用前须将节点接入数据链，再设置参数；未连接至处理链的节点不参与处理。

## 节点选择参考

| 处理目标 | 适用节点 |
| --- | --- |
| 更改视频编码、码率、分辨率及音轨编码 | 音视频处理 |
| 将字幕烧录至视频画面 | 字幕烧录 |
| 保留指定时间范围内的片段 | 片段截取 |
| 从视频提取图片 | 帧提取 |
| 同步加速或减速画面与声音 | 变速 |
| 将视频音轨提取为音频文件 | 提取音频 |
| 统一帧率 | 帧率转换 |
| 处理隔行素材的梳齿现象 | 视频去隔行 |
| 画面与原音轨一起倒放 | 视频倒放 |
| 仅对画面应用黑色淡入/淡出 | 视频淡入淡出 |

缩放、裁剪、旋转、调色、锐化和水印功能位于[通用节点](image-common.md)，须选择“视频”媒体类型后使用。

## 音视频处理

操作：添加并选中节点，设置编码器和质量控制方式，再按需修改分辨率及帧率。常规输出可先使用CPU、H.264和AAC，并在输出节点核对封装格式及其兼容性。

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

“码率保持”不表示“复制流”：默认编码器仍为libx264。不重新编码时，须明确选择复制流；裁剪、字幕、变速等滤镜处理不能通过复制流完成。

> GPU选项表示请求使用的编码路径，实际可用性取决于设备和FFmpeg支持。Android MediaCodec未指定码率时默认使用8 Mbps，CRF会映射为硬件CQ；该控制方式与CPU的CRF并不完全相同。

## 字幕烧录

1. 选择字幕来源：默认“外部”，可浏览SRT、ASS、SSA、SUB、VTT；已有内嵌轨道时也可切到“内嵌”并选轨道。
2. 确认已选定字幕文件或内嵌轨道。
3. 设置字体、字号、描边和颜色，再处理短片段以检查实际字体效果。

默认字体为Arial，字号24，白字，黑色描边宽2。界面示例文字仅展示样式，不提供视频帧上的完整排版预览。烧录后的字幕属于画面内容，不能像独立字幕轨一样在播放器中关闭。

## 片段截取

1. 连接成“开始 → 片段截取 → 输出”。
2. 输入开始、结束时间，也可以拖范围滑块。默认从0到媒体时长。
3. 例如保留第10到30秒，填00:00:10.000与00:00:30.000。
4. 核对显示时长是否符合预期，再保存节点图。

连续截取时，下游截取时间相对于上游片段的有效范围，不能继续按原片时长填写。负时间或超出上游截取范围的时间会被校验拒绝。

## 帧提取

| 模式 | 参数 | 结果 |
| --- | --- | --- |
| 单帧（默认） | 提取时间，默认0秒 | 一张图片 |
| 范围 | 起止时间、提取帧率，初值1 fps | 将多张图片保存至文件夹 |
| 全部 | 提取帧率，初值1 fps | 在完整时段内按指定帧率提取图片，并保存至文件夹 |

格式可选PNG、JPG、BMP，默认PNG。例如每5秒提取一张图片时，提取帧率设为0.2 fps。“全部”表示覆盖完整时段，仍受提取帧率控制，不表示逐一保存全部原始帧。

“上一帧/下一帧”按钮当前按1/30秒步进，不保证按素材实际帧率定位。需要指定时间时，应直接输入时间并刷新。验证后续图片处理时，应先使用单帧模式；多帧目录不能等同于单张普通图片输入。

## 变速

默认速度为1倍。可使用常规倍速滑块和预设，或开启“自定义倍速”；自定义输入初值为10倍，支持正数。

例如以2倍速播放时，将倍速设为2并将节点接在截取节点之后：**开始 → 片段截取 → 变速 → 输出**。该操作同步改变画面和声音的速度及输出时长，需要重新编码，不能仅通过修改视频帧率标签完成。

## 提取音频

默认采用完整提取、Copy编码和M4A格式。提取指定片段时，切换到“片段提取”并设置起止时间；可试听所选片段。

- Copy表示复制原音频流，不执行目标格式所需的编码转换。因容器不兼容而报错时，须明确选择AAC、MP3等兼容编码。
- 输出媒体类型为音频，可连接[音质调整、音量等节点](audio.md)。
- 试听仅临时提取所选片段，不表示已生成最终文件，也不包含后续完整音频链的处理效果。

## 帧率转换

默认帧率为30 fps。预设包含23.976、24、25、29.97、30、50、59.94、60，也支持自定义输入；界面标注为1–240 fps，实际输入检查要求大于0且不超过240。

例如将目标帧率设为25后保存。节点会重新编码为恒定帧率，并保持音频；提高帧率通过补帧/重复帧处理实现，不能恢复原素材未记录的拍摄细节。

## 视频去隔行

默认模式为“逐帧（推荐）”，场序为“自动检测”。先使用默认值处理短片段；结果不符合预期时，根据源素材实际场序选择上场优先或下场优先。“逐场”会使输出帧率翻倍，须按素材和输出要求选择。

## 视频倒放

本节点无专用参数，接入数据链后同时倒放画面和原有音轨。

> 倒放需要缓存完整素材，内存需求随素材长度增加。应先使用“片段截取”保留所需片段，再连接倒放节点。

## 视频淡入淡出

默认淡入2秒、淡出2秒，淡出位置为“自动”。淡入从当前输入的0秒开始；自动淡出根据上游截取/变速后的输入时长推算。

1. 分别填写淡入、淡出时长，范围为0–60秒；0表示关闭对应效果。
2. 需要指定淡出位置时，切换到“指定时间”，填写相对于当前输入起点的淡出开始时间。
3. 需要对声音应用淡入淡出时，须另行使用提取音频和音频处理方案；本节点仅处理画面，原音轨不变。

## 源码核对

字段和默认值来自[音视频处理](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L73-L101)、[字幕](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/subtitle_step_editor.dart#L27-L37)、[截取](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/clip_step_editor.dart#L38-L43)、[帧提取](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/frame_step_editor.dart#L36-L48)、[变速](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/speed_step_editor.dart#L18-L22)、[音频提取](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/extract_audio_step_editor.dart#L151-L169)、[帧率](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_frame_rate_step_editor.dart#L20-L80)、[去隔行](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_deinterlace_step_editor.dart#L30-L60)、[倒放](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_reverse_step_editor.dart#L20-L33)、[视频淡入淡出](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/video_fade_step_editor.dart#L37-L52)。

[上一节：画布](canvas.md) · [下一节：音频节点](audio.md)
