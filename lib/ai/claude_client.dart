import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/guided.dart';
import '../core/secrets.dart' show redactSecrets;

/// モデルの応答。[text]は出力本文（構造化出力のJSON）、[model]は実際に応答したモデル。
/// [usage]はモデルごとの種類別のトークン数（安全上の理由で代わりのモデルが答えたときは両方）。
class ModelReply {
  ModelReply({
    required this.text,
    required this.model,
    Map<String, TokenUsage>? usage,
    int inputTokens = 0,
    int outputTokens = 0,
  }) : usage =
           usage ??
           {
             if (inputTokens > 0 || outputTokens > 0)
               model: TokenUsage(input: inputTokens, output: outputTokens),
           };
  final String text, model;
  final Map<String, TokenUsage> usage;
  int get inputTokens => usage.values.fold(0, (n, u) => n + u.allInput);
  int get outputTokens => usage.values.fold(0, (n, u) => n + u.output);
}

/// 利用者に示せる失敗。本文にAPIキーや送った内容は含めない。
class ModelException implements Exception {
  const ModelException(
    this.message, {
    this.retryable = false,
    this.usage = const {},
    this.costUncertain = false,
  });
  final String message;

  /// 時間をおけば成功しうるか（混雑・通信断・応答なし）。
  final bool retryable;

  /// 断られた・途中で止まった応答でも使ったトークン（利用の記録用）。
  final Map<String, TokenUsage> usage;

  /// 依頼は届いたが、応答が途中で途切れて使ったトークンを最後まで受け取れなかったか。
  /// サーバー側では処理が進み、費用がかかっている可能性がある。
  final bool costUncertain;

  int get inputTokens => usage.values.fold(0, (n, u) => n + u.allInput);
  int get outputTokens => usage.values.fold(0, (n, u) => n + u.output);

  ModelException _with(Map<String, TokenUsage> used, {bool? uncertain}) =>
      ModelException(
        message,
        retryable: retryable,
        usage: addUsage(usage, used),
        costUncertain: uncertain ?? costUncertain,
      );

  @override
  String toString() => message;
}

abstract class ModelClient {
  Future<ModelReply> send(GuidedPrompt prompt, {required String apiKey});

  /// 実行中の依頼を打ち切る。打ち切った依頼はModelExceptionで終わる。
  void abort();
}

/// HTTPの応答。成功（200）で[HttpTransport.post]に`onData`を渡したときは、本文は`onData`へ
/// 少しずつ渡し、[body]は空にする。[headers]は名前を小文字にした応答ヘッダー（必要なものだけ）。
class HttpReply {
  const HttpReply(this.status, this.body, {this.headers = const {}});
  final int status;
  final String body;
  final Map<String, String> headers;
}

/// HTTPの送受信。テストでは偽物に差し替え、実際の通信をしない。
abstract class HttpTransport {
  /// [idle]の間データが届かない、または[total]を超えたら、ModelException（retryable）で終える。
  /// 依頼を送った後に途切れたときは、`costUncertain`をtrueにする。
  Future<HttpReply> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    required Duration idle,
    required Duration total,
    void Function(String chunk)? onData,
  });
  void abort();
}

/// dart:ioで送る。成功の応答を少しずつ受け取るとき（SSE）は、イベントの包みやpingも届くため
/// [maxStream]まで読む（本文そのものの上限は受け取る側で数える）。それ以外の応答は[maxResponse]まで。
class IoHttpTransport implements HttpTransport {
  static const maxResponse = 1 << 20, maxStream = 16 << 20;

  /// 読み取る応答ヘッダー。混雑時に待つ秒数と、問い合わせに使う依頼ID。
  static const keptHeaders = ['retry-after', 'request-id'];
  final _active = <HttpClient>{};

  @override
  Future<HttpReply> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    required Duration idle,
    required Duration total,
    void Function(String chunk)? onData,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    _active.add(client);
    var sent = false;
    try {
      return await () async {
        final request = await client.postUrl(url);
        headers.forEach(request.headers.set);
        request.add(utf8.encode(body));
        final pending = request.close();
        sent = true;
        final response = await pending.timeout(idle);
        final kept = <String, String>{
          for (final name in keptHeaders)
            if (response.headers.value(name) case final String v) name: v,
        };
        final streaming = response.statusCode == 200 && onData != null;
        final out = StringBuffer();
        var size = 0;
        // 一定の間何も届かなければ途切れたとみなす（考えている間もpingが届く）。
        await for (final chunk
            in response
                .timeout(idle)
                .cast<List<int>>()
                .transform(utf8.decoder)) {
          size += chunk.length;
          if (size > (streaming ? maxStream : maxResponse)) {
            throw const ModelException('応答が大きすぎます。', costUncertain: true);
          }
          if (streaming) {
            onData(chunk);
          } else {
            out.write(chunk);
          }
        }
        return HttpReply(
          response.statusCode,
          streaming ? '' : out.toString(),
          headers: kept,
        );
      }().timeout(total);
    } on ModelException {
      rethrow;
    } on TimeoutException {
      throw ModelException(
        sent
            ? 'Claudeからの応答が途中で途切れました。通信状況を確かめて、もう一度試してください。'
            : 'Claudeから応答がありませんでした。通信状況を確かめて、もう一度試してください。',
        retryable: true,
        costUncertain: sent,
      );
    } on IOException {
      throw ModelException(
        sent
            ? 'Claude APIとの通信が途中で切れました。ネットワークを確かめて、もう一度試してください。'
            : 'Claude APIに接続できませんでした。ネットワークを確かめて、もう一度試してください。',
        retryable: true,
        costUncertain: sent,
      );
    } on Exception {
      // UTF-8として読めない応答など。送った後なら、費用が発生した可能性がある。
      throw ModelException(
        'Claudeの応答を読めませんでした。もう一度試してください。',
        retryable: true,
        costUncertain: sent,
      );
    } finally {
      _active.remove(client);
      client.close(force: true);
    }
  }

  @override
  void abort() {
    for (final client in _active.toList()) {
      client.close(force: true);
    }
  }
}

/// Server-Sent Eventsで届くMessages APIの応答を読み、本文・応答したモデル・使ったトークンを集める。
/// 途中で途切れても、それまでに届いた使用量（message_startの入力など）を返せるようにする。
class _StreamReader {
  _StreamReader(this.requested);

  /// 依頼したモデル。代わりのモデルが答えたときの内訳の振り分けに使う。
  final String requested;

  /// 本文（textのブロック）の上限。包み（SSEのイベント・ping）は数えない。
  static const maxText = 1 << 20;
  final _line = StringBuffer(), _data = StringBuffer();
  String? startModel, stopReason;
  Map? stopDetails, error;
  bool started = false, stopped = false;

  /// 代わりのモデルへの切替（fallbackのブロック）の順の、断ったモデルと続けたモデル。
  final _switches = <(String?, String?)>[];

  /// 届いた使用量。message_startの値に、message_deltaで届いた値（累計）を項目ごとに重ねる。
  /// nullの項目は重ねない（届いていない項目の値を消さない）。
  final _usage = <String, Object>{};
  final _texts = <int, StringBuffer>{};
  int _textSize = 0;

  String get text => [
    for (final k in _texts.keys.toList()..sort()) _texts[k]!.toString(),
  ].join();

  /// 応答したモデル。出力の途中で代わりのモデルに替わると、message_startは依頼したモデルのまま
  /// で、fallbackのブロックの`to`が替わった先を示す。
  String get model => _switches.isNotEmpty && _switches.last.$2 != null
      ? _switches.last.$2!
      : startModel ?? requested;

  /// 行ごとに読む。受け取った文字列を行の終わりまでだけ見て、残りを毎回写し直さない。
  void add(String chunk) {
    var from = 0;
    while (true) {
      final at = chunk.indexOf('\n', from);
      if (at < 0) {
        _line.write(chunk.substring(from));
        return;
      }
      _line.write(chunk.substring(from, at));
      from = at + 1;
      var line = _line.toString();
      _line.clear();
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) {
        _dispatch();
      } else if (line.startsWith('data:')) {
        if (_data.isNotEmpty) _data.write('\n');
        _data.write(line.substring(5).trimLeft());
      }
      // event:行は、dataの中のtypeで判断するので読まない。ping・コメントも読み飛ばす。
    }
  }

  void close() {
    if (_line.isNotEmpty) add('\n');
    _dispatch();
  }

  void _overlay(Object? usage) {
    if (usage is! Map) return;
    for (final e in usage.entries) {
      final v = e.value;
      if (e.key is String &&
          (v is int || (e.key == 'iterations' && v is List))) {
        _usage[e.key as String] = v as Object;
      }
    }
  }

  static String? _modelOf(Object? value) =>
      value is Map && value['model'] is String
      ? value['model'] as String
      : null;

  void _dispatch() {
    if (_data.isEmpty) return;
    final raw = _data.toString();
    _data.clear();
    final Object? event;
    try {
      event = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (event is! Map) return;
    switch (event['type']) {
      case 'message_start':
        final m = event['message'];
        if (m is Map) {
          started = true;
          if (m['model'] is String) startModel = m['model'] as String;
          _overlay(m['usage']);
        }
      case 'content_block_start':
        final index = event['index'], block = event['content_block'];
        if (block is Map && block['type'] == 'fallback') {
          _switches.add((_modelOf(block['from']), _modelOf(block['to'])));
        } else if (index is int && block is Map && block['type'] == 'text') {
          final first = block['text'] is String ? block['text'] as String : '';
          _grow(first.length);
          _texts[index] = StringBuffer(first);
        }
      case 'content_block_delta':
        final index = event['index'], delta = event['delta'];
        if (index is int &&
            delta is Map &&
            delta['type'] == 'text_delta' &&
            delta['text'] is String) {
          final piece = delta['text'] as String;
          _grow(piece.length);
          _texts[index]?.write(piece);
        }
      case 'message_delta':
        final delta = event['delta'];
        if (delta is Map) {
          if (delta['stop_reason'] is String) {
            stopReason = delta['stop_reason'] as String;
          }
          if (delta['stop_details'] is Map) {
            stopDetails = delta['stop_details'] as Map;
          }
        }
        _overlay(event['usage']);
      case 'message_stop':
        stopped = true;
      case 'error':
        if (event['error'] is Map) error = event['error'] as Map;
    }
  }

  void _grow(int n) {
    _textSize += n;
    if (_textSize > maxText) {
      throw const ModelException('応答が大きすぎます。', costUncertain: true);
    }
  }

  /// モデルごとの種類別のトークン数。
  ///
  /// サーバー側の代替が働いたときは、試行ごとの内訳（iterations）を使う。代わりのモデルの試行
  /// （fallback_message）は応答したモデル、断られた試行（message）は、fallbackのブロックの`from`を
  /// 順に当てる（ブロックがなければ依頼したモデル）。試行にモデル名があれば、それを使う。
  Map<String, TokenUsage> get usage {
    int count(Map m, String key) =>
        m[key] is int && (m[key] as int) > 0 ? m[key] as int : 0;
    TokenUsage of(Map m) => TokenUsage(
      input: count(m, 'input_tokens'),
      cacheWrite: count(m, 'cache_creation_input_tokens'),
      cacheRead: count(m, 'cache_read_input_tokens'),
      output: count(m, 'output_tokens'),
    );
    final served = model;
    final declined = [for (final (from, _) in _switches) from ?? requested];
    final parts = _usage['iterations'];
    if (parts is List && parts.whereType<Map>().isNotEmpty) {
      var result = <String, TokenUsage>{};
      var refused = 0;
      for (final part in parts.whereType<Map>()) {
        final String who;
        if (part['model'] is String) {
          who = part['model'] as String;
        } else if (part['type'] == 'fallback_message') {
          who = served;
        } else {
          who = refused < declined.length
              ? declined[refused]
              : declined.isEmpty
              ? requested
              : declined.last;
          refused++;
        }
        result = addUsage(result, {who: of(part)});
      }
      return result;
    }
    final total = of(_usage);
    return total.isEmpty ? const {} : {served: total};
  }
}

/// Claude API（Messages API）を直接呼ぶ。SDKはDartにないためHTTPで送る。
class ClaudeClient implements ModelClient {
  ClaudeClient({HttpTransport? transport})
    : transport = transport ?? IoHttpTransport();
  final HttpTransport transport;
  static final endpoint = Uri.parse('https://api.anthropic.com/v1/messages');
  static const apiVersion = '2026-10-21';

  /// 安全上の理由で断られた依頼を、別のモデルで自動的にやり直す（サーバー側の代替）。
  static const fallbackBeta = 'server-side-fallback-2026-07-01';

  /// 送る本文。資料のブロックにキャッシュの印を付け、2問目以降は同じ前半を再利用できるようにする。
  /// 応答は少しずつ受け取り（stream）、途中で途切れても使ったトークンを数えられるようにする。
  /// Haikuにはサーバー側の代替がないため、`fallbacks`もベータの指定も付けない。
  static Map<String, Object?> body(GuidedPrompt p) => {
    'model': p.model,
    'max_tokens': p.maxTokens,
    'stream': true,
    'system': p.system,
    'messages': [
      {
        'role': 'user',
        'content': [
          {
            'type': 'text',
            'text': p.context,
            'cache_control': {'type': 'ephemeral'},
          },
          {'type': 'text', 'text': p.turn},
        ],
      },
    ],
    'output_config': {
      'effort': p.effort,
      'format': {'type': 'json_schema', 'schema': p.schema},
    },
    if (guidedModelChoice(p.model).fallback) 'fallbacks': 'default',
  };

  static Map<String, String> headers(String apiKey, {String model = guidedModel}) => {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': apiVersion,
    if (guidedModelChoice(model).fallback) 'anthropic-beta': fallbackBeta,
  };

  @override
  void abort() => transport.abort();

  static const _uncertainNote =
      '送った依頼の分の費用がかかっている可能性があります（今月の利用には、受け取れた分だけを数えました）。';

  @override
  Future<ModelReply> send(GuidedPrompt prompt, {required String apiKey}) async {
    final reader = _StreamReader(prompt.model);
    final HttpReply reply;
    try {
      reply = await transport.post(
        endpoint,
        headers(apiKey, model: prompt.model),
        jsonEncode(body(prompt)),
        idle: prompt.idleTimeout,
        total: prompt.timeout,
        onData: reader.add,
      );
    } on ModelException catch (e) {
      reader.close();
      final uncertain = e.costUncertain || reader.started;
      throw ModelException(
        uncertain ? '${e.message}$_uncertainNote' : e.message,
        retryable: e.retryable,
        costUncertain: uncertain,
      )._with(reader.usage);
    }
    if (reply.status != 200) {
      throw _statusError(reply, apiKey, prompt.model);
    }
    reader.close();
    final used = reader.usage;
    final error = reader.error;
    if (error != null) {
      // 応答の途中で届いた失敗（混雑など）。
      final type = '${error['type']}';
      throw ModelException(
        'Claudeが応答の途中で止まりました（${_safeType(type) ?? 'error'}）。少し待ってから試してください。$_uncertainNote',
        retryable: true,
        costUncertain: true,
      )._with(used);
    }
    if (!reader.stopped || reader.stopReason == null) {
      throw ModelException(
        reader.started
            ? 'Claudeからの応答が途中で途切れました。もう一度試してください。$_uncertainNote'
            : 'Claudeの応答を読めませんでした。もう一度試してください。',
        retryable: true,
        costUncertain: reader.started,
      )._with(used);
    }
    final stop = reader.stopReason;
    if (stop == 'refusal') {
      // 代わりのモデルが混雑・上限で動けなかったときは、推奨のモデルが示される（言い方の問題ではない）。
      if (reader.stopDetails?['recommended_model'] is String) {
        throw const ModelException(
          'Claudeがこの内容への応答を控え、代わりに答えるモデルが混み合っていて使えませんでした。少し待ってから試してください。',
          retryable: true,
        )._with(used);
      }
      throw const ModelException(
        'Claudeがこの内容への応答を控えました。きっかけや回答の言い方を変えて試してください。',
      )._with(used);
    }
    if (stop == 'max_tokens') {
      throw const ModelException(
        '出力が上限に達して途中で止まりました。もう一度試してください。',
        retryable: true,
      )._with(used);
    }
    final text = reader.text;
    if (text.trim().isEmpty) {
      throw const ModelException(
        'Claudeの応答が空でした。もう一度試してください。',
        retryable: true,
      )._with(used);
    }
    final model = reader.model;
    return ModelReply(
      text: text,
      model: _modelName.hasMatch(model) ? model : prompt.model,
      usage: {
        for (final e in used.entries)
          (_modelName.hasMatch(e.key) ? e.key : prompt.model): e.value,
      },
    );
  }

  static final _modelName = RegExp(r'^[a-z0-9.\-]{1,100}$');

  static String? _safeType(String type) =>
      RegExp(r'^[a-z_]{1,60}$').hasMatch(type) ? type : null;

  /// 依頼IDの形（問い合わせに使う。秘密ではない）。
  static final _requestId = RegExp(r'^[A-Za-z0-9_\-]{1,100}$');

  static ModelException _statusError(
    HttpReply reply,
    String apiKey,
    String model,
  ) {
    String type = '', detail = '', requestId = '';
    try {
      final value = jsonDecode(reply.body);
      final error = value is Map ? value['error'] : null;
      if (error is Map && error['type'] is String) {
        type = _safeType(error['type'] as String) ?? '';
      }
      if (error is Map && error['message'] is String) {
        detail = error['message'] as String;
      }
      if (value is Map && value['request_id'] is String) {
        requestId = value['request_id'] as String;
      }
    } catch (_) {
      // 本文が読めなくても状態コードで案内する。
    }
    final header = reply.headers['request-id'];
    if (requestId.isEmpty && header != null) requestId = header;
    if (!_requestId.hasMatch(requestId)) requestId = '';
    final code = [
      '${reply.status}',
      if (type.isNotEmpty) type,
      if (requestId.isNotEmpty) 'request-id: $requestId',
    ].join(' ');
    // 待つ秒数（retry-afterは秒）。長すぎる・読めない値は示さない。
    final wait = int.tryParse(reply.headers['retry-after']?.trim() ?? '');
    final after = wait != null && wait > 0 && wait <= 3600
        ? '約$wait秒待ってから'
        : '少し待ってから';
    return switch (reply.status) {
      400 => ModelException(
        'Claude APIが依頼を受け付けませんでした（$code）。${_detail(detail, apiKey)}アプリを更新するか、内容を短くして試してください。',
      ),
      401 => ModelException('APIキーが無効です（$code）。AIの設定でAPIキーを確かめてください。'),
      402 => ModelException('Anthropicの支払いまたは利用枠を確かめてください（$code）。'),
      403 => ModelException(
        'このAPIキーでは使えません（$code）。Anthropicのワークスペースの設定を確かめてください。',
      ),
      404 => ModelException(
        'モデル $model が見つからないか、このAPIキーでは使えません（$code）。AIの設定で別のモデルを選ぶか、提供が終わった場合はアプリを更新してください。',
      ),
      408 || 409 => ModelException(
        'Claude APIが依頼を処理できませんでした（$code）。$after試してください。',
        retryable: true,
      ),
      413 => ModelException('送る内容が大きすぎます（$code）。資料を送らずに試してください。'),
      429 => ModelException(
        '呼び出しが多すぎます（$code）。$after試してください。',
        retryable: true,
      ),
      >= 500 => ModelException(
        'Claudeが混み合っているか、一時的に使えません（$code）。$after試してください。',
        retryable: true,
      ),
      _ => ModelException('Claude APIの呼び出しに失敗しました（$code）。'),
    };
  }

  /// 400の理由。キーらしい文字列を伏せ、1行・短くして示す。送ったAPIキーそのものも消す。
  static String _detail(String message, String apiKey) {
    if (message.trim().isEmpty) return '';
    var text = message;
    if (apiKey.isNotEmpty) text = text.replaceAll(apiKey, '[伏せ字:APIキー]');
    text = redactSecrets(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 160) text = '${text.substring(0, 160)}…';
    return '理由: $text。';
  }
}
