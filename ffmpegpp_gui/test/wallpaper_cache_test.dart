import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/widgets/wallpaper_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存专项回归（对应 .workbuddy/reports/memory-audit-2026-10-02.md 的 M1）：
/// WallpaperBlurCache 用静态字段持有两张全屏 ui.Image，必须有释放入口。
void main() {
  testWidgets('WallpaperBlurCache.release() 释放静态持有的预模糊图', (tester) async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 2, 2), ui.Paint());
    final pic = rec.endRecording();
    final img = await pic.toImage(2, 2);
    pic.dispose();

    WallpaperBlurCache.image.value = img;
    expect(WallpaperBlurCache.image.value, isNotNull);

    WallpaperBlurCache.release();

    // 核心断言：静态引用必须交还给 GC（否则壁纸移除后会常驻到进程退出）
    expect(WallpaperBlurCache.image.value, isNull,
        reason: 'release() 必须清空 image.value');
    // 源图引用也要一并清掉，否则它会把整屏壁纸钉在 ImageCache 管辖之外
    expect(WallpaperBlurCache.currentFor(img, const Size(100, 100)), isNull);

    await tester.pump(); // 跑掉帧末的 dispose 回调
    WallpaperBlurCache.release(); // 幂等：重复释放不应抛异常
    expect(WallpaperBlurCache.image.value, isNull);
  });
}
