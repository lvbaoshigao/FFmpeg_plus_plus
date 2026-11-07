import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

const _currentVersion = '5.30.51';

const _lanzouUrls = {
  'windows': 'https://wwbrq.lanzouv.com/b002w12goj',
  'linux': 'https://wwbrq.lanzouv.com/b002w12gpa',
  'linux_arm64': 'https://wwbrq.lanzouv.com/b002w12gqb',
  'macos_arm64': 'https://wwbrq.lanzouv.com/b002w17vte',
  'android': 'https://wwbrq.lanzouv.com/b002w51tof',
};

const _lanzouPasswords = {
  'windows': '88te',
  'linux': '4zlx',
  'linux_arm64': 'fnk0',
  'macos_arm64': '26qb',
  'android': 'davc',
};

const _githubRepo = 'lvbaoshigao/FFmpeg_plus_plus';

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
  /// 安装包的期望 SHA-256（取自 release 资产里的 `<asset>.sha256`）。
  /// 为空表示发布方未提供校验文件，此时无法校验完整性（H-4）。
  final String? downloadSha256;
  UpdateResult({this.remoteVersion, this.releaseNotes, this.downloadUrl, this.password, this.error, this.releaseNotesError = false, this.source = UpdateSource.github, this.downloadSha256});
  bool get hasUpdate => remoteVersion != null && compareVersions(remoteVersion!, _currentVersion) > 0;
}

/// 下载结果。
///
/// 旧的 [downloadUpdate] 直接返回路径字符串（调用方已在使用），为了不破坏
/// 编译与既有语义，保留其签名；需要「是否做过完整性校验」的调用方改用
/// [downloadUpdateWithResult] 拿本对象。
class DownloadResult {
  /// 落盘后的完整路径。
  final String path;

  /// 是否完成密码学完整性校验（发布方 SHA-256 与实际文件一致）。
  ///
  /// 发布方未提供 `.sha256` 时为 false —— 此时文件只通过了基础校验
  /// （非空 + 扩展名与本平台匹配，见 [warnings]）。false 不等于文件损坏，
  /// UI 应据此提示「未做完整性校验」，而不是静默安装。
  final bool verified;

  /// 下载过程中记录的非致命告警（例如服务端未返回 Content-Length）。
  final List<String> warnings;

  /// 实际写入的字节数。
  final int bytes;

  /// 默认 verified=false：拿不到校验结论时一律按「未校验」对待，
  /// 避免新增字段时漏传导致误报「已验证」。
  const DownloadResult({
    required this.path,
    this.verified = false,
    this.warnings = const <String>[],
    this.bytes = 0,
  });
}

enum UpdateSource { lanzou, github }

int compareVersions(String a, String b) {
  // [FIX M-3] 前缀剥离改为大小写不敏感：'V5.30.51' 的大写 V 也要剥掉，
  // 否则 'V5' 被 int.tryParse 抹平成 0，大版本号被错误拉低。
  final (na, pa) = _parseVersionParts(a.replaceFirst(RegExp(r'^[vV]'), ''));
  final (nb, pb) = _parseVersionParts(b.replaceFirst(RegExp(r'^[vV]'), ''));
  var i = 0;
  while (i < na.length || i < nb.length) {
    final va = i < na.length ? na[i] : 0;
    final vb = i < nb.length ? nb[i] : 0;
    if (va != vb) return va.compareTo(vb);
    i++;
  }
  // 主版本号相同：正式版 > 预发布版；预发布之间逐段比较（beta < beta2 < rc）
  if (pa.isEmpty && pb.isEmpty) return 0;
  if (pa.isEmpty) return 1;
  if (pb.isEmpty) return -1;
  final segA = pa.split(RegExp(r'(?<=\d)(?=\D)|(?<=\D)(?=\d)'));
  final segB = pb.split(RegExp(r'(?<=\d)(?=\D)|(?<=\D)(?=\d)'));
  var j = 0;
  while (j < segA.length || j < segB.length) {
    if (j >= segA.length) return -1; // 更短的预发布更旧（beta < beta2）
    if (j >= segB.length) return 1;
    final xa = int.tryParse(segA[j]);
    final xb = int.tryParse(segB[j]);
    if (xa != null && xb != null) {
      if (xa != xb) return xa.compareTo(xb);
    } else {
      final c = segA[j].compareTo(segB[j]);
      if (c != 0) return c;
    }
    j++;
  }
  return 0;
}

(List<int>, String) _parseVersionParts(String s) {
  final dash = s.indexOf('-');
  final core = dash >= 0 ? s.substring(0, dash) : s;
  final pre = dash >= 0 ? s.substring(dash + 1) : '';
  // [FIX M-3] 空串 / 只有 "v" 等：返回 [0] 表示「未知/无版本」，不崩溃
  //（比较时视为低于任何真实版本，不会误报更新）。
  if (core.isEmpty) return (<int>[0], pre);
  // [FIX M-3] 分段解析：纯数字转 int；非数字段记为 -1（语义上「低于任何数字段」，
  // 即预发布/无效字段 < 对应数字字段，例如 5.3.x < 5.3.0，避免误判为「无更新」）。
  final nums = core.split('.').map((e) {
    final n = int.tryParse(e);
    return n ?? -1;
  }).toList();
  return (nums, pre);
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
    // 用当前平台的蓝奏云链接解析版本（原来固定请求 windows 页面，
    // 其他平台的版本号会与实际下载的包不一致）
    final key = _platformKey();
    final url = _lanzouUrls[key];
    // 该平台（如 Intel Mac）尚未提供更新包时给出明确提示，而不是回退到 windows 包
    if (url == null) return UpdateResult(error: '该平台暂未提供更新包', source: UpdateSource.lanzou);
    final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    final match = RegExp(r'<span id="filename">([^<]+)</span>').firstMatch(resp.body);
    if (match == null) return UpdateResult(error: 'parse_failed', source: UpdateSource.lanzou);
    final raw = match.group(1)!.trim();
    // [FIX M-4] 正则失败时不要用文件名原文当版本号（否则几乎必然误报有新版本），
    // 置为 null：hasUpdate 在 remoteVersion 为 null 时显式视为「无更新」。
    final version = RegExp(r'(\d+(?:\.\d+){1,3}(?:-[a-zA-Z]+\d*)?)')
        .firstMatch(raw)?.group(1);
    final password = _lanzouPasswords[key];
    return UpdateResult(remoteVersion: version, downloadUrl: url, password: password, source: UpdateSource.lanzou);
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
    String? checksumUrl;
    final archSuffix = _assetSuffix();
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.contains(archSuffix)) {
        assetUrl = a['browser_download_url'] as String?;
        // 同名 .sha256 资产（发布侧约定）；找不到则下载时无法校验
        for (final b in assets) {
          final bName = (b['name'] as String?) ?? '';
          if (bName == '$name.sha256') {
            checksumUrl = b['browser_download_url'] as String?;
            break;
          }
        }
        break;
      }
    }

    String? sha256Hex;
    if (checksumUrl != null) {
      sha256Hex = await _fetchSha256(checksumUrl);
    }

    return UpdateResult(
      remoteVersion: tagName,
      releaseNotes: body,
      downloadUrl: assetUrl,
      downloadSha256: sha256Hex,
      source: UpdateSource.github,
    );
  } catch (e) {
    return UpdateResult(error: e.toString(), source: UpdateSource.github);
  }
}

/// 取回 `.sha256` 文件并解析出十六进制摘要。
/// 兼容 `"<hash>"`、`"<hash>  <filename>"`（sha256sum 格式）两种写法。
Future<String?> _fetchSha256(String url) async {
  try {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https') return null;
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final m = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(resp.body);
    return m?.group(1)?.toLowerCase();
  } catch (_) {
    return null;
  }
}

String _platformKey() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return _isArm64() ? 'macos_arm64' : 'macos_x64';
  return _isArm64() ? 'linux_arm64' : 'linux';
}

String _assetSuffix() {
  if (Platform.isAndroid) return '.apk';
  if (Platform.isWindows) return '_setup.exe';
  if (Platform.isMacOS) return '.dmg';
  if (_isArm64()) return '_arm64.deb';
  return '_amd64.deb';
}

bool _isArm64() {
  // 缓存结果，避免每次检查更新时阻塞 UI 线程
  if (_arm64Cache != null) return _arm64Cache!;
  if (Platform.isWindows) { _arm64Cache = false; return false; }
  try {
    final result = Process.runSync('uname', ['-m']);
    final arch = result.stdout.toString().trim();
    _arm64Cache = arch == 'aarch64' || arch == 'arm64';
  } catch (_) {
    _arm64Cache = false;
  }
  return _arm64Cache!;
}
bool? _arm64Cache;

/// [FIX M-5] 净化下载文件名，避免 Windows 保留名 / 结尾点空格 / 非法字符
/// 导致文件被系统裁剪或写入失败：
/// - 去掉结尾的 '.' 与空格（Windows 会静默裁剪）；
/// - 过滤非法字符 < > : " / \ | ? * ；
/// - 基名（不含扩展名）命中保留名（CON/PRN/AUX/NUL/COM1-9/LPT1-9）时加前缀 '_'。
/// 正常文件名原样保留；空 / 路径段（含 '/' '\' / '.' '..'）退回到固定名。
String _safeDownloadName(String rawName) {
  if (rawName.isEmpty || rawName == '.' || rawName == '..' ||
      rawName.contains('/') || rawName.contains(r'\')) {
    return 'update.download';
  }
  var name = rawName.replaceAll(RegExp(r'[. ]+$'), '');
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  if (name.isEmpty) return 'update.download';
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  final reserved = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
    caseSensitive: false,
  );
  final safeBase = reserved.hasMatch(base) ? '_$base' : base;
  return '$safeBase$ext';
}

/// 下载更新包，只返回落盘路径（旧签名，保持既有调用方不变）。
///
/// 需要「是否做过完整性校验」的调用方请用 [downloadUpdateWithResult]；
/// 本函数等价于取 `.path`，校验失败同样抛异常。
Future<String> downloadUpdate(String url, {
  void Function(int received, int total)? onProgress,
  String? expectedSha256,
}) async {
  final result = await downloadUpdateWithResult(
    url,
    onProgress: onProgress,
    expectedSha256: expectedSha256,
  );
  return result.path;
}

/// 下载更新包并返回带校验信息的结果对象。
///
/// 安全约束（H-4）：
/// - 只接受 https：明文 http 可被中间人替换安装包，直接拒绝。
/// - 提供 [expectedSha256] 时必须比对，不一致立即删除并报错；匹配时
///   [DownloadResult.verified] == true。
/// - 【本次修复】未提供 [expectedSha256]（发布方没传 .sha256）时，不再
///   「下载完直接交给安装器」：至少做基础校验 —— 文件非空 + 扩展名与本平台
///   匹配（.deb/.AppImage | .exe | .dmg | .apk）。不通过就删文件并抛错，
///   通过则 verified=false，并在 warnings 里说明「只做了基础校验」，
///   由 UI 提示用户，而不是让用户以为已经校验过。
/// - 服务端没返回 Content-Length（total == -1）时无法校验长度：记录告警后
///   按实际收到的字节继续（不直接失败），由 SHA-256 或基础校验兜底。
Future<DownloadResult> downloadUpdateWithResult(String url, {
  void Function(int received, int total)? onProgress,
  String? expectedSha256,
}) async {
  final uri = Uri.parse(url);
  // 明文 http 一律拒绝：更新包会被以应用（Linux 下甚至提权）身份执行
  if (uri.scheme != 'https') {
    throw Exception('拒绝下载：更新包必须使用 https（当前 ${uri.scheme}）');
  }
  final dir = Directory('${_dataDir()}${_s}update');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  // pathSegments.last 可能是空串或 ".."（URL 以 / 结尾、或含相对段），
  // 直接拼进路径会写到 update/ 之外；这里做净化并退回一个固定名字。
  final rawName = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final fileName = _safeDownloadName(rawName);
  final savePath = '${dir.path}$_s$fileName';

  final warnings = <String>[];
  var verified = false;
  final client = HttpClient();
  final file = File(savePath);
  IOSink? sink;
  var received = 0;
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    request.maxRedirects = 10;
    final response = await request.close();

    // 原先不看状态码：404/403 返回的 HTML 错误页会被当成安装包存下来，
    // 然后 installAndRestart 直接执行它。
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw Exception('下载失败：HTTP ${response.statusCode}');
    }

    final total = response.contentLength;
    // contentLength 为 -1 表示服务端没给长度（chunked 传输），此时无法用
    // 「收到字节数 == 声明长度」判断完整性：只记录告警，不中断下载。
    if (total < 0) {
      _warn(
        warnings,
        '服务端未返回 Content-Length，无法校验下载长度（已按实际收到的字节数继续）',
      );
    }
    sink = file.openWrite();
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
    await sink.close();
    sink = null;

    if (total > 0 && received != total) {
      throw Exception('下载不完整：$received / $total 字节');
    }

    // 哈希校验：提供期望值时必须一致，否则视为被篡改/损坏（供应链/中间人）
    if (expectedSha256 != null && expectedSha256.trim().isNotEmpty) {
      final expected = expectedSha256.trim().toLowerCase();
      final actual = sha256.convert(await file.readAsBytes()).toString();
      if (actual != expected) {
        throw Exception('安装包校验失败：SHA-256 不匹配（期望 $expected，实际 $actual）');
      }
      verified = true;
    } else {
      // 没有发布方哈希时的兜底：至少确认这是「给本平台的、非空的安装包」，
      // 而不是 404 错误页、其他平台的包或 0 字节的半截文件。
      _checkBasicPackage(bytes: received, fileName: fileName);
      _warn(
        warnings,
        '发布方未提供 SHA-256，仅完成基础校验（非空 + 扩展名/平台匹配），未做完整性强校验',
      );
    }
  } catch (_) {
    // 失败时清掉半截文件，避免下次被误当成有效安装包执行
    if (sink != null) { try { await sink.close(); } catch (_) {} }
    if (file.existsSync()) { try { file.deleteSync(); } catch (_) {} }
    rethrow;
  } finally {
    client.close();
  }
  return DownloadResult(
    path: savePath,
    verified: verified,
    warnings: warnings,
    bytes: received,
  );
}

/// 当前平台允许的安装包扩展名（小写、带点）。
Set<String> _allowedPackageExtensions() {
  if (Platform.isWindows) return const <String>{'.exe'};
  if (Platform.isMacOS) return const <String>{'.dmg'};
  if (Platform.isAndroid) return const <String>{'.apk'};
  // Linux：发行包是 .deb；同时接受 .AppImage（需用户自行运行，
  // installAndRestart 的 dpkg 分支只对 .deb 有效）。
  return const <String>{'.deb', '.appimage'};
}

/// 取文件名的扩展名（小写、带点）；没有扩展名返回空串。
String _packageExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(dot).toLowerCase() : '';
}

/// 缺 SHA-256 时的基础校验：文件非空 + 扩展名与本平台匹配。
/// 不通过直接抛异常（调用方会删掉该文件，不会交给安装器执行）。
void _checkBasicPackage({required int bytes, required String fileName}) {
  if (bytes <= 0) {
    throw Exception('安装包校验失败：文件为空（0 字节），可能下载被中断或被服务端拒绝');
  }
  final ext = _packageExtension(fileName);
  final allowed = _allowedPackageExtensions();
  if (!allowed.contains(ext)) {
    throw Exception(
      '安装包校验失败：扩展名 "${ext.isEmpty ? '(无)' : ext}" '
      '与当前平台（${Platform.operatingSystem}）不匹配，'
      '期望 ${allowed.join(' / ')}',
    );
  }
}

/// 记录一条非致命告警：进 warnings 供 UI 展示，同时写日志便于排查。
void _warn(List<String> warnings, String message) {
  warnings.add(message);
  debugPrint('[UpdateService] $message');
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
