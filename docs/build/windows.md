# 4.2 在 Windows 上构建

Windows 端要准备两部分：Flutter 的 Release 目录，以及放到同目录的 `ffmpegpp.dll`。

## 1. 准备环境

安装 Flutter，并按 `flutter doctor -v` 补齐 Windows 桌面工具链。Visual Studio 需要 C++ 桌面开发组件和 Windows SDK；仅安装 VS Code 不包含这些编译器。

仓库提供的后端脚本会定位和初始化 MSVC，并检查缓存是否属于当前工具链。以下使用 PowerShell；若通过 `pwsh` 启动，需要先安装 PowerShell 7。

## 2. 编译后端

从仓库根目录运行：

```powershell
pwsh -NoProfile -File ./build/windows/build_backend.ps1
```

默认后端产物为：

```text
server_cpp/build_win/ffmpegpp.dll
```

脚本内部复用 `setup_msvc.ps1`，默认使用 NMake Makefiles 和 Release 配置。配置失败时先修复错误，不要拿缓存里的旧 DLL 继续打包。

## 3. 编译 Flutter 界面

```powershell
Push-Location ffmpegpp_gui
flutter pub get
flutter build windows --release
Pop-Location
```

若 Flutter 命令失败，先停在这里排错，确认成功后再复制后端。

```powershell
Copy-Item ./server_cpp/build_win/ffmpegpp.dll ./ffmpegpp_gui/build/windows/x64/runner/Release/ffmpegpp.dll
Test-Path ./ffmpegpp_gui/build/windows/x64/runner/Release/ffmpegpp.dll
```

最后一条应返回 `True`。同时检查 DLL 的修改时间，避免误用旧产物。

## 4. 运行时别只复制一个 exe

最终应用位于：

```text
ffmpegpp_gui/build/windows/x64/runner/Release/
```

应保留整个目录中的依赖和 data。只把 exe 拿出去，常见结果就是插件、资源或后端加载失败。

桌面运行仍需可用的 ffmpeg / ffprobe。可以使用应用安装助手准备它们；这和 C++ 共享库不是一回事。

## 想生成安装器？

仓库发布流程使用 Inno Setup 和 `make/setup.iss`，会先准备脚本预期的暂存目录再打包。第一次构建建议先验证 Release 目录可以运行，再参照工作流的 Windows 打包阶段制作安装包，别把“成功生成 exe”与“安装器完整”混为一步。

依据：[Windows 后端脚本](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/windows/build_backend.ps1)、[现有发布流程](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/.github/workflows/build-release.yml)。
