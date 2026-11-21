// Dartが保存したNOW項目の完了・解決報告と「誤りとして外す」報告、期日・見直す日（と繰り返し）の依頼、定例の回の完了・見送り、記録に聞くの問い、端末間でそろえる好み、「片付いたかも」の見送り、作業記録の下書きの見送り、下書きから作った入力、メモの訂正のREQを、
// 固定参照の本体が受理して反映するかを検査する。fixtureには前回の出力（ファイルの対応表）も渡せる。
// 4番目の引数に stale を渡すと、古い訂正対象への訂正として本体が受付を断り、理由を記録することを確認する。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,organize,MockLlm,readItemResolutions,readItemSchedules,activeSchedules,readNowItems,readHintDismissals,readGitDrafts,readRereads,rebuildDashboard,readInputs,readItemOccurrences,readAskRecords,answerPending,readClientPreferences} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,out,mode]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.ok(['item-resolution','item-hint-dismiss','item-schedule','item-occurrence','ask','client-preferences','git-draft-dismiss','capture','correct'].includes(packet.operation));
const root=await mkdtemp(join(tmpdir(),'ctx-request-protocol-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 const resolutionsBefore=(await readItemResolutions(vault)).length;
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 if(mode==='stale'){
  // 古い訂正対象は受け付けず、最新の訂正IDを理由に残す。再受付でも重複して記録しない。
  assert.equal(packet.operation,'correct');
  const first=await ingest(config);assert.equal(first.accepted,0);assert.equal(first.rejected,1);
  const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);
  assert.equal(await vault.read(`90_system/intake/${packet.request_id}.json`),undefined);
  const chain=(await readInputs(config)).filter(i=>i.kind==='correction'&&i.corrects_input_id===packet.target_id);
  assert.equal(chain.length,1);
  const errors=await vault.files('90_system/intake-errors');
  const reasons=await Promise.all(errors.map(async p=>JSON.parse(await vault.read(p))));
  assert.ok(reasons.some(e=>e.path===path&&e.reason?.code==='stale-correction-target'&&e.reason.latest_input_id===chain[0].id));
 }else{
 assert.equal((await ingest(config)).accepted,1);const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
 if(packet.operation==='correct'){
  // 訂正は元の原文を残し、Dartが書いた全文をそのまま訂正原文にする。
  const inputs=await readInputs(config),saved=inputs.find(i=>i.id===ack.result.inputId);
  assert.equal(saved.kind,'correction');assert.equal(saved.corrects_input_id,packet.target_id);assert.equal(saved.text,packet.text);assert.equal(saved.source,packet.source);
  assert.ok(inputs.some(i=>i.id===packet.target_id));
 }else if(packet.operation==='item-resolution'){
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,action:ack.result.action,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,action:packet.action,deduped:false});
  assert.equal((await readItemResolutions(vault)).length,resolutionsBefore+1);
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.resolution?.id??null,packet.action==='reopen'?null:ack.result.resolutionId);
  if(packet.action==='exclude'){
   // 誤りとして外した項目は、完了・解決とは別に、理由と一言を付けて項目一覧に残る。
   assert.deepEqual({action:item.resolution.action,reason:item.resolution.reason,note:item.resolution.note},{action:'exclude',reason:packet.reason,note:packet.note});
   // 読み違いは、次の整理でメモを読み直した記録が残り、外した項目は戻せるよう一覧に残る。
   if(packet.reason==='misread'){
    await organize(config,new MockLlm());
    assert.equal((await readRereads(vault)).records.get(item.input_id)?.status,'reread');
    assert.equal((await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key)?.resolution?.id,ack.result.resolutionId);
   }
  }else assert.equal(item.resolution?.action,undefined);
 }else if(packet.operation==='item-schedule'){
  // 変更後の全体（期日と見直す日）がそのまま記録され、NOWの項目一覧に反映される。両方nullなら外す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemSchedules(vault)).records.find(r=>r.id===ack.result.scheduleId);
  assert.deepEqual({due:record.due,review_after:record.review_after,source:record.source},{due:packet.due,review_after:packet.review_after,source:packet.source});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  const clearing=packet.due===null&&packet.review_after===null;
  // 繰り返しを省いた依頼は今の繰り返しを保ち、添えた依頼はそのとおりにする（毎月は期日の日を覚える）。
  if(packet.repeat!==undefined)assert.deepEqual(record.repeat??null,packet.repeat&&packet.due?{...packet.repeat,...(packet.repeat.unit==='month'?{day:Number(packet.due.slice(8))}:{})}:null);
  assert.deepEqual(item.schedule,clearing?null:{id:record.id,due:packet.due,review_after:packet.review_after,...(record.repeat?{repeat:record.repeat}:{})});
  assert.equal(activeSchedules((await readItemSchedules(vault)).records).has(packet.item_key),!clearing);
 }else if(packet.operation==='item-occurrence'){
  // 今の回を片付けた記録を残し、項目は欄に残したまま期日を次の回へ進める。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,action:ack.result.action,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,action:packet.action,deduped:false});
  const occurrence=(await readItemOccurrences(vault)).records.find(o=>o.id===ack.result.occurrenceId);
  assert.deepEqual({due:occurrence.due,next:occurrence.next_due,source:occurrence.source},{due:packet.due,next:ack.result.nextDue,source:packet.source});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.resolution,null);assert.equal(item.schedule.due,ack.result.nextDue);assert.ok(ack.result.nextDue>packet.due);
 }else if(packet.operation==='ask'){
  // 問いは受付で答え待ちとして記録し、答えはcycleと同じ処理で作る（モックのモデル）。
  const before=(await readAskRecords(vault)).records.find(r=>r.id===ack.result.askId);
  assert.deepEqual({status:before.status,question:before.question,project:before.project,event:before.source_event_id},{status:'pending',question:packet.text,project:packet.project??null,event:packet.request_id});
  await answerPending(config,new MockLlm());
  const after=(await readAskRecords(vault)).records.find(r=>r.id===ack.result.askId);
  assert.notEqual(after.status,'pending');
 }else if(packet.operation==='client-preferences'){
  // 送ったまとまりを、送った日時・端末・受付IDとともに記録する。
  const body=JSON.parse(packet.text),stored=await readClientPreferences(vault);
  assert.deepEqual([...ack.result.applied].sort(),Object.keys(body.groups).sort());
  for(const[g,v]of Object.entries(body.groups))assert.deepEqual({device:stored.groups[g].device,request:stored.groups[g].request_id,value:stored.groups[g].value},{device:body.device,request:packet.request_id,value:v.value});
 }else if(packet.operation==='item-hint-dismiss'){
  // 見送りは候補の表示だけを変え、項目は未解決のまま残す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,hintInputId:ack.result.hintInputId,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,hintInputId:packet.input_id,deduped:false});
  assert.ok((await readHintDismissals(vault)).some(d=>d.id===ack.result.dismissalId&&d.item_key===packet.item_key&&d.input_id===packet.input_id));
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.resolution,null);assert.equal(item.hints,undefined);
 }else if(packet.operation==='git-draft-dismiss'){
  assert.deepEqual({draftId:ack.result.draftId,dismissed:ack.result.dismissed},{draftId:packet.draft_id,dismissed:true});
  assert.equal((await readGitDrafts(config)).find(d=>d.id===packet.draft_id).status,'dismissed');
 }else{
  // 下書きから作った入力は、確認した下書きのhashが一致すれば使用済みになる。
  await organize(config,new MockLlm());
  assert.equal((await readGitDrafts(config)).find(d=>d.id===packet.meta.git_draft).status,'used');
 }
 }
 assert.equal(await vault.read(path),raw);
 await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
 process.stdout.write(`DartのREQ（${packet.operation}）を受理し、反映と重複なしを確認\n`);
}finally{await rm(root,{recursive:true,force:true});}
