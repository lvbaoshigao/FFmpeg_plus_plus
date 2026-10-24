// 「底部动作按钮位置」配置项的持久化回归测试。
//
// 背景：AI 提供商详情页底部保留「获取模型 / 添加模型」两颗圆形动作按钮，
// 它们与底部菜单栏分开摆放，整体靠左或靠右，由 AppConfig.mobileBottomActionSide
// 决定（设置 → 外观 → 表面样式）。这里锁定：
//  * 默认右侧；
//  * toJson/fromJson 往返不丢；
//  * 非法/缺失值回退右侧（老配置升级无需迁移步骤）。
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobileBottomActionSide defaults to the right side', () {
    expect(AppConfig().mobileBottomActionSide, 'right');
    expect(AppConfig.fromJson({}).mobileBottomActionSide, 'right');
  });

  test('mobileBottomActionSide round-trips through JSON', () {
    final config = AppConfig()..mobileBottomActionSide = 'left';
    final json = config.toJson();
    expect(json['mobile_bottom_action_side'], 'left');
    expect(
      AppConfig.fromJson(json).mobileBottomActionSide,
      'left',
    );
  });

  test('invalid mobileBottomActionSide falls back to right', () {
    expect(
      AppConfig.fromJson({
        'mobile_bottom_action_side': 'bogus',
      }).mobileBottomActionSide,
      'right',
    );
    expect(
      AppConfig.fromJson({
        'mobile_bottom_action_side': 42,
      }).mobileBottomActionSide,
      'right',
    );
  });
}
