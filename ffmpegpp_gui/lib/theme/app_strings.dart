/// 全局多语言字符串
/// 使用: Strings.of(context).xxx 或直接 Strings.zh / Strings.en
class AppStrings {
  final String lang;
  const AppStrings(this.lang);

  static const zh = AppStrings('zh');
  static const en = AppStrings('en');

  factory AppStrings.of(String lang) => lang == 'zh' ? zh : en;
  bool get isZh => lang == 'zh';

  // ── 侧边栏 ──
  String get navProjects => lang == 'zh' ? '项目' : 'Projects';
  String get navQueue => lang == 'zh' ? '处理队列' : 'Queue';
  String get navCommand => lang == 'zh' ? '命令' : 'Command';
  String get navSettings => lang == 'zh' ? '设置' : 'Settings';
  String get backendConnected => lang == 'zh' ? '后端已连接' : 'Backend connected';

  // ── 项目页 ──
  String get addVideo => lang == 'zh' ? '添加文件' : 'Add File';
  String get noVideos => lang == 'zh' ? '还没有添加文件' : 'No files added';
  String get clickAdd => lang == 'zh' ? '点击上方「添加文件」按钮开始' : 'Click Add File to start';
  String get probing => lang == 'zh' ? '解析中...' : 'Probing...';
  String get edit => lang == 'zh' ? '编辑' : 'Edit';
  String get addToQueue => lang == 'zh' ? '加入处理队列' : 'Add to queue';
  String get remove => lang == 'zh' ? '移除' : 'Remove';
  String get dropToAdd => lang == 'zh' ? '松开以添加文件' : 'Drop to add files';
  String get dragDropHint => lang == 'zh' ? '或拖拽文件到此处' : 'or drag & drop files here';
  String get noMatch => lang == 'zh' ? '未找到匹配的文件' : 'No matching files';
  String get searchVideos => lang == 'zh' ? '搜索文件...' : 'Search files...';
  String get search => lang == 'zh' ? '搜索' : 'Search';
  String get close => lang == 'zh' ? '关闭' : 'Close';
  String get selectAll => lang == 'zh' ? '全选' : 'Select all';
  String get deselectAll => lang == 'zh' ? '取消全选' : 'Deselect all';
  String get deleteSelected => lang == 'zh' ? '删除选中' : 'Delete selected';

  // ── 队列页 ──
  String get startProcessing => lang == 'zh' ? '开始处理' : 'Start';
  String get cancelAll => lang == 'zh' ? '取消全部' : 'Cancel All';
  String get clearCompleted => lang == 'zh' ? '清除已完成' : 'Clear done';
  String get clearAll => lang == 'zh' ? '移除所有' : 'Remove all';
  String get emptyQueue => lang == 'zh' ? '处理队列为空' : 'Queue empty';
  String get emptyQueueHint => lang == 'zh' ? '在项目页添加文件并点击 ▶ 按钮' : 'Add files in Projects and click ▶';
  String get pending => lang == 'zh' ? '等待中' : 'Pending';
  String get processing => lang == 'zh' ? '处理中' : 'Processing';
  String get completed => lang == 'zh' ? '已完成' : 'Completed';
  String get failed => lang == 'zh' ? '失败' : 'Failed';
  String get cancelled => lang == 'zh' ? '已取消' : 'Cancelled';
  String get remaining => lang == 'zh' ? '剩余' : 'Remaining';
  String get cancel => lang == 'zh' ? '取消' : 'Cancel';
  // Queue detail labels
  String get qInput => lang == 'zh' ? '输入' : 'Input';
  String get qOutput => lang == 'zh' ? '输出' : 'Output';
  String get qCmd => 'FFmpeg';
  String get qLogs => lang == 'zh' ? '日志' : 'Logs';
  String get qError => lang == 'zh' ? '错误' : 'Error';
  String get qWeight => lang == 'zh' ? '字重' : 'Weight';
  // Debug
  String get dDebug => lang == 'zh' ? '调试' : 'Debug';
  String get dDebugMode => lang == 'zh' ? '调试模式' : 'Debug mode';
  String get dSaveLogs => lang == 'zh' ? '保存日志' : 'Save logs';
  String get dLogPath => lang == 'zh' ? '日志路径' : 'Log path';
  // Background
  String get bgTitle => lang == 'zh' ? '背景' : 'Background';
  String get bgNone => lang == 'zh' ? '无' : 'None';
  String get bgOpacity => lang == 'zh' ? '背景不透明度' : 'BG Opacity';
  String get cardOpacity => lang == 'zh' ? '卡片不透明度' : 'Card Opacity';
  // Resource monitor
  String get resCpu => 'CPU';
  String get resGpu => 'GPU';
  String get resRam => lang == 'zh' ? '内存' : 'RAM';
  // Command page
  String get cmdRef => lang == 'zh' ? '命令参考' : 'Command Reference';
  String get cmdExamples => lang == 'zh' ? '常用示例' : 'Examples';
  String get cmdParams => lang == 'zh' ? '参数说明' : 'Parameters';
  String get cmdPlaceholders => lang == 'zh' ? '占位符' : 'Placeholders';
  String get cmdPlaceholderDesc => lang == 'zh' ? '{input}→输入文件  {output}→输出文件' : '{input}→input file  {output}→output file';
  String get cmdExecute => lang == 'zh' ? '执行' : 'Execute';
  String get cmdHint => lang == 'zh' ? '命令执行功能将在后续版本实现' : 'Command execution coming in next version';

  // ── 设置页 ──
  String get settingsTitle => lang == 'zh' ? '设置' : 'Settings';
  String get software => lang == 'zh' ? '软件信息' : 'Software';
  String get appearance => lang == 'zh' ? '外观' : 'Appearance';
  String get language => lang == 'zh' ? '语言' : 'Language';
  String get font => lang == 'zh' ? '字体' : 'Font';
  String get ffmpegSettings => lang == 'zh' ? 'FFmpeg' : 'FFmpeg';
  String get output => lang == 'zh' ? '输出' : 'Output';
  String get darkMode => lang == 'zh' ? '暗色模式' : 'Dark Mode';
  String get accentColor => lang == 'zh' ? '主题色' : 'Accent Color';
  String get fontFamily => lang == 'zh' ? '字体名称' : 'Font Family';
  String get fontSize => lang == 'zh' ? '字号' : 'Font Size';
  String get importFont => lang == 'zh' ? '选择系统字体' : 'Pick System Font';
  String get fontOrSelect => lang == 'zh' ? '输入字体名或从列表选择' : 'Type name or pick from list';
  String get fontBuiltin => lang == 'zh' ? '内置字体' : 'Built-in fonts';

  // ── 软件信息 ──
  String get swName => lang == 'zh' ? '软件名称' : 'Name';
  String get swVersion => lang == 'zh' ? '版本' : 'Version';
  String get swBuild => lang == 'zh' ? '构建日期' : 'Build';
  String get swProtocol => lang == 'zh' ? '协议' : 'Protocol';
  String get swFooter => lang == 'zh' ? 'FFmpeg++ Video Tool  v4.7.2  |  构建 2026-07-13  |  JSON v0.1.0' : 'FFmpeg++ Video Tool  v4.7.2  |  Build 2026-07-13  |  JSON v0.1.0';
  String get languageInterface => lang == 'zh' ? '界面语言' : 'Interface Language';
  String get ffmpegFound => lang == 'zh' ? 'FFmpeg 已检测到' : 'FFmpeg detected';
  String get ffmpegNotFound => lang == 'zh' ? 'FFmpeg 未检测到' : 'FFmpeg not found';
  String get recheck => lang == 'zh' ? '重新检测' : 'Re-check';
  String get ffmpegPath => lang == 'zh' ? 'FFmpeg 路径' : 'FFmpeg path';
  String get ffprobePath => lang == 'zh' ? 'FFprobe 路径' : 'FFprobe path';
  String get outputDir => lang == 'zh' ? '默认输出目录' : 'Default output dir';
  String get browse => lang == 'zh' ? '浏览' : 'Browse';
  String get save => lang == 'zh' ? '保存' : 'Save';

  // ── 编辑配置 ──
  String get editTitle => lang == 'zh' ? '编辑' : 'Edit';
  String get tabOutput => lang == 'zh' ? '输出' : 'Output';
  String get tabVideo => lang == 'zh' ? '视频' : 'Video';
  String get tabAudio => lang == 'zh' ? '音频' : 'Audio';
  String get tabSubtitle => lang == 'zh' ? '字幕' : 'Subtitle';
  String get saveConfig => lang == 'zh' ? '保存配置' : 'Save Config';
  // Output tab
  String get cfgFormat => lang == 'zh' ? '格式' : 'Format';
  String get cfgFormatKeep => lang == 'zh' ? '保持原格式' : 'Original';
  String get cfgNaming => lang == 'zh' ? '命名' : 'Naming';
  String get cfgNamingKeep => lang == 'zh' ? '保持原名' : 'Original';
  String get cfgNamingSuffix => lang == 'zh' ? '添加后缀' : 'Suffix';
  String get cfgNamingCustom => lang == 'zh' ? '自定义' : 'Custom';
  String get cfgSuffix => lang == 'zh' ? '后缀' : 'Suffix';
  String get cfgFilename => lang == 'zh' ? '文件名' : 'Filename';
  // Video tab
  String get cfgCodec => lang == 'zh' ? '编码器' : 'Codec';
  String get cfgGpu => lang == 'zh' ? 'GPU' : 'GPU';
  String get cfgRate => lang == 'zh' ? '码率' : 'Rate';
  String get cfgBitrate => lang == 'zh' ? '码率 (kbps)' : 'Bitrate';
  String get cfgCrf => lang == 'zh' ? 'CRF 质量' : 'CRF';
  String get cfgRateKeep => lang == 'zh' ? '不变 (保持原码率)' : 'Keep (original)';
  String get cfgRes => lang == 'zh' ? '分辨率' : 'Res';
  String get cfgResOrig => lang == 'zh' ? '保持原分辨率' : 'Original';
  String get cfgRes4k => lang == 'zh' ? '4K' : '4K';
  String get cfgRes1080p => '1080p';
  String get cfgRes720p => '720p';
  String get cfgRes480p => '480p';
  String get cfgResCustom => lang == 'zh' ? '自定义' : 'Custom';
  String get cfgFps => 'FPS';
  String get cfgFpsKeep => lang == 'zh' ? '保持' : 'Original';
  String get cfgFps24 => '24';
  String get cfgFps30 => '30';
  String get cfgFps60 => '60';
  String get cfgFpsCustom => lang == 'zh' ? '自定义' : 'Custom';
  // Audio tab
  String get cfgAudioCodec => lang == 'zh' ? '编码器' : 'Codec';
  String get cfgAudioBitrate => lang == 'zh' ? '码率' : 'Bitrate';
  String get cfgChannels => lang == 'zh' ? '声道' : 'Ch';
  String get cfgChKeep => lang == 'zh' ? '保持' : 'Original';
  String get cfgChMono => lang == 'zh' ? '单声道' : 'Mono';
  String get cfgChStereo => lang == 'zh' ? '立体声' : 'Stereo';
  String get cfgCh51 => lang == 'zh' ? '5.1环绕' : '5.1';
  // Subtitle tab
  String get cfgBurn => lang == 'zh' ? '烧录字幕' : 'Burn subtitles';
  String get cfgSubSource => lang == 'zh' ? '来源' : 'Source';
  String get cfgSubExternal => lang == 'zh' ? '外挂文件' : 'External file';
  String get cfgSubEmbedded => lang == 'zh' ? '内嵌轨道' : 'Embedded track';
  String get cfgSubNotSel => lang == 'zh' ? '未选择' : 'Not selected';
  // Subtitle style
  String get cfgSubStyle => lang == 'zh' ? '字幕样式 (ASS/SSA)' : 'Subtitle Style (ASS/SSA)';
  String get cfgSubFont => lang == 'zh' ? '字体' : 'Font';
  String get cfgSubSize => lang == 'zh' ? '大小' : 'Size';
  String get cfgSubColor => lang == 'zh' ? '颜色' : 'Color';
  String get cfgSubOutline => lang == 'zh' ? '描边' : 'Outline';
  String get cfgSubOutlineColor => lang == 'zh' ? '描边颜色' : 'Outline Color';
  // About
  String get aboutTitle => lang == 'zh' ? '关于' : 'About';
  String get aboutVersion => lang == 'zh' ? '版本' : 'Version';
  String get aboutBuildDate => lang == 'zh' ? '编译日期' : 'Build Date';
  String get aboutBlog => lang == 'zh' ? '作者博客' : 'Blog';
  String get aboutGithub => lang == 'zh' ? '开源地址' : 'GitHub';
  String get aboutSponsor => lang == 'zh' ? '赞助支持' : 'Sponsor';
  String get aboutSponsorBtn => lang == 'zh' ? '查看收款码' : 'View QR Codes';
  String get aboutBlogLink => lang == 'zh' ? '博客' : 'Blog';
  String get aboutThanks => lang == 'zh' ? '感谢您的支持！' : 'Thank you for your support!';
  String get aboutWxTitle => lang == 'zh' ? '微信收款码' : 'WeChat Pay';
  String get aboutZfbTitle => lang == 'zh' ? '支付宝收款码' : 'Alipay';
  String get aboutClose => lang == 'zh' ? '关闭' : 'Close';
  String get aboutZoomHint => lang == 'zh' ? '点击放大' : 'Tap to zoom';
  String get checkUpdate => lang == 'zh' ? '检查更新' : 'Check for Updates';
  String get checking => lang == 'zh' ? '检查中...' : 'Checking...';
  String get updateAvailable => lang == 'zh' ? '发现新版本' : 'Update Available';
  String get alreadyLatest => lang == 'zh' ? '已是最新版本' : 'Already up to date';
  String get updateFailed => lang == 'zh' ? '检查更新失败' : 'Update check failed';
  String get goDownload => lang == 'zh' ? '前往下载' : 'Go to Download';

  // ── 步骤编辑器 ──
  String get stepStart => lang == 'zh' ? '开始' : 'Start';
  String get stepAvProcess => lang == 'zh' ? '音视频处理' : 'AV Process';
  String get keepIntermediate => lang == 'zh' ? '保留中间文件' : 'Keep intermediate files';
  String get intermediateDir => lang == 'zh' ? '中间文件目录' : 'Intermediate Dir';
  String get intermediateHint => lang == 'zh' ? '为空则使用系统临时目录' : 'Empty = system temp';

  // ── 流程图编辑器 ──
  String get pipelineAddChain => lang == 'zh' ? '添加链' : 'Add Chain';
  String get pipelineParallel => lang == 'zh' ? '并行' : 'Parallel';
  String get pipelineAddStage => lang == 'zh' ? '添加阶段' : 'Add Stage';
  String get pipelineAddParallel => lang == 'zh' ? '添加并行步骤' : 'Add Parallel';

  // ── 容器 ──
  String get container => lang == 'zh' ? '容器' : 'Container';
  String get containerNew => lang == 'zh' ? '新建容器' : 'New Container';
  String get containerFromFolder => lang == 'zh' ? '从文件夹创建' : 'From Folder';
  String get containerFromFiles => lang == 'zh' ? '选择文件创建' : 'From Files';
  String get containerEnter => lang == 'zh' ? '进入' : 'Enter';
  String get containerFiles => lang == 'zh' ? '个文件' : ' files';
  String get containerSortName => lang == 'zh' ? '按名称' : 'By Name';
  String get containerSortSize => lang == 'zh' ? '按大小' : 'By Size';
  String get containerSortDuration => lang == 'zh' ? '按时长' : 'By Duration';
  String get containerReindex => lang == 'zh' ? '重新编号' : 'Reindex';
  String get containerAddFiles => lang == 'zh' ? '添加文件' : 'Add Files';
  String get containerTargetIndex => lang == 'zh' ? '处理编号' : 'Target Index';
  String get containerAll => lang == 'zh' ? '全部' : 'All';
  String get containerQueueAll => lang == 'zh' ? '全部加入队列' : 'Queue All';
}
