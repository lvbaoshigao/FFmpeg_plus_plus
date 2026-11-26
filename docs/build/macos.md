# 4.4 在 macOS 上构建

macOS 同样需要 Flutter 应用和 C++ 后端。这里按现有 CI 的路线给出手动步骤，便于看清每一步产物。

## 1. 准备工具

在 macOS 上安装 Flutter、Xcode、Xcode 命令行工具以及 CMake，按 `flutter doctor -v` 补齐当前插件要求的构建环境。编译 macOS 应用需要 macOS 工具链，不是在 Linux 上把目标名称改成 macos。

## 2. 编译后端

从仓库根目录执行：

```sh
cmake -S server_cpp -B server_cpp/build_macos \
  -DCMAKE_BUILD_TYPE=Release \
  '-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64'
cmake --build server_cpp/build_macos --parallel "$(sysctl -n hw.ncpu)"
```

上面的架构参数沿用发布流程的 Universal 设置。如果只做本机开发构建，可以按自己的工具链调整目标架构，但后端和 Flutter 应用必须匹配。

## 3. 编译应用并放入后端

```sh
cd ffmpegpp_gui
flutter pub get
flutter build macos --release
cd ..
cp server_cpp/build_macos/libffmpegpp.dylib \
  ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app/Contents/MacOS/libffmpegpp.dylib
```

关键位置是 **Contents/MacOS**。当前启动代码在可执行文件附近寻找后端，不要凭其他项目经验改放到 Frameworks。

确认库存在：

```sh
test -f ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app/Contents/MacOS/libffmpegpp.dylib
open ffmpegpp_gui/build/macos/Build/Products/Release/ffmpegpp_gui.app
```

## 4. 发布前还差哪些事？

本地能打开 .app，不代表已经完成签名、公证或 DMG 发布。仓库工作流还包含剥离调试符号和 DMG 打包步骤；有分发需求时应结合自己的签名流程处理。

显式使用 `--release`，并核对最终使用的 .app 位于 Release 目录。不要把 `flutter run` 生成的开发产物当作最终安装包。

::: tip 关于现有一键脚本
`build/build_desktop.sh macos` 也有对应分支，但其中后端并行构建使用 `nproc`，标准 macOS 环境未必提供这个命令。本页改用 CI 同样使用的 `sysctl -n hw.ncpu`，无需为此修改项目脚本。
:::

ffmpeg / ffprobe 的运行依赖仍需另外准备。依据：[macOS 发布阶段](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/.github/workflows/build-release.yml#L253)。
