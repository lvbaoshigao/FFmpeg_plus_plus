import 'dart:convert';
import 'dart:io';

class LanzouDownloader {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const _acwOrder = [
    0xf,0x23,0x1d,0x18,0x21,0x10,0x1,0x26,0xa,0x9,
    0x13,0x1f,0x28,0x1b,0x16,0x17,0x19,0xd,0x6,0xb,
    0x27,0x12,0x14,0x8,0xe,0x15,0x20,0x1a,0x2,0x1e,
    0x7,0x4,0x11,0x5,0x3,0x1c,0x22,0x25,0xc,0x24,
  ];
  static const _acwKey = '3000176000856006061501533003690027800375';

  static String _solveAcw(String arg1) {
    final q = List<String>.filled(_acwOrder.length, '');
    for (var i = 0; i < arg1.length; i++) {
      for (var j = 0; j < _acwOrder.length; j++) {
        if (_acwOrder[j] == i + 1) q[j] = arg1[i];
      }
    }
    final u = q.join();
    final buf = StringBuffer();
    final len = u.length < _acwKey.length ? u.length : _acwKey.length;
    for (var i = 0; i < len; i += 2) {
      final a = int.parse(u.substring(i, i + 2), radix: 16) ^ int.parse(_acwKey.substring(i, i + 2), radix: 16);
      var h = a.toRadixString(16);
      if (h.length == 1) h = '0$h';
      buf.write(h);
    }
    return buf.toString();
  }

  static Future<String?> resolveDirectLink(
    String shareUrl, {
    void Function(String status)? onStatus,
  }) async {
    final client = HttpClient();
    client.userAgent = _ua;
    try {
      final base = RegExp(r'(https?://[^/]+)').firstMatch(shareUrl)?.group(1) ?? '';

      // Step 1: ACW challenge
      onStatus?.call('正在解析分享页面...');
      final r1 = await _get(client, shareUrl, {});
      final arg1Match = RegExp(r"var arg1='([A-F0-9]+)'").firstMatch(r1.body);
      if (arg1Match == null) return null;
      final acw = _solveAcw(arg1Match.group(1)!);

      // Step 2: Real page with cookie
      onStatus?.call('正在获取文件信息...');
      final cookies = Map<String, String>.from(r1.cookies);
      cookies['acw_sc__v2'] = acw;
      final r2 = await _get(client, shareUrl, cookies);

      // Step 3: iframe
      final iframeMatch = RegExp(r'iframe[^>]+src="(/fn\?[^"]+)"').firstMatch(r2.body);
      if (iframeMatch == null) return null;
      final iframeUrl = base + iframeMatch.group(1)!;

      onStatus?.call('正在解析下载地址...');
      final r3 = await _get(client, iframeUrl, cookies, referer: shareUrl);

      // Step 4: Extract sign and POST url
      final signs = RegExp(r"var [a-z_]+ = '([a-zA-Z0-9_/+=]+)'").allMatches(r3.body).map((m) => m.group(1)!).toList();
      final postMatch = RegExp(r"url\s*:\s*'(/ajaxm\.php[^']*)'").firstMatch(r3.body);
      if (postMatch == null || signs.length < 2) return null;

      // Step 5: POST for direct link
      onStatus?.call('正在获取直链...');
      final postUrl = base + postMatch.group(1)!;
      final postBody = 'action=downprocess&sign=${signs[1]}&p=${signs.length > 2 ? signs[2] : ""}&kd=1';
      final r4 = await _post(client, postUrl, postBody, cookies, referer: iframeUrl);
      final json = jsonDecode(r4.body) as Map<String, dynamic>;

      if (json['zt'] == 1) {
        final dom = json['dom'] as String? ?? '';
        final urlPath = json['url'] as String? ?? '';
        return '$dom/file/$urlPath';
      }
      return null;
    } finally {
      client.close();
    }
  }

  static Future<void> downloadFile(
    String directUrl,
    String savePath, {
    void Function(int received, int total, double speed)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('正在连接下载服务器...');
    final client = HttpClient();
    client.userAgent = _ua;
    try {
      final request = await client.getUrl(Uri.parse(directUrl));
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();

      final total = response.contentLength;
      onStatus?.call('开始下载... ${total > 0 ? "${(total / 1024 / 1024).toStringAsFixed(1)}MB" : ""}');

      final file = File(savePath);
      final sink = file.openWrite();
      var received = 0;
      final sw = Stopwatch()..start();
      var lastReceived = 0;
      var lastTime = 0;

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final elapsed = sw.elapsedMilliseconds;
        if (elapsed - lastTime > 500 || received == total) {
          final dt = (elapsed - lastTime) / 1000;
          final speed = dt > 0 ? (received - lastReceived) / dt : 0;
          onProgress?.call(received, total, speed.toDouble());
          lastReceived = received;
          lastTime = elapsed;
        }
      }
      await sink.close();
      onStatus?.call('下载完成: ${(received / 1024 / 1024).toStringAsFixed(1)}MB');
    } finally {
      client.close();
    }
  }

  // ── HTTP helpers ──

  static Future<_Resp> _get(HttpClient client, String url, Map<String, String> cookies, {String? referer}) async {
    final request = await client.getUrl(Uri.parse(url));
    if (cookies.isNotEmpty) {
      request.headers.set('Cookie', cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    if (referer != null) request.headers.set('Referer', referer);
    request.followRedirects = true;
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final respCookies = <String, String>{};
    for (final c in response.cookies) {
      respCookies[c.name] = c.value;
    }
    respCookies.addAll(cookies);
    return _Resp(body, respCookies);
  }

  static Future<_Resp> _post(HttpClient client, String url, String body, Map<String, String> cookies, {String? referer}) async {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    request.headers.set('X-Requested-With', 'XMLHttpRequest');
    if (cookies.isNotEmpty) {
      request.headers.set('Cookie', cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    if (referer != null) request.headers.set('Referer', referer);
    request.write(body);
    final response = await request.close();
    final respBody = await response.transform(utf8.decoder).join();
    return _Resp(respBody, cookies);
  }
}

class _Resp {
  final String body;
  final Map<String, String> cookies;
  _Resp(this.body, this.cookies);
}
