# 4.6 构建产物与常见错误

构建失败时，先往日志前面找**第一处实际错误**。最后一行“build failed”只是结果，通常没说原因。

## 先确认你拿到了什么

| 平台 | 应用产物 | 后端位置 |
| --- | --- | --- |
| Windows x64 | `ffmpegpp_gui/build/windows/x64/runner/Release/` | 同目录 `ffmpegpp.dll` |
| Linux | `ffmpegpp_gui/build/linux/<架构>/release/bundle/` | bundle/lib/libffmpegpp.so |
| macOS | `ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app` | Contents/MacOS/libffmpegpp.dylib |
| Android | `ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk` | APK 的 arm64 原生库区域 |

桌面目录必须完整保留。exe、主程序或 .app 中的一个文件，不能替代整套 bundle。

## 对照症状排查

| 症状 | 优先检查 |
| --- | --- |
| Dart SDK 版本不满足 | Flutter 实际版本、pubspec 约束，是否用了另一套 PATH |
| 本地 path 包找不到 | third_party 是否完整，是否只复制了部分 GUI 目录 |
| Linux 找不到 GTK / libsecret / GStreamer | 系统开发包和 pkg-config，按 Linux 页安装 |
| Windows NMake / cl.exe 不存在 | Visual Studio C++ 组件和 SDK，使用仓库的 MSVC 初始化脚本 |
| 更换工具链后 CMake 缓存报冲突 | 使用后端脚本的缓存识别逻辑，不要继续打包旧库 |
| macOS nproc 不存在 | 使用本手册的 sysctl 并行构建命令 |
| Android local.properties / SDK 路径错误 | ANDROID_HOME、FLUTTER_BIN 与脚本实际解析结果 |
| Android 缺原生 .so | 先构建 FFmpeg 和后端，再构建 APK |
| Android 报缺 h264_mediacodec | 重新构建原生 FFmpeg；不要跳过检查强行打包 |
| Gradle 网络、429、daemon 或内存故障 | 确认缓存盘和网络，脚本只对识别的暂时性故障有限重试 |
| 界面打开但后端未连接 | 后端库路径、架构、运行时依赖与构建时间 |
| 后端连接却无法探测媒体 | 运行时 ffprobe、文件权限和访问路径 |

确定性的编译或配置错误不会因为反复重试自动变好。先修复配置，再重跑失败步骤。

## 可以先跑哪些轻量检查？

仓库已有构建辅助脚本测试，不需要编译整个应用：

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

这些测试覆盖各自的范围，不能替代 GUI、真实媒体和目标设备验证。准备正式发布时，还需要确认架构、签名、安装包内容、FFmpeg 能力和实际安装结果。

## 提问时带什么最有用？

把系统与架构、Flutter / Dart / CMake 版本、完整构建命令、第一处错误及其前后几行一起提供。涉及私有路径或密钥时先脱敏，尤其不要贴签名文件和 AI Key。
