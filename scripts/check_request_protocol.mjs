// Dartが保存したNOW項目の完了・解決報告、作業記録の下書きの見送り、下書きから作った入力、メモの訂正のREQを、
// 固定参照の本体が受理して反映するかを検査する。fixtureには前回の出力（ファイルの対応表）も渡せる。
// 4番目の引数に stale を渡すと、古い訂正対象への訂正として本体が受付を断り、理由を記録することを確認する。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,organize,MockLlm,readItemResolutions,readNowItems,readGitDrafts,rebuildDashboard,readInputs} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,out,mode]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.ok(['item-resolution','git-draft-dismiss','capture','correct'].includes(packet.operation));
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
  assert.equal(item.resolution?.id??null,packet.action==='resolve'?ack.result.resolutionId:null);
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
