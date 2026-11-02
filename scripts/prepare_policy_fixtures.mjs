// サンプルと本体生成の確認一覧を、方針manifestまで揃った架空Vaultへまとめる。
import {mkdtemp,readFile,writeFile,rm,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {defaultConfig,Vault,rebuildDashboard,rebuildDigest,addProject,propose,approve,capture,organize,MockLlm,hash,readPolicies,formatPolicies,retireKnowledge,readKnowledge} from '../vendor/context-hub/packages/core/dist/index.js';
async function filesAt(dir,prefix=''){const out={};for(const e of await readdir(dir,{withFileTypes:true})){if(e.name.startsWith('.'))continue;const p=prefix+e.name;if(e.isDirectory())Object.assign(out,await filesAt(join(dir,e.name),p+'/'));else out[p]=await readFile(join(dir,e.name),'utf8');}return out;}
// 停滞日数とふりかえりの期間が実行日で変わらないよう、生成時刻を固定する。
const clock=new Date('2026-11-02T00:00:00Z');
const root=await mkdtemp(join(tmpdir(),'hub-policy-fixtures-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const sample=await filesAt('vendor/context-hub/sample-vault');for(const[p,raw]of Object.entries(sample))await vault.write(p,raw);await rebuildDigest(config,{now:clock,days:60});await rebuildDashboard(config,{now:clock});await writeFile('assets/sample.json',JSON.stringify(await filesAt(config.vaultPath),null,2)+'\n');
 const exportResult=spawnSync(process.execPath,['vendor/context-hub/scripts/export-review-fixtures.mjs',resolve(root,'review.json')],{encoding:'utf8'});if(exportResult.status!==0)throw new Error(exportResult.stderr);
 const review=JSON.parse(await readFile(join(root,'review.json'),'utf8'));for(const[p,raw]of Object.entries(review.files))await vault.write(p,raw);await rebuildDashboard(config,{now:clock});review.files=await filesAt(config.vaultPath);await writeFile('assets/review.json',JSON.stringify(review,null,2)+'\n');
 const scopedConfig=defaultConfig(join(root,'scoped'),join(root,'scoped-state')),scoped=new Vault(scopedConfig);await scoped.init();await addProject(scopedConfig,{id:'example',title:'対象の例'});
 const projectHash=hash(await scoped.read('10_projects/example/project.md')),target={scope:'project',projectId:'example',projectHash};
 const global=await propose(scopedConfig,{kind:'decision',claim:'共通の採用方針'});await approve(scopedConfig,global.candidateId,global.hash,{scope:'global'});
 const project=await propose(scopedConfig,{kind:'preference',claim:'対象固有の採用方針'});await approve(scopedConfig,project.candidateId,project.hash,target);
 const reference=await propose(scopedConfig,{kind:'knowledge',claim:'必要時に参照する知識'});await approve(scopedConfig,reference.candidateId,reference.hash,target);
 const retired=await propose(scopedConfig,{kind:'decision',claim:'停止した古い方針'}),retiredResult=await approve(scopedConfig,retired.candidateId,retired.hash,{scope:'global'}),old=await readKnowledge(scoped,retiredResult.knowledgeId);await retireKnowledge(scopedConfig,old.id,hash(old.raw));
 const result={category:'decision-candidate',summary:'候補',project_candidates:[{id:'example',confidence:0.8}],next_action_suggestions:[],extracted:{current:[],next:[],open:[]},knowledge_candidate:{kind:'decision',claim:'新しい採用候補',rationale:'使いやすくする'},new_project_hint:null};
 await capture(scopedConfig,{source:'cli',occurredAt:'2026-11-01T00:00:00Z',project:'example',text:'対象のメモ'});await organize(scopedConfig,new MockLlm([result]));await rebuildDashboard(scopedConfig,{now:clock});
 const bundle=await readPolicies(scopedConfig,'example');await writeFile('assets/scoped-policy.json',JSON.stringify({schema_version:1,files:await filesAt(scopedConfig.vaultPath),expected:{bundle,text:formatPolicies(bundle),target}},null,2)+'\n');
 console.log('架空の方針・採用先fixtureを本体から生成しました');
}finally{await rm(root,{recursive:true,force:true});}
