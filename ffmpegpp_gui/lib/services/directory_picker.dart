import 'package:file_picker/file_picker.dart';

/// Picks a filesystem directory for the local FFmpeg process.
///
/// This keeps the API supported by our pinned file_picker 13.1–13.3 versions.
/// Its replacement in 13.4 returns SAF URIs on Android, which cannot be passed
/// directly to the native FFmpeg process as filesystem paths.
Future<String?> pickLocalDirectory() {
  // Keep the path API until the native backend supports directory URI grants.
  // ignore: deprecated_member_use
  return FilePicker.getDirectoryPath();
}
