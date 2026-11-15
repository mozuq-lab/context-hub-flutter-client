// 似ているアイデアの索引と、Dartが保存した「束ねる・別の話」の依頼（idea-link）を、固定参照の本体で検査する。
// prepareは似ている2件と別の話1件のアイデアがあるVaultを作る。ingestはDartのREQを受理し、索引への反映と重複なしを確認する。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,capture,organize,MockLlm,rebuildDashboard} from '../vendor/context-hub/packages/core/dist/index.js';
const [mode,...args]=process.argv.slice(2);
const root=await mkdtemp(join(tmpdir(),'ctx-idea-protocol-'));
const clock=new Date('2026-11-12T00:00:00Z');
async function open(fixture){
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 if(fixture){const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files))await vault.write(p,value);}
 return{config,vault};
}
async function save(vault,out){
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md','HOME.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
}
try{
 if(mode==='prepare'){
  const[out]=args,{config,vault}=await open();
  for(const[i,text]of ['開発再開を助ける仕組みがあると面白そう','数日ぶりの開発再開を助ける仕組み、面白そう。','いつか週末にキャンプへ行く計画を立てたい'].entries())await capture(config,{source:'cli',text,occurredAt:`2026-11-0${i+1}T00:00:00Z`});
  await organize(config,new MockLlm());await rebuildDashboard(config,{now:clock});
  const index=JSON.parse(await vault.read('90_system/idea-index.json'));assert.equal(index.candidates.length,1);
  await save(vault,out);process.stdout.write('似ている2件のアイデアを作成\n');
 }else if(mode==='ingest'){
  const[file,fixture,out]=args,raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
  assert.equal(packet.operation,'idea-link');assert.equal(packet.confirmed,true);
  const{config,vault}=await open(fixture);
  await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
  const first=await ingest(config);
  // 受理できない依頼（確認後の作り直しなど）は、理由を受付の失敗に残す。
  if(first.accepted===0){assert.equal(first.rejected,1,JSON.stringify(first));}
  else{
   const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
   const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));assert.equal(ack.result.action,packet.action);
  }
  assert.equal(await vault.read(path),raw);
  await rebuildDashboard(config,{now:clock});
  await save(vault,out);process.stdout.write(`DartのREQ（idea-link ${packet.action}）を処理\n`);
 }else throw new Error(`不明なmode: ${mode}`);
}finally{await rm(root,{recursive:true,force:true});}
