# 主题与 AI 配置协议

两种贡献都由清单中的独立白名单协议解析。它们不接收 AppConfig、AiProfile 或 ThemeData 的引用；安装时不会自动更改用户设置。只含数据贡献时可省略 WASM module。

SDK 的 theme-ai 数据包可直接构建，无需编译器：

~~~sh
python3 tools/build_plugin.py --example examples/theme-ai --output dist/theme-ai.fppplugin
~~~

或下载 [已打包示例](/examples/plugin-theme-ai.fppplugin)，在插件页导入、启用后分别预览并确认主题与 AI 导入。示例 AI 端点和模型是占位演示，不代表真实服务，使用前应在正常 AI 设置中修改。

## 主题预设

放入 manifest.themes 数组：

~~~json
{
  "kind":"ffmpegpp.theme",
  "schema_version":1,
  "id":"demo-glass",
  "name":{"zh":"示例玻璃主题","en":"Demo Glass"},
  "values":{
    "use_theme_color":true,
    "theme_color":"#FF3870B8",
    "theme_color2":null,
    "card_style":"liquid",
    "nav_style":"liquid",
    "pill_style":"liquid",
    "menu_style":"liquid"
  }
}
~~~

name 可使用非空字符串或语言对象。values 只允许下列字段：

| 字段 | 值 |
| --- | --- |
| theme_color、theme_color2 | #AARRGGBB，强调色 AA 必须为 FF；theme_color2 可为 null 以取消渐变 |
| border_color | #AARRGGBB |
| use_theme_color、glass_follow_theme、border_enabled | 布尔值 |
| card_style、nav_style、pill_style、menu_style | theme / liquid / blur / gray |
| glass_effect | liquid / blur / none |
| dropdown_appearance | theme / liquid / frosted / highlight / gray |
| selection_indicator_style | theme / liquid / blur / outline |
| settings_glass_mode | follow / frosted / solid |
| canvas_bg | global / gray / black / white |
| card_opacity、glass_clarity、glass_light_pos | 0 到 1 |
| glass_blur | 0 到 30 |
| glass_highlight | 0 到 1.6 |
| glass_edge | 0 到 2 |
| theme_tone | 0 到 0.8 |
| border_width | 0.5 到 4 |

颜色或数值非法、包含未知键会拒绝导入。主题不修改字体、亮暗模式、动态取色、GPU 兼容或无障碍偏好。宿主把这些 token 应用到已有渲染器，因此 liquid 表示选择现有液态玻璃效果；插件不能直接创建新的 Flutter Theme 或运行任意着色器。

## AI 目录结构

放入 manifest.ai_configs 数组：

~~~json
{
  "kind":"ffmpegpp.ai-config",
  "schema_version":1,
  "bundle_id":"org.example.models",
  "name":{"zh":"示例目录","en":"Example Catalog"},
  "profiles":[{
    "source_id":"sample-provider",
    "profile":{
      "name":"Example Provider",
      "provider":"openai",
      "api_url":"https://api.example.org/v1",
      "api_path":"/chat/completions",
      "model":"example-chat-model",
      "models":[{
        "id":"example-chat-model",
        "display_name":"Example Chat Model",
        "capabilities":["chat"],
        "input_modalities":["text"],
        "output_modalities":["text"],
        "context_window":8192,
        "max_tokens":2048
      }]
    }
  }]
}
~~~

bundle_id 标识目录来源，source_id 标识该目录中的供应商项，与本机供应商 UUID 不同。供应商支持 openai 或 anthropic 协议，以及白名单字段 name、api_url、api_path、use_responses_api、model、group、context_window、max_tokens、temperature、models。models 必须是数组，条目复用现有模型元数据字段：id、display_name、enabled、capabilities、input_modalities、output_modalities、context_window、max_tokens、temperature、top_p。宿主校验能力/模态枚举、有限数值与上限；每个供应商最多 1024 个模型，单个目录最多 4096 个模型。

## 预览、新增和合并

1. 解析并验证目录，不进行网络请求。
2. 展示将新增的供应商/模型数量及字段变化。
3. 默认新增为本机独立配置，生成本机身份，并保持 disabled；不会切换当前活动供应商。
4. 用户可明确将 source_id 映射到一个本机供应商作为合并目标。宿主要求协议、端点和请求方式一致；合并仅添加缺失模型，保留既有模型设置、用户配置和凭据。存在自定义请求头或代理的目标不能作为含义不明的合并对象。
5. 预览后本机配置若已变化，旧导入计划会被拒绝，需要重新预览。

api_key、api_keys、custom_headers、proxy_url 和其他非白名单字段不能随插件目录导入，也不能让插件读取本机凭据。AI 设置中的密钥继续由已有安全存储管理。配置导入成功不代表端点或模型可用；用户还需检查服务信息、凭据与网络环境。

卸载插件不会自动撤销用户已确认导入的独立 AI 配置或主题设置，避免误删用户后续编辑。可以在正常设置中编辑、删除或更换这些结果。
