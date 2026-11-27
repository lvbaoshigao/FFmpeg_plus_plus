# 6.6 部署到 GitHub Pages

本地构建通过后，可将站点部署到 GitHub Pages。以下工作流模板仅在手动触发时部署，便于先检查文档，再安排发布。

## base 路径配置

仓库型 Pages 地址通常包含仓库名路径。本项目默认前缀为 `/FFmpeg_plus_plus/`，该前缀会影响图片、脚本和站内链接。

| 部署位置 | VITEPRESS_BASE / base |
| --- | --- |
| 当前仓库的项目 Pages | `/FFmpeg_plus_plus/` |
| fork 后改名的项目仓库 | `/你的仓库名/` |
| 用户/组织根站点或自定义域名根路径 | `/` |

配置文件允许通过 `VITEPRESS_BASE` 覆盖默认值。模板会根据仓库名自动设置子路径；部署到根站点时，应将模板中的对应值改为 `/`。使用自定义域名时，还需配置 DNS 和 Pages 域名选项；本项目未预设域名。

## 第一步：在本地做生产检查

从仓库根目录运行：

```sh
npm --prefix docs ci
npm --prefix docs run docs:check-examples
npm --prefix docs run docs:build
npm --prefix docs run docs:preview
```

请确认首页、深层章节、图片和示例下载均可用后，再提交源文件。部署流程会重新生成 dist，无需将本地 node_modules 或 dist 提交到仓库。

## 第二步：启用 Pages 的 Actions 来源

在仓库的 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**。配置此选项需要相应的仓库设置权限。

然后将以下模板保存为仓库中的 `.github/workflows/docs-pages.yml`。文档提供了[可直接保存的模板文件](/examples/deploy-pages.yml)；该文件仅作为公开下载资源，不会自动执行。

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

配置注意事项：

- run 步骤的工作目录为 docs，因此应使用 `npm ci`，不应再添加 `--prefix docs`。
- 缓存锁文件仍从仓库根定位为 `docs/package-lock.json`。
- 上传目录为 `docs/.vitepress/dist`。
- Pages 部署需要模板中声明的权限；启用环境保护时，按仓库设置完成所需审批。

## 第三步：手动触发部署

1. 提交并推送文档与工作流。手动触发入口需要工作流已存在于默认分支。
2. 进入 **Actions → Deploy FFmpeg++ documentation**。
3. 点击 **Run workflow**，选择要部署的分支后运行。
4. 等待 build 和 deploy 完成，打开部署结果中的站点地址。
5. 直接访问某个深层页面并刷新，再试搜索和示例下载。

如需自动部署，可在模板的 on 下增加 main 分支 push 触发条件，并使用 paths 限定 docs 和该工作流。是否启用该条件可根据发布流程决定；手动触发也可完成部署。

## 常见问题

| 表现 | 检查方向 |
| --- | --- |
| 首页可访问，但样式或图片返回 404 | 检查 base 是否与实际仓库路径一致，并确认大小写一致 |
| 内部链接可用，但直接访问地址并刷新时返回 404 | 检查是否上传完整 dist，以及是否启用了 cleanUrls 或单页应用式 fallback |
| Actions 找不到 npm 锁文件 | 确认文档清单和锁文件均已提交，并检查 cache-dependency-path |
| 构建因死链失败 | 修正链接或补齐目标页面，不要直接关闭死链检查 |
| 无法看到 Run workflow | 确认工作流包含 workflow_dispatch，且已存在于默认分支 |
| 部署权限被拒绝 | 检查 Pages 来源、GITHUB_TOKEN 权限、环境规则和仓库权限 |
| fork 后资源仍指向原路径 | 根据 fork 仓库名设置 VITEPRESS_BASE，然后重新构建并部署 |

此流程生成静态文档站，不能用于运行 Flutter 应用或 C++ 后端。软件安装包仍应从项目的 Releases 获取。

参考：[VitePress 官方部署指南](https://vitepress.dev/zh/guide/deploy)、[GitHub 自定义 Pages 工作流说明](https://docs.github.com/zh/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。
