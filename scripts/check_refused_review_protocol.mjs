// 同じ対象を指すプロジェクト案をまとめて判断する依頼を、固定参照の本体が受け付けられなかったときの記録を確認する。
// 先に受け付けた1件の採用で、名前の重なる代表の案が古い案になり、後から届いたまとめた依頼は受け付けられない。
// 使い方: node check_refused_review_protocol.mjs <先に受け付ける依頼> <受け付けられない依頼> <fixture.json> [<output.json>]
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,rebuildDashboard,buildReviewIndex} from '../vendor/context-hub/packages/core/dist/index.js';
const [firstFile,secondFile,fixture,output]=process.argv.slice(2),sha=value=>createHash('sha256').update(value).digest('hex');
const load=async file=>{const raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`;return{raw,path,packet:parseIntake(path,raw,8000)};};
const first=await load(firstFile),second=await load(secondFile);
assert.equal(first.packet.operation,'project-approve');assert.ok(second.packet.cover_ids?.length);
const root=await mkdtemp(join(tmpdir(),'ctx-refused-review-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const{files}=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files))await vault.write(p,value);
 const put=async request=>{await vault.create(request.path,request.raw);await utimes(await vault.path(request.path),new Date(0),new Date(0));};
 await put(first);assert.equal((await ingest(config)).accepted,1);
 await put(second);
 const outcome=await ingest(config);assert.equal(outcome.accepted,0);assert.equal(outcome.rejected,1);
 // 受け付けられなかった依頼には、受け付けた記録を作らず、依頼の内容のhashを添えた失敗の記録を残す。
 assert.equal(await vault.read(`90_system/intake/${second.packet.request_id}.json`),undefined);
 const error=JSON.parse(await vault.read(`90_system/intake-errors/${sha(second.path)}.json`));
 assert.equal(error.schema_version,1);assert.equal(error.path,second.path);assert.equal(error.file_hash,sha(second.raw));assert.equal(error.status,'error');
 // 理由を示さない失敗は、実行のたびに受け付け直す。状況が変わらなければ、受け付けられないままになる。
 assert.equal(error.reason,undefined);assert.equal((await ingest(config)).accepted,0);
 await rebuildDashboard(config);
 const index=await buildReviewIndex(config),status=id=>index.items.find(i=>i.id===id)?.status;
 assert.equal(status(first.packet.candidate_id),'approved');
 // 採用した案と名前の重なる代表の案は古い案になり、まとめた案には判断が記録されない。
 assert.equal(status(second.packet.candidate_id),'stale');
 for(const id of second.packet.cover_ids)assert.notEqual(index.items.find(i=>i.id===id)?.coveredBy,second.packet.candidate_id);
 assert.equal(await vault.read(second.path),second.raw);
 if(output){const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);snapshot['POLICY.md']=await vault.read('POLICY.md');await writeFile(output,JSON.stringify(snapshot));}
 process.stdout.write('先に届いた採用の後のまとめた依頼を本体が受け付けず、失敗の記録を残したことを確認\n');
}finally{await rm(root,{recursive:true,force:true});}
