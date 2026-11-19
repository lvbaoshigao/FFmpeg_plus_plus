import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppState media index', () {
    test('should reflect imports, edits, removals and clearing', () async {
      final state = AppState();
      addTearDown(state.dispose);

      expect(state.videoById('missing'), isNull);
      await state.addVideos(['first.mp4', 'second.mp4']);
      final first = state.videos.first;
      final second = state.videos.last;
      expect(state.videoById(first.id), same(first));
      expect(state.videoById(second.id), same(second));

      final config = TranscodeConfig();
      state.updateVideoConfig(first.id, config);
      expect(state.videoById(first.id)?.config, same(config));
      final graph = PipelineGraph();
      state.updateVideoPipeline(first.id, graph);
      expect(state.videoById(first.id)?.pipelineGraph, same(graph));

      state.removeVideo(first.id);
      expect(state.videoById(first.id), isNull);
      expect(state.videoById(second.id), same(second));
      state.clearAllVideos();
      expect(state.videoById(second.id), isNull);
    });
  });
}
