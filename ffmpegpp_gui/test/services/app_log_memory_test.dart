import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large log bursts retain only a bounded tail, even below 2000 entries',
    () {
      final state = AppState();
      addTearDown(state.dispose);
      for (var i = 0; i < 1000; i++) {
        state.addLog('entry-$i ${'x' * 4096}', category: 'error');
      }
      expect(state.logEntries.length, lessThan(2000));
      expect(
        state.logEntries.fold<int>(
          0,
          (total, entry) => total + entry.message.length,
        ),
        lessThanOrEqualTo(512 * 1024),
      );
      expect(state.logEntries.last.message, startsWith('entry-999 '));
      state.clearLogs();
      expect(state.logEntries, isEmpty);
      state.addLog('after clear', category: 'error');
      expect(state.logEntries.single.message, 'after clear');
    },
  );

  test('one oversized message is truncated, keeping the useful error tail', () {
    final state = AppState();
    addTearDown(state.dispose);
    state.addLog('${'x' * (2 * 1024 * 1024)}final error', category: 'error');
    final message = state.logEntries.single.message;
    expect(message.length, lessThanOrEqualTo(16 * 1024));
    expect(message, startsWith('[...truncated...]'));
    expect(message, endsWith('final error'));
  });
}
