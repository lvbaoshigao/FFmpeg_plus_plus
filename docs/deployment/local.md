# 6.5 维护文档与本地预览

帮助站是仓库中的独立文档子项目，其依赖位于 `docs/`。编写文档无需编译 Flutter 或 C++。

## 初次运行

准备 Node.js 22 或更高版本和 npm，从仓库根目录执行：

```sh
npm --prefix docs ci
npm --prefix docs run docs:dev
```

终端会输出访问地址。默认站点带有 `/FFmpeg_plus_plus/` 前缀，访问时应保留该路径。停止预览时，在终端按 Ctrl+C。

| 操作 | 仓库根目录下的命令 |
| --- | --- |
| 开发预览，保存后自动更新 | `npm --prefix docs run docs:dev` |
| 生成静态站点 | `npm --prefix docs run docs:build` |
| 查看生产构建效果 | `npm --prefix docs run docs:preview` |
| 检查节点图示例 | `npm --prefix docs run docs:check-examples` |

节点示例检查另外需要 Python 3.9+；Windows 可以直接用 `py -3 docs/public/examples/fppx_tool.py check docs/public/examples`。

## 生产构建产物

```sh
npm --prefix docs run docs:build
npm --prefix docs run docs:preview
```

静态文件输出到 `docs/.vitepress/dist/`。这才是部署目录，既不是 Markdown 源目录，也不是整个仓库。

开发服务器能够启动，不代表生产构建一定通过。提交前至少应运行一次 build，并检查修改过的页面。

## 新增一页的顺序

1. 在相应章节目录创建 Markdown，写一个清楚的一级标题。
2. 按“场景 → 操作 → 检查结果 → 限制”组织需要动手的内容。
3. 在 `.vitepress/config.mts` 的侧边栏中加入页面。
4. 用相对 `.md` 链接连接相关页面，检查目标文件存在。
5. 执行构建，再预览长表格、代码块和手机宽度。

代码示例中的字段应与实际模型一致，UI 名称应根据当前中文界面核对。源码依据应链接到仓库页面；不要使用跳出 docs 的相对路径，否则文档站无法定位源码。

## 图片与可下载示例的存放位置

- 图片放在 `docs/public/images/`，Markdown 中用 `/images/文件名` 引用。
- 可下载脚本、JSON 和 .fppx 放在 `docs/public/examples/`。
- 使用普通 Markdown 链接引用 `/examples/文件名`，让 VitePress 处理部署前缀。
- 修改 JSON 后同步重新封装 .fppx，并检查往返；不要仅更新 Markdown 示例片段。

构建会原样复制 public 目录中的文件，因此该目录仅应包含明确需要公开的资源。日志、用户配置、密钥、实验采样和临时输出均不应放入该目录。

## 修改版本与依赖

本项目默认锁定 VitePress 1.6.4，并使用默认主题。`package-lock.json` 用于复现依赖安装；计划升级依赖时，应同时检查构建、搜索和实际页面，并提交清单文件与锁文件。

VitePress 官网当前主线教程可能使用预发布版本。本帮助站采用稳定版的相同入门结构，并以实际构建通过的配置为准；编写 Markdown 时无需自动采用预发布依赖。

`.vitepress/cache/`、`.vitepress/dist/` 和 node_modules 已列入文档子项目的忽略规则，提交源码时不应包含这些目录。

参考：[VitePress 快速开始](https://vitepress.dev/zh/guide/getting-started)、[稳定版入门](https://vuejs.github.io/vitepress/v1/zh/guide/getting-started)。
