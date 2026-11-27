# 4.4 在 macOS 上构建

macOS 构建需要 Flutter 应用和 C++ 后端。以下手动步骤参照现有 CI 流程，并分别检查各阶段的产物。

## 1. 准备工具

在 macOS 上安装 Flutter、Xcode、Xcode 命令行工具和 CMake，并根据 `flutter doctor -v` 的结果补齐当前插件所需的构建环境。编译 macOS 应用需要 macOS 工具链，不能仅在 Linux 上更改目标名称为 macos。

## 2. 编译后端

从仓库根目录执行：

```sh
cmake -S server_cpp -B server_cpp/build_macos \
  -DCMAKE_BUILD_TYPE=Release \
  '-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64'
cmake --build server_cpp/build_macos --parallel "$(sysctl -n hw.ncpu)"
```

上述架构参数沿用发布流程的 Universal 设置。仅进行本机开发构建时，可根据工具链调整目标架构，但后端与 Flutter 应用的目标架构必须匹配。

## 3. 编译应用并放入后端

```sh
cd ffmpegpp_gui
flutter pub get
flutter build macos --release
cd ..
cp server_cpp/build_macos/libffmpegpp.dylib \
  ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app/Contents/MacOS/libffmpegpp.dylib
```

后端库应放在 **Contents/MacOS**。当前启动代码会在可执行文件附近查找后端库，因此不应将其改放到 Frameworks。

确认库存在：

```sh
test -f ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app/Contents/MacOS/libffmpegpp.dylib
open ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app
```

## 4. 发布前检查事项

本地能够打开 .app 不代表签名、公证或 DMG 发布已完成。仓库工作流还包括剥离调试符号和 DMG 打包步骤；如需分发，应按相应签名流程完成处理。

请显式使用 `--release`，并确认最终使用的 .app 位于 Release 目录。`flutter run` 生成的是开发产物，不应作为最终安装包。

::: tip macOS 一键构建脚本说明
`build/build_desktop.sh macos` 也提供对应分支，但其中的后端并行构建使用 `nproc`，标准 macOS 环境可能未提供该命令。CI 同样使用 `sysctl -n hw.ncpu`，无需修改项目脚本。
:::

ffmpeg / ffprobe 的运行依赖仍需另外准备。依据：[macOS 发布阶段](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/.github/workflows/build-release.yml#L253)。
