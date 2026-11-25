import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../storage/capture_service.dart';
import '../parts.dart';
import '../save_checks.dart';
import '../shortcuts.dart';

Future<void> showCorrection(
  BuildContext context,
  HubController c,
  String recordId,
  HubRecord latest,
) async {
  if (c.composing) return;
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          CorrectionDialog(controller: c, recordId: recordId, latest: latest),
    );
  } finally {
    c.composing = false;
  }
}

/// 元のメモを残したまま、訂正後の全文を新しい入力として送るフォーム。
class CorrectionDialog extends StatefulWidget {
  const CorrectionDialog({
    super.key,
    required this.controller,
    required this.recordId,
    required this.latest,
  });
  final HubController controller;
  final String recordId;

  /// 訂正チェーンの最新の記録。本文を下書きにし、この入力IDを訂正対象にする。
  final HubRecord latest;
  @override
  State<CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<CorrectionDialog> {
  late final text = TextEditingController(text: widget.latest.body.trimRight());
  final operation = const Uuid().v4();

  /// 本人が追加した行動の文面を直す。行動と同じく1行・200文字以内にする。
  late final bool action =
      widget.controller.repository
          ?.correctionChainOf(widget.recordId)
          ?.first
          .kind ==
      'action';
  String? error;
  CaptureResult? result;
  bool busy = false;

  /// 新しい訂正が届いて、この下書きの訂正対象が古くなった。保存は出さず、閉じて開き直してもらう。
  bool targetChanged = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (action && !validActionText(text.text)) {
      setState(
        () => error = '行動の文面は1行・$actionTextChars文字以内で、前後に空白を付けずに入力してください。',
      );
      return;
    }
    if (text.text.trim().isEmpty || text.text.length > 8000) {
      setState(() => error = '訂正文は1〜8000文字で入力してください。');
      return;
    }
    final checked = await checkSecretsBeforeSave(
      context,
      text.text,
      secrets: widget.controller.repository?.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (checked != text.text) {
      if (checked.length > 8000) {
        setState(() => error = '伏せ字にすると8000文字を超えます。訂正文を短くしてください。');
        return;
      }
      if (action && !validActionText(checked)) {
        setState(() => error = '伏せ字にすると$actionTextChars文字を超えます。文面を短くしてください。');
        return;
      }
      text.text = checked;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await widget.controller.requestCorrection(
        operation,
        widget.recordId,
        widget.latest.sourceId,
        text.text,
      );
      if (mounted) setState(() => result = r);
    } catch (e) {
      // 保存前に止まった場合は、本文を直してもう一度保存できる。
      if (mounted) {
        setState(() {
          error = HubController.message(e);
          targetChanged = e is CorrectionTargetChanged;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    setState(() => busy = true);
    try {
      final r = await widget.controller.confirm(operation);
      if (mounted) setState(() => result = r);
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = result != null;
    // ⌘Return（Ctrl+Enter）で「訂正を保存」と同じ操作をする。
    return CallbackShortcuts(
      bindings: {
        saveFormActivator: () {
          if (!busy && !locked && !targetChanged) submit();
        },
        // Escは、訂正文を書き換えていない（変換中でもない）ときだけ「フォームを閉じる」と同じ操作をする。
        // 書きかけの訂正を誤って捨てないため。
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!busy &&
              !text.value.composing.isValid &&
              text.text == widget.latest.body.trimRight()) {
            Navigator.pop(context);
          }
        },
      },
      // Mac以外では入力欄が自動で選ばれないため、開いた直後からキーが届くよう受け口を置く（ソフトキーボードは開かない）。
      child: Focus(
        autofocus: !usesCommandKey,
        skipTraversal: true,
        child: PopScope(
          canPop: !busy,
          child: HubAlertDialog(
            title: Text(action ? '行動の文面を直す' : 'メモを訂正する'),
            onClose: busy ? null : () => Navigator.pop(context),
            content: SizedBox(
              width: 620,
              child: DialogScroll(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '訂正対象: ${widget.latest.sourceId}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      action
                          ? '直した後の文面を1行で書いてください。元の文面は原文に残ります。Mac miniで処理されると現状の次の一手が直した文面になります。付けた日付は直した後の行動に引き継がれます。'
                          : '訂正後の全文を書いてください。元のメモは残り、訂正として追加されます。Mac miniのAIが読み取るまで、要約や現状は訂正前の内容のままです。',
                      style: noteStyle(context),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('correction-text'),
                      controller: text,
                      // Macではキーボードで開いたまま書けるよう、本文へ移る。
                      autofocus: usesCommandKey,
                      readOnly: locked || busy,
                      minLines: action ? 1 : 5,
                      maxLines: action ? 1 : 12,
                      // 行動の文面は本体と同じ数え方（UTF-16の単位）で示し、保存の前に確かめる。
                      maxLength: action ? null : 8000,
                      decoration: InputDecoration(
                        alignLabelWithHint: true,
                        counterText: action
                            ? '${text.text.length} / $actionTextChars'
                            : null,
                      ),
                      onChanged: action ? (_) => setState(() {}) : null,
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: NoticeBox(error!, error: true),
                      ),
                    if (result != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: NoticeBox(
                          result!.saved
                              ? 'この端末に訂正を保存しました'
                              : '保存確認待ちです。再送せず同じ操作を確認してください。',
                        ),
                      ),
                    if (locked)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          '操作ID: $operation',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(result?.saved == true ? '閉じる' : 'フォームを閉じる'),
              ),
              if (!locked && !targetChanged)
                FilledButton(
                  key: const Key('save-correction'),
                  onPressed: busy ? null : submit,
                  child: const Text('訂正を保存'),
                ),
              if (locked && result?.saved != true)
                FilledButton(
                  onPressed: busy ? null : confirm,
                  child: const Text('同じ操作を確認'),
                ),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
