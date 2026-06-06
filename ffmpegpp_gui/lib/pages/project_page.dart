import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/video_card.dart';

class ProjectPage extends StatelessWidget {
  const ProjectPage({super.key});

  static const _exts = ['mp4', 'avi', 'mkv', 'mov', 'flv', 'wmv', 'webm', 'm4v', 'mpg', 'mpeg', '3gp', 'ts', 'm2ts'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clr = theme.colorScheme.outline;
    return Consumer<AppState>(
      builder: (context, state, _) {
        final s = AppStrings.of(state.config.language);
        return Scaffold(
          appBar: AppBar(
            title: Text(s.navProjects),
            actions: [
              FilledButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(s.addVideo),
                  onPressed: () { _pick(state); }),  // void callback, not Future
              const SizedBox(width: 16),
            ],
          ),
          body: state.videos.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.video_library_outlined, size: 64, color: clr),
                  const SizedBox(height: 16),
                  Text(s.noVideos, style: TextStyle(fontSize: 16, color: clr)),
                  const SizedBox(height: 8),
                  Text(s.clickAdd, style: TextStyle(fontSize: 13, color: clr)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16), itemCount: state.videos.length,
                  itemBuilder: (_, i) => VideoCard(video: state.videos[i]),
                ),
        );
      },
    );
  }

  static Future<void> _pick(AppState state) async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: _exts);
    if (r != null && r.files.isNotEmpty) {
      final paths = r.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) state.addVideos(paths);
    }
  }
}
