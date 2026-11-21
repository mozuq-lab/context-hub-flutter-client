// Dartが保存した人の登録・名前と呼び名の変更・外す依頼のREQを、固定参照の本体が受理して定義へ反映するかを検査する。
// 反映後に本体の人ごとの一覧（SUMMARY.md・PEOPLE.md）を作り直し、アプリの読取テスト用のsnapshotを書き出す。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,inspectPeople,readPersonChanges,rebuildPeople,rebuildDashboard,hash,personDefinitionPath} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,out]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.equal(packet.operation,'person-definition');assert.equal(packet.text,'');assert.equal(packet.confirmed,true);
const root=await mkdtemp(join(tmpdir(),'ctx-person-protocol-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 const before=await vault.read(personDefinitionPath(packet.person_id));
 if(packet.action==='add')assert.equal(before,undefined);else assert.equal(hash(before),packet.person_hash);
 const changes=(await readPersonChanges(vault)).length;
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 assert.equal((await ingest(config)).accepted,1);const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
 assert.equal(ack.result.personId,packet.person_id);assert.equal(ack.result.action,packet.action);assert.equal(ack.result.deduped,false);
 const person=(await inspectPeople(vault)).people.find(p=>p.id===packet.person_id);
 if(packet.action==='remove')assert.equal(person,undefined);
 else assert.deepEqual({name:person.name,aliases:person.aliases},{name:packet.name,aliases:packet.aliases??[]});
 assert.equal((await readPersonChanges(vault)).length,changes+1);
 assert.equal(await vault.read(path),raw);
 await rebuildPeople(config);
 await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','40_people','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
 process.stdout.write(`DartのREQ（${packet.action}）を受理し、人の定義への反映と重複なしを確認\n`);
}finally{await rm(root,{recursive:true,force:true});}
