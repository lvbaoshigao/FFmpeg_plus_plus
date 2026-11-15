package com.ffmpegpp.ffmpegpp_gui

import org.json.JSONObject

/** JSON-only builder shared by production notifications and JVM regression tests. */
internal object XiaomiIslandPayload {
    private const val HIGHLIGHT = "#FF6B4A"

    fun build(
        business: String,
        frontTitle: String,
        title: String,
        content: String,
        iconKey: String,
        updatable: Boolean,
        dismissIsland: Boolean,
        islandTimeoutSec: Int,
        timeoutMin: Int,
        firstFloat: Boolean,
        progress: Int? = null,
    ): String {
        fun picInfo(): JSONObject = JSONObject().put("type", 1).put("pic", iconKey)

        val pct = progress?.coerceIn(0, 100)

        // ── 大岛（摘要态）A 区：图文组件 1 ─────────────────────────────────
        //
        // 结构是 imageTextInfoLeft{ type, picInfo, textInfo }，**不是**
        // `miui.focus.paramtextInfo`（那个 key 只出现在《开发指南》的展开态示例里，
        // 摘要态用它会认不出来 → 大岛只剩一个图标）。字段名同理：
        // 摘要态 textInfo 用 `showHighlightColor`，不是 `useHighLight`。
        val aZone = JSONObject()
            .put("type", 1)
            .put("picInfo", picInfo())
            .put(
                "textInfo",
                JSONObject()
                    .put("frontTitle", frontTitle)
                    .put("title", title)
                    .put("content", content)
                    .put("narrowFont", false)
                    .put("showHighlightColor", true),
            )

        val bigArea = JSONObject().put("imageTextInfoLeft", aZone)

        // ── 大岛 B 区：进度文本组件（文本 + 线性进度条）─────────────────────
        //
        // 模板库 4.1 的 B 区可用组件里有 `progressTextInfo`（文本 + 环形/线性进度），
        // 这才是「大岛上加进度条」的正确位置；把 `progressInfo` 直接平铺进
        // bigIslandArea 不是合法 B 区成员（上一版就是这么写的，所以看不到条）。
        if (pct != null) {
            bigArea.put(
                "progressTextInfo",
                JSONObject()
                    .put(
                        "progressInfo",
                        JSONObject()
                            .put("progress", pct)
                            .put("colorReach", HIGHLIGHT),
                    )
                    .put(
                        "textInfo",
                        JSONObject()
                            .put("frontTitle", "")
                            .put("title", "$pct%")
                            .put("content", "")
                            .put("showHighlightColor", false),
                    ),
            )
        }

        // ── 小岛（摘要态）：进度用「图标 + 外圈环形进度」───────────────────
        //
        // combinePicInfo 是小岛唯一能表达进度的组件（模板库 4.3）：
        // 图标周围一圈环形进度，会随每次 updatable 更新实时变化。
        // 官方模板库 p111-112：组合图标携带环形进度，不能再并列普通 picInfo。
        // 结构正确不等于 ROM 必然展示环形进度，仍需真机验证权限与模板策略。
        val smallArea = if (pct != null) {
            JSONObject().put(
                "combinePicInfo",
                JSONObject()
                    .put("picInfo", picInfo())
                    .put(
                        "progressInfo",
                        JSONObject()
                            .put("progress", pct)
                            .put("colorReach", HIGHLIGHT)
                            .put("colorUnReach", "#33FFFFFF")
                            .put("isCCW", false),
                    ),
            )
        } else {
            JSONObject().put("picInfo", picInfo())
        }

        val island = JSONObject()
            .put("islandProperty", 1) // 1 = 信息展示为主
            .put("islandTimeout", islandTimeoutSec)
            .put("dismissIsland", dismissIsland)
            .put("highlightColor", HIGHLIGHT)
            .put("bigIslandArea", bigArea)
            .put("smallIslandArea", smallArea)

        // 展开态（焦点通知）：文本组件 2。
        val baseInfo = JSONObject()
            .put("type", 2)
            .put("title", title)
            .put("content", content)

        val v2 = JSONObject()
            .put("protocol", 1)
            .put("business", business) // 必填：运营场景统计
            .put("updatable", updatable)
            .put("islandFirstFloat", firstFloat) // 首次是否直接展开
            .put("enableFloat", false) // 更新时不再抢焦点
            .put("timeout", timeoutMin) // 单位 min
            .put("ticker", content)
            .put("aodTitle", title)
            .put("param_island", island)
            .put("baseInfo", baseInfo)

        // Xiaomi template library (2026-01-29), p45: expanded progress component 2.
        // Do not add it to non-progress completion notifications.
        if (pct != null) {
            v2.put("progressInfo", JSONObject()
                .put("progress", pct)
                .put("colorProgress", HIGHLIGHT)
                .put("colorProgressEnd", HIGHLIGHT))
        }
        return JSONObject().put("param_v2", v2).toString()
    }
}
