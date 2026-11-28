# 插件 v1 实现合约

本文件记录实现分工共享的接口，后续由集成检查与开发文档补充。

## 文件格式

插件包扩展名 .fppplugin，ZIP 内根目录 manifest.json，可选 plugin.wasm；数据包允许无 module。manifest:

- format_version: 1; id: 反向域名字符串; api_version: 1; app_version: ">=6.0.0-beta2 <7.0.0"（比较器以空格连接）。
- Basic_info: {Name, Version（semver）, IsPreview（bool）, Summary} 必需。
- module: 可选相对路径。Node_info: 可选节点列表；未声明不注册。
- 节点 {id, name, fun, IsLogic, IO:{inputs:1,outputs:1}, input_types:[video|audio|image], output_type:video|audio|image, schema_version:1, fields:[...]}。v1 只支持一入一出，IsLogic 表示允许宿主使能/状态控制连接，不把节点当作逻辑门。
- fields 项 {key,label,type:number|integer|string|boolean|select,default,min?,max?,options?:[string]}；UI 由宿主构建。节点 values 和 fields 必须被宿主校验，不能信任图里的快照。
- permissions:{files:{read:false,write:false},network:["https://example.org"]}，默认均拒绝。文件能力仅限插件私有 data 子目录；网络仅限用户同意的精确 HTTPS origin。
- limits:{memory_mb:16,time_ms:1000,fuel:1000000}；宿主硬上限64MiB/5000ms/10000000指令，并限制模块/请求/响应/表大小。
- dependencies:[{id,version:版本比较器字符串}]；校验缺失/禁用/不兼容/循环依赖。
- themes:[主题配置对象]；ai_configs:[AI目录对象]。由独立白名单协议解析，不直接反序列化任意 AppConfig/AiProfile。

## WASM ABI

WASM32、无WASI、无guest线程、无start section、无自动初始化导出。仅允许两个函数import：模块名 ffmpegpp，request_read(i32 pointer,i32 capacity)->i32（复制请求UTF8 JSON到guest内存，返回字节数；不足返回负值），response_write(i32 pointer,i32 length)->i32（复制有界UTF8 JSON作为响应）。由SDK头文件声明。所有宿主调用的export均为 ()->()；允许 Basic_info、Node_info、Node_editor_add、Node_execute。Basic_info 必需且响应必须与清单一致。Node_info 有节点时必需且与清单节点声明一致。Node_editor_add 可选，响应 {fields:[...]}，请求带 node_id；无该export使用清单fields。Node_execute 请求 {api_version:1,plugin_id,node_id,params:{...},media_type:..., continuation?,host_response?}。

guest 在业务导出内通过 request_read() 读取本次请求；request_read(i32 dst,i32 capacity)->i32 返回请求字节数，不足或参数越界返回负错误码。guest 以 response_write(i32 src,i32 length)->i32 提交UTF-8 JSON，宿主即时复制并检查长度；一次export调用只允许一次有效响应写入。调用函数签名均为 ()->()。Basic_info直接返回 {Name,Version,IsPreview,Summary}；Node_info返回 {nodes:[与manifest.Node_info相同的节点描述]}；Node_editor_add返回 {fields:[宿主字段schema]}；Node_execute读取请求 {api_version:1,plugin_id,node_id,params,media_type,continuation?,host_response?}。Node_execute 完成响应保留既有 audio.volume、video.flip、video.scale 和 media.copy 操作，并增加 {operation:"ffmpeg.execute",arguments:[输出选项字符串]}。FFmpeg 方案由插件自己的 C/C++ 实现生成，SDK 只提供 JSON 与参数构造接口；宿主绑定唯一输入输出，后端按选项和滤镜白名单构造 argv，不调用 shell。ffmpeg.execute 支持节点声明的一入一出媒体转换，其余操作保持同媒体类型约束。Node_execute 请求保留 media_type，并增加 input_media_type、output_media_type 和 host:{api_version:1,operations:[实际支持的操作],ffmpeg?:后端能力对象}。缺少 ffmpeg 能力时不得广告或执行该操作。

需要宿主文件/网络调用时返回 {host_request:{id,method:"file.read"|"file.write"|"http.get",path?,content_base64?,url?},continuation:JSON}；宿主校验权限、范围、配额、超时后重新调用同export并附 host_response:{id,ok,result?,error?} 和 continuation。每次WASM实例独立，整轮最多16个host请求且受总时间预算约束。无权限不得I/O。

## Dart 接口边界

- lib/plugins/plugin_manifest.dart：PluginManifest、PluginBasicInfo、PluginNodeDefinition、PluginLimits、PluginPermissions、版本约束；纯模型校验。
- lib/plugins/plugin_node_catalog.dart：PluginNodeCatalog.instance，节点描述查找及可用性，供模型getter/编辑器使用。
- lib/plugins/plugin_runtime.dart：`abstract PluginRuntime { Future<Map<String,dynamic>> invoke(String modulePath,String entry,Map<String,dynamic> request,PluginLimits limits); }` CallbackPluginRuntime 将宿主注入回调包装为runtime。
- lib/plugins/plugin_manager.dart：PluginManager extends ChangeNotifier，构造(root:Directory,runtime:PluginRuntime,appVersion:String)，initialize() 只读清单，setFeatureEnabled(bool)，plugins 列表，inspectPackage(Uint8List)，installPackage(Uint8List)，`setEnabled(id,bool,{previewAcknowledged:false,grantedPermissions:const Set<String>{}})`，uninstall(id)，rollback(id)，invoke(pluginId,entry,request,{bool Function()? isCancelled})。异步安装保持disabled；enable检验Basic_info/Node_info。全部变更应重新发布catalog。
- Native backend action plugin_invoke，params:{module_path,entry,request,limits:{memory_mb,time_ms,fuel}}，success/data为标准BackendClient协议；data是WASM JSON响应。plugin_capabilities用于判断后端支持。callback通过现有NativeProcessManager.requestWithTimeout调用。WASM运行在后端辅助工作线程，不在Flutter UI线程。
- AppState 提供可空 PluginManager plugins，并与 updateConfig 的实验开关联动；插件根目录为现有应用数据目录下 plugins。plugin_execution.dart 校验执行响应、宿主媒体类型及参数预算。plugin_ffmpeg 与普通媒体任务共用 worker、任务 ID、进度、暂停和取消，不在 WASM 辅助线程里运行媒体进程。
- lib/plugins/plugin_sdk.dart：PluginSdk.createArchive() 为无参 `static Future<Uint8List>`，返回完整 SDK ZIP；PluginSdk.archiveFileName 为 ffmpegpp-plugin-sdk-v1.zip。assets/plugin_sdk/files.json 索引归档相对路径，Flutter资源以斜杠替换为双下划线扁平存储，pubspec 仅需 assets/plugin_sdk/。失败向调用方抛异常，不写入文件。

## 节点持久化

仅追加 PipelineStepType.plugin（不改变旧索引）；固定C++承载类型在现有未占用媒体ID后分配。身份与版本使用params：{_plugin:{id:pluginId,node:nodeId,version:pluginVersion,schema_version:1,snapshot:节点声明},values:{用户参数}}。snapshot仅用于缺失时显示与文件保留，执行前根据实际启用插件重新校验。BackendCall(action:"_plugin",params:{input,output,plugin:envelope,values,media_type,input_media_type,output_media_type})。每次执行从已启用的真实节点声明重新生成方案，不能持久化 plugin_ffmpeg 作为可直接恢复执行的任务 action。AppState 在调用前、应用方案前及 FFmpeg 完成后检查插件版本、generation 和节点启用状态。媒体类型改变时，图编译器为中间文件及 keep 输出选择 audio=wav、video=mkv、image=png；同类型保留既有后缀。

## 写入范围

lead: 本文件、providers/app_state.dart、services/backend_client.dart、其余集成修复/最终检查；涉及他人文件先协调。
node: models/models.dart（包括新增AppConfig.pluginsEnabled默认false及持久化）、services/graph_executor.dart、pages/pipeline_editor_page.dart、相关节点图标/编辑器/测试、C++ node_registry/fppx_validate（不改运行时文件）。
runtime: server_cpp/CMakeLists.txt、server_cpp/cmake或runtime子目录、src/plugin_runtime.*、src/dll_main.cpp及runtime测试；不改node_registry和fppx。
manifest: plugins/plugin_manifest.dart 与 plugin_node_catalog.dart 及对应测试。
manager: plugins/plugin_manager.dart、plugin_runtime.dart、plugin_storage.dart、plugin_permissions.dart及对应测试。
extension: plugins/plugin_contributions.dart及主题/AI校验测试。
shell: app.dart、widgets/sidebar.dart、mobile_bottom_nav.dart、liquid_glass_mobile_nav.dart、pages/settings_page.dart、theme/app_strings.dart与导航门控测试（不修改models/AppState）。
page: pages/plugins_page.dart、widgets/plugin_form.dart及页面测试。
sdk/docs: plugin_sdk/、assets/plugin_sdk/、plugins/plugin_sdk.dart、docs/plugins（除architecture.md）、docs/public/examples/plugin-*及docs导航；pubspec资产变更交lead。

所有成员使用现有组件和状态管理，总并发含lead不超过9人。不独立启动第10人。
