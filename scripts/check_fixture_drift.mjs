// 読取側fixtureが固定参照の本体の出力形式と一致するかを検査する。
// fixtureは本体の生成物をコミットしたもので、日時・ULID・hashは毎回変わる。
// それらを置換したうえで、パスごとの内容とexpectedを比較する。本体の形式・値・本文書式の変更や、追加された記録の種類を検出する。
// fixtureに含まれない記録（Input/、90_system/intake/、associations/ など）は対象外で、protocolテストが書き込み側を確認する。
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,cp,readFile,rm,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

const repo=resolve(import.meta.dirname,'..');
const fixtures=['assets/sample.json','assets/review.json','assets/scoped-policy.json','test/fixtures/numeric-policy.json'];
const generators=['scripts/prepare_policy_fixtures.mjs','scripts/prepare_numeric_policy_fixture.mjs'];

// 日時・ULID・hashは生成ごとに変わるため置換する。hashを先に置換し、16進の一部を小文字ULIDと誤認しない。
const volatile=s=>s.replace(/[a-f0-9]{64}/g,'<HASH>').replace(/[0-9A-HJKMNP-TV-Z]{26}/g,'<ULID>').replace(/[0-9a-hjkmnp-tv-z]{26}/g,'<ulid>')
  .replace(/\d{4}-\d{2}-\d{2}(?:T[\d:.]+(?:Z|[+-]\d{2}:\d{2})?)?/g,'<DATE>').replace(/<DATE> \d{2}:\d{2}/g,'<DATE> <TIME>');
// 正規化したパスごとに、正規化した内容の多重集合を作る。値・本文の書式・文言の変更も、Dartが読む形式の変更として扱う。
function signature(fixture){
  const files=fixture.files??fixture, byPath=new Map();
  for(const[path,raw]of Object.entries(files)){const key=volatile(path);byPath.set(key,[...(byPath.get(key)??[]),volatile(raw)]);}
  for(const list of byPath.values())list.sort();
  return {files:byPath,expected:fixture.expected===undefined?'none':volatile(JSON.stringify(fixture.expected,null,1))};
}
function firstDifference(a,b){
  const left=a.split('\n'),right=b.split('\n');
  for(let i=0;i<Math.max(left.length,right.length);i++)if(left[i]!==right[i])return `${i+1}行目\n      fixture: ${left[i]??'(なし)'}\n      本体:    ${right[i]??'(なし)'}`;
  return '差分なし';
}
function differences(name,committed,generated){
  const out=[];
  for(const path of new Set([...committed.files.keys(),...generated.files.keys()])){
    const a=committed.files.get(path),b=generated.files.get(path);
    if(!a)out.push(`${name}: 本体の出力にだけある記録 ${path}`);
    else if(!b)out.push(`${name}: fixtureにだけある記録 ${path}`);
    else if(a.length!==b.length)out.push(`${name}: ${path} の件数が異なる（fixture ${a.length}件、本体 ${b.length}件）`);
    else{const i=a.findIndex((text,index)=>text!==b[index]);if(i>=0)out.push(`${name}: ${path} の内容が異なる ${firstDifference(a[i],b[i])}`);}
  }
  if(committed.expected!==generated.expected)out.push(`${name}: expected が異なる ${firstDifference(committed.expected,generated.expected)}`);
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
