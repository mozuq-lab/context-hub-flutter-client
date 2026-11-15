import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/ai/guided_services.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/app/guided_controller.dart';
import 'package:context_hub_client/core/guided.dart';
import 'package:context_hub_client/storage/guided_store.dart';
import 'fixtures.dart';
import 'guided_test.dart'
    show FakeModel, MemorySecrets, UncertainAccess, question, until;

/// guided.jsonの読み出しを失敗させたり、書き込みを止めておいたりできる。
class GatedAccess extends UncertainAccess {
  bool failGuidedRead = false;
  Completer<void>? gate;
  @override
  Future<String?> readState(String name) async {
    if (failGuidedRead && name == GuidedStore.fileName) {
      throw StateError('読み出せない');
    }
    return super.readState(name);
  }

  @override
  Future<void> writeState(
    String name,
    String raw, {
    bool exclusive = false,
  }) async {
    final g = gate;
    if (g != null && name == GuidedStore.fileName) await g.future;
    return super.writeState(name, raw, exclusive: exclusive);
  }
}

void main() {
  late GatedAccess access;
  late HubController hub;
  late FakeModel model;
  var now = DateTime(2026, 11, 7, 10);
  setUp(() async {
    access = GatedAccess();
    await access.init();
    model = FakeModel();
    now = DateTime(2026, 11, 7, 10);
    hub = HubController(
      access,
      sampleLoader: () async => fixture().files,
      guided: GuidedServices(
        model: model,
        secrets: MemorySecrets('sk-ant-test-key-0000000000'),
        clock: () => now,
      ),
    );
    await hub.useSample();
  });
  tearDown(() async {
    hub.dispose();
    await access.directory.delete(recursive: true);
  });

  Future<GuidedController> started() async {
    final g = GuidedController(hub);
    addTearDown(g.dispose);
    await g.load();
    await g.start(GuidedPurpose.idea, seed: '案');
    return g;
  }

  test('状態ファイルを読み出せないときは、上限や途中の深掘りを上書きせず、Claude APIも呼ばない', () async {
    await GuidedStore(access).write(
      GuidedState(
        usage: const GuidedUsage('2026-11', calls: 7),
        monthlyLimit: 7,
      ),
    );
    final before = await access.readState(GuidedStore.fileName);
    access.failGuidedRead = true;
    final g = GuidedController(hub);
    addTearDown(g.dispose);
    await g.load();
    model.replies.add(question('Q1', ['a', 'b']));
    await g.start(GuidedPurpose.idea, seed: '案');
    await g.setLimit(500);
    expect(model.prompts, isEmpty);
    expect(g.error, contains('読み出せませんでした'));
    access.failGuidedRead = false;
    expect(await access.readState(GuidedStore.fileName), before);
  });

  test('送る前に回数を残す間に中止したら、送らなかった1回は数えない', () async {
    model.replies.add(question('Q1', ['a', 'b']));
    final g = await started();
    expect(g.usage!.calls, 1);
    final gate = access.gate = Completer<void>();
    final pending = g.answer(const GuidedAnswer.selected(['a']));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    g.cancel();
    access.gate = null;
    gate.complete();
    await pending;
    expect(model.prompts, hasLength(1));
    expect(g.usage!.calls, 1);
    await until(() => g.busy == false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await GuidedStore(access).read(now)).usage.calls, 1);
  });

  test('回数を端末に残せないときは、Claude APIへ送らない', () async {
    model.replies.addAll([
      question('Q1', ['a', 'b']),
      question('Q2', ['c', 'd']),
    ]);
    final g = await started();
    access.failGuided = true;
    await g.answer(const GuidedAnswer.selected(['a']));
    expect(model.prompts, hasLength(1));
    expect(g.usage!.calls, 1);
    expect(g.error, contains('残せなかった'));
    access.failGuided = false;
    await g.ask();
    expect(model.prompts, hasLength(2));
    expect(g.usage!.calls, 2);
  });

  test('端末の時計を過去の月へ戻しても、今月の回数を数え直さない', () {
    const usage = GuidedUsage('2026-11', calls: 5);
    final back = usage.current(DateTime(2026, 10, 30));
    expect(back.calls, 5);
    expect(usage.add(DateTime(2025, 1, 1), calls: 1).calls, 6);
    expect(usage.current(DateTime(2026, 12, 1)).calls, 0);
  });

  test('時計が一度先の月になっても、直したあとの月で数え、次の月には0から数える', () {
    // 誤って2027-05に進んだ時計で記録し、正しい2026-11に直した。
    const usage = GuidedUsage('2027-05', calls: 5, input: 100);
    final fixed = usage.current(DateTime(2026, 11, 20));
    expect(fixed.month, '2026-11');
    expect(fixed.calls, 5);
    expect(fixed.input, 100);
    final next = fixed.add(DateTime(2026, 11, 21), calls: 1);
    expect(next.month, '2026-11');
    expect(next.current(DateTime(2026, 12, 1)).calls, 0);
  });

}
