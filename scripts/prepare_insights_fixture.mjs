// 週次の統合の結果（今週の気づき。90_system/insights.json）を含む、本体由来の架空fixture。
// 5つの欄の項目、最初の一歩、複数の根拠、気づきを作った後に訂正が届いた根拠の読取に使う。
// モデルは使わず、渡されたメモの参照名から決まった応答を返す偽のクライアントで実行する。
import {mkdtemp,rm,writeFile,mkdir,readdir,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {defaultConfig,Vault,addProject,capture,correctInput,organize,MockLlm,runSynthesis,rebuildDigest,rebuildDashboard} from '../vendor/context-hub/packages/core/dist/index.js';
async function filesAt(dir,prefix=''){const out={};for(const e of await readdir(dir,{withFileTypes:true})){if(e.name.startsWith('.'))continue;const p=prefix+e.name;if(e.isDirectory())Object.assign(out,await filesAt(join(dir,e.name),p+'/'));else out[p]=await readFile(join(dir,e.name),'utf8');}return out;}
const result=extra=>({category:'idea',summary:'AIの要約',project_candidates:[],next_action_suggestions:[],extracted:{current:[],next:[],open:[]},knowledge_candidate:null,new_project_hint:null,...extra});
// 実行時刻と生成時刻を固定し、HOMEの日付が実行日で変わらないようにする。
const ranAt=new Date('2026-11-15T00:00:00Z'),clock=new Date('2026-11-15T03:00:00Z');
const root=await mkdtemp(join(tmpdir(),'hub-insights-fixture-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 config.synthesis={...config.synthesis,enabled:true};
 await addProject(config,{id:'garden',title:'家庭菜園'});
 const memos=[
  ['菜園の土を調べたい','2026-10-20T09:00:00+09:00',result({project_candidates:[{id:'garden',confidence:0.9}]})],
  ['資格の講習に関心がある','2026-11-03T09:00:00+09:00',result()],
  ['資格の講習を受ける必要がある','2026-11-10T09:00:00+09:00',result({category:'task'})],
  ['動画の作り方を見直した','2026-11-12T09:00:00+09:00',result()],
  ['読んだ本の感想を1か所に集めたい','2026-11-13T09:00:00+09:00',result()],
 ];
 const ids=[];
 for(const[text,occurredAt]of memos)ids.push((await capture(config,{source:'cli',occurredAt,receivedAt:occurredAt,text})).inputId);
 await organize(config,new MockLlm(memos.map(m=>m[2])));
 // 渡されたメモの本文から参照名を引いて、5つの欄の応答を作る。
 const marker='入力データ(JSON):\n';
 const llm={complete:async prompt=>{
  const payload=JSON.parse(prompt.slice(prompt.lastIndexOf(marker)+marker.length)),ref=text=>payload.memos.find(m=>m.text.includes(text)).ref;
  return{text:JSON.stringify({
   connections:[{refs:[ref('関心がある'),ref('受ける必要がある')],text:'11/03の関心が、11/10には受ける必要へ進んでいるように見えます'}],
   shifts:[{refs:[ref('動画'),ref('感想')],text:'11/12の見直しと11/13の「1か所に集めたい」は、作るより整える方へ関心が移っているように見えます'}],
   stalled:[{refs:[ref('土を調べたい')],text:'10/20の「調べたい」から続きが見当たりません。まだ調べますか',first_step:'土の種類を3つ書き出す'}],
   actions:[{refs:[ref('受ける必要がある'),ref('関心がある')],text:'講習の日程と申込期限を確かめますか'}],
   questions:[{refs:[ref('動画')],text:'見直した結果、次に試したいことはありますか'},{refs:[ref('感想')],text:'感想は、どの本から集め始めますか'}],
  })};
 }};
 const outcome=await runSynthesis(config,llm,{now:ranAt});
 if(!outcome.ran||outcome.status!=='ok'||outcome.items!==6)throw new Error(`週次の統合が想定どおりに終わりませんでした: ${JSON.stringify(outcome)}`);
 // 気づきを作った後に、根拠のメモへ訂正が届く。
 await correctInput(config,ids[0],{source:'cli',occurredAt:'2026-11-15T10:00:00+09:00',receivedAt:'2026-11-15T10:00:00+09:00',text:'土はもう調べた'});
 await rebuildDigest(config,{now:clock});
 await rebuildDashboard(config,{now:clock});
 const insights=JSON.parse(await vault.read('90_system/insights.json')),items=insights.latest.items;
 // 実行の記録（90_system/synthesis/）はアプリが読まないので、fixtureに含めない。
 const files=Object.fromEntries(Object.entries(await filesAt(config.vaultPath)).filter(([path])=>!path.startsWith('90_system/synthesis/')));
 await mkdir('test/fixtures',{recursive:true});
 await writeFile('test/fixtures/insights.json',JSON.stringify({schema_version:1,files,expected:{
  total:items.length,
  sections:Object.fromEntries(['connections','shifts','stalled','actions','questions'].map(s=>[s,items.filter(i=>i.section===s).map(i=>i.text)])),
  first_step:items.find(i=>i.section==='stalled').first_step,
  sources:items.map(i=>i.sources.length),
  corrected:ids[0],
 }},null,2)+'\n');
 console.log('今週の気づき（週次の統合の結果）の本体fixtureを生成しました');
}finally{await rm(root,{recursive:true,force:true});}
