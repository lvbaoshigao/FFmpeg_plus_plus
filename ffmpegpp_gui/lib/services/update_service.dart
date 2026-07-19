import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _currentVersion = '4.13.47';

const _lanzouUrls = {
  'windows': 'https://wwbrq.lanzouv.com/b002w12goj',
  'linux': 'https://wwbrq.lanzouv.com/b002w12gpa',
  'linux_arm64': 'https://wwbrq.lanzouv.com/b002w12gqb',
  'macos_arm64': 'https://wwbrq.lanzouv.com/b002w17vte',
};

const _lanzouPasswords = {
  'macos_arm64': '26qb',
};

const _githubRepo = 'pity-Fox/FFmpeg_plus_plus';

final _s = Platform.pathSeparator;

String _dataDir() {
  if (Platform.isWindows) {
    return '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}${_s}FFmpeg++';
  }
  if (Platform.isMacOS) {
    return '${Platform.environment['HOME'] ?? '/tmp'}/Library/Application Support/FFmpeg++';
  }
  final base = Platform.environment['XDG_DATA_HOME'] ??
      '${Platform.environment['HOME'] ?? '/tmp'}$_s.local${_s}share';
  return '$base${_s}FFmpeg++';
}

String get _versionCachePath => '${_dataDir()}${_s}update_version.txt';

class UpdateResult {
  final String? remoteVersion;
  final String? releaseNotes;
  final String? downloadUrl;
  final String? password;
  final String? error;
  final bool releaseNotesError;
  final UpdateSource source;
  UpdateResult({this.remoteVersion, this.releaseNotes, this.downloadUrl, this.password, this.error, this.releaseNotesError = false, this.source = UpdateSource.github});
  bool get hasUpdate => remoteVersion != null && compareVersions(remoteVersion!, _currentVersion) > 0;
}

enum UpdateSource { lanzou, github }

int compareVersions(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va.compareTo(vb);
  }
  return 0;
}

String get currentVersion => _currentVersion;

Future<UpdateResult> checkForUpdate({required bool preferLanzou}) async {
  // Always try to get GitHub release notes
  final ghFuture = _checkGithub();

  if (preferLanzou) {
    final lz = await _checkLanzou();
    final gh = await ghFuture;
    if (lz.error == null) {
      return UpdateResult(
        remoteVersion: lz.remoteVersion,
        releaseNotes: gh.releaseNotes,
        downloadUrl: lz.downloadUrl,
        password: lz.password,
        source: UpdateSource.lanzou,
        releaseNotesError: gh.error != null,
      );
    }
    return gh;
  } else {
    final gh = await ghFuture;
    if (gh.error == null) return gh;
    final lz = await _checkLanzou();
    if (lz.error == null) {
      return UpdateResult(
        remoteVersion: lz.remoteVersion,
        downloadUrl: lz.downloadUrl,
        password: lz.password,
        source: UpdateSource.lanzou,
        releaseNotesError: true,
      );
    }
    return gh;
  }
}

Future<UpdateResult> _checkLanzou() async {
  try {
    final url = _lanzouUrls['windows']!;
    final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    final match = RegExp(r'<span id="filename">([^<]+)</span>').firstMatch(resp.body);
    if (match == null) return UpdateResult(error: 'parse_failed', source: UpdateSource.lanzou);
    final version = match.group(1)!.trim();
    final key = _platformKey();
    final lanzouLink = _lanzouUrls[key] ?? _lanzouUrls['windows']!;
    final password = _lanzouPasswords[key];
    return UpdateResult(remoteVersion: version, downloadUrl: lanzouLink, password: password, source: UpdateSource.lanzou);
  } catch (e) {
    return UpdateResult(error: e.toString(), source: UpdateSource.lanzou);
  }
}

Future<UpdateResult> _checkGithub() async {
  try {
    final resp = await http.get(
      Uri.parse('https://api.github.com/repos/$_githubRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github.v3+json'},
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return UpdateResult(error: 'http_${resp.statusCode}', source: UpdateSource.github);
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final tagName = (json['tag_name'] as String?) ?? '';
    final body = (json['body'] as String?) ?? '';
    final assets = (json['assets'] as List?) ?? [];

    String? assetUrl;
    final archSuffix = _assetSuffix();
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.contains(archSuffix)) {
        assetUrl = a['browser_download_url'] as String?;
        break;
      }
    }

    return UpdateResult(
      remoteVersion: tagName,
      releaseNotes: body,
      downloadUrl: assetUrl,
      source: UpdateSource.github,
    );
  } catch (e) {
    return UpdateResult(error: e.toString(), source: UpdateSource.github);
  }
}

String _platformKey() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos_arm64';
  return _isArm64() ? 'linux_arm64' : 'linux';
}

String _assetSuffix() {
  if (Platform.isWindows) return '_setup.exe';
  if (Platform.isMacOS) return '.dmg';
  if (_isArm64()) return '_arm64.deb';
  return '_amd64.deb';
}

bool _isArm64() {
  if (Platform.isWindows) return false;
  try {
    final result = Process.runSync('uname', ['-m']);
    final arch = result.stdout.toString().trim();
    return arch == 'aarch64' || arch == 'arm64';
  } catch (_) {
    return false;
  }
}

Future<String> downloadUpdate(String url, {void Function(int received, int total)? onProgress}) async {
  final dir = Directory('${_dataDir()}${_s}update');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final fileName = Uri.parse(url).pathSegments.last;
  final savePath = '${dir.path}$_s$fileName';

  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    request.maxRedirects = 10;
    final response = await request.close();
    final total = response.contentLength;
    final file = File(savePath);
    final sink = file.openWrite();
    var received = 0;
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();
  } finally {
    client.close();
  }
  return savePath;
}

Future<void> installAndRestart(String filePath) async {
  // Write version cache before install — on next launch, app detects the update
  await writeVersionCache(_currentVersion);

  if (Platform.isWindows) {
    await Process.start(filePath, [], mode: ProcessStartMode.detached);
    await Future.delayed(const Duration(milliseconds: 500));
    exit(0);
  } else if (Platform.isMacOS) {
    await Process.start('open', [filePath], mode: ProcessStartMode.detached);
    await Future.delayed(const Duration(milliseconds: 500));
    exit(0);
  } else {
    // Linux: pkexec for GUI password prompt, then restart
    final exe = Platform.resolvedExecutable;
    await Process.start('bash', [
      '-c',
      'sleep 1 && pkexec dpkg -i "\$0" ; nohup "\$1" &>/dev/null &',
      filePath, exe,
    ], mode: ProcessStartMode.detached);
    await Future.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}

Future<void> writeVersionCache(String version) async {
  try {
    final dir = Directory(_dataDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(_versionCachePath).writeAsStringSync(version);
  } catch (_) {}
}

/// Called at startup. Returns:
/// - 'updated' if cache version < current (just updated)
/// - 'downgraded' if cache version > current (downgraded, silent)
/// - null if no cache or same version
Future<String?> checkPostUpdateStatus() async {
  try {
    final file = File(_versionCachePath);
    if (!file.existsSync()) {
      await writeVersionCache(_currentVersion);
      return null;
    }
    final cached = file.readAsStringSync().trim();
    if (cached.isEmpty) {
      await writeVersionCache(_currentVersion);
      return null;
    }
    final cmp = compareVersions(_currentVersion, cached);
    if (cmp > 0) {
      await writeVersionCache(_currentVersion);
      return 'updated';
    } else if (cmp < 0) {
      await writeVersionCache(_currentVersion);
      return 'downgraded';
    }
    return null;
  } catch (_) {
    return null;
  }
}
