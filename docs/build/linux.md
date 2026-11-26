# 4.3 在 Linux 上构建

Linux 这条路线相对直接：Flutter 的 Linux 工程已经接入 C++ 后端，不需要先手动编译一份再猜放哪里。

## 1. 安装系统依赖

下面以当前发布流程使用的 Ubuntu / Debian 系包名为例。其他发行版请换成相应软件包。

```sh
sudo apt update
sudo apt install cmake g++ clang libgtk-3-dev pkg-config ninja-build \
  libsecret-1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good
```

准备 Git、curl、unzip、xz 等 Flutter 安装所需工具，确认 `flutter doctor -v` 的 Linux 桌面项目正常。libsecret 也涉及应用的密钥存储，不能只因为“没用 AI”就假定它无关。

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

这两种方式选一种即可，不必为了“更完整”连续构建两遍。

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

## ARM64 不是给命令换个名字

当前发布流程在 ARM64 runner 上原生构建 ARM64。不要在 x64 主机上把产物目录改成 arm64，就以为得到了跨架构应用。Flutter SDK、插件与原生库都需要对应的目标支持。

## 运行环境还要注意什么？

- 桌面文件选择器、D-Bus、密钥存储服务等属于实际桌面环境的一部分；裸容器或最小化远程环境可能缺失。
- GPU / 渲染问题先看日志和驱动，不要直接把高内存或软件渲染当作转码故障。
- ffmpeg / ffprobe 仍需安装或由应用安装助手准备。

制作 deb 的目录布局、依赖和架构字段可以参照发布工作流的 Linux 打包阶段。先验证 bundle，再做系统安装包。

依据：[Linux CMake 集成](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/linux/CMakeLists.txt)、[桌面构建脚本](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/build_desktop.sh)。
