# 4.2 在 Windows 上构建

Windows 构建需要准备 Flutter Release 目录，并将 `ffmpegpp.dll` 放入该目录。

## 1. 准备环境

安装 Flutter，并根据 `flutter doctor -v` 补齐 Windows 桌面工具链。Visual Studio 需包含 C++ 桌面开发组件和 Windows SDK；仅安装 VS Code 不会提供这些编译器。

仓库提供的后端脚本会定位并初始化 MSVC，同时检查缓存是否对应当前工具链。以下命令使用 PowerShell；通过 `pwsh` 启动时，需先安装 PowerShell 7。

## 2. 编译后端

从仓库根目录运行：

```powershell
pwsh -NoProfile -File ./build/windows/build_backend.ps1
```

默认后端产物为：

```text
server_cpp/build_win/ffmpegpp.dll
```

脚本内部调用 `setup_msvc.ps1`，默认使用 NMake Makefiles 和 Release 配置。若配置失败，应先修复错误，不应继续打包缓存中的旧 DLL。

## 3. 编译 Flutter 界面

```powershell
Push-Location ffmpegpp_gui
flutter pub get
flutter build windows --release
Pop-Location
```

若 Flutter 命令失败，应先排除故障并确认构建成功，再复制后端。

```powershell
Copy-Item ./server_cpp/build_win/ffmpegpp.dll ./ffmpegpp_gui/build/windows/x64/runner/Release/ffmpegpp.dll
Test-Path ./ffmpegpp_gui/build/windows/x64/runner/Release/ffmpegpp.dll
```

最后一条命令应返回 `True`。同时应检查 DLL 的修改时间，以确认使用的是当前构建产物。

## 4. 保留完整运行目录

最终应用位于：

```text
ffmpegpp_gui/build/windows/x64/runner/Release/
```

应保留目录中的全部依赖和 data。单独复制 exe 可能导致插件、资源或后端加载失败。

桌面运行仍需可用的 ffmpeg / ffprobe。可通过应用安装助手准备这些工具；它们与 C++ 共享库不同。

## 生成安装器

仓库发布流程使用 Inno Setup 和 `make/setup.iss`，并在打包前准备脚本所需的暂存目录。首次构建时，建议先验证 Release 目录可以正常运行，再参照工作流的 Windows 打包阶段制作安装包。生成 exe 不等同于完成安装器打包。

依据：[Windows 后端脚本](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/windows/build_backend.ps1)、[现有发布流程](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/.github/workflows/build-release.yml)。
