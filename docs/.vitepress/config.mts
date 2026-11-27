import { defineConfig } from 'vitepress'

// 让 Markdown 构建与客户端路由把教程下载识别为文件，而不是 HTML 页面。
process.env.VITE_EXTRA_EXTENSIONS = [process.env.VITE_EXTRA_EXTENSIONS, 'fppx', 'fppplugin', 'wasm', 'py']
  .filter(Boolean).join(',')

// 仓库 Pages 默认使用子路径；自定义域名可设置 VITEPRESS_BASE=/。
export default defineConfig({
  lang: 'zh-CN',
  title: 'FFmpeg++',
  titleTemplate: ':title · 使用手册',
  description: 'FFmpeg++ 中文使用手册：节点编辑器、快捷配置、设置、源码构建与节点文件编写。',
  base: process.env.VITEPRESS_BASE || '/FFmpeg_plus_plus/',
  lastUpdated: true,
  cleanUrls: false,
  head: [['link', { rel: 'icon', href: (process.env.VITEPRESS_BASE || '/FFmpeg_plus_plus/') + 'images/app-icon.png' }]],
  themeConfig: {
    siteTitle: 'FFmpeg++ 使用手册',
    nav: [
      { text: '入门指南', link: '/guide/introduction' },
      { text: '节点编辑器', link: '/nodes/' },
      { text: '编写节点文件', link: '/node-files/' },
      { text: '开发插件', link: '/plugins/' },
      { text: '构建软件', link: '/build/' }
    ],
    sidebar: [
    {
        "text": "1 软件入门",
        "collapsed": false,
        "items": [
            {
                "text": "软件介绍",
                "link": "/guide/introduction"
            },
            {
                "text": "下载与首次启动",
                "link": "/guide/installation"
            },
            {
                "text": "界面导览",
                "link": "/guide/interface"
            },
            {
                "text": "第一个任务",
                "link": "/guide/first-task"
            }
        ]
    },
    {
        "text": "2 节点编辑器",
        "collapsed": true,
        "items": [
            {
                "text": "编辑器入门",
                "link": "/nodes/"
            },
            {
                "text": "创建节点",
                "link": "/nodes/creation"
            },
            {
                "text": "编辑节点",
                "link": "/nodes/editing"
            },
            {
                "text": "连线与端口",
                "link": "/nodes/connections"
            },
            {
                "text": "画布与快捷操作",
                "link": "/nodes/canvas"
            },
            {
                "text": "视频节点",
                "link": "/nodes/video"
            },
            {
                "text": "音频节点",
                "link": "/nodes/audio"
            },
            {
                "text": "图片与通用节点",
                "link": "/nodes/image-common"
            },
            {
                "text": "容器与组合",
                "link": "/nodes/containers"
            },
            {
                "text": "逻辑门与逻辑块",
                "link": "/nodes/logic"
            },
            {
                "text": "预览与图校验",
                "link": "/nodes/preview-validation"
            },
            {
                "text": "保存与草稿",
                "link": "/nodes/saving"
            },
            {
                "text": "常用流程实例",
                "link": "/nodes/recipes"
            }
        ]
    },
    {
        "text": "3 其他功能与设置",
        "collapsed": true,
        "items": [
            {
                "text": "项目与媒体导入",
                "link": "/features/project"
            },
            {
                "text": "快捷配置",
                "link": "/features/quick-config"
            },
            {
                "text": "处理队列",
                "link": "/features/queue"
            },
            {
                "text": "配置库与文件交换",
                "link": "/features/library"
            },
            {
                "text": "AI 助手",
                "link": "/features/ai"
            },
            {
                "text": "MCP 接入",
                "link": "/features/mcp"
            },
            {
                "text": "日志与排障",
                "link": "/features/logs"
            },
            {
                "text": "通用与外观",
                "link": "/settings/appearance"
            },
            {
                "text": "编辑器设置",
                "link": "/settings/editor"
            },
            {
                "text": "输出、任务与通知",
                "link": "/settings/processing"
            },
            {
                "text": "高级、缓存与调试",
                "link": "/settings/advanced"
            },
            {
                "text": "更新与关于",
                "link": "/settings/about"
            }
        ]
    },
    {
        "text": "4 构建软件",
        "collapsed": true,
        "items": [
            {
                "text": "构建前准备",
                "link": "/build/"
            },
            {
                "text": "Windows",
                "link": "/build/windows"
            },
            {
                "text": "Linux",
                "link": "/build/linux"
            },
            {
                "text": "macOS",
                "link": "/build/macos"
            },
            {
                "text": "Android",
                "link": "/build/android"
            },
            {
                "text": "产物与常见错误",
                "link": "/build/troubleshooting"
            }
        ]
    },
    {
        "text": "5 编写节点编辑器文件",
        "collapsed": true,
        "items": [
            {
                "text": "节点图与文件格式",
                "link": "/node-files/"
            },
            {
                "text": "编写第一张节点图",
                "link": "/node-files/first-file"
            },
            {
                "text": "字段与参数参考",
                "link": "/node-files/schema"
            },
            {
                "text": "逻辑与控制连线",
                "link": "/node-files/logic"
            },
            {
                "text": "封装、导入与调试",
                "link": "/node-files/pack-import"
            },
            {
                "text": "新版格式与兼容性",
                "link": "/node-files/formats"
            }
        ]
    },
    {
        "text": "6 插件系统（实验性）",
        "collapsed": true,
        "items": [
            { "text": "插件系统入门", "link": "/plugins/" },
            { "text": "编译、导入并运行示例", "link": "/plugins/getting-started" },
            { "text": "清单与 API", "link": "/plugins/api" },
            { "text": "主题与 AI 配置", "link": "/plugins/contributions" },
            { "text": "安全与兼容性", "link": "/plugins/security" }
        ]
    },
    {
        "text": "7 附录与站点维护",
        "collapsed": true,
        "items": [
            {
                "text": "常见问题",
                "link": "/reference/faq"
            },
            {
                "text": "快捷键",
                "link": "/reference/shortcuts"
            },
            {
                "text": "术语表",
                "link": "/reference/glossary"
            },
            {
                "text": "Android 与平台差异",
                "link": "/settings/platforms"
            },
            {
                "text": "维护与本地预览",
                "link": "/deployment/local"
            },
            {
                "text": "部署到 GitHub Pages",
                "link": "/deployment/github-pages"
            }
        ]
    }
],
    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    lastUpdated: { text: '最后更新' },
    darkModeSwitchLabel: '外观',
    sidebarMenuLabel: '章节目录',
    returnToTopLabel: '回到顶部',
    notFound: { title: '页面未找到', quote: '请返回首页或使用搜索查找相关内容。', linkText: '返回首页', linkLabel: '返回首页' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/lvbaoshigao/FFmpeg_plus_plus' }],
    editLink: { pattern: 'https://github.com/lvbaoshigao/FFmpeg_plus_plus/edit/main/docs/:path', text: '在 GitHub 上编辑本页' },
    search: {
      provider: 'local',
      options: {
        miniSearch: {
          options: {
            tokenize(text) {
              return [...new Intl.Segmenter('zh-CN', { granularity: 'word' }).segment(text)]
                .filter(part => part.isWordLike).map(part => part.segment.toLowerCase())
            }
          },
          searchOptions: { prefix: true, fuzzy: 0.2, boost: { title: 4, text: 2, titles: 1 } }
        },
        locales: { root: { translations: {
          button: { buttonText: '搜索手册', buttonAriaLabel: '搜索手册' },
          modal: { displayDetails: '显示详细列表', resetButtonTitle: '清空搜索', backButtonTitle: '返回', noResultsText: '未找到匹配结果，请尝试其他关键词', footer: { selectText: '选择', navigateText: '切换', closeText: '关闭' } }
        } } }
      }
    },
    footer: { message: '以当前仓库实现为依据 · 软件版本 6.0.0-beta2' }
  }
})
