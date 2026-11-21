import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/ui/review_view.dart' show adoptMeaning;
import 'package:context_hub_client/ui/views.dart'
    show intakeNextStep, intakeStateLabel;

void main() {
  test('保存と反映は、保存済み → Mac miniが受け取り済み → 反映済み／失敗 の段階で示す', () {
    expect(intakeStateLabel('waiting'), startsWith('保存済み'));
    expect(intakeStateLabel('accepted'), startsWith('Mac miniが受け取り済み'));
    expect(intakeStateLabel('organized'), '反映済み');
    for (final state in ['failed', 'rejected', 'conflict']) {
      expect(intakeStateLabel(state), startsWith('失敗'));
      // 失敗には次にすることを添える。
      expect(intakeNextStep(state), startsWith('次に: '));
    }
    expect(intakeNextStep('waiting'), isNull);
    expect(intakeNextStep('organized'), isNull);
  });

  test('採用したときに起きることを、種類ごとに短く示す', () {
    expect(adoptMeaning('project'), contains('プロジェクトを作ります'));
    expect(adoptMeaning('knowledge'), contains('参照'));
    expect(adoptMeaning('decision'), contains('守ります'));
    expect(adoptMeaning('preference'), contains('守ります'));
  });
}
