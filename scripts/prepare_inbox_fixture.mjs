// プロジェクトに結び付いていないメモと、同じ対象を指すプロジェクト案の組を含む、本体由来の架空fixture。
// 「プロジェクト未定の次の一手」（90_system/unassigned-actions.json）と、確認待ち一覧のまとめ（duplicates・duplicateOf）の読取に使う。
import {mkdtemp,rm,writeFile,mkdir,readdir,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {defaultConfig,Vault,addProject,capture,organize,MockLlm,rebuildDashboard,buildReviewIndex} from '../vendor/context-hub/packages/core/dist/index.js';
async function filesAt(dir,prefix=''){const out={};for(const e of await readdir(dir,{withFileTypes:true})){if(e.name.startsWith('.'))continue;const p=prefix+e.name;if(e.isDirectory())Object.assign(out,await filesAt(join(dir,e.name),p+'/'));else out[p]=await readFile(join(dir,e.name),'utf8');}return out;}
const result=extra=>({category:'unclassified',summary:'AIの要約',project_candidates:[],next_action_suggestions:[],extracted:{current:[],next:[],open:[]},knowledge_candidate:null,new_project_hint:null,...extra});
const proposal=(title,aliases,rationale)=>({title,aliases,keywords:['読書'],rationale});
// 生成時刻を固定し、HOMEの日付が実行日で変わらないようにする。
const clock=new Date('2026-11-10T00:00:00Z');
const root=await mkdtemp(join(tmpdir(),'hub-inbox-fixture-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 await addProject(config,{id:'garden',title:'家庭菜園'});
 const memos=[
  // プロジェクトに結び付くメモ。未定の一覧には載らない。
  ['家庭菜園の土を入れ替える','2026-11-01T09:00:00+09:00',result({category:'task',project_candidates:[{id:'garden',confidence:0.9}],next_action_suggestions:['土を買う']})],
  // プロジェクト未定のタスクと、AIの提案。
  ['講習の申込をする','2026-11-02T09:00:00+09:00',result({category:'task'})],
  ['読んだ本の感想を1か所に集めたい','2026-11-03T09:00:00+09:00',result({category:'idea',next_action_suggestions:['感想の書式を決める','直近の3冊で試しに書く'],project_proposal:proposal('読書ノート',[],'読んだ本の記録を続けたい')})],
  ['読書ノートを見返す画面がほしい','2026-11-04T09:00:00+09:00',result({category:'idea',next_action_suggestions:['画面の案を紙に描く'],project_proposal:proposal('読書ノートアプリ',['読書アプリ'],'記録を見返す道具を作りたい')})],
  ['読書の記録を入力しやすくしたい','2026-11-05T09:00:00+09:00',result({category:'idea',project_proposal:proposal('読書の記録づくり',['読書ノート'],'記録の手間を減らしたい')})],
  ['家計簿の項目を見直す','2026-11-06T09:00:00+09:00',result({category:'task',next_action_suggestions:['固定費を書き出す'],project_proposal:{title:'家計の見直し',aliases:[],keywords:['家計'],rationale:'支出を把握したい'}})],
  // 長いメモはAIの一行要約で示す。
  ['引っ越しの準備について考えたことを並べる。'.repeat(8),'2026-11-07T09:00:00+09:00',result({category:'task',summary:'引っ越しの準備を進める',next_action_suggestions:['業者に見積もりを頼む','不用品を分ける','住所変更の一覧を作る','荷造りの日を決める']})],
 ];
 for(const[text,occurredAt]of memos)await capture(config,{source:'cli',occurredAt,text});
 await organize(config,new MockLlm(memos.map(m=>m[2])));
 await rebuildDashboard(config,{now:clock});
 const index=await buildReviewIndex(config),pending=index.items.filter(i=>i.status==='pending'),lead=pending.find(i=>i.duplicates?.length);
 const unassigned=JSON.parse(await vault.read('90_system/unassigned-actions.json'));
 await mkdir('test/fixtures',{recursive:true});
 await writeFile('test/fixtures/unassigned-and-proposals.json',JSON.stringify({schema_version:1,files:await filesAt(config.vaultPath),expected:{pending:pending.length,rows:pending.filter(i=>!i.duplicateOf).length,lead:lead.title,members:lead.duplicates.map(id=>pending.find(i=>i.id===id).title),unassigned:unassigned.total_memos,texts:unassigned.memos.map(m=>m.text)}},null,2)+'\n');
 console.log('プロジェクト未定のメモと、同じ対象を指すプロジェクト案の本体fixtureを生成しました');
}finally{await rm(root,{recursive:true,force:true});}
