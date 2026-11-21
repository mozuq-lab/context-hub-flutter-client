import 'repository.dart';

/// この端末から保存したメモ・訂正が、どこまで進んだか。
/// 保存（この端末のInput）→ Miniが受付 → 整理済み、の順に進み、受け付けられなかったものは[failed]。
enum CaptureStage { saved, accepted, organized, failed }

/// [requestId]の依頼の段階を、読込済みの受付状況から決める。
///
/// 受付の記録がまだ同期されていなければ[CaptureStage.saved]。受け付けた後の整理済み・整理失敗は、
/// 受付状況と同じく、受け付けて作られた原文の処理記録で決まる。
CaptureStage captureStage(HubRepository repo, String requestId) =>
    switch (repo.intake.where((s) => s.id == requestId).firstOrNull?.state) {
      'accepted' => CaptureStage.accepted,
      'organized' => CaptureStage.organized,
      'failed' || 'rejected' || 'conflict' => CaptureStage.failed,
      _ => CaptureStage.saved,
    };

/// 段階が進んだことの知らせ。
class CaptureNotice {
  const CaptureNotice(this.requestId, this.stage);
  final String requestId;
  final CaptureStage stage;
}

/// 画面下に出す1行と、押したときに開く画面（受付状況・最近のメモ）。
({String text, String page}) captureNoticeText(List<CaptureNotice> notices) {
  int count(CaptureStage s) => notices.where((n) => n.stage == s).length;
  final organized = count(CaptureStage.organized),
      accepted = count(CaptureStage.accepted),
      failed = count(CaptureStage.failed);
  String n(int c) => c == 1 ? '' : '$c件の';
  final parts = [
    if (organized > 0) '${n(organized)}メモをAIが読み取りました',
    if (accepted > 0) '${n(accepted)}メモをMac miniが受け取りました（AIの読み取りはこれから）',
    if (failed > 0) '${n(failed)}メモの受け取りかAIの読み取りがうまくいきませんでした',
  ];
  return (
    text: parts.join('。'),
    page: failed > 0 || organized == 0 ? 'intake' : 'recent',
  );
}
