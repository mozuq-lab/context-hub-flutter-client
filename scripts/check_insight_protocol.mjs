// 今週の気づき（90_system/insights.json）と、Dartが保存した反応の依頼（insight-reaction）・問いへの答え（meta付きのcapture）を、固定参照の本体で検査する。
// prepareは週次の統合を1回実行したVaultを作る（偽のモデル。つながり1件と問い1件）。
// ingestはDartのREQを受理し、反応の記録または答えのメモと、一覧への反映を確かめる。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,capture,organize,MockLlm,runSynthesis,rebuildDashboard,readInsightReactions} from '../vendor/context-hub/packages/core/dist/index.js';
const [mode,...args]=process.argv.slice(2);
const root=await mkdtemp(join(tmpdir(),'ctx-insight-protocol-'));
async function open(fixture){
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 config.synthesis={...config.synthesis,enabled:true};
 if(fixture){const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files))await vault.write(p,value);}
 return{config,vault};
}
async function save(vault,out){
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md','HOME.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
}
const insights=async vault=>JSON.parse(await vault.read('90_system/insights.json'));
try{
 if(mode==='prepare'){
  const[out]=args,{config,vault}=await open();
  for(const[text,at]of [['資格の講習に関心がある','2026-11-03T09:00:00+09:00'],['資格の講習を受ける必要がある','2026-11-10T09:00:00+09:00'],['動画の作り方を見直した','2026-11-12T09:00:00+09:00']])
   await capture(config,{source:'cli',occurredAt:at,receivedAt:at,text});
  await organize(config,new MockLlm());
  const marker='入力データ(JSON):\n';
  const llm={complete:async prompt=>{
   const payload=JSON.parse(prompt.slice(prompt.lastIndexOf(marker)+marker.length)),ref=text=>payload.memos.find(m=>m.text.includes(text)).ref;
   return{text:JSON.stringify({connections:[{refs:[ref('関心がある'),ref('受ける必要がある')],text:'11/03の関心が、11/10には受ける必要へ進んでいるように見えます'}],shifts:[],stalled:[],actions:[],questions:[{refs:[ref('動画')],text:'見直した結果、次に試したいことはありますか'}]})};
  }};
  const outcome=await runSynthesis(config,llm,{now:new Date('2026-11-15T00:00:00Z')});
  assert.equal(outcome.status,'ok',JSON.stringify(outcome));assert.equal(outcome.items,2);
  await rebuildDashboard(config);
  assert.equal((await insights(vault)).latest.items.length,2);
  await save(vault,out);process.stdout.write('今週の気づき2件のVaultを作成\n');
 }else if(mode==='ingest'){
  const[file,fixture,out]=args,raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
  const{config,vault}=await open(fixture);
  await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
  const first=await ingest(config);
  if(packet.operation==='insight-reaction'){
   assert.equal(packet.confirmed,true);
   // 受理できない依頼（知らない項目など）は、理由を受付の失敗に残す。
   if(first.accepted===0)assert.equal(first.rejected,1,JSON.stringify(first));
   else{
    const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
    const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
    assert.deepEqual([ack.result.runId,ack.result.itemKey,ack.result.reaction],[packet.run_id,packet.item_key,packet.reaction]);
    assert.equal((await readInsightReactions(vault)).records.filter(r=>r.id===ack.result.reactionId).length,1);
   }
  }else{
   assert.equal(packet.operation,'capture');assert.equal(packet.meta?.capture_mode,'insight-answer');
   assert.equal(first.accepted,1,JSON.stringify(first));
   await organize(config,new MockLlm());
  }
  assert.equal(await vault.read(path),raw);
  await rebuildDashboard(config);
  await save(vault,out);process.stdout.write(`DartのREQ（${packet.operation}）を処理\n`);
 }else throw new Error(`不明なmode: ${mode}`);
}finally{await rm(root,{recursive:true,force:true});}
