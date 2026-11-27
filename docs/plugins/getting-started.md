# 编译并运行第一个插件

本例使用无 libc 的 C 代码构建 Audio Gain 节点，默认降低音量 6 dB。它通过宿主现有音频处理流程执行，不读取媒体文件、不直接启动 FFmpeg，也不申请网络权限。

## 1. 导出 SDK 并安装工具链

在插件页的新增入口选择导出 SDK，解压后保留目录结构。SDK 含头文件、JSON Schema、两个示例与 Python 构建脚本；**不捆绑编译器**。

先访问 [WebAssembly 官方开发者指南](https://webassembly.org/getting-started/developers-guide/)。WebAssembly 是编译目标与规范，官网不会提供一个统一的“WebAssembly 编译器安装包”。C/C++ 开发者可选择：

| 工具链 | 获取入口 | 本插件的使用方式 |
| --- | --- | --- |
| WASI SDK | [WebAssembly/wasi-sdk releases](https://github.com/WebAssembly/wasi-sdk/releases) | 设置 WASI_SDK_PATH，使用其 bin/clang 与 wasm-ld |
| Emscripten | [官方 emsdk 安装指南](https://emscripten.org/docs/getting_started/downloads.html) | 按官方步骤安装激活后，使用 upstream/bin/clang，而非生成 JS 胶水的 emcc 默认模式 |
| LLVM | [LLVM releases](https://releases.llvm.org/) | 安装支持 wasm32 的 clang 和 wasm-ld |

本例显式使用 --target=wasm32 -nostdlib，因此即使用 WASI SDK 的编译器，也不生成带 WASI 导入的程序。不要添加 _start、_initialize、线程、SIMD、浏览器 DOM 或 Emscripten JS 运行时依赖。构建需 Python 3.9+；可选自测还需 Node.js。

## 2. 实际编译和打包

在解压的 SDK 根目录执行：

~~~sh
python3 tools/build_plugin.py --self-test
~~~

Windows PowerShell 可执行：

~~~powershell
py -3 tools/build_plugin.py --clang "C:/tools/wasi-sdk/bin/clang.exe" --self-test
~~~

如果 clang 找不到 WASM 链接器，可补充 --wasm-ld 参数。脚本不调用 shell、不自动下载依赖，编译或自测失败会返回非零退出码。输出为 dist/audio-gain.fppplugin。

脚本从清单生成元数据头，避免 Basic_info 与 Node_info 在清单和代码中漂移。它使用 --no-entry 和有界线性内存；四个业务函数均为 void(void)，仅导入 request_read 与 response_write。自测真实实例化 WASM 并执行 16 组输入，覆盖元数据、宿主表单字段、合法增益、错误媒体/节点、越界参数和过长请求。

在仓库根目录复现已发布的示例及运行时 fixture：

~~~sh
python3 plugin_sdk/tools/build_plugin.py --output docs/public/examples/plugin-demo.fppplugin --emit-wasm docs/public/examples/plugin-demo.wasm --self-test --fixtures docs/public/examples/plugin-fixtures/selftest.json
~~~

可直接下载 [已编译插件包](/examples/plugin-demo.fppplugin)、[WASM 模块](/examples/plugin-demo.wasm) 和 [自测请求/响应](/examples/plugin-fixtures/selftest.json)。Node 自测验证 ABI 和示例逻辑；应用内采用原生 WASM 沙箱，还需要通过应用运行时测试。

## 3. 导入并启用

1. 打开设置中的插件实验开关，从桌面侧栏或移动底栏进入插件页。
2. 导入插件包，确认 ID、版本、描述和声明节点。安装本身不会运行节点或自动启用。
3. 点击启用并确认预览版稳定性提示。本例没有文件/网络权限，无需额外授予。
4. 若后端未编入 WASM 运行时、应用版本不符或声明与导出信息不符，启用会失败；保留错误信息检查构建与清单。

## 4. 在现有节点图中运行

导入一个测试音频，打开节点编辑器，在插件节点中添加 Audio Gain。按正常方式连接 **音频开始 → Audio Gain → 输出**，设置输出文件后运行。把 Gain (dB) 设为 -6 时，WASM 接收经宿主验证的参数并返回：

~~~json
{"operation":"audio.volume","decibels":-6}
~~~

宿主校验媒体类型和数值后构造现有 BackendCall，任务进入正常队列。可用逻辑门控制其使能端；IsLogic 仅表示接受已有控制机制，不把媒体节点变为布尔逻辑门。禁用/卸载插件后，该节点数据仍可保留，但不能继续执行。

需要可重复的源文件时，可在装有 FFmpeg 的开发机生成 1 秒正弦测试音频：

~~~sh
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a pcm_s16le input.wav
~~~

分别输出 0 dB 与 -6 dB，比较音量分析或波形，确认图中的参数影响了实际处理结果；避免用是否“出现节点”替代运行验证。

## 5. 修改并分发

先修改清单中的插件 ID 与版本，再修改 C 实现。不要改变已有节点 ID 或无迁移方案地重解释参数。重新编译、运行自测并在应用中导入测试后分发插件包。SDK、ABI 与清单详见 [API 参考](./api.md)，发布前检查 [安全与兼容性](./security.md)。
