/// AI 流式请求的稳健传输与解码。
///
/// 背景（用户反馈「节点编辑器智能体的会话经常截断」）：flutter_ai_sdk 1.9 的
/// 流式链路有几处会把一条本来正常的回答掐断或丢字：
///  * `AIHttpClient.postStream` 对**每个网络分片**单独 `utf8.decode`：多字节
///    字符（中文 3 字节）被 TCP / TLS 分片切开时直接抛 FormatException，整条
///    流中断，界面上就是「（回答被截断）请求失败：FormatException…」；
///  * OpenAI 解析器遇到带 `finish_reason` 的分片会丢掉同一分片里的正文；
///    `reasoning_content: ""` 会遮蔽同一 delta 里的 `content`；usage / content
///    的强类型转换失败会变成致命错误；
///  * 流式工具调用拿不到 id / name，页面只能再发一次**非流式**请求重新生成
///    （双倍耗时，网关超时，两次生成结果还可能不一致）；
///  * 流结束时一律伪造 `finish_reason = stop`，真正的异常断流无法识别；
///  * 流式模式下的 HTTP 报错只剩一句 "Unknown error"。
///
/// 这里不改 SDK，而是用它留出的扩展点（`BaseProvider.streamChat` 可覆写、
/// provider 可注入 `AIHttpClient`、`FlutterAI` 可注入 `customProvider`）替换
/// 「传输 + 流解码」两层；请求体构造与非流式请求仍由 SDK 负责。
///
/// 本文件不依赖 Flutter，全部逻辑可离线单测（见 test/ai_stream_client_test.dart）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_ai_sdk/flutter_ai_sdk.dart' as ai;

// ════════════════════════════════════════════════════════════════════════
// 约定
// ════════════════════════════════════════════════════════════════════════

/// 最终 done chunk 的 metadata 键。
abstract final class AiStreamMeta {
  /// bool：服务端是否给出了明确的结束信号（finish_reason / `[DONE]` /
  /// message_stop）。false = 连接在没有任何结束标记的情况下就关了。
  static const String terminated = 'stream_terminated';

  /// int：收到了但拼不出来的工具调用个数（缺 name，或参数 JSON 被截断）。
  static const String incompleteToolCalls = 'incomplete_tool_calls';

  /// int：usage 里报告的推理 token 数（若有）。
  static const String reasoningTokens = 'reasoning_tokens';

  /// String：流式工具调用参数的增量片段（进度事件用）。
  static const String partialArgs = 'partial_args';
}

// ════════════════════════════════════════════════════════════════════════
// 错误归类
// ════════════════════════════════════════════════════════════════════════

const int _maxErrorMessageLength = 400;

String _clip(String text) => text.length <= _maxErrorMessageLength
    ? text
    : '${text.substring(0, _maxErrorMessageLength)}…';

String? _nonEmptyString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num) return value.toString();
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.round() : null;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String? _messageFromErrorJson(Object? json) {
  if (json is String) return _nonEmptyString(json);
  if (json is! Map) return null;
  final error = json['error'];
  if (error is Map) {
    for (final key in const ['message', 'msg', 'detail']) {
      final nested = error[key];
      if (nested is String && nested.trim().isNotEmpty) return nested.trim();
    }
  }
  for (final key in const [
    'message',
    'msg',
    'detail',
    'error_msg',
    'error_description',
  ]) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is List && value.isNotEmpty) return jsonEncode(value);
  }
  return error is String ? _nonEmptyString(error) : null;
}

/// 报错体里的 code / type / status（小写、空格分隔），只用于归类。
String _errorTagsFromJson(Object? json) {
  if (json is! Map) return '';
  final error = json['error'];
  final source = error is Map ? error : json;
  return [
    for (final key in const ['code', 'type', 'status'])
      ?_nonEmptyString(source[key]),
  ].join(' ').toLowerCase();
}

/// 从 HTTP 错误响应体里取出服务端给的原话（最多 400 字）。
///
/// 兼容 OpenAI / Anthropic / Google 的 JSON 报错、FastAPI 的 `detail`、以及
/// 网关直接吐出来的 HTML / 纯文本报错页。取不到时返回空串。
String aiErrorMessageFromBody(String body) {
  final text = body.trim();
  if (text.isEmpty) return '';
  try {
    final message = _messageFromErrorJson(jsonDecode(text));
    if (message != null) return _clip(message);
  } on FormatException {
    // 不是 JSON：多半是网关的 HTML / 纯文本报错页，走下面的文本兜底。
  }
  final title = RegExp(
    r'<title[^>]*>([^<]*)</title>',
    caseSensitive: false,
  ).firstMatch(text)?.group(1)?.trim();
  if (title != null && title.isNotEmpty) return _clip(title);
  final plain = text.startsWith('<')
      ? text.replaceAll(RegExp(r'<[^>]*>'), ' ')
      : text;
  return _clip(plain.replaceAll(RegExp(r'\s+'), ' ').trim());
}

const List<String> _contextLengthHints = [
  'context_length_exceeded',
  'context length',
  'maximum context',
  'context window',
  'too many tokens',
  'prompt is too long',
  'input is too long',
  'reduce the length',
  'range of input length',
];
const List<String> _authHints = [
  'authentication_error',
  'invalid_api_key',
  'invalid api key',
  'incorrect api key',
  'permission_error',
];
const List<String> _quotaHints = [
  'insufficient_quota',
  'insufficient balance',
  'insufficient_balance',
  'exceeded your current quota',
  '余额不足',
  '额度不足',
];
const List<String> _contentFilterHints = [
  'content_filter',
  'content_policy',
  'data_inspection_failed',
];
const List<String> _clientFaultHints = [
  'invalid_request',
  'invalid request',
  'bad request',
  'not_found',
  'validation',
];

ai.AIError _classifyAiError({
  required int? status,
  required String message,
  String tags = '',
  Duration? retryAfter,
}) {
  final lower = '$tags ${message.toLowerCase()}';
  final trimmedTags = tags.trim();
  final code = trimmedTags.isEmpty ? null : trimmedTags.split(' ').first;
  final details = <String, dynamic>{'status': ?status};
  if (_contextLengthHints.any(lower.contains)) {
    return ai.AIContextLengthError(
      message: message,
      code: code,
      details: details,
    );
  }
  if (status == 401 || status == 403 || _authHints.any(lower.contains)) {
    return ai.AIAuthenticationError(
      message: message,
      code: code,
      details: details,
    );
  }
  final quota = status == 402 || _quotaHints.any(lower.contains);
  if (status == 429 ||
      quota ||
      lower.contains('rate_limit') ||
      lower.contains('rate limit')) {
    return ai.AIRateLimitError(
      message: message,
      code: code,
      // 额度用尽重试也没用；纯限流（429）等一会儿通常就能过。
      details: {...details, 'retryable': !quota},
      retryAfter: retryAfter,
    );
  }
  if (_contentFilterHints.any(lower.contains)) {
    return ai.AIContentFilterError(
      message: message,
      code: code,
      details: details,
    );
  }
  // 没有 HTTP 状态码 = 流中途的 error 事件：除非明说是请求本身的问题，否则
  // 都按上游故障处理（可重试 / 可续写）。
  final serverSide = status == null
      ? !_clientFaultHints.any(lower.contains)
      : status >= 500 || status == 408 || status == 425;
  if (serverSide) {
    return ai.AIServerError(
      message: message,
      code: code,
      details: details,
      statusCode: status,
    );
  }
  return ai.AIInvalidRequestError(
    message: message,
    code: code,
    details: details,
  );
}

/// 把 HTTP 错误响应翻译成带「服务端原话」的类型化错误。
///
/// SDK 在流式模式下拿到的是一个未读的响应流，解析不出报错体，最终只给出
/// "Unknown error"，用户完全不知道是 Key 错了、模型名错了还是被限流。
ai.AIError aiErrorFromHttpResponse(
  int status,
  String body, {
  Duration? retryAfter,
  String? reasonPhrase,
}) {
  final serverMessage = aiErrorMessageFromBody(body);
  final reason = reasonPhrase?.trim() ?? '';
  final label = serverMessage.isNotEmpty
      ? serverMessage
      : (reason.isNotEmpty ? reason : 'no error message from the server');
  Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    json = null;
  }
  return _classifyAiError(
    status: status,
    message: 'HTTP $status: $label',
    tags: _errorTagsFromJson(json),
    retryAfter: retryAfter,
  );
}

/// 把流中途的 error 事件翻译成类型化错误。
///
/// OpenAI 兼容网关：`data: {"error": {"message": …, "type": …}}`；
/// Anthropic：`data: {"type": "error", "error": {"type": "overloaded_error", …}}`。
/// SDK 的解析器会直接忽略这些事件，于是上游报错看起来像「回答说到一半没了」。
ai.AIError aiErrorFromStreamEvent(Map<Object?, Object?> event) {
  final error = event['error'];
  final rawStatus = error is Map
      ? _asInt(error['status']) ?? _asInt(error['code'])
      : _asInt(event['code']);
  final status = rawStatus != null && rawStatus >= 400 && rawStatus <= 599
      ? rawStatus
      : null;
  final message =
      _messageFromErrorJson(event) ??
      'The model service reported an error in the middle of the response.';
  return _classifyAiError(
    status: status,
    message: _clip(message),
    tags: _errorTagsFromJson(event),
  );
}

/// 这个错误是否值得自动重试 / 续写（网络抖动、网关超时、上游过载、限流）。
///
/// 鉴权失败、请求非法、上下文超长、内容拦截重试多少次结果都一样，返回 false。
bool aiErrorIsTransient(Object error) {
  if (error is ai.AINetworkError) return error.code != 'cancelled';
  if (error is ai.AIServerError) return true;
  if (error is ai.AIRateLimitError) {
    return error.details?['retryable'] != false;
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is TlsException;
}

/// 给用户看的错误细节：类型化错误取服务端原话，其余取 toString（限长）。
String aiErrorDetail(Object error) =>
    _clip(error is ai.AIError ? error.message : error.toString());

// ════════════════════════════════════════════════════════════════════════
// 请求体修正
// ════════════════════════════════════════════════════════════════════════

/// 可以靠「改掉一个参数再发一次」绕过去的服务端拒绝。
enum AiRequestCompat {
  /// 不认识 `stream_options`（老版本网关 / 部分自建服务）。
  dropStreamOptions,

  /// 要求用 `max_completion_tokens` 代替 `max_tokens`（OpenAI 推理模型）。
  useMaxCompletionTokens,

  /// 不接受自定义 `temperature`（OpenAI 推理模型、新版 Claude）。
  dropTemperature,

  /// 不接受 `top_p`。
  dropTopP,
}

/// 根据一次 400 / 422 的报错原话判断「改掉哪个参数重发就能过」。
///
/// 只在报错里**点名**了对应参数、且请求体里确实带着它时才返回；已经应用过的
/// 改写不会重复返回，因此调用方的重试必然有限。
AiRequestCompat? aiRequestCompatFor(
  String serverMessage,
  Map<String, dynamic> body,
  Set<AiRequestCompat> applied,
) {
  final lower = serverMessage.toLowerCase();
  bool usable(AiRequestCompat compat, String bodyKey, String mention) =>
      !applied.contains(compat) &&
      body.containsKey(bodyKey) &&
      lower.contains(mention);
  if (usable(
    AiRequestCompat.dropStreamOptions,
    'stream_options',
    'stream_options',
  )) {
    return AiRequestCompat.dropStreamOptions;
  }
  if (usable(
    AiRequestCompat.useMaxCompletionTokens,
    'max_tokens',
    'max_completion_tokens',
  )) {
    return AiRequestCompat.useMaxCompletionTokens;
  }
  if (usable(AiRequestCompat.dropTemperature, 'temperature', 'temperature')) {
    return AiRequestCompat.dropTemperature;
  }
  if (usable(AiRequestCompat.dropTopP, 'top_p', 'top_p')) {
    return AiRequestCompat.dropTopP;
  }
  return null;
}

/// 把 [compat] 里的改写应用到请求体（就地修改）。
void applyAiRequestCompat(
  Map<String, dynamic> body,
  Iterable<AiRequestCompat> compat,
) {
  for (final item in compat) {
    switch (item) {
      case AiRequestCompat.dropStreamOptions:
        body.remove('stream_options');
      case AiRequestCompat.useMaxCompletionTokens:
        final value = body.remove('max_tokens');
        if (value != null) body.putIfAbsent('max_completion_tokens', () => value);
      case AiRequestCompat.dropTemperature:
        body.remove('temperature');
      case AiRequestCompat.dropTopP:
        body.remove('top_p');
    }
  }
}

bool _isBlankTextBlock(Object? block) {
  if (block is! Map || block['type'] != 'text') return false;
  final text = block['text'];
  return text is! String || text.trim().isEmpty;
}

/// 发送前修正 SDK 生成的请求体（就地修改，只动 `messages`）。
///
///  * Anthropic 拒绝空白 text 块（`text content blocks must be non-empty`）。
///    模型不写任何前言直接调工具时，SDK 会生成
///    `[{type: text, text: ""}, {type: tool_use, …}]`，于是工具结果回传的那
///    一轮必定 400 —— 智能体执行完第一个工具就「断」了。这里删掉空白 text 块，
///    并移除因此变空的 assistant 消息。
///  * OpenAI 的 tool 消息被 SDK 二次 JSON 编码（`"\"Created node n4\""`），
///    模型看到的是带转义引号的字符串；还原成原文。
void sanitizeAiRequestBody(Map<String, dynamic> body) {
  final messages = body['messages'];
  if (messages is! List) return;
  final emptied = <Object?>[];
  for (final message in messages) {
    if (message is! Map) continue;
    final content = message['content'];
    if (message['role'] == 'tool' && content is String) {
      if (content.length >= 2 &&
          content.startsWith('"') &&
          content.endsWith('"')) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is String) {
            // 空的 tool 内容会被部分网关拒绝，给一个占位。
            message['content'] = decoded.isEmpty ? '(no output)' : decoded;
          }
        } on FormatException {
          // 本来就不是被二次编码的字符串，保持原样。
        }
      }
      continue;
    }
    if (content is! List || !content.any(_isBlankTextBlock)) continue;
    final kept = [
      for (final block in content)
        if (!_isBlankTextBlock(block)) block,
    ];
    if (kept.isNotEmpty) {
      message['content'] = kept;
    } else if (message['role'] == 'assistant') {
      if (message['tool_calls'] == null) {
        emptied.add(message);
      } else {
        message['content'] = '';
      }
    } else {
      message['content'] = [
        {'type': 'text', 'text': '(empty message)'},
      ];
    }
  }
  if (emptied.isNotEmpty) messages.removeWhere(emptied.contains);
}

// ════════════════════════════════════════════════════════════════════════
// 传输层
// ════════════════════════════════════════════════════════════════════════

/// 稳健的流式 HTTP 传输。
///
/// 只覆写 [postStream]（非流式请求仍走 SDK 自带的 Dio）：
///  * 用**流式** UTF-8 解码器 + 行切分器，多字节字符 / 一行数据被网络分片
///    切开都不会出错；
///  * HTTP >= 400 时读出报错体，抛带服务端原话的类型化错误；
///  * 连接、首字节、流中空闲分别计时：连接断了但没有 FIN 的「静默卡死」会在
///    [idleTimeout] 后以可恢复的超时错误退出，而不是让界面转 20 分钟；
///  * 400 / 422 且报错点名了某个可选参数时，去掉该参数自动重发一次（见
///    [AiRequestCompat]），并记住这个结论；
///  * [dispose] 立即终止在途的流，「停止生成」不必等下一个数据包。
class RobustAiHttpClient extends ai.AIHttpClient {
  RobustAiHttpClient(
    super.config, {
    this.connectTimeout = const Duration(seconds: 30),
    Duration? firstByteTimeout,
    Duration? idleTimeout,
  }) : firstByteTimeout =
           firstByteTimeout ?? config.timeout ?? const Duration(minutes: 5),
       idleTimeout = idleTimeout ?? _defaultIdleTimeout(config.timeout);

  /// TCP / TLS 建连上限。
  final Duration connectTimeout;

  /// 从发出请求到收到第一个数据分片的上限。推理模型可能要想很久才吐第一个
  /// 字，所以默认沿用 `config.timeout`（页面给的是 20 分钟）。
  final Duration firstByteTimeout;

  /// 流开始后两个数据分片之间的最长间隔。
  final Duration idleTimeout;

  /// 已经验证有效的参数改写，按「主机 + 路径 + 模型」记忆。每次发送都会新建
  /// client，放实例上就得每轮都先撞一次 400。
  static final Map<String, Set<AiRequestCompat>> _compatCache = {};

  HttpClient? _http;
  bool _disposed = false;
  final Set<_AiStreamJob> _jobs = {};

  static Duration _defaultIdleTimeout(Duration? timeout) {
    const cap = Duration(minutes: 5);
    return timeout == null || timeout > cap ? cap : timeout;
  }

  HttpClient get _io =>
      _http ??= (HttpClient()..connectionTimeout = connectTimeout);

  /// 与 SDK 的 Dio 配置等价的请求头：基础头 → `config.headers` → 默认
  /// Bearer 鉴权（除非自定义头里给了 Authorization / x-api-key）→ 单次请求头。
  /// 头名大小写不敏感，后者覆盖前者。
  Map<String, String> _mergedHeaders(Map<String, String>? requestHeaders) {
    final merged = <String, MapEntry<String, String>>{};
    void put(String name, String value) =>
        merged[name.toLowerCase()] = MapEntry(name, value);
    put('Content-Type', 'application/json');
    final custom = config.headers ?? const <String, String>{};
    for (final entry in custom.entries) {
      put(entry.key, entry.value);
    }
    if (custom['Authorization'] == null && custom['x-api-key'] == null) {
      put('Authorization', 'Bearer ${config.apiKey}');
    }
    for (final entry
        in (requestHeaders ?? const <String, String>{}).entries) {
      put(entry.key, entry.value);
    }
    return {for (final entry in merged.values) entry.key: entry.value};
  }

  @override
  Stream<String> postStream(
    String url, {
    required Map<String, dynamic> body,
    Map<String, String>? headers,
  }) {
    late final StreamController<String> controller;
    _AiStreamJob? job;
    controller = StreamController<String>(
      onListen: () {
        final started = _AiStreamJob(
          owner: this,
          controller: controller,
          url: url,
          body: body,
          headers: _mergedHeaders(headers),
        );
        job = started;
        _jobs.add(started);
        unawaited(started.run());
      },
      onPause: () => job?.pause(),
      onResume: () => job?.resume(),
      onCancel: () => job?.cancel(),
    );
    return controller.stream;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in _jobs.toList()) {
      job.abort();
    }
    _http?.close(force: true);
    _http = null;
    super.dispose();
  }
}

const ai.AINetworkError _cancelledError = ai.AINetworkError(
  message: 'Request cancelled',
  code: 'cancelled',
);

/// 一次流式 POST 的生命周期。
///
/// 刻意不用 `async*`：生成器阻塞在 `await for` 上时，取消订阅要等到下一个
/// 数据包才生效 —— 连接静默卡死时「停止生成」就永远停不下来。这里用
/// StreamController + 显式状态，取消 / 超时 / dispose 都是立即生效的。
class _AiStreamJob {
  _AiStreamJob({
    required this.owner,
    required this.controller,
    required this.url,
    required this.body,
    required this.headers,
  });

  final RobustAiHttpClient owner;
  final StreamController<String> controller;
  final String url;
  final Map<String, dynamic> body;
  final Map<String, String> headers;

  HttpClientRequest? _request;
  StreamSubscription<String>? _subscription;
  Timer? _idleTimer;
  bool _finished = false;
  bool _receivedData = false;

  Future<void> run() async {
    try {
      if (owner._disposed) throw _cancelledError;
      final uri = Uri.parse(url);
      final compatKey =
          '${uri.host}:${uri.port}${uri.path}|${body['model'] ?? ''}';
      final applied = <AiRequestCompat>{
        ...?RobustAiHttpClient._compatCache[compatKey],
      };
      final learned = <AiRequestCompat>{};
      sanitizeAiRequestBody(body);
      while (true) {
        final payload = Map<String, dynamic>.of(body);
        applyAiRequestCompat(payload, applied);
        final response = await _post(uri, payload);
        if (_finished) {
          // 等响应头的时候已被取消：丢弃这条响应并释放连接。
          unawaited(response.listen((_) {}).cancel());
          return;
        }
        // POST 不会自动跟随重定向：3xx 的响应体不是模型输出，按错误处理，否则
        // 界面上只会得到一条莫名其妙的空回复。
        if (response.statusCode < 300) {
          if (learned.isNotEmpty) {
            if (RobustAiHttpClient._compatCache.length > 64) {
              RobustAiHttpClient._compatCache.clear();
            }
            RobustAiHttpClient._compatCache[compatKey] = applied;
          }
          _pipe(response);
          return;
        }
        final errorBody = await _readErrorBody(response);
        if (_finished) return;
        final status = response.statusCode;
        final fix = status == 400 || status == 422
            ? aiRequestCompatFor(
                aiErrorMessageFromBody(errorBody),
                payload,
                applied,
              )
            : null;
        if (fix == null) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          throw aiErrorFromHttpResponse(
            status,
            status < 400 && location != null
                ? 'Redirected to $location (check the API URL)'
                : errorBody,
            retryAfter: _retryAfter(response),
            reasonPhrase: response.reasonPhrase,
          );
        }
        applied.add(fix);
        learned.add(fix);
      }
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  Future<HttpClientResponse> _post(
    Uri uri,
    Map<String, dynamic> payload,
  ) async {
    final opening = owner._io.openUrl('POST', uri);
    final request = await opening.timeout(
      owner.connectTimeout + const Duration(seconds: 5),
      onTimeout: () {
        // openUrl 本身不可取消：晚到的连接要主动丢弃，否则会泄漏一个 socket。
        unawaited(
          opening.then<void>(
            (late) => late.abort(),
            onError: (Object _) {},
          ),
        );
        throw TimeoutException('Timed out while connecting to the AI endpoint');
      },
    );
    if (_finished) {
      request.abort();
      throw _cancelledError;
    }
    _request = request;
    for (final entry in headers.entries) {
      try {
        request.headers.set(entry.key, entry.value);
      } on FormatException {
        // dart:io 的报错原文会带上头的值（可能就是 API Key），这里只报头名。
        request.abort();
        throw ai.AIInvalidRequestError(
          message:
              'The "${entry.key}" request header contains characters that '
              'are not allowed (check the API key and custom headers).',
          code: 'invalid_header',
        );
      }
    }
    final bytes = utf8.encode(jsonEncode(payload));
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(
      owner.firstByteTimeout,
      onTimeout: () {
        request.abort();
        throw TimeoutException(
          'The AI endpoint did not answer within '
          '${owner.firstByteTimeout.inSeconds}s',
        );
      },
    );
    _request = null;
    return response;
  }

  Future<String> _readErrorBody(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        builder.add(chunk);
        if (builder.length > 64 * 1024) break;
      }
    } on Object catch (_) {
      // 报错体读到一半断了：用已经读到的部分，总比 "Unknown error" 强。
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Duration? _retryAfter(HttpClientResponse response) {
    final raw = response.headers.value('retry-after');
    final seconds = raw == null ? null : double.tryParse(raw.trim());
    if (seconds == null || seconds.isNaN || seconds < 0 || seconds > 3600) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void _pipe(HttpClientResponse response) {
    _armIdleTimer();
    _subscription = response
        .map((chunk) {
          _receivedData = true;
          _armIdleTimer();
          return chunk;
        })
        // 流式解码：解码器跨分片保留未完成的多字节序列，allowMalformed 保证
        // 真有坏字节时也只是出现一个 U+FFFD，而不是整条回答报废。
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty && !_finished) controller.add(trimmed);
          },
          onError: _fail,
          onDone: _complete,
          cancelOnError: true,
        );
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    if (_finished) return;
    final limit = _receivedData ? owner.idleTimeout : owner.firstByteTimeout;
    _idleTimer = Timer(limit, () {
      _fail(
        ai.AINetworkError(
          message: _receivedData
              ? 'No data received from the model for ${limit.inSeconds}s'
              : 'The model did not start responding within '
                    '${limit.inSeconds}s',
          code: 'idle_timeout',
          isTimeout: true,
        ),
        StackTrace.current,
      );
    });
  }

  void pause() {
    _idleTimer?.cancel();
    _subscription?.pause();
  }

  void resume() {
    _subscription?.resume();
    if (_subscription != null) _armIdleTimer();
  }

  /// 下游取消订阅。
  Future<void>? cancel() {
    if (_finished) return null;
    _finished = true;
    return _release();
  }

  /// client 被 dispose：让下游立即收到一个「已取消」的错误并结束。
  void abort() => _fail(_cancelledError, StackTrace.current);

  void _complete() {
    if (_finished) return;
    _finished = true;
    unawaited(_release());
    unawaited(controller.close());
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_finished) return;
    _finished = true;
    unawaited(_release());
    controller.addError(_translate(error), stackTrace);
    unawaited(controller.close());
  }

  Future<void>? _release() {
    _idleTimer?.cancel();
    _idleTimer = null;
    owner._jobs.remove(this);
    _request?.abort();
    _request = null;
    final subscription = _subscription;
    _subscription = null;
    return subscription?.cancel();
  }

  static Object _translate(Object error) {
    if (error is ai.AIError) return error;
    if (error is TimeoutException) {
      return ai.AINetworkError(
        message: error.message ?? 'The request timed out',
        code: 'timeout',
        isTimeout: true,
      );
    }
    if (error is SocketException) {
      final os = error.osError?.message.trim() ?? '';
      final text = os.isEmpty || error.message.contains(os)
          ? error.message
          : '${error.message} ($os)';
      return ai.AINetworkError(
        message: 'Network error: ${_clip(text)}',
        code: 'socket',
        isTimeout: error.message.contains('timed out'),
      );
    }
    if (error is TlsException) {
      return ai.AINetworkError(
        message: 'TLS error: ${_clip(error.message)}',
        code: 'tls',
      );
    }
    if (error is HttpException) {
      return ai.AINetworkError(
        message: 'Connection lost: ${_clip(error.message)}',
        code: 'http',
      );
    }
    if (error is FormatException) {
      return ai.AIInvalidRequestError(
        message: 'Invalid AI endpoint or request: ${_clip(error.message)}',
        code: 'invalid_request',
      );
    }
    return ai.AIUnknownError(
      message: _clip(error.toString()),
      originalError: error,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 流解码
// ════════════════════════════════════════════════════════════════════════

/// 把一条原始行流（SSE 行）解码成 [ai.StreamChunk] 序列的有状态解码器。
///
/// 约定：
///  * [add] 对格式不对的行**只忽略、不抛错**；只有服务端明确发来 error 事件
///    才抛 [ai.AIError]；
///  * 正文 / 思考增量即时产出；工具调用在 [close] 时一次性产出**完整**的
///    `StreamChunk.toolCall`（带 id / name / 解析好的参数），流中途只发
///    `toolCallDelta` 进度事件；
///  * [close] 的最后一个 chunk 一定是 done，`finishReason` 如实为空（不伪造
///    stop），并带 [AiStreamMeta] 的元信息。
abstract class AiStreamDecoder {
  List<ai.StreamChunk> add(String line);

  List<ai.StreamChunk> close();

  /// 是否已经收到「后面不会再有数据」的结束标记（`[DONE]` / message_stop）。
  bool get isTerminated;
}

class _PendingToolCall {
  String? id;
  String? name;
  Map<String, dynamic>? preset;
  final StringBuffer arguments = StringBuffer();
}

Map<String, dynamic>? _decodeToolArguments(
  String raw,
  Map<String, dynamic>? preset,
) {
  final text = raw.trim();
  if (text.isEmpty) return preset ?? <String, dynamic>{};
  try {
    var decoded = jsonDecode(text);
    // 个别网关把参数对象又包了一层字符串。
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on FormatException {
    // 参数 JSON 不完整（多半是被 max_tokens 截断）。
  }
  return null;
}

({List<ai.ToolCallContent> complete, int incomplete}) _finishToolCalls(
  Iterable<_PendingToolCall> calls,
) {
  final complete = <ai.ToolCallContent>[];
  final seenIds = <String>{};
  var incomplete = 0;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  for (final call in calls) {
    final name = call.name?.trim() ?? '';
    final arguments = _decodeToolArguments(
      call.arguments.toString(),
      call.preset,
    );
    if (name.isEmpty || arguments == null) {
      incomplete++;
      continue;
    }
    var id = call.id?.trim() ?? '';
    // 缺 id 或 id 重复（有的网关给并行调用发同一个 id）时本地生成，保证
    // assistant tool_calls 与 tool 结果能一一配对。
    if (id.isEmpty || !seenIds.add(id)) {
      id = 'call_$stamp${complete.length}';
      seenIds.add(id);
    }
    complete.add(ai.ToolCallContent(id: id, name: name, arguments: arguments));
  }
  return (complete: complete, incomplete: incomplete);
}

/// 取 delta 里的文本：字符串原样返回；分块数组拼接其中的 text。
String? _flatText(Object? value) {
  if (value is String) return value;
  if (value is! List) return null;
  final buffer = StringBuffer();
  for (final part in value) {
    if (part is String) {
      buffer.write(part);
    } else if (part is Map && part['text'] is String) {
      buffer.write(part['text'] as String);
    }
  }
  return buffer.toString();
}

ai.StreamChunk _toolProgressChunk(String partialArguments) => ai.StreamChunk(
  type: ai.StreamEventType.toolCallDelta,
  metadata: {AiStreamMeta.partialArgs: partialArguments},
);

final RegExp _sseFieldLine = RegExp(r'^(event|id|retry)\s*:');

/// 两种协议共用的「行 → JSON 事件」前处理。
abstract class _SseJsonDecoder implements AiStreamDecoder {
  final StringBuffer _rawBody = StringBuffer();
  bool _sawEvent = false;
  bool _closed = false;

  List<ai.StreamChunk> handleEvent(Map<Object?, Object?> event);

  List<ai.StreamChunk> finish();

  /// 行内容是 `[DONE]` 之类的非 JSON 结束标记时调用。
  void handleSentinel(String payload) {}

  @override
  List<ai.StreamChunk> add(String line) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith(':')) return const [];
    final String payload;
    if (text.startsWith('data:')) {
      // 规范写法是 "data: "，但不少网关不带空格；两种都接受。
      payload = text.substring(5).trim();
    } else if (_sseFieldLine.hasMatch(text)) {
      return const [];
    } else {
      // 不是 SSE 行：服务端可能忽略了 stream=true 直接回整包 JSON，或者在
      // 200 状态下回了一个报错体 / 网页。先攒着，close() 时整体解析。
      if (!_sawEvent && _rawBody.length < 4 * 1024 * 1024) {
        _rawBody.writeln(text);
      }
      return const [];
    }
    if (payload.isEmpty) return const [];
    if (!payload.startsWith('{')) {
      handleSentinel(payload);
      return const [];
    }
    final Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      return const [];
    }
    if (json is! Map) return const [];
    _sawEvent = true;
    return handleEvent(json);
  }

  @override
  List<ai.StreamChunk> close() {
    if (_closed) return const [];
    _closed = true;
    final out = <ai.StreamChunk>[];
    if (!_sawEvent && _rawBody.isNotEmpty) {
      Object? json;
      try {
        json = jsonDecode(_rawBody.toString());
      } on FormatException {
        json = null;
      }
      if (json is Map) {
        out.addAll(handleEvent(json));
      } else if (!isTerminated) {
        // 整个响应里没有任何模型事件，只有一段看不懂的文本：最常见的是 API
        // 地址填错（少了 /v1），拿到的是网站首页。如实报错，而不是给用户一条
        // 空回复。
        throw ai.AIInvalidRequestError(
          message:
              'The endpoint did not return a model response (check the API '
              'URL): ${aiErrorMessageFromBody(_rawBody.toString())}',
          code: 'unexpected_response',
        );
      }
    }
    out.addAll(finish());
    return out;
  }
}

/// OpenAI Chat Completions 流（以及一切 OpenAI 兼容网关）的解码器。
class OpenAiStreamDecoder extends _SseJsonDecoder {
  final List<_PendingToolCall> _calls = [];
  final Map<int, _PendingToolCall> _callsByIndex = {};
  ai.FinishReason? _finishReason;
  ai.Usage? _usage;
  int? _reasoningTokens;
  bool _sawDone = false;
  bool _sawFinish = false;

  @override
  bool get isTerminated => _sawDone;

  @override
  void handleSentinel(String payload) {
    if (payload == '[DONE]') _sawDone = true;
  }

  @override
  List<ai.StreamChunk> handleEvent(Map<Object?, Object?> event) {
    final error = event['error'];
    if (error != null && error != false && event['choices'] == null) {
      throw aiErrorFromStreamEvent(event);
    }
    final out = <ai.StreamChunk>[];
    _readUsage(event['usage']);
    final choices = event['choices'];
    if (choices is! List || choices.isEmpty) return out;
    final choice = choices.first;
    if (choice is! Map) return out;
    _readUsage(choice['usage']);
    // 非流式整包回复把内容放在 message 里，结构与 delta 相同。
    final delta = choice['delta'] ?? choice['message'];
    if (delta is Map) {
      // 思考与正文可以出现在同一个 delta 里，两个都要发：SDK 只要看到
      // reasoning_content 键（哪怕是空串）就丢掉同一 delta 的 content。
      final reasoning =
          _flatText(delta['reasoning_content']) ?? _flatText(delta['reasoning']);
      if (reasoning != null && reasoning.isNotEmpty) {
        out.add(ai.StreamChunk.thinkingDelta(reasoning));
      }
      final content = _flatText(delta['content']);
      if (content != null && content.isNotEmpty) {
        out.add(ai.StreamChunk.delta(content));
      }
      final toolCalls = delta['tool_calls'];
      if (toolCalls is List) {
        for (final raw in toolCalls) {
          if (raw is Map) out.add(_addToolDelta(raw));
        }
      }
      final legacy = delta['function_call'];
      if (legacy is Map) {
        out.add(_addToolDelta({'index': 0, 'function': legacy}));
      }
    }
    // finish_reason 与最后一段正文经常在同一个分片里（Gemini 兼容端点、
    // 一次性回整段的网关都这样）：先收正文，再记结束原因。
    final finish = choice['finish_reason'];
    if (finish is String && finish.isNotEmpty) {
      _finishReason = _finishReasonFrom(finish);
      _sawFinish = true;
    }
    return out;
  }

  ai.StreamChunk _addToolDelta(Map<Object?, Object?> raw) {
    final index = _asInt(raw['index']);
    final rawId = raw['id'];
    final id = rawId is String && rawId.isNotEmpty ? rawId : null;
    final function = raw['function'];
    final rawName = function is Map ? function['name'] : null;
    final name = rawName is String && rawName.isNotEmpty ? rawName : null;
    final rawArguments = function is Map ? function['arguments'] : null;
    final arguments = rawArguments is String
        ? rawArguments
        : (rawArguments is Map ? jsonEncode(rawArguments) : null);

    _PendingToolCall? call;
    if (index != null) {
      call = _callsByIndex[index];
      // 有的网关给每个并行调用都发 index 0：同一 index 出现了新的 id 就是
      // 一次新的调用。
      if (call != null && id != null && call.id != null && call.id != id) {
        call = null;
      }
    } else if (id != null) {
      for (final candidate in _calls) {
        if (candidate.id == id) call = candidate;
      }
    } else if (_calls.isNotEmpty && name == null) {
      call = _calls.last;
    }
    if (call == null) {
      call = _PendingToolCall();
      _calls.add(call);
      if (index != null) _callsByIndex[index] = call;
    }
    call.id ??= id;
    call.name ??= name;
    if (arguments != null) call.arguments.write(arguments);
    return _toolProgressChunk(arguments ?? '');
  }

  void _readUsage(Object? raw) {
    if (raw is! Map) return;
    final prompt = _asInt(raw['prompt_tokens']) ?? _asInt(raw['input_tokens']);
    final completion =
        _asInt(raw['completion_tokens']) ?? _asInt(raw['output_tokens']);
    final completionDetails = raw['completion_tokens_details'];
    if (completionDetails is Map) {
      _reasoningTokens =
          _asInt(completionDetails['reasoning_tokens']) ?? _reasoningTokens;
    }
    if (prompt == null && completion == null) return;
    final promptDetails = raw['prompt_tokens_details'];
    _usage = ai.Usage(
      promptTokens: prompt ?? _usage?.promptTokens ?? 0,
      completionTokens: completion ?? _usage?.completionTokens ?? 0,
      cachedTokens:
          (promptDetails is Map ? _asInt(promptDetails['cached_tokens']) : null) ??
          _asInt(raw['prompt_cache_hit_tokens']) ??
          _asInt(raw['cached_tokens']),
    );
  }

  static ai.FinishReason _finishReasonFrom(String reason) =>
      switch (reason.toLowerCase()) {
        'stop' ||
        'eos' ||
        'end_turn' ||
        'stop_sequence' => ai.FinishReason.stop,
        // insufficient_system_resource：DeepSeek 在推理资源不足时中断生成，
        // 语义上就是「话没说完」，按截断处理才能触发续写。
        'length' ||
        'max_tokens' ||
        'model_length' ||
        'insufficient_system_resource' => ai.FinishReason.maxTokens,
        'tool_calls' ||
        'function_call' ||
        'tool_use' => ai.FinishReason.toolCalls,
        'content_filter' ||
        'safety' ||
        'sensitive' => ai.FinishReason.contentFilter,
        _ => ai.FinishReason.unknown,
      };

  @override
  List<ai.StreamChunk> finish() {
    final calls = _finishToolCalls(_calls);
    var reason = _finishReason;
    // 有完整工具调用但结束原因缺失 / 写成了 stop（老版本 Ollama 等）：以工具
    // 调用为准。
    if (calls.complete.isNotEmpty &&
        reason != ai.FinishReason.maxTokens &&
        reason != ai.FinishReason.contentFilter) {
      reason = ai.FinishReason.toolCalls;
    }
    return [
      for (final call in calls.complete) ai.StreamChunk.toolCall(call),
      ai.StreamChunk(
        type: ai.StreamEventType.done,
        finishReason: reason,
        usage: _usage,
        metadata: {
          AiStreamMeta.terminated: _sawDone || _sawFinish,
          AiStreamMeta.incompleteToolCalls: calls.incomplete,
          AiStreamMeta.reasoningTokens: ?_reasoningTokens,
        },
      ),
    ];
  }
}

/// Anthropic Messages 流的解码器。
class AnthropicStreamDecoder extends _SseJsonDecoder {
  final Map<int, _PendingToolCall> _callsByIndex = {};
  ai.FinishReason? _finishReason;
  int? _inputTokens;
  int? _outputTokens;
  int? _cacheReadTokens;
  int? _cacheWriteTokens;
  bool _sawStop = false;
  bool _sawFinish = false;

  @override
  bool get isTerminated => _sawStop;

  @override
  List<ai.StreamChunk> handleEvent(Map<Object?, Object?> event) {
    final type = event['type'];
    final error = event['error'];
    if (type == 'error' || (type == null && error != null && error != false)) {
      throw aiErrorFromStreamEvent(event);
    }
    final out = <ai.StreamChunk>[];
    switch (type) {
      case 'message_start':
        final message = event['message'];
        if (message is Map) _readUsage(message['usage']);
      case 'content_block_start':
        final block = event['content_block'];
        if (block is Map) {
          out.addAll(_startBlock(_asInt(event['index']), block));
        }
      case 'content_block_delta':
        final delta = event['delta'];
        if (delta is Map) {
          out.addAll(_applyDelta(_asInt(event['index']), delta));
        }
      case 'message_delta':
        final delta = event['delta'];
        if (delta is Map) _readStopReason(delta['stop_reason']);
        _readUsage(event['usage']);
      case 'message_stop':
        _sawStop = true;
      case 'message':
        // 服务端忽略了 stream=true，直接回了整包消息。
        final content = event['content'];
        if (content is List) {
          for (var i = 0; i < content.length; i++) {
            final block = content[i];
            if (block is Map) out.addAll(_startBlock(i, block));
          }
        }
        _readStopReason(event['stop_reason']);
        _readUsage(event['usage']);
        _sawStop = true;
    }
    return out;
  }

  List<ai.StreamChunk> _startBlock(int? index, Map<Object?, Object?> block) {
    switch (block['type']) {
      case 'text':
        final text = block['text'];
        if (text is String && text.isNotEmpty) {
          return [ai.StreamChunk.delta(text)];
        }
      case 'thinking':
        final thinking = block['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          return [ai.StreamChunk.thinkingDelta(thinking)];
        }
      case 'tool_use':
        // SDK 的解析器不看 content_block_start，于是流式工具调用永远没有
        // id / name，页面只能再发一次非流式请求。
        final call = _PendingToolCall();
        final id = block['id'];
        final name = block['name'];
        if (id is String) call.id = id;
        if (name is String) call.name = name;
        final input = block['input'];
        if (input is Map && input.isNotEmpty) {
          call.preset = Map<String, dynamic>.from(input);
        }
        _callsByIndex[index ?? _callsByIndex.length] = call;
        return [_toolProgressChunk('')];
    }
    return const [];
  }

  List<ai.StreamChunk> _applyDelta(int? index, Map<Object?, Object?> delta) {
    switch (delta['type']) {
      case 'text_delta':
        final text = delta['text'];
        if (text is String && text.isNotEmpty) {
          return [ai.StreamChunk.delta(text)];
        }
      case 'thinking_delta':
        final thinking = delta['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          return [ai.StreamChunk.thinkingDelta(thinking)];
        }
      case 'input_json_delta':
        final partial = delta['partial_json'];
        final call = _callsByIndex[index] ??
            (_callsByIndex.isEmpty ? null : _callsByIndex.values.last);
        if (partial is String && call != null) {
          call.arguments.write(partial);
          return [_toolProgressChunk(partial)];
        }
    }
    return const [];
  }

  void _readStopReason(Object? reason) {
    if (reason is! String || reason.isEmpty) return;
    _sawFinish = true;
    _finishReason = switch (reason) {
      'end_turn' || 'stop_sequence' => ai.FinishReason.stop,
      'max_tokens' ||
      'model_context_window_exceeded' => ai.FinishReason.maxTokens,
      'tool_use' => ai.FinishReason.toolCalls,
      'refusal' => ai.FinishReason.contentFilter,
      _ => ai.FinishReason.unknown,
    };
  }

  void _readUsage(Object? raw) {
    if (raw is! Map) return;
    _inputTokens = _asInt(raw['input_tokens']) ?? _inputTokens;
    _outputTokens = _asInt(raw['output_tokens']) ?? _outputTokens;
    _cacheReadTokens =
        _asInt(raw['cache_read_input_tokens']) ?? _cacheReadTokens;
    _cacheWriteTokens =
        _asInt(raw['cache_creation_input_tokens']) ?? _cacheWriteTokens;
  }

  @override
  List<ai.StreamChunk> finish() {
    final calls = _finishToolCalls(_callsByIndex.values);
    var reason = _finishReason;
    if (calls.complete.isNotEmpty &&
        reason != ai.FinishReason.maxTokens &&
        reason != ai.FinishReason.contentFilter) {
      reason = ai.FinishReason.toolCalls;
    }
    final hasUsage = _inputTokens != null || _outputTokens != null;
    return [
      for (final call in calls.complete) ai.StreamChunk.toolCall(call),
      ai.StreamChunk(
        type: ai.StreamEventType.done,
        finishReason: reason,
        usage: hasUsage
            ? ai.Usage(
                promptTokens: _inputTokens ?? 0,
                completionTokens: _outputTokens ?? 0,
                cachedTokens: _cacheReadTokens,
                cacheWriteTokens: _cacheWriteTokens,
              )
            : null,
        metadata: {
          AiStreamMeta.terminated: _sawStop || _sawFinish,
          AiStreamMeta.incompleteToolCalls: calls.incomplete,
        },
      ),
    ];
  }
}

/// 用 [decoder] 把 [open] 返回的原始行流解码成 chunk 流。
///
/// 与 SDK 的模板方法相比：
///  * 行流出错 / 服务端发 error 事件 → 流以**错误事件**结束（调用方的
///    onError），而不是混在数据里的 `StreamChunk.error`；
///  * 收到 `[DONE]` / message_stop 之后最多再等 [terminatorGrace] 就收尾 ——
///    有的服务发完结束标记不关连接，不能让调用方一直挂着；
///  * 取消立即生效（不是 `async*`，见 [_AiStreamJob] 的说明）。
Stream<ai.StreamChunk> decodeAiLineStream({
  required Stream<String> Function() open,
  required AiStreamDecoder decoder,
  Duration terminatorGrace = const Duration(milliseconds: 1500),
}) {
  late final StreamController<ai.StreamChunk> controller;
  StreamSubscription<String>? subscription;
  Timer? graceTimer;
  var finished = false;

  void finish([Object? error, StackTrace? stackTrace]) {
    if (finished) return;
    finished = true;
    graceTimer?.cancel();
    final pending = subscription;
    subscription = null;
    if (error != null) {
      controller.addError(error, stackTrace);
    } else {
      try {
        decoder.close().forEach(controller.add);
      } on Object catch (closeError, closeStack) {
        controller.addError(closeError, closeStack);
      }
    }
    unawaited(pending?.cancel());
    unawaited(controller.close());
  }

  controller = StreamController<ai.StreamChunk>(
    onListen: () {
      controller.add(const ai.StreamChunk.start());
      final Stream<String> lines;
      try {
        lines = open();
      } on Object catch (error, stackTrace) {
        finish(error, stackTrace);
        return;
      }
      subscription = lines.listen(
        (line) {
          if (finished) return;
          final List<ai.StreamChunk> chunks;
          try {
            chunks = decoder.add(line);
          } on Object catch (error, stackTrace) {
            finish(error, stackTrace);
            return;
          }
          chunks.forEach(controller.add);
          if (decoder.isTerminated) {
            graceTimer ??= Timer(terminatorGrace, finish);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          // 结束标记之后的断连不算错误：回答已经完整收到了。
          if (decoder.isTerminated) {
            finish();
          } else {
            finish(error, stackTrace);
          }
        },
        onDone: finish,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      finished = true;
      graceTimer?.cancel();
      final pending = subscription;
      subscription = null;
      return pending?.cancel();
    },
  );
  return controller.stream;
}

// ════════════════════════════════════════════════════════════════════════
// Provider 装配
// ════════════════════════════════════════════════════════════════════════

mixin _DecodedStreaming on ai.BaseProvider {
  AiStreamDecoder createStreamDecoder();

  @override
  Stream<ai.StreamChunk> streamChat(List<ai.Message> messages) =>
      decodeAiLineStream(
        open: () {
          validateConfig();
          return openStream(messages);
        },
        decoder: createStreamDecoder(),
      );
}

class _OpenAiProvider extends ai.OpenAIProvider with _DecodedStreaming {
  _OpenAiProvider(super.config, {super.client});

  @override
  AiStreamDecoder createStreamDecoder() => OpenAiStreamDecoder();
}

class _MistralProvider extends ai.MistralProvider with _DecodedStreaming {
  _MistralProvider(super.config, {super.client});

  @override
  AiStreamDecoder createStreamDecoder() => OpenAiStreamDecoder();
}

class _XaiProvider extends ai.XAIProvider with _DecodedStreaming {
  _XaiProvider(super.config, {super.client});

  @override
  AiStreamDecoder createStreamDecoder() => OpenAiStreamDecoder();
}

class _DeepSeekProvider extends ai.DeepSeekProvider with _DecodedStreaming {
  _DeepSeekProvider(super.config, {super.client});

  @override
  AiStreamDecoder createStreamDecoder() => OpenAiStreamDecoder();
}

class _OpenRouterProvider extends ai.OpenRouterProvider
    with _DecodedStreaming {
  _OpenRouterProvider(super.config, {super.client});

  @override
  AiStreamDecoder createStreamDecoder() => OpenAiStreamDecoder();
}

class _AnthropicProvider extends ai.AnthropicProvider with _DecodedStreaming {
  _AnthropicProvider(super.config, {super.client});

  @override
  AiStreamDecoder createStreamDecoder() => AnthropicStreamDecoder();
}

/// 创建带稳健传输（以及 OpenAI / Anthropic 协议的稳健解码）的 provider，交给
/// `ai.FlutterAI(customProvider: …)` 使用。
///
/// Google / Ollama 原生协议在应用里没有入口（设置页只提供 OpenAI 兼容与
/// Anthropic 两种请求协议），这里只替换它们的传输层，解码沿用 SDK。
ai.BaseProvider createRobustAiProvider(
  ai.AIProvider provider,
  ai.AIConfig config, {
  ai.AIHttpClient? client,
}) {
  final http = client ?? RobustAiHttpClient(config);
  return switch (provider) {
    ai.AIProvider.openai => _OpenAiProvider(config, client: http),
    ai.AIProvider.mistral => _MistralProvider(config, client: http),
    ai.AIProvider.xai => _XaiProvider(config, client: http),
    ai.AIProvider.deepseek => _DeepSeekProvider(config, client: http),
    ai.AIProvider.openrouter => _OpenRouterProvider(config, client: http),
    ai.AIProvider.anthropic => _AnthropicProvider(config, client: http),
    ai.AIProvider.googleAI => ai.GoogleAIProvider(config, client: http),
    ai.AIProvider.ollama => ai.OllamaProvider(config, client: http),
  };
}

// ════════════════════════════════════════════════════════════════════════
// 上下文
// ════════════════════════════════════════════════════════════════════════

/// 不做滑窗裁剪的上下文管理器。
///
/// SDK 的 ContextManager 在每次 add / get 时按「最早一条 user + 紧随其后的
/// assistant」成对删除消息。它的估算只看纯文本（工具结果、图片都不算），对
/// 中文又严重低估，于是长工具链里它可能把**本轮的用户消息**或某次
/// assistant(tool_calls) 删掉，留下孤立的 tool 消息 —— 供应商直接 400，对话
/// 看起来就是「聊着聊着断了」。请求侧的历史预算由页面的
/// `requestHistoryIndices` 负责（按完整回合裁剪），这里保证装进来的消息
/// 原样发出去。顺带省掉 SDK 每加一条消息就全量重估 token 的 O(n²) 开销。
class UntrimmedAiContext extends ai.ContextManager {
  UntrimmedAiContext({super.systemPrompt})
    : super(maxTokens: 0x3fffffff, reservedTokens: 0);

  @override
  void addMessage(ai.Message message) => conversation.addMessage(message);

  /// 发送前修复工具调用顺序：悬空 tool_call / 孤立 tool 结果会让整个请求 400，
  /// 之后每一次发送都失败（对话「断掉」）。
  @override
  List<ai.Message> getMessagesForRequest() =>
      repairToolMessageSequence(conversation.allMessages);
}

/// 构造 assistant 上下文消息；正文为空时不带空 text 块。
///
/// `ai.Message.assistant('', toolCalls: …)` 会带一个空的 TextContent，
/// Anthropic 协议下序列化成空白 text 块并被拒绝（见 [sanitizeAiRequestBody]）。
ai.Message aiAssistantMessage(
  String text, {
  List<ai.ToolCallContent> toolCalls = const [],
}) => ai.Message(
  role: ai.MessageRole.assistant,
  content: text.trim().isEmpty
      ? const <ai.Content>[]
      : <ai.Content>[ai.TextContent(text)],
  toolCalls: toolCalls.isEmpty ? null : toolCalls,
);

String? _toolResultId(ai.Message message) {
  for (final content in message.content) {
    if (content is ai.ToolResultContent) return content.toolCallId;
  }
  return null;
}

bool _hasVisibleContent(ai.Message message) => message.content.any(
  (content) => content is! ai.TextContent || content.text.trim().isNotEmpty,
);

/// 修复工具调用消息序列，保证发给供应商的上下文结构合法。
///
/// OpenAI / Anthropic 都要求：assistant 的每个 tool_call 后面必须**紧跟**对应
/// 的 tool 结果，tool 结果前面必须有发起它的 assistant 消息；否则整个请求
/// 400。历史里出现悬空调用的途径不少：用户在工具执行期间按了停止（结果气泡
/// 被回滚，tool_use 块还留在上一条消息里）、`ask_user` 只生成提问气泡而没有
/// tool_result 块、老版本存档等等。一旦出现，这个会话之后的**每一次**发送
/// 都会失败 —— 对话就此「断掉」。
///
/// 规则：
///  * assistant(tool_calls) 只保留后面紧跟着结果的调用；一个都不剩时退化成
///    普通 assistant 消息，没有正文则整条丢弃；
///  * 没有对应调用的孤立 tool 消息丢弃；
///  * 其余消息原样保留，顺序不变。
List<ai.Message> repairToolMessageSequence(List<ai.Message> messages) {
  final out = <ai.Message>[];
  var i = 0;
  while (i < messages.length) {
    final message = messages[i];
    if (message.role == ai.MessageRole.tool) {
      i++;
      continue;
    }
    final calls = message.toolCalls;
    if (message.role != ai.MessageRole.assistant ||
        calls == null ||
        calls.isEmpty) {
      out.add(message);
      i++;
      continue;
    }
    final results = <String, ai.Message>{};
    var end = i + 1;
    while (end < messages.length && messages[end].role == ai.MessageRole.tool) {
      final id = _toolResultId(messages[end]);
      if (id != null) results.putIfAbsent(id, () => messages[end]);
      end++;
    }
    final answered = [
      for (final call in calls)
        if (results.containsKey(call.id)) call,
    ];
    if (answered.length == calls.length) {
      out.add(message);
    } else if (answered.isNotEmpty || _hasVisibleContent(message)) {
      out.add(
        ai.Message(
          role: ai.MessageRole.assistant,
          content: message.content,
          toolCalls: answered.isEmpty ? null : answered,
        ),
      );
    }
    for (final call in answered) {
      out.add(results[call.id]!);
    }
    i = end;
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════
// 文本工具协议
// ════════════════════════════════════════════════════════════════════════

/// 文本协议里的一次工具调用：`[TOOL_CALL:action|arg1|arg2]`。
typedef AiTextToolCall = ({String action, List<String> arguments});

final RegExp _textToolMarker = RegExp(r'\[TOOL_CALL:([^\]\n]+)\]');
final RegExp _textToolMarkerLine = RegExp(
  r'^(?:\[TOOL_CALL:[^\]\n]+\]\s*)+$',
);
final RegExp _textToolAction = RegExp(r'^[a-z][a-z0-9_]*$');

bool _isFenceLine(String trimmedLine) =>
    trimmedLine.startsWith('```') || trimmedLine.startsWith('~~~');

/// 一行（已 trim）上可执行的调用；不是「整行只有标记」或含非法动作名时为空。
List<AiTextToolCall> _textToolCallsOnLine(String line) {
  if (!_textToolMarkerLine.hasMatch(line)) return const [];
  final calls = <AiTextToolCall>[];
  for (final match in _textToolMarker.allMatches(line)) {
    final parts = match.group(1)!.split('|');
    final action = parts.first.trim();
    if (!_textToolAction.hasMatch(action)) return const [];
    calls.add((
      action: action,
      arguments: [for (final part in parts.skip(1)) part.trim()],
    ));
  }
  return calls;
}

/// 解析正文里**独占一行**的 `[TOOL_CALL:…]` 标记。
///
/// 不支持函数调用的模型 / 网关只能用文本标记调工具。为了不把「向用户解释
/// 标记语法」误当成调用，只认代码围栏之外、整行只有标记的写法；行内出现的、
/// 反引号里的、列表项里的标记一律不执行。
List<AiTextToolCall> parseTextToolCalls(String text, {int maxCalls = 16}) {
  final calls = <AiTextToolCall>[];
  var fenced = false;
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (_isFenceLine(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    for (final call in _textToolCallsOnLine(line)) {
      calls.add(call);
      if (calls.length >= maxCalls) return calls;
    }
  }
  return calls;
}

/// 去掉 [parseTextToolCalls] 会执行的那些标记行，其余正文原样保留。
String stripTextToolCalls(String text) {
  final kept = <String>[];
  var fenced = false;
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (_isFenceLine(line)) {
      fenced = !fenced;
    } else if (!fenced && _textToolCallsOnLine(line).isNotEmpty) {
      continue;
    }
    kept.add(rawLine);
  }
  return kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// 把文本协议的调用包装成与原生函数调用同构的 [ai.ToolCallContent]。
///
/// 这样后面的执行、UI 卡片配对、历史重建都只有一条路径：模型用文本标记还是
/// 原生函数调用，对其余代码没有区别。
List<ai.ToolCallContent> textToolCallsToSdk(
  List<AiTextToolCall> calls, {
  required String toolName,
}) {
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return [
    for (var i = 0; i < calls.length; i++)
      ai.ToolCallContent(
        id: 'call_t$stamp$i',
        name: toolName,
        arguments: {
          'action': calls[i].action,
          'arguments': calls[i].arguments,
        },
      ),
  ];
}
