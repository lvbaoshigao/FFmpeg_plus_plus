# 4.3 在 Linux 上构建

Flutter 的 Linux 工程已集成 C++ 后端，因此通常无需先单独编译后端再手动确定其放置位置。

## 1. 安装系统依赖

下面以当前发布流程使用的 Ubuntu / Debian 系包名为例。其他发行版请换成相应软件包。

```sh
sudo apt update
sudo apt install cmake g++ clang libgtk-3-dev pkg-config ninja-build \
  libsecret-1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good
```

请准备 Git、curl、unzip、xz 等 Flutter 安装所需工具，并通过 `flutter doctor -v` 确认 Linux 桌面工具链正常。libsecret 也用于应用的密钥存储，因此即使未使用 AI 功能，也不能据此排除该依赖。

## 2. 构建

从仓库根目录执行：

```sh
bash build/build_desktop.sh linux
```

脚本会执行依赖解析与 `flutter build linux --release`，并检查 bundle 里的后端库。

也可以按发布流程直接运行：

```sh
cd ffmpegpp_gui
flutter pub get
flutter build linux --release
```

以上两种方式任选其一即可，无需重复构建。

## 3. 检查产物

| 宿主架构 | Bundle 目录 |
| --- | --- |
| x86_64 | `ffmpegpp_gui/build/linux/x64/release/bundle/` |
| aarch64 / arm64 | `ffmpegpp_gui/build/linux/arm64/release/bundle/` |

以 x64 为例，回到仓库根目录检查：

```sh
test -f ffmpegpp_gui/build/linux/x64/release/bundle/lib/libffmpegpp.so
./ffmpegpp_gui/build/linux/x64/release/bundle/ffmpegpp_gui
```

第一条成功时通常没有输出，退出码为 0。共享库应该在 bundle 的 lib 下；运行目录也要保留 data 和其他依赖。

## ARM64 构建要求

当前发布流程在 ARM64 runner 上原生构建 ARM64。仅在 x64 主机上将产物目录改名为 arm64，不会生成跨架构应用。Flutter SDK、插件和原生库均须支持相应目标架构。

## 运行环境注意事项

- 桌面文件选择器、D-Bus、密钥存储服务等属于桌面运行环境的一部分；精简容器或最小化远程环境可能未提供这些组件。
- 遇到 GPU 或渲染问题时，应先检查日志和驱动；高内存占用或软件渲染本身不能直接证明存在转码故障。
- ffmpeg / ffprobe 仍需安装或由应用安装助手准备。

制作 deb 时，可参照发布工作流 Linux 打包阶段的目录布局、依赖和架构字段。请先验证 bundle，再制作系统安装包。

依据：[Linux CMake 集成](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/linux/CMakeLists.txt)、[桌面构建脚本](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/build_desktop.sh)。
