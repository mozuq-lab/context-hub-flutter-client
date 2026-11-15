// 「片付いたかも」を含む状態を、固定参照の本体で作る。サンプルのVaultに、本人がプロジェクトを指定した
// 「完了: <次の一手の本文>」のメモを足して整理し、本体がNOWと項目一覧に候補を書いた後のファイルを出力する。
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {defaultConfig,Vault,capture,organize,MockLlm,readNowItems,rebuildDashboard} from '../vendor/context-hub/packages/core/dist/index.js';
const [fixture,out]=process.argv.slice(2),project='context-hub';
const root=await mkdtemp(join(tmpdir(),'ctx-hint-state-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 const next=(await readNowItems(vault,project)).items.find(i=>i.section==='next'&&i.resolution===null);
 assert.ok(next,'サンプルに片付いていない次の一手がありません');
 const now=new Date().toISOString();
 const memo=await capture(config,{source:'fixture',kind:'memo',project,occurredAt:now,receivedAt:now,text:`今日の作業\n完了: ${next.label}${next.text}`});
 await organize(config,new MockLlm());
 const hinted=(await readNowItems(vault,project)).items.find(i=>i.key===next.key);
 assert.deepEqual(hinted.hints?.map(h=>h.input_id),[memo.inputId]);
 await rebuildDashboard(config);
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['HOME.md','POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
 process.stdout.write('「片付いたかも」を含む状態を作成\n');
}finally{await rm(root,{recursive:true,force:true});}
