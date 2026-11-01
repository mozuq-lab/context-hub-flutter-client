// 読取側fixtureが固定参照の本体の出力形式と一致するかを検査する。
// fixtureは本体の生成物をコミットしたもので、日時・ULID・hashは毎回変わる。そのため値ではなく、
// 正規化したパスごとのfrontmatter/JSONのキー構造と見出しを比較する。本体の形式変更や追加された記録の種類を検出する。
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,cp,readFile,rm,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {parse} from 'yaml';

const repo=resolve(import.meta.dirname,'..');
const fixtures=['assets/sample.json','assets/review.json','assets/scoped-policy.json','test/fixtures/numeric-policy.json'];
const generators=['scripts/prepare_policy_fixtures.mjs','scripts/prepare_numeric_policy_fixture.mjs'];

const volatile=s=>s.replace(/[a-f0-9]{64}/g,'<HASH>').replace(/[0-9A-HJKMNP-TV-Z]{26}/g,'<ULID>').replace(/\d{4}-\d{2}-\d{2}(?:T[\d:.]+(?:Z|[+-]\d{2}:\d{2})?)?/g,'<DATE>');
function shape(value){
  if(value===null)return 'null';
  if(Array.isArray(value))return `[${[...new Set(value.map(shape))].sort().join('|')}]`;
  if(typeof value==='object'){
    // IDをキーにした連想配列は、キー名を正規化して同じ形の項目をまとめる。
    const entries=new Map();for(const[k,v]of Object.entries(value)){const key=volatile(k);entries.set(key,[...new Set([...(entries.get(key)??[]),shape(v)])].sort().join('|'));}
    return `{${[...entries].sort(([a],[b])=>a.localeCompare(b)).map(([k,v])=>`${k}:${v}`).join(',')}}`;
  }
  return typeof value;
}
function fileShape(path,raw){
  if(path.endsWith('.json')){try{return shape(JSON.parse(raw));}catch{return 'invalid-json';}}
  if(path.endsWith('.md')){
    const match=/^---\r?\n([\s\S]*?)\r?\n---\r?\n/.exec(raw);
    const headings=[...new Set(raw.split(/\r?\n/).filter(l=>/^#{1,6}\s/.test(l)).map(l=>volatile(l.replace(/\s+$/,''))))].sort();
    return `fm=${match?shape(parse(match[1])):'none'};h=${headings.join('/')}`;
  }
  return 'text';
}
function signature(fixture){
  const files=fixture.files??fixture, byPath=new Map();
  for(const[path,raw]of Object.entries(files)){const key=volatile(path);byPath.set(key,new Set([...(byPath.get(key)??[]),fileShape(path,raw)]));}
  return {files:byPath,expected:fixture.expected===undefined?'none':shape(fixture.expected)};
}
function differences(name,committed,generated){
  const out=[];
  for(const path of new Set([...committed.files.keys(),...generated.files.keys()])){
    const a=committed.files.get(path),b=generated.files.get(path);
    if(!a)out.push(`${name}: 本体の出力にだけある記録 ${path}`);
    else if(!b)out.push(`${name}: fixtureにだけある記録 ${path}`);
    else{for(const s of b)if(!a.has(s))out.push(`${name}: ${path} の形式が本体と異なる\n    本体: ${s}`);for(const s of a)if(!b.has(s))out.push(`${name}: ${path} の形式が本体にない\n    fixture: ${s}`);}
  }
  if(committed.expected!==generated.expected)out.push(`${name}: expectedの形式が本体と異なる`);
  return out;
}

const root=await mkdtemp(join(tmpdir(),'ctx-fixture-drift-'));
try{
  // 生成スクリプトはcwd相対で書き込むため、作業コピーを汚さないよう一時ディレクトリで実行する。
  await cp(join(repo,'scripts'),join(root,'scripts'),{recursive:true});
  await symlink(join(repo,'vendor'),join(root,'vendor'));
  await mkdir(join(root,'assets'));await mkdir(join(root,'test/fixtures'),{recursive:true});
  for(const script of generators){
    const run=spawnSync(process.execPath,[script],{cwd:root,encoding:'utf8'});
    assert.equal(run.status,0,`${script} が失敗しました\n${run.stderr}`);
  }
  const problems=[];
  for(const fixture of fixtures){
    const committed=JSON.parse(await readFile(join(repo,fixture),'utf8')),generated=JSON.parse(await readFile(join(root,fixture),'utf8'));
    problems.push(...differences(fixture,signature(committed),signature(generated)));
  }
  if(problems.length){
    console.error(`fixtureが固定参照の本体の出力形式と一致しません（${problems.length}件）。\n`+problems.map(p=>`  - ${p}`).join('\n')+
      '\n本体の更新に合わせて node scripts/prepare_policy_fixtures.mjs と node scripts/prepare_numeric_policy_fixture.mjs で再生成し、Dart側の読取を確認してください。');
    process.exitCode=1;
  }else console.log(`fixtureの形式は固定参照の本体と一致: ${fixtures.length}件`);
}finally{await rm(root,{recursive:true,force:true});}
