// Dartが保存したプロジェクト作成（project-create）と「NOWを生成版に戻す」（conflict-resolve）のREQを、
// 固定参照の本体が受理して反映するかを検査する。prepare-conflictは、NOWを手で書き換えて本体に新版を退避させた状態を作る。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,rebuildNow,rebuildDashboard} from '../vendor/context-hub/packages/core/dist/index.js';
const [mode,...args]=process.argv.slice(2);
const root=await mkdtemp(join(tmpdir(),'ctx-project-tools-protocol-'));
async function open(fixture){
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 return{config,vault};
}
async function save(vault,out){
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md','HOME.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
}
try{
 if(mode==='prepare-conflict'){
  const[fixture,out]=args,{config,vault}=await open(fixture),path='10_projects/context-hub/NOW.md';
  const raw=await vault.read(path),edited=raw.replace('- サンプルの検索を確認する。','- サンプルの検索は手で確認済み。');
  assert.notEqual(edited,raw);await vault.write(path,edited);
  const result=await rebuildNow(config,'context-hub');assert.ok(result.conflict);assert.equal(await vault.read(path),edited);
  await save(vault,out);process.stdout.write('NOWを手で書き換え、本体が新版を退避した状態を作成\n');
 }else if(mode==='ingest'){
  const[file,fixture,out]=args,raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
  assert.ok(['project-create','conflict-resolve'].includes(packet.operation));assert.equal(packet.confirmed,true);
  const{config,vault}=await open(fixture);
  await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
  const first=await ingest(config);assert.equal(first.accepted,1,JSON.stringify(first));const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
  const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
  if(packet.operation==='project-create')assert.equal(ack.result.projectId,packet.project_id);else assert.equal(ack.result.target,packet.target);
  assert.equal(await vault.read(path),raw);
  await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
  await save(vault,out);process.stdout.write(`DartのREQ（${packet.operation}）を受理し、反映と重複なしを確認\n`);
 }else throw new Error(`不明なmode: ${mode}`);
}finally{await rm(root,{recursive:true,force:true});}
