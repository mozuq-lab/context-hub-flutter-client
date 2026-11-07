// 端末からのメモをN件受け付けて整理したVaultを、固定参照の本体（MockLlm）で作り、
// アプリが走査する範囲のファイルをJSONで書き出す。記録が増えたときの読取件数の検証に使う。
// 使い方: node scripts/generate_growth_vault.mjs <件数> <出力.json>
import {mkdtemp,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {defaultConfig,Vault,markdown,addProject,runCycle,MockLlm} from '../vendor/context-hub/packages/core/dist/index.js';

const [countArg,out]=process.argv.slice(2),count=Number(countArg);
if(!Number.isSafeInteger(count)||count<1||count>2000||!out)throw new Error('使い方: generate_growth_vault.mjs <1〜2000> <出力.json>');
const root=await mkdtemp(join(tmpdir(),'ctx-growth-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 await addProject(config,{id:'garden',title:'家庭菜園',aliases:['菜園'],keywords:['苗']});
 for(let i=0;i<count;i++){
  const request_id=`REQ-${i.toString(16).padStart(32,'0')}`,path=`Input/${request_id}.md`;
  const meta={schema_version:1,request_id,operation:'capture',kind:i%5===0?'work-summary':'memo',source:'growth-test-device',occurred_at:new Date(Date.UTC(2026,9,1)+i*3600_000).toISOString(),tool:'context-hub-flutter',...(i%2===0?{project:'garden'}:{})};
  await vault.create(path,markdown(meta,`架空のメモ${i}: 菜園の苗の様子`));
  await utimes(join(config.vaultPath,path),new Date(0),new Date(0));
 }
 // 1回の受付件数には上限があるため、受け付けと整理がなくなるまで繰り返す。
 for(let round=0;round<count+5;round++){const r=await runCycle(config,new MockLlm(),{limit:count*2});if(!r.intake.accepted&&!r.organize.processed)break;}
 const files={},entries={};
 for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir)){
  // アプリと同じく、.md/.json以外は数えるが読まない。
  const parts=p.split('/');for(let k=2;k<parts.length;k++)entries[parts.slice(0,k).join('/')+'/']=true;
  entries[p]=true;if(/\.(md|json)$/.test(p))files[p]=await vault.read(p);
 }
 for(const p of ['POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined){files[p]=v;entries[p]=true;}}
 await writeFile(out,JSON.stringify({count,files,entries:Object.keys(entries)}));
}finally{await rm(root,{recursive:true,force:true});}
