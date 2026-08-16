// 最小冒烟测试：仅验证 Flutter 测试框架可用（完整应用需要 C++ 后端，
// 不适合在 widget test 中启动）。
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smoke', () {
    expect(1 + 1, 2);
  });
}
