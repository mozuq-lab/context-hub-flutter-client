// Dartが保存したプロジェクトの統合・取り消し（project-merge・project-unmerge）のREQを、固定参照の本体が
// 受理して定義・資料・帰属へ反映するかを検査する。
// prepareは、同じものを指す2つ目のプロジェクトと、その資料・作業要約を足したVaultを作る。
// rejectは、本体が受け付けない依頼（確認後に定義が変わった、統合済みのプロジェクトへの操作）の記録を作る。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,addProject,capture,runCycle,MockLlm,readProjects,readProjectMerges,setProjectDefinition,hash,doctor} from '../vendor/context-hub/packages/core/dist/index.js';
const [mode,...args]=process.argv.slice(2);
const root=await mkdtemp(join(tmpdir(),'ctx-merge-protocol-'));
async function open(fixture){
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 return{config,vault};
}
async function save(config,vault,out,{refused=false}={}){
 await runCycle(config,new MockLlm());
 // 受け付けなかった依頼はdoctorにも出るので、その場合は整合性を見ない。
 if(!refused)assert.deepEqual((await doctor(config)).issues,[]);
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md','HOME.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
}
async function place(vault,file){
 const raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 return{raw,path,packet};
}
const at=iso=>({occurredAt:iso,receivedAt:iso});
try{
 if(mode==='prepare'){
  const[fixture,out]=args,{config,vault}=await open(fixture);
  await addProject(config,{id:'hub-tool',title:'まとめツール',aliases:['まとめ'],keywords:['まとめる']});
  await capture(config,{source:'file',kind:'work-summary',tool:'codex',project:'hub-tool',...at('2026-09-01T01:00:00Z'),text:'## 現在地\n- [確認済み] 試作が動いた\n## 次の一手\n- [確認済み] 利用者に見せる\n## 未解決\n- 配布方法が決まっていない'});
  await capture(config,{source:'cli',project:'hub-tool',...at('2026-10-01T01:00:00Z'),text:'同期の仕様はここ https://example.com/spec'});
  await save(config,vault,out);
  assert.match(await vault.read('10_projects/hub-tool/REFERENCES.md'),/<https:\/\/example\.com\/spec>/);
  process.stdout.write('同じものを指す2つ目のプロジェクトと、その資料を作成\n');
 }else if(mode==='ingest'){
  const[file,fixture,out]=args,{config,vault}=await open(fixture),{raw,path,packet}=await place(vault,file);
  assert.ok(['project-merge','project-unmerge'].includes(packet.operation));assert.equal(packet.text,'');assert.equal(packet.confirmed,true);
  for(const[id,expected]of[[packet.project_id,packet.project_hash],[packet.into_id,packet.into_hash]])assert.equal(hash(await vault.read(`10_projects/${id}/project.md`)),expected);
  const before=(await readProjectMerges(vault)).length,action=packet.operation==='project-merge'?'merge':'unmerge';
  const first=await ingest(config);assert.equal(first.accepted,1,JSON.stringify(first));const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
  const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
  assert.deepEqual({fromId:ack.result.fromId,intoId:ack.result.intoId,action:ack.result.action,deduped:ack.result.deduped},{fromId:packet.project_id,intoId:packet.into_id,action,deduped:false});
  const merges=await readProjectMerges(vault);assert.equal(merges.length,before+1);assert.equal(merges.at(-1).id,ack.result.mergeId);
  assert.equal((await readProjects(config)).find(p=>p.id===packet.project_id).merged_into,action==='merge'?packet.into_id:undefined);
  assert.equal(await vault.read(path),raw);
  await save(config,vault,out);
  const shelf=await vault.read(`10_projects/${packet.project_id}/REFERENCES.md`);
  if(action==='merge'){assert.match(shelf,/統合済みです/);assert.match(await vault.read(`10_projects/${packet.into_id}/REFERENCES.md`),/<https:\/\/example\.com\/spec>/);}
  else assert.match(shelf,/<https:\/\/example\.com\/spec>/);
  process.stdout.write(`DartのREQ（${packet.operation}）を受理し、定義・資料への反映と重複なしを確認\n`);
 }else if(mode==='reject'){
  // 第4引数にプロジェクトIDを渡すと、依頼を受け付ける前にその定義を変える（確認後に定義が変わった場合）。
  const[file,fixture,out,changed]=args,{config,vault}=await open(fixture);
  if(changed){const current=(await readProjects(config)).find(p=>p.id===changed);await setProjectDefinition(config,{projectId:changed,title:current.title,aliases:current.aliases,keywords:[...current.keywords,'あとから足した語'],expectedHash:hash(await vault.read(`10_projects/${changed}/project.md`)),source:'cli'});}
  const definitions=JSON.stringify(await readProjects(config)),{packet,path}=await place(vault,file);
  const result=await ingest(config);assert.equal(result.accepted,0,JSON.stringify(result));assert.equal(result.rejected,1,JSON.stringify(result));
  assert.equal(JSON.stringify(await readProjects(config)),definitions);
  const error=JSON.parse(await vault.read(`90_system/intake-errors/${hash(path)}.json`));
  await save(config,vault,out,{refused:true});
  process.stdout.write(`DartのREQ（${packet.operation}）を本体が受け付けないことを確認: ${error.reason?.code}\n`);
 }else throw new Error(`不明なmode: ${mode}`);
}finally{await rm(root,{recursive:true,force:true});}
