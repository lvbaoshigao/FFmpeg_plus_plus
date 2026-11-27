# FFmpeg++ 统一构建脚本

本目录集中管理 **Windows 桌面端 / Linux 桌面端 / Android 移动端** 的构建脚本。
默认开发环境将代码放在工作区，将缓存与工具链放在 sdb2；相关路径可通过环境变量配置。

## 目录结构

```
build/
├── build_all.sh            # 一键三端入口（all | desktop | android）
├── build_desktop.sh        # 桌面端一键构建（server_cpp + flutter build）
├── android/                # Android 端
│   ├── env.sh              # 公共环境：自动定位仓库根/缓存根 + 工具链
│   ├── build_ffmpeg.sh     # 交叉编译内置 ffmpeg/ffprobe + libffmpegpp.so（arm64）
│   ├── build_apk.sh        # SDK 路径、依赖与 APK；网络/资源失败才重试
│   ├── gradle_retry.sh     # 保留实际退出码，有界指数退避
│   ├── gradle-repositories.init.gradle # 主构建与 included build 的仓库策略
│   └── patch_pubcache.sh   # 按实际 package_config 幂等修补旧插件
└── windows/                # GitHub Actions 与本地 PowerShell 构建入口
    ├── setup_msvc.ps1     # 当前 MSVC/SDK 环境与缓存指纹
    ├── build_backend.ps1  # 验证工具链缓存；配置失败立即停止
    └── test_build_backend.ps1 # 无编译器依赖的构建脚本契约测试
```

## 快速开始

```bash
# 一键构建全部（桌面端 + Android APK）
build/build_all.sh all

# 只构建 Android APK
build/build_all.sh android

# 只构建桌面端（自动探测 Linux/Windows）
build/build_all.sh desktop

# Android 分步：先交叉编译 ffmpeg/后端（只需一次，产物在缓存根/dist/）
build/android/build_ffmpeg.sh
# 再构建 APK（自动补齐 jniLibs、自动打 file_picker 补丁、OOM 自动重试）
build/android/build_apk.sh
```

## 目录与路径配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FFMPEGPP_ROOT` | 仓库根（脚本自动推导） | 代码所在位置 |
| `FFMPEGPP_CACHE` | 与仓库同级的 `android-build/` | 构建缓存根（sdb2） |
| `JAVA_HOME` | sdb2 `apk_analysis/tools/jdk-21.0.2+13` | JDK |
| `ANDROID_HOME` | sdb2 `android-sdk` | Android SDK |
| `GRADLE_USER_HOME` | sdb2 `gradle-home` | Gradle 缓存（转 SSD 时用符号链接保持路径） |
| `PUB_CACHE` | 保留现有环境值，否则 sdb2 `dart-pub-cache` | pub 依赖缓存；`FFMPEGPP_PUB_CACHE` 可显式覆盖 |
| `FFMPEGPP_MAVEN_CENTRAL_MIRROR` | Google 托管的 Maven Central 镜像 | 可配置为可信的 HTTPS 镜像，同时保留官方仓库 |
| `FFMPEGPP_RETRY_MAX_ATTEMPTS` | `5` | Gradle 暂时性失败的总尝试次数，上限 10 |
| `FFMPEGPP_RETRY_BASE_DELAY` | `20` | 指数退避初值（秒），最多等待 180 秒 |
| `NDK_HOME` | sdb2 `reversing/tools/ndk/android-ndk-r26d` | NDK（r26d） |

> 开发环境的 sdb2 容量为 20G。该环境中，Gradle 的
> `caches/9.1.0/{transforms,generated-gradle-jars}` 已迁移至
> `/media/lvbaoshigao/SSD/ffmpegpp-build-cache/`，并在
> `GRADLE_USER_HOME/caches/9.1.0/` 的原路径建立符号链接。此配置无需修改脚本，其他环境应按实际存储布局设置。

## 构建产物

| 平台 | 产物路径 |
|------|----------|
| Android APK | `ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk`（arm64-v8a，内置 ffmpeg/ffprobe/后端） |
| Linux 桌面 | `ffmpegpp_gui/build/linux/x64/release/bundle/` |
| Windows 桌面 | `ffmpegpp_gui/build/windows/x64/runner/Release/` |

## 构建脚本验证（不编译应用）

```sh
python3 build/android/test_build_helpers.py BuildHelpers
```

```powershell
pwsh -NoProfile -File ./build/windows/test_build_backend.ps1
```

可选的 Gradle 复合构建验证仅运行临时工程的仓库检查任务。设置 `JAVA_HOME` 和
`FFMPEGPP_TEST_GRADLE` 后运行 `python3 build/android/test_build_helpers.py GradleRepositories`，
可检查主构建和 included build 在不同仓库模式下均优先使用镜像并保留插件门户。

## 注意事项

- Android 的 HTTP 429、暂时性网络故障、daemon 消失或资源不足按指数退避重试；
  编译/配置错误立即返回真实失败码，最后一次失败后不会再等待。
- Windows 后端缓存同时绑定编译器路径/版本、SDK、生成器与源码路径。runner
  更新 MSVC 后不会恢复另一工具链的对象；脚本还会检查旧 CMakeCache 并仅清理已识别的构建目录。
- 应保持 `org.gradle.configuration-cache` 相关属性不变，以避免构建失败。
- 桌面端更新机制与安装器不适用于移动端。Android 提供 H.264 / HEVC MediaCodec 编码选项，
  实际可用性取决于设备、FFmpeg 构建与参数。
