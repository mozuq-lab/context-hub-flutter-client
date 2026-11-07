import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/guided.dart';

/// モデルの応答。[text]は出力本文（構造化出力のJSON）、[model]は実際に応答したモデル。
class ModelReply {
  const ModelReply({
    required this.text,
    required this.model,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });
  final String text, model;
  final int inputTokens, outputTokens;
}

/// 利用者に示せる失敗。本文にAPIキーや送った内容は含めない。
class ModelException implements Exception {
  const ModelException(
    this.message, {
    this.retryable = false,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });
  final String message;

  /// 時間をおけば成功しうるか（混雑・通信断・応答なし）。
  final bool retryable;

  /// 断られた・途中で止まった応答でも使ったトークン（利用の記録用）。
  final int inputTokens, outputTokens;
  @override
  String toString() => message;
}

abstract class ModelClient {
  Future<ModelReply> send(GuidedPrompt prompt, {required String apiKey});

  /// 実行中の依頼を打ち切る。打ち切った依頼はModelExceptionで終わる。
  void abort();
}

class HttpReply {
  const HttpReply(this.status, this.body);
  final int status;
  final String body;
}

/// HTTPの送受信。テストでは偽物に差し替え、実際の通信をしない。
abstract class HttpTransport {
  Future<HttpReply> post(
    Uri url,
    Map<String, String> headers,
    String body,
    Duration timeout,
  );
  void abort();
}

/// dart:ioで送る。応答は1MiBまで読む。
class IoHttpTransport implements HttpTransport {
  static const maxResponse = 1 << 20;
  final _active = <HttpClient>{};

  @override
  Future<HttpReply> post(
    Uri url,
    Map<String, String> headers,
    String body,
    Duration timeout,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    _active.add(client);
    try {
      return await () async {
        final request = await client.postUrl(url);
        headers.forEach(request.headers.set);
        request.add(utf8.encode(body));
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxResponse) {
            throw const ModelException('応答が大きすぎます。');
          }
          bytes.addAll(chunk);
        }
        return HttpReply(
          response.statusCode,
          utf8.decode(bytes, allowMalformed: true),
        );
      }().timeout(timeout);
    } on ModelException {
      rethrow;
    } on TimeoutException {
      throw const ModelException(
        'Claudeから応答がありませんでした。通信状況を確かめて、もう一度試してください。',
        retryable: true,
      );
    } on IOException {
      throw const ModelException(
        'Claude APIに接続できませんでした。ネットワークを確かめて、もう一度試してください。',
        retryable: true,
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
  static Map<String, Object?> body(GuidedPrompt p) => {
    'model': guidedModel,
    'max_tokens': p.maxTokens,
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
    'fallbacks': 'default',
  };

  static Map<String, String> headers(String apiKey) => {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': apiVersion,
    'anthropic-beta': fallbackBeta,
  };

  @override
  void abort() => transport.abort();

  @override
  Future<ModelReply> send(GuidedPrompt prompt, {required String apiKey}) async {
    final reply = await transport.post(
      endpoint,
      headers(apiKey),
      jsonEncode(body(prompt)),
      prompt.timeout,
    );
    if (reply.status != 200) throw _statusError(reply);
    final Object? value;
    try {
      value = jsonDecode(reply.body);
    } on FormatException {
      throw const ModelException(
        'Claudeの応答を読めませんでした。もう一度試してください。',
        retryable: true,
      );
    }
    if (value is! Map) {
      throw const ModelException(
        'Claudeの応答を読めませんでした。もう一度試してください。',
        retryable: true,
      );
    }
    final (input, output) = _usage(value['usage']);
    final stop = value['stop_reason'];
    if (stop == 'refusal') {
      throw ModelException(
        'Claudeがこの内容への応答を控えました。きっかけや回答の言い方を変えて試してください。',
        inputTokens: input,
        outputTokens: output,
      );
    }
    if (stop == 'max_tokens') {
      throw ModelException(
        '出力が上限に達して途中で止まりました。もう一度試してください。',
        retryable: true,
        inputTokens: input,
        outputTokens: output,
      );
    }
    final content = value['content'];
    final text = content is List
        ? content
              .whereType<Map>()
              .where((b) => b['type'] == 'text' && b['text'] is String)
              .map((b) => b['text'] as String)
              .join()
        : '';
    if (text.trim().isEmpty) {
      throw ModelException(
        'Claudeの応答が空でした。もう一度試してください。',
        retryable: true,
        inputTokens: input,
        outputTokens: output,
      );
    }
    final model = value['model'];
    return ModelReply(
      text: text,
      model: model is String && RegExp(r'^[a-z0-9.\-]{1,100}$').hasMatch(model)
          ? model
          : guidedModel,
      inputTokens: input,
      outputTokens: output,
    );
  }

  /// 使ったトークン（入力はキャッシュの書込・読取を含む）。サーバー側の代替が働いたときは、
  /// 最上位の値は返した応答の分だけなので、試行ごとの内訳（iterations）を合計する。
  static (int, int) _usage(Object? raw) {
    if (raw is! Map) return (0, 0);
    int count(Map m, String key) => m[key] is int ? m[key] as int : 0;
    (int, int) of(Map m) => (
      count(m, 'input_tokens') +
          count(m, 'cache_creation_input_tokens') +
          count(m, 'cache_read_input_tokens'),
      count(m, 'output_tokens'),
    );
    final parts = raw['iterations'];
    if (parts is List && parts.whereType<Map>().isNotEmpty) {
      var input = 0, output = 0;
      for (final part in parts.whereType<Map>()) {
        final (i, o) = of(part);
        input += i;
        output += o;
      }
      return (input, output);
    }
    return of(raw);
  }

  static ModelException _statusError(HttpReply reply) {
    String type = '';
    try {
      final value = jsonDecode(reply.body);
      final error = value is Map ? value['error'] : null;
      if (error is Map && error['type'] is String) {
        type = error['type'] as String;
      }
    } catch (_) {
      // 本文が読めなくても状態コードで案内する。
    }
    final code = type.isEmpty || !RegExp(r'^[a-z_]{1,60}$').hasMatch(type)
        ? '${reply.status}'
        : '${reply.status} $type';
    return switch (reply.status) {
      400 => ModelException(
        'Claude APIが依頼を受け付けませんでした（$code）。アプリを更新するか、内容を短くして試してください。',
      ),
      401 => ModelException('APIキーが無効です（$code）。AIの設定でAPIキーを確かめてください。'),
      402 => ModelException('Anthropicの支払いまたは利用枠を確かめてください（$code）。'),
      403 => ModelException(
        'このAPIキーでは使えません（$code）。Anthropicのワークスペースの設定を確かめてください。',
      ),
      404 => ModelException('モデル $guidedModel が見つかりません（$code）。'),
      413 => ModelException('送る内容が大きすぎます（$code）。資料を送らずに試してください。'),
      429 => ModelException(
        '呼び出しが多すぎます（$code）。少し待ってから試してください。',
        retryable: true,
      ),
      500 || 502 || 503 || 504 || 529 => ModelException(
        'Claudeが混み合っているか、一時的に使えません（$code）。少し待ってから試してください。',
        retryable: true,
      ),
      _ => ModelException('Claude APIの呼び出しに失敗しました（$code）。'),
    };
  }
}
