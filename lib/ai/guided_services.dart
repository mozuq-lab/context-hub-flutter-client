import 'claude_client.dart';
import '../storage/secret_store.dart';

/// 選んで深掘りが端末の外や保管場所とやり取りするもの。
/// テストでは偽物に差し替え、実際の通信やAPIキーの保管をしない。
class GuidedServices {
  GuidedServices({
    required this.model,
    required this.secrets,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// 実際のClaude APIと、端末の安全な保管場所を使う。
  factory GuidedServices.native() =>
      GuidedServices(model: ClaudeClient(), secrets: NativeSecretStore());

  final ModelClient model;
  final SecretStore secrets;

  /// 今月の利用回数を数えるための時刻。
  final DateTime Function() clock;
}
