import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,rebuildDashboard,buildReviewIndex,correctInput} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.equal(packet.text,'');assert.equal(packet.confirmed,true);
const root=await mkdtemp(join(tmpdir(),'ctx-review-protocol-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const{files}=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files))await vault.write(p,value);
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 assert.equal((await ingest(config)).accepted,1);assert.equal((await ingest(config)).deduped,1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));assert.equal(ack.result.candidateId,packet.candidate_id);
 await rebuildDashboard(config);const index=await buildReviewIndex(config),candidate=index.items.find(i=>i.id===packet.candidate_id);
 assert.equal(candidate.status,packet.operation.endsWith('approve')?'approved':'rejected');assert.equal(candidate.reflected,true);assert.equal(index.items.filter(i=>i.status==='pending').length,3);
 assert.equal(await vault.read(path),raw);
 // 確定後の訂正は過去の判断を取り消さない。端末側も同じ履歴を保持する。
 if(candidate.inputIds.length){
  await correctInput(config,candidate.inputIds.at(-1),{source:'cli',occurredAt:'2026-11-01T04:00:00Z',text:'判断後に根拠を見直す'});
  await rebuildDashboard(config);
  assert.equal((await buildReviewIndex(config)).items.find(i=>i.id===candidate.id).status,candidate.status);
 }
 if(process.argv[4]){const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);snapshot['POLICY.md']=await vault.read('POLICY.md');await writeFile(process.argv[4],JSON.stringify(snapshot));}
 process.stdout.write('DartのREQを受理し、重複なし・未承認一覧から除外・反映済みを確認\n');
}finally{await rm(root,{recursive:true,force:true});}
