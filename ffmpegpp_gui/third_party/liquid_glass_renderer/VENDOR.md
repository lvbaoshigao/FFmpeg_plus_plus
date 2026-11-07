# 本地 vendor：liquid_glass_renderer

本目录是 [liquid_glass_renderer](https://pub.dev/packages/liquid_glass_renderer)
**0.2.0-dev.4** 的副本（MIT，见 `LICENSE`），仅做了下述着色器兼容性修补。
它不是上游代码的改写版，除着色器外与上游逐字节一致。

## 为什么必须 vendor

上游 4 个 fragment shader 里有大量 **SkSL 不支持**的写法。Flutter 构建时会把
依赖图里所有包声明的 shader 对**所有目标平台**编译一遍，Windows / Linux 走
Skia 后端必须产出合法 SkSL，于是 `flutter build windows` 在
`flutter_assemble.vcxproj` 阶段直接失败：

```
CUSTOMBUILD : error : 111: initializers are not permitted on arrays
CUSTOMBUILD : error : 112: unknown identifier 'param_2'
CUSTOMBUILD : error : 58: loop index initializer must be a constant expression
error MSB8066: Custom build for '...\flutter_assemble.vcxproj' exited with code -1.
```

对应上游 issue：<https://github.com/flutter/flutter/issues/182400>。
Flutter 的修复 PR [flutter/flutter#183146](https://github.com/flutter/flutter/pull/183146)
只把 SkSL 失败在**不需要 SkSL 的平台**（iOS/macOS 的 Metal）降级为 warning；
Windows/Linux 需要 SkSL，因此仍然是致命错误。

**换版本救不了**：`liquid_glass_renderer` 最新是 `1.0.0-dev.2`，是 Flutter GPU
重写版、API 全换且不留兼容；而 `liquid_glass_tab_bar`（仍为 0.1.0-dev.10）
只兼容 0.2.x。

本包是 `liquid_glass_tab_bar` 的传递依赖，项目代码没有直接 import 它。

## 修补清单（共 4 个文件）

| 文件 | 上游写法 | 问题 | 改法 |
| --- | --- | --- | --- |
| `lib/assets/shaders/sdf.glsl` | `getShapeSDFFromArray(int index, vec2 p, float shapeData[MAX_SHAPES*6])`，`sceneSDF(..., float shapeData[], ...)` | 数组按值传参被翻译成 `float param_2[96] = shapeData;`（SkSL error 111/112）；uniform 数组的运行期下标被拒（error 81） | 删掉数组形参，改为宏 `SHAPE_SDF_AT(I, p)` 直接读全局 uniform `uShapeData`，下标全为字面量；`sceneSDF` 把 16 个形状全部按常量展开 |
| `lib/assets/shaders/sdf.glsl` | `for (int i = 1; i < min(numShapes, MAX_SHAPES); i++)` | SkSL 没有 `min(int,int)` 重载（error 147），且循环上界必须是编译期常量 | 常量上界 + `if (i >= numShapes) break;` |
| `lib/assets/shaders/sdf.glsl` | `dFdx(sd)` / `dFdy(sd)` | SkSL 无 `dFdx`/`dFdy` 可用重载（error 195/196，内建名是小写 `dfdx`，GLSL 侧调不到） | 新增 `sdfGradient()`：前向差分（步长 1px，与硬件导数同量纲），`getNormal` 改为接收预先算好的梯度 |
| `lib/assets/shaders/shared.glsl` | `calculateRefraction(..., sampler2D backgroundTexture, ...)`，`renderLiquidGlass(..., sampler2D backgroundTexture, ...)` | SkSL 不允许 sampler 作为函数参数（error: parameters of type 'shader' not allowed） | 两个函数改为直接读全局 `uniform sampler2D uBackgroundTexture;`，该 uniform 在本文件顶部声明（因此它在 `#include` 处即可见） |
| `lib/assets/shaders/liquid_glass_filter.frag` | 自声明 `uniform sampler2D uBlurredTexture;` | 与上一条配套 | 采样器统一改名 `uBackgroundTexture`（仍只有 1 个采样器，索引 0 不变），删掉本地声明 |
| `lib/assets/shaders/liquid_glass_arbitrary.frag` | `int sampleRadius = 10; for (int y = -sampleRadius; ...)` | 循环下标初值必须是常量表达式（error 55/58） | `const int sampleRadius`，下标从 0 起、循环体内回补 `- sampleRadius` 偏移 |
| `lib/assets/shaders/liquid_glass_geometry_blended.frag` | `sceneSDF(p, n, uShapeData, blend)`；`dFdx(sd)` | 同上 | 改调用与梯度计算 |
| `pubspec.yaml` | `screenshots: doc/screenshot.png` | `doc/` 未随 vendor 收录 | 删掉该字段（仅 pub.dev 展示用） |

**渲染数学未改**：所有改动都是「换一种等价写法」，SDF 求值、折射、色散、
高光的公式与参数一字未动。唯一的近似是法线导数由硬件 `dFdx` 换成步长 1px 的
前向差分 —— 二者本就是同量纲的同一阶近似。

## 未收录的目录

`test/`（2.6MB）、`example/`、`doc/`、`coverage/`、`dart_test.yaml`、
`analysis_options.yaml` 均未收录，原因：

- `analysis_options.yaml` 是 `include: package:lintervention/...`，而
  `lintervention` 只是本包的 **dev_dependency**，作为 path 依赖时不会被解析，
  `flutter analyze` 会因 include 解析失败而报错；
- `test/` 会 import `mocktail` / `alchemist`，同样不在根包解析里，会被
  `flutter analyze` 判为 `uri_does_not_exist`（ERROR 级，CI 门禁会红）。

## 本地验证（不需要跑 CI）

Flutter SDK 自带的 `impellerc` 就是 CI 用的同一个编译器，可直接离线复验：

```powershell
$ie  = "C:\flutter\flutter\bin\cache\artifacts\engine\windows-x64\impellerc.exe"
$inc = "C:\flutter\flutter\bin\cache\artifacts\engine\windows-x64\shader_lib"
$sd  = "third_party\liquid_glass_renderer\lib\assets\shaders"
foreach ($f in @("liquid_glass_geometry_blended","liquid_glass_arbitrary",
                 "liquid_glass_filter","liquid_glass_final_render")) {
  & $ie --iplr --runtime-stage-gles --sksl --input-type=frag `
        --input="$sd\$f.frag" --include="$sd" --include="$inc" `
        "--sl=$env:TEMP\$f.sl" "--spirv=$env:TEMP\$f.spv"
  "$f EXIT=$LASTEXITCODE"
}
```

四个都 `EXIT=0` 即为通过。把 `--runtime-stage-gles` 换成
`--runtime-stage-vulkan --runtime-stage-gles3`（Android）或
`--runtime-stage-metal`（macOS）可验证其余平台。

## 升级上游时怎么处理

1. 取新版本源码，比对 `lib/assets/shaders/` 下的上述 4 个文件；
2. 若上游已自行修复 SkSL 兼容性，直接删掉本目录并移除 `pubspec.yaml` 里的
   `dependency_overrides` 条目；
3. 若未修复，按上表逐条重放补丁，并跑一遍上面的本地验证。
