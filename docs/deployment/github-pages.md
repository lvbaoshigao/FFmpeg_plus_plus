# 6.6 部署到 GitHub Pages

本地构建通过后，就可以把站点交给 GitHub Pages。下面的模板只在你手动运行时部署，方便先检查文档，再决定何时上线。

## 先弄清 base

仓库型 Pages 地址一般带仓库名路径。本项目默认前缀为 `/FFmpeg_plus_plus/`；它会影响图片、脚本和站内链接。

| 部署位置 | VITEPRESS_BASE / base |
| --- | --- |
| 当前仓库的项目 Pages | `/FFmpeg_plus_plus/` |
| fork 后改名的项目仓库 | `/你的仓库名/` |
| 用户/组织根站点或自定义域名根路径 | `/` |

配置文件允许通过 `VITEPRESS_BASE` 覆盖默认值。模板按仓库名自动传入子路径；使用根站点时，把模板对应值改成 `/`。自定义域名还需要你另行配置 DNS 与 Pages 的域名选项，本项目没有替你填写域名。

## 第一步：在本地做生产检查

从仓库根目录运行：

```sh
npm --prefix docs ci
npm --prefix docs run docs:check-examples
npm --prefix docs run docs:build
npm --prefix docs run docs:preview
```

确认首页、深层章节、图片和示例下载都可用，再提交源文件。部署流程会自己重新生成 dist，不需要把本地 node_modules 或 dist 提交进仓库。

## 第二步：启用 Pages 的 Actions 来源

在仓库的 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**。你需要有相应仓库设置权限。

接着把下面模板保存为仓库的 `.github/workflows/docs-pages.yml`。文档里提供了[可直接保存的模板文件](/examples/deploy-pages.yml)，此刻它只是公开下载资源，不会自动执行。

```yaml
name: Deploy FFmpeg++ documentation

# 仅手动触发；启用自动部署时再按维护说明增加 push。
on:
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: docs-pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: docs
    steps:
      - name: Checkout
        uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - name: Setup Node
        uses: actions/setup-node@v6
        with:
          node-version: '22'
          cache: npm
          cache-dependency-path: docs/package-lock.json
      - name: Setup Pages
        uses: actions/configure-pages@v5
      - name: Install dependencies
        run: npm ci --no-fund --no-audit
      - name: Check tutorial examples
        run: npm run docs:check-examples
      - name: Build documentation
        run: npm run docs:build
        env:
          VITEPRESS_BASE: /${{ github.event.repository.name }}/
      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: docs/.vitepress/dist

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

几个地方别改错：

- run 步骤在 docs 中执行，所以是 `npm ci`，不是再套一层 `--prefix docs`。
- 缓存锁文件仍从仓库根定位为 `docs/package-lock.json`。
- 上传目录为 `docs/.vitepress/dist`。
- Pages 部署需要模板中声明的权限；启用环境保护时，按仓库设置完成所需审批。

## 第三步：手动运行

1. 提交并推送文档与工作流。手动触发入口需要工作流已存在于默认分支。
2. 到 **Actions → Deploy FFmpeg++ documentation**。
3. 点击 **Run workflow**，选择要部署的分支后运行。
4. 等待 build 和 deploy 完成，打开部署结果中的站点地址。
5. 直接访问某个深层页面并刷新，再试搜索和示例下载。

如果你之后想自动部署，可以在模板的 on 下增加 main 分支 push 触发，并用 paths 限定 docs 和该工作流。这一步按你的发布习惯决定，手动部署本身已经能完成上线。

## 常见问题

| 表现 | 检查方向 |
| --- | --- |
| 首页出现，样式或图片 404 | base 是否和实际仓库路径一致？大小写是否一致？ |
| 点击内部链接正常，复制地址刷新 404 | 是否上传了完整 dist？是否擅自开启了 cleanUrls 或用了单页应用式 fallback？ |
| Actions 找不到 npm 锁文件 | 文档清单和锁文件是否都已提交？cache-dependency-path 是否正确？ |
| 构建因死链失败 | 修正链接或补齐目标页面，不要直接关闭死链检查 |
| 看不到 Run workflow | 是否包含 workflow_dispatch，且工作流已在默认分支？ |
| 部署权限被拒绝 | Pages 来源、GITHUB_TOKEN 权限、环境规则与仓库权限 |
| fork 后资源仍指向原路径 | 按 fork 仓库名设置 VITEPRESS_BASE，重新构建部署 |

这里生成的是静态文档站，不能通过部署它来运行 Flutter 应用或 C++ 后端。软件安装包仍从项目的 Releases 获取。

参考：[VitePress 官方部署指南](https://vitepress.dev/zh/guide/deploy)、[GitHub 自定义 Pages 工作流说明](https://docs.github.com/zh/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。
