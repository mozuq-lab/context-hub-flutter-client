// Dartが保存したNOW項目の完了・解決報告、作業記録の下書きの見送り、下書きから作った入力のREQを、
// 固定参照の本体が受理して反映するかを検査する。fixtureには前回の出力（ファイルの対応表）も渡せる。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,organize,MockLlm,readItemResolutions,readNowItems,readGitDrafts,rebuildDashboard} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,out]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.ok(['item-resolution','git-draft-dismiss','capture'].includes(packet.operation));
const root=await mkdtemp(join(tmpdir(),'ctx-request-protocol-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 const resolutionsBefore=(await readItemResolutions(vault)).length;
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 assert.equal((await ingest(config)).accepted,1);const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
 if(packet.operation==='item-resolution'){
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
 assert.equal(await vault.read(path),raw);
 await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
 process.stdout.write(`DartのREQ（${packet.operation}）を受理し、反映と重複なしを確認\n`);
}finally{await rm(root,{recursive:true,force:true});}
