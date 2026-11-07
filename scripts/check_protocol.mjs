import assert from 'node:assert/strict';
import {mkdtemp,readFile,copyFile,mkdir,utimes,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,basename} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,readInputs,addProject} from '../vendor/context-hub/packages/core/dist/index.js';

// Dartが保存した実際の受付ファイルを固定上流のコードへ渡す。
const [file,expectedFile]=process.argv.slice(2);
const path=`Input/${basename(file)}`, raw=await readFile(file,'utf8');
const expected=JSON.parse(await readFile(expectedFile,'utf8'));
const packet=parseIntake(path,raw,8000);
assert.equal(packet.text,expected.text);
assert.equal(packet.source,`flutter-client/${expected.operationId}`);
assert.equal(packet.project,expected.project);
// 選んで深掘りのメモはmeta（文字列だけ）を付ける。付けない入力ではmetaがないことも確かめる。
assert.deepEqual(packet.meta,expected.meta);
const root=await mkdtemp(join(tmpdir(),'ctx-flutter-protocol-'));
try {
  const config=defaultConfig(join(root,'vault'),join(root,'state'));
  const vault=new Vault(config);await vault.init();
  if (expected.project) await addProject(config,{id:expected.project,title:'互換検証プロジェクト'});
  await mkdir(join(config.vaultPath,'Input'),{recursive:true});
  await copyFile(file,join(config.vaultPath,path));
  await utimes(join(config.vaultPath,path),new Date(0),new Date(0));
  assert.equal((await ingest(config)).accepted,1);
  assert.equal((await ingest(config)).deduped,1);
  const inputs=await readInputs(config);
  assert.equal(inputs.length,1);assert.equal(inputs[0].text,expected.text);
  assert.equal(inputs[0].origin,'user-note');
  assert.deepEqual(inputs[0].meta,expected.meta);
  assert.equal(await readFile(join(config.vaultPath,path),'utf8'),raw);
  console.log('上流parseIntake/ingest: 原文一致、受領1件、再受付の重複なし');
} finally {await rm(root,{recursive:true,force:true});}
