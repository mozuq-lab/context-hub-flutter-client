// JavaScriptが整数キーを列挙する順序を含む、本体由来の共通fixture。
import {mkdtemp,rm,writeFile,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {defaultConfig,Vault,addProject,hash,propose,approve,readPolicies,formatPolicies} from '../vendor/context-hub/packages/core/dist/index.js';
const root=await mkdtemp(join(tmpdir(),'hub-numeric-policy-'));
try{const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();for(const id of ['100','20','alpha']){await addProject(config,{id,title:`対象${id}`});const c=await propose(config,{kind:'decision',claim:`対象${id}の方針`});await approve(config,c.candidateId,c.hash,{scope:'project',projectId:id,projectHash:hash(await vault.read(`10_projects/${id}/project.md`))});}const files={};for(const dir of ['10_projects','30_knowledge','90_system'])for(const p of await vault.files(dir))files[p]=await vault.read(p);files['POLICY.md']=await vault.read('POLICY.md');const b=await readPolicies(config,'100');await mkdir('test/fixtures',{recursive:true});await writeFile('test/fixtures/numeric-policy.json',JSON.stringify({schema_version:1,files,expected:{text:formatPolicies(b)}},null,2)+'\n');console.log('数字IDを含む本体fixtureを生成しました');}finally{await rm(root,{recursive:true,force:true});}
