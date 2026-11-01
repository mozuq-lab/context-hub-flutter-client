import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/ui/review_view.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'policy_test.dart' show scopedFiles;

void main() {
  for (final mode in ['explicit', 'inferred', 'unknown']) {
    testWidgets('採用先の$modeを表示し共通を初期選択しない', (t) async {
      t.view.physicalSize = const Size(1280, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });
      final files = scopedFiles(),
          root = jsonDecode(files['90_system/review/index.json']!) as Map;
      final row =
          (root['items'] as List).firstWhere((i) => i['status'] == 'pending')
              as Map;
      if (mode == 'unknown') {
        row.remove('suggestedTarget');
        row['projectSuggestions'] = [];
      }
      if (mode == 'inferred') {
        for (final p in row['projectSuggestions'] as List) {
          p['source'] = 'inferred';
        }
      }
      files['90_system/review/index.json'] = jsonEncode(root);
      final a = MemoryUIAccess();
      a.current = VaultSnapshot(files);
      final c = HubController(a, sampleLoader: () async => files);
      addTearDown(c.dispose);
      await c.useSample();
      final item = c.review!.pending.single;
      await t.pumpWidget(
        MaterialApp(
          home: ReviewDetail(
            controller: c,
            id: item.id,
            identity: c.location!.identity,
          ),
        ),
      );
      await t.pumpAndSettle();
      final approve = t.widget<FilledButton>(
        find.byKey(const Key('review-approve')),
      );
      expect(approve.onPressed == null, mode == 'unknown');
      expect(
        find.textContaining('採用先は未定'),
        mode == 'unknown' ? findsOneWidget : findsNothing,
      );
      if (mode == 'unknown') {
        await t.ensureVisible(find.byKey(const Key('review-reject')));
        await t.tap(find.byKey(const Key('review-reject')));
        await t.pumpAndSettle();
        expect(find.text('この候補を却下しますか？'), findsOneWidget);
        await t.tap(find.text('取消'));
      } else {
        expect(
          find.textContaining(mode == 'explicit' ? '元メモで指定' : 'AIの推定'),
          findsWidgets,
        );
      }
      expect(a.writes, 0);
    });
  }
}
