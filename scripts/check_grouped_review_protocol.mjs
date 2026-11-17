// 同じ対象を指すプロジェクト案をまとめて判断する依頼（cover_ids・cover_hashes）を、固定参照の本体が受理し、
// まとめた案にも同じ判断を記録することを確認する。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,rebuildDashboard,buildReviewIndex} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,output]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.equal(packet.text,'');assert.equal(packet.confirmed,true);assert.ok(packet.cover_ids?.length);
const root=await mkdtemp(join(tmpdir(),'ctx-grouped-review-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const{files}=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files))await vault.write(p,value);
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 assert.equal((await ingest(config)).accepted,1);assert.equal((await ingest(config)).deduped,1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));assert.equal(ack.result.candidateId,packet.candidate_id);
 await rebuildDashboard(config);
 const index=await buildReviewIndex(config),status=packet.operation.endsWith('approve')?'approved':'rejected',lead=index.items.find(i=>i.id===packet.candidate_id);
 assert.equal(lead.status,status);assert.equal(lead.reflected,true);assert.deepEqual(lead.duplicates,packet.cover_ids);
 for(const id of packet.cover_ids){
  const covered=index.items.find(i=>i.id===id);
  assert.equal(covered.status,status);assert.equal(covered.coveredBy,lead.id);assert.equal(covered.decisionId,lead.decisionId);assert.equal(covered.reflected,true);
 }
 assert.equal(await vault.read(path),raw);
 if(output){const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);snapshot['POLICY.md']=await vault.read('POLICY.md');await writeFile(output,JSON.stringify(snapshot));}
 process.stdout.write('DartのまとめたREQを受理し、まとめた案にも同じ判断が記録されたことを確認\n');
}finally{await rm(root,{recursive:true,force:true});}
