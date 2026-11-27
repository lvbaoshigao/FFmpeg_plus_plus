# 4.6 构建产物与常见错误

构建失败时，应优先在日志中定位**首个实际错误**。末尾的“build failed”通常只表示失败结果，不能说明根因。

## 构建产物与后端位置

| 平台 | 应用产物 | 后端位置 |
| --- | --- | --- |
| Windows x64 | `ffmpegpp_gui/build/windows/x64/runner/Release/` | 同目录 `ffmpegpp.dll` |
| Linux | `ffmpegpp_gui/build/linux/<架构>/release/bundle/` | bundle/lib/libffmpegpp.so |
| macOS | `ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app` | Contents/MacOS/libffmpegpp.dylib |
| Android | `ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk` | APK 的 arm64 原生库区域 |

桌面目录必须完整保留。exe、主程序或 .app 中的一个文件，不能替代整套 bundle。

## 按症状排查

| 症状 | 优先检查 |
| --- | --- |
| Dart SDK 版本不满足 | 检查 Flutter 实际版本、pubspec 约束，以及 PATH 是否指向预期 SDK |
| 找不到本地 path 包 | 检查 third_party 是否完整，以及是否仅复制了部分 GUI 目录 |
| Linux 找不到 GTK / libsecret / GStreamer | 检查系统开发包和 pkg-config，并参照 Linux 构建页安装 |
| Windows 缺少 NMake / cl.exe | 检查 Visual Studio C++ 组件和 SDK，并使用仓库的 MSVC 初始化脚本 |
| 更换工具链后 CMake 缓存冲突 | 使用后端脚本的缓存识别逻辑；修复冲突后再打包，勿沿用旧库 |
| macOS nproc 不存在 | 使用 macOS 构建页提供的 sysctl 并行构建命令 |
| Android local.properties / SDK 路径错误 | 检查 ANDROID_HOME、FLUTTER_BIN 和脚本的实际路径解析结果 |
| Android 缺原生 .so | 先构建 FFmpeg 和后端，再构建 APK |
| Android 缺少 h264_mediacodec | 重新构建原生 FFmpeg，不应跳过检查继续打包 |
| Gradle 网络、429、daemon 或内存故障 | 检查缓存盘和网络；脚本仅对识别出的暂时性故障进行有限重试 |
| 界面打开但后端未连接 | 检查后端库路径、架构、运行时依赖和构建时间 |
| 后端连接却无法探测媒体 | 运行时 ffprobe、文件权限和访问路径 |

确定性的编译或配置错误不会因重复重试而消失。应先修复配置，再重新执行失败步骤。

## 轻量检查命令

仓库提供构建辅助脚本测试，可在不编译整个应用的情况下运行：

```sh
python3 build/android/test_build_helpers.py BuildHelpers
```

```powershell
pwsh -NoProfile -File ./build/windows/test_build_backend.ps1
```

原生 FPPX 编解码测试为可选目标，可在单独的 CMake 构建目录开启：

```sh
cmake -S server_cpp -B server_cpp/build_tests -DFFMPEGPP_BUILD_TESTS=ON
cmake --build server_cpp/build_tests
ctest --test-dir server_cpp/build_tests --output-on-failure
```

这些测试仅覆盖各自范围，不能替代 GUI、真实媒体和目标设备验证。正式发布前还应确认架构、签名、安装包内容、FFmpeg 能力和实际安装结果。

## 提交问题时应提供的信息

请一并提供操作系统与架构、Flutter / Dart / CMake 版本、完整构建命令，以及首个错误及其前后日志。涉及私有路径或密钥时应先脱敏，尤其不要提供签名文件或 AI Key。
