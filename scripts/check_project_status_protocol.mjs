// Dartが保存したプロジェクト状態変更のREQを、固定参照の本体が受理して定義へ反映するかを検査する。
// fixtureには前回の出力（ファイルの対応表）も渡せるため、連続した変更も検査できる。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,readProjects,readProjectStatusChanges,rebuildDashboard,hash} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,out]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.equal(packet.operation,'project-status');assert.equal(packet.text,'');assert.equal(packet.confirmed,true);
const root=await mkdtemp(join(tmpdir(),'ctx-status-protocol-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 assert.equal(hash((await vault.read(`10_projects/${packet.project_id}/project.md`))),packet.project_hash);
 const changesBefore=(await readProjectStatusChanges(vault)).length;
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 assert.equal((await ingest(config)).accepted,1);const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
 assert.deepEqual({projectId:ack.result.projectId,status:ack.result.status,deduped:ack.result.deduped},{projectId:packet.project_id,status:packet.status,deduped:false});
 assert.equal((await readProjects(config)).find(p=>p.id===packet.project_id).status,packet.status);
 assert.equal((await readProjectStatusChanges(vault)).length,changesBefore+1);
 assert.equal(await vault.read(path),raw);
 await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
 if(packet.status!=='active')assert.match(await vault.read('HOME.md'),/## 休止・完了（1件）/);
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
 process.stdout.write('DartのREQを受理し、状態変更の反映と重複なしを確認\n');
}finally{await rm(root,{recursive:true,force:true});}
