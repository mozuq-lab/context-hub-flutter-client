// プロジェクト案の採用の依頼と、同じ対象を指す案をまとめて判断する依頼を、この順に固定参照の本体へ渡したときの受付を確認する。
// refused: 先に受け付けた採用でできたプロジェクトと名前か別名が一致する案が古い案になり、その案を含むまとめた依頼は受け付けられない。
// accepted: 名前も別名も一致しなければ、後から届いたまとめた依頼も受け付ける。
// 使い方: node check_review_sequence_protocol.mjs <refused|accepted> <先に受け付ける採用の依頼> <後から届くまとめた依頼> <fixture.json> [<output.json> [<partial.json>]]
// partial.json には、採用を受け付けた直後の、確認待ち一覧を作り直す前の記録を書き出す（判断記録とプロジェクトの定義だけが先に届いた端末の状態）。
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,rebuildDashboard,buildReviewIndex} from '../vendor/context-hub/packages/core/dist/index.js';
const [mode,firstFile,secondFile,fixture,output,partial]=process.argv.slice(2),sha=value=>createHash('sha256').update(value).digest('hex');
assert.ok(['refused','accepted'].includes(mode));
const load=async file=>{const raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`;return{raw,path,packet:parseIntake(path,raw,8000)};};
const first=await load(firstFile),second=await load(secondFile);
assert.equal(first.packet.operation,'project-approve');assert.ok(second.packet.cover_ids?.length);
const root=await mkdtemp(join(tmpdir(),'ctx-review-sequence-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const{files}=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files))await vault.write(p,value);
 const put=async request=>{await vault.create(request.path,request.raw);await utimes(await vault.path(request.path),new Date(0),new Date(0));};
 const dump=async file=>{const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);snapshot['POLICY.md']=await vault.read('POLICY.md');await writeFile(file,JSON.stringify(snapshot));};
 await put(first);assert.equal((await ingest(config)).accepted,1);
 // 受付は判断記録を書くだけで、確認待ち一覧（index.json）は作り直さない。一覧では、採用した案も、名前か別名が同じ案も確認待ちのまま。
 if(partial){const stale=JSON.parse(await vault.read('90_system/review/index.json')).items.find(i=>i.id===first.packet.candidate_id);assert.equal(stale.status,'pending');assert.notEqual(await vault.read(`90_system/project-approvals/PAPR-${first.packet.candidate_id.slice(5)}.json`),undefined);await dump(partial);}
 await put(second);
 const outcome=await ingest(config),ack=await vault.read(`90_system/intake/${second.packet.request_id}.json`),errorPath=`90_system/intake-errors/${sha(second.path)}.json`;
 const decided=second.packet.operation.endsWith('approve')?'approved':'rejected';
 if(mode==='refused'){
  assert.equal(outcome.accepted,0);assert.equal(outcome.rejected,1);
  // 受け付けられなかった依頼には、受け付けた記録を作らず、依頼の内容のhashを添えた失敗の記録を残す。
  assert.equal(ack,undefined);
  const error=JSON.parse(await vault.read(errorPath));
  assert.equal(error.schema_version,1);assert.equal(error.path,second.path);assert.equal(error.file_hash,sha(second.raw));assert.equal(error.status,'error');
  // 理由を示さない失敗は、実行のたびに受け付け直す。状況が変わらなければ、受け付けられないままになる。
  assert.equal(error.reason,undefined);assert.equal((await ingest(config)).accepted,0);
 }else{
  assert.equal(outcome.accepted,1);assert.equal(outcome.rejected,0);
  assert.equal(JSON.parse(ack).result.candidateId,second.packet.candidate_id);assert.equal(await vault.read(errorPath),undefined);
 }
 await rebuildDashboard(config);
 const index=await buildReviewIndex(config),item=id=>index.items.find(i=>i.id===id);
 assert.equal(item(first.packet.candidate_id).status,'approved');
 if(mode==='refused'){
  // 採用した案と名前か別名が一致する代表の案は古い案になり、まとめた案には判断が記録されない。
  assert.equal(item(second.packet.candidate_id).status,'stale');
  for(const id of second.packet.cover_ids)assert.notEqual(item(id)?.coveredBy,second.packet.candidate_id);
 }else{
  assert.equal(item(second.packet.candidate_id).status,decided);
  for(const id of second.packet.cover_ids){assert.equal(item(id).status,decided);assert.equal(item(id).coveredBy,second.packet.candidate_id);}
 }
 assert.equal(await vault.read(second.path),second.raw);
 if(output)await dump(output);
 process.stdout.write(mode==='refused'?'先に届いた採用の後のまとめた依頼を本体が受け付けず、失敗の記録を残したことを確認\n':'名前の重ならない採用の後のまとめた依頼を、本体が受け付けたことを確認\n');
}finally{await rm(root,{recursive:true,force:true});}
