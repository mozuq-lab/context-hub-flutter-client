// Dartが保存したNOW項目の完了・解決報告と、本人が追加する次の一手（行動）と「誤りとして外す」報告、期日・見直す日（と繰り返し）・手間の目安・場所・道具の札・連絡待ち・「いつかやる」の依頼、「いつかやる」の見直し、週次レビューの「見直した」、定例の回の完了・見送り、記録に聞くの問い、端末間でそろえる好み、「片付いたかも」の見送り、作業記録の下書きの見送り、下書きから作った入力、メモの続き、メモの訂正のREQを、
// 手順・領域・整理のやり直しの依頼、ファイルを添えたメモ（files/<受付ID>に置いたファイル）も含む。
// 固定参照の本体が受理して反映するかを検査する。fixtureには前回の出力（ファイルの対応表）も渡せる。
// 4番目の引数に stale を渡すと、古い訂正対象への訂正として本体が受付を断り、理由を記録することを確認する。
import assert from 'node:assert/strict';
import {copyFile,mkdir,mkdtemp,readFile,rm,stat,utimes,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import {join,basename,dirname} from 'node:path';
import {parseIntake,defaultConfig,Vault,ingest,organize,MockLlm,readItemResolutions,readItemSchedules,activeSchedules,readNowItems,readHintDismissals,readGitDrafts,readRereads,rebuildDashboard,readInputs,readItemOccurrences,readAskRecords,answerPending,readClientPreferences,readItemEfforts,readItemContexts,readItemSteps,readOrganizeRetries,readProjectAreaChanges,readProjects,readReceipts,readItemWaits,readItemSomedays,readSomedayReviews,somedayListPath,readWeeklyReviews,weeklyReviewPath,readReferenceMarks,rebuildReferences,readReferenceIndex} from '../vendor/context-hub/packages/core/dist/index.js';
const [file,fixture,out,mode]=process.argv.slice(2),raw=await readFile(file,'utf8'),path=`Input/${basename(file)}`,packet=parseIntake(path,raw,8000);
assert.ok(['item-resolution','item-hint-dismiss','item-schedule','item-effort','item-contexts','item-steps','project-area','organize-retry','item-wait','item-someday','someday-review','weekly-review','item-occurrence','ask','client-preferences','git-draft-dismiss','reference-mark','capture','correct'].includes(packet.operation));
const root=await mkdtemp(join(tmpdir(),'ctx-request-protocol-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 const files=JSON.parse(await readFile(fixture,'utf8'));for(const[p,value]of Object.entries(files.files??files))await vault.write(p,value);
 const resolutionsBefore=(await readItemResolutions(vault)).length;
 // 整理のやり直しは、整理に失敗したメモにだけ頼める。fixtureの整理済みのメモを、Dartが見た試行回数で失敗したことにする。
 if(packet.operation==='organize-retry'){
  const receiptPath=`90_system/receipts/${packet.input_id}.json`,receipt=JSON.parse(await vault.read(receiptPath));
  await vault.write(receiptPath,JSON.stringify({...receipt,status:'failed',attempts:packet.attempts,result:null,writes:[],error:'検査用の失敗'},null,2)+'\n');
 }
 // ファイルを添えた依頼は、Dartが依頼の隣（files/<受付ID>）に置いたファイルを、Vaultの受け渡し場所（Input/files/<受付ID>）へ移す。
 const transport=packet.attachment?await vault.path(`Input/files/${packet.request_id}`):undefined;
 if(transport){await mkdir(dirname(transport),{recursive:true});await copyFile(join(dirname(file),'files',packet.request_id),transport);await utimes(transport,new Date(0),new Date(0));}
 await vault.create(path,raw);await utimes(await vault.path(path),new Date(0),new Date(0));
 if(mode==='stale'){
  // 古い訂正対象は受け付けず、最新の訂正IDを理由に残す。再受付でも重複して記録しない。
  assert.equal(packet.operation,'correct');
  const first=await ingest(config);assert.equal(first.accepted,0);assert.equal(first.rejected,1);
  const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);
  assert.equal(await vault.read(`90_system/intake/${packet.request_id}.json`),undefined);
  const chain=(await readInputs(config)).filter(i=>i.kind==='correction'&&i.corrects_input_id===packet.target_id);
  assert.equal(chain.length,1);
  const errors=await vault.files('90_system/intake-errors');
  const reasons=await Promise.all(errors.map(async p=>JSON.parse(await vault.read(p))));
  assert.ok(reasons.some(e=>e.path===path&&e.reason?.code==='stale-correction-target'&&e.reason.latest_input_id===chain[0].id));
 }else{
 assert.equal((await ingest(config)).accepted,1);const again=await ingest(config);assert.equal(again.accepted,0);assert.equal(again.rejected,0);assert.ok(again.deduped>=1);
 const ack=JSON.parse(await vault.read(`90_system/intake/${packet.request_id}.json`));
 if(packet.operation==='correct'){
  // 訂正は元の原文を残し、Dartが書いた全文をそのまま訂正原文にする。
  const inputs=await readInputs(config),saved=inputs.find(i=>i.id===ack.result.inputId);
  assert.equal(saved.kind,'correction');assert.equal(saved.corrects_input_id,packet.target_id);assert.equal(saved.text,packet.text);assert.equal(saved.source,packet.source);
  assert.ok(inputs.some(i=>i.id===packet.target_id));
 }else if(packet.operation==='item-resolution'){
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,action:ack.result.action,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,action:packet.action,deduped:false});
  assert.equal((await readItemResolutions(vault)).length,resolutionsBefore+1);
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.resolution?.id??null,packet.action==='reopen'?null:ack.result.resolutionId);
  if(packet.action==='exclude'){
   // 誤りとして外した項目は、完了・解決とは別に、理由と一言を付けて項目一覧に残る。
   assert.deepEqual({action:item.resolution.action,reason:item.resolution.reason,note:item.resolution.note},{action:'exclude',reason:packet.reason,note:packet.note});
   // 読み違いは、次の整理でメモを読み直した記録が残り、外した項目は戻せるよう一覧に残る。
   if(packet.reason==='misread'){
    await organize(config,new MockLlm());
    assert.equal((await readRereads(vault)).records.get(item.input_id)?.status,'reread');
    assert.equal((await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key)?.resolution?.id,ack.result.resolutionId);
   }
  }else assert.equal(item.resolution?.action,undefined);
 }else if(packet.operation==='item-schedule'){
  // 変更後の全体（期日と見直す日）がそのまま記録され、NOWの項目一覧に反映される。両方nullなら外す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemSchedules(vault)).records.find(r=>r.id===ack.result.scheduleId);
  assert.deepEqual({due:record.due,review_after:record.review_after,source:record.source},{due:packet.due,review_after:packet.review_after,source:packet.source});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  const clearing=packet.due===null&&packet.review_after===null;
  // 繰り返しを省いた依頼は今の繰り返しを保ち、添えた依頼はそのとおりにする（毎月は期日の日を覚える）。
  if(packet.repeat!==undefined)assert.deepEqual(record.repeat??null,packet.repeat&&packet.due?{...packet.repeat,...(packet.repeat.unit==='month'?{day:Number(packet.due.slice(8))}:{})}:null);
  assert.deepEqual(item.schedule,clearing?null:{id:record.id,due:packet.due,review_after:packet.review_after,...(record.repeat?{repeat:record.repeat}:{})});
  assert.equal(activeSchedules((await readItemSchedules(vault)).records).has(packet.item_key),!clearing);
 }else if(packet.operation==='item-effort'){
  // 変更後の目安がそのまま記録され、NOWの項目一覧に反映される。nullなら外す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemEfforts(vault)).records.find(r=>r.id===ack.result.effortId);
  assert.deepEqual({effort:record.effort,source:record.source,event:record.source_event_id},{effort:packet.effort,source:packet.source,event:packet.request_id});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.effort??null,packet.effort);
 }else if(packet.operation==='item-contexts'){
  // 変更後の札の全体がそのまま記録され、項目一覧とNOWの行末（@札）に反映される。nullなら外す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemContexts(vault)).records.find(r=>r.id===ack.result.contextId);
  assert.deepEqual({contexts:record.contexts,source:record.source,event:record.source_event_id},{contexts:packet.contexts,source:packet.source,event:packet.request_id});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.deepEqual(item.contexts??null,packet.contexts);
  if(packet.contexts&&packet.project_id!=='_unassigned')assert.ok((await vault.read(`10_projects/${packet.project_id}/NOW.md`)).includes(packet.contexts.map(t=>`@${t}`).join(' ')));
 }else if(packet.operation==='item-steps'){
  // 変更後の手順の全体がそのまま記録され、項目一覧とNOWの行末（今の手順）に反映される。nullなら外す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemSteps(vault)).records.find(r=>r.id===ack.result.stepsId);
  assert.deepEqual({steps:record.steps,source:record.source,event:record.source_event_id},{steps:packet.steps,source:packet.source,event:packet.request_id});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.deepEqual(item.steps?{items:item.steps.items,done:item.steps.done}:null,packet.steps);
  if(packet.steps&&packet.project_id!=='_unassigned'&&packet.steps.done<packet.steps.items.length)assert.ok((await vault.read(`10_projects/${packet.project_id}/NOW.md`)).includes(`手順 ${packet.steps.done+1}/${packet.steps.items.length}: `));
 }else if(packet.operation==='project-area'){
  // 確認したproject.mdのhashに結び付けて、領域だけが書き換わる（nullなら外す）。登録簿の欄は変わらない。
  assert.deepEqual({projectId:ack.result.projectId,area:ack.result.area,deduped:ack.result.deduped},{projectId:packet.project_id,area:packet.area,deduped:false});
  const change=(await readProjectAreaChanges(vault)).records.find(r=>r.id===ack.result.areaChangeId);
  assert.deepEqual({to:change.to,before:change.before_hash,source:change.source,event:change.source_event_id},{to:packet.area,before:packet.project_hash,source:packet.source,event:packet.request_id});
  assert.equal((await readProjects(config)).find(p=>p.id===packet.project_id).area??null,packet.area);
 }else if(packet.operation==='organize-retry'){
  // やり直しの記録ができ、次の整理でそのメモだけをもう一度試して整理済みになる。
  assert.deepEqual({inputId:ack.result.inputId,deduped:ack.result.deduped},{inputId:packet.input_id,deduped:false});
  const record=(await readOrganizeRetries(vault)).records.find(r=>r.id===ack.result.retryId);
  assert.deepEqual({input:record.input_id,attempts:record.attempts,event:record.source_event_id},{input:packet.input_id,attempts:packet.attempts,event:packet.request_id});
  const tried=await organize(config,new MockLlm());
  assert.deepEqual(tried.inputIds,[packet.input_id]);
  assert.deepEqual(((await readReceipts(config)).find(r=>r.input_id===packet.input_id)),{...(await readReceipts(config)).find(r=>r.input_id===packet.input_id),status:'organized',attempts:packet.attempts+1});
 }else if(packet.operation==='item-wait'){
  // 変更後の印（相手と頼んだ日）がそのまま記録され、項目一覧に反映される。nullなら外す。NOW.mdには相手の名前を載せない。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemWaits(vault)).records.find(r=>r.id===ack.result.waitId);
  assert.deepEqual({waiting:record.waiting,source:record.source,event:record.source_event_id},{waiting:packet.waiting,source:packet.source,event:packet.request_id});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.deepEqual(item.waiting??null,packet.waiting?{id:record.id,...packet.waiting}:null);
  if(packet.waiting?.who){
   for(const p of await vault.files('10_projects')) if(p.endsWith('/NOW.md')) assert.ok(!(await vault.read(p)).includes(packet.waiting.who));
  }
 }else if(packet.operation==='item-someday'){
  // 移した日と見直した日がそのまま記録され、項目一覧に反映される。nullなら戻す。移した項目は「いつかやる」の一覧に並ぶ。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,deduped:false});
  const record=(await readItemSomedays(vault)).records.find(r=>r.id===ack.result.somedayId);
  assert.deepEqual({someday:record.someday,source:record.source,event:record.source_event_id},{someday:packet.someday,source:packet.source,event:packet.request_id});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.deepEqual(item.someday??null,packet.someday?{id:record.id,since:packet.someday.since,reviewed:packet.someday.reviewed??packet.someday.since}:null);
  const list=JSON.parse(await vault.read(somedayListPath));
  assert.equal(list.entries.some(e=>e.kind==='item'&&e.item_key===packet.item_key),packet.someday!==null);
  assert.ok(Date.parse(list.generated_at)>=Date.parse(record.created_at));
 }else if(packet.operation==='someday-review'){
  // 見直しの記録が残り、「いつかやる」の一覧が記録の後に書き直される（アプリは書いた日時で反映を確かめる）。
  assert.deepEqual({target:ack.result.target,targetId:ack.result.targetId,action:ack.result.action,deduped:ack.result.deduped},{target:packet.target,targetId:packet.target_id,action:packet.action,deduped:false});
  const record=(await readSomedayReviews(vault)).records.find(r=>r.id===ack.result.reviewId);
  assert.deepEqual({target:record.target,id:record.target_id,action:record.action,on:record.on,event:record.source_event_id},{target:packet.target,id:packet.target_id,action:packet.action,on:packet.on,event:packet.request_id});
  const list=JSON.parse(await vault.read(somedayListPath)),listed=list.entries.some(e=>e.kind===packet.target&&(e.idea_id??e.project_id)===packet.target_id);
  assert.equal(listed,['add','keep'].includes(packet.action));
  assert.ok(Date.parse(list.generated_at)>=Date.parse(record.created_at));
 }else if(packet.operation==='weekly-review'){
  // 見直した日が記録され、点検の一覧が記録の後に書き直される（アプリは書いた日時で反映を確かめる）。
  assert.deepEqual({on:ack.result.on,deduped:ack.result.deduped},{on:packet.on,deduped:false});
  const record=(await readWeeklyReviews(vault)).records.find(r=>r.id===ack.result.weeklyReviewId);
  assert.deepEqual({on:record.on,source:record.source,event:record.source_event_id},{on:packet.on,source:packet.source,event:packet.request_id});
  const list=JSON.parse(await vault.read(weeklyReviewPath));
  assert.deepEqual(list.last_review,{id:record.id,on:packet.on,created_at:record.created_at});
  assert.ok(Date.parse(list.generated_at)>=Date.parse(record.created_at));
 }else if(packet.operation==='item-occurrence'){
  // 今の回を片付けた記録を残し、項目は欄に残したまま期日を次の回へ進める。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,action:ack.result.action,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,action:packet.action,deduped:false});
  const occurrence=(await readItemOccurrences(vault)).records.find(o=>o.id===ack.result.occurrenceId);
  assert.deepEqual({due:occurrence.due,next:occurrence.next_due,source:occurrence.source},{due:packet.due,next:ack.result.nextDue,source:packet.source});
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.resolution,null);assert.equal(item.schedule.due,ack.result.nextDue);assert.ok(ack.result.nextDue>packet.due);
 }else if(packet.operation==='ask'){
  // 問いは受付で答え待ちとして記録し、答えはcycleと同じ処理で作る（モックのモデル）。
  const before=(await readAskRecords(vault)).records.find(r=>r.id===ack.result.askId);
  assert.deepEqual({status:before.status,question:before.question,project:before.project,event:before.source_event_id},{status:'pending',question:packet.text,project:packet.project??null,event:packet.request_id});
  await answerPending(config,new MockLlm());
  const after=(await readAskRecords(vault)).records.find(r=>r.id===ack.result.askId);
  assert.notEqual(after.status,'pending');
 }else if(packet.operation==='client-preferences'){
  // 送ったまとまりを、送った日時・端末・受付IDとともに記録する。
  const body=JSON.parse(packet.text),stored=await readClientPreferences(vault);
  assert.deepEqual([...ack.result.applied].sort(),Object.keys(body.groups).sort());
  for(const[g,v]of Object.entries(body.groups))assert.deepEqual({device:stored.groups[g].device,request:stored.groups[g].request_id,value:stored.groups[g].value},{device:body.device,request:packet.request_id,value:v.value});
 }else if(packet.operation==='item-hint-dismiss'){
  // 見送りは候補の表示だけを変え、項目は未解決のまま残す。
  assert.deepEqual({projectId:ack.result.projectId,itemKey:ack.result.itemKey,hintInputId:ack.result.hintInputId,deduped:ack.result.deduped},{projectId:packet.project_id,itemKey:packet.item_key,hintInputId:packet.input_id,deduped:false});
  assert.ok((await readHintDismissals(vault)).some(d=>d.id===ack.result.dismissalId&&d.item_key===packet.item_key&&d.input_id===packet.input_id));
  const item=(await readNowItems(vault,packet.project_id)).items.find(i=>i.key===packet.item_key);
  assert.equal(item.resolution,null);assert.equal(item.hints,undefined);
 }else if(packet.operation==='reference-mark'){
  // 資料の記録は、本人の判断（加える・名前・外す）をそのまま残し、資料棚の一覧に反映される。
  assert.deepEqual({inputId:ack.result.inputId,action:ack.result.action,deduped:ack.result.deduped},{inputId:packet.input_id,action:packet.action,deduped:false});
  const record=(await readReferenceMarks(vault)).records.find(r=>r.id===ack.result.markId);
  assert.deepEqual({input:record.input_id,action:record.action,title:record.title,source:record.source,event:record.source_event_id,decided:record.decided_at},{input:packet.input_id,action:packet.action,title:packet.title??null,source:packet.source,event:packet.request_id,decided:new Date(packet.occurred_at).toISOString()});
  await rebuildReferences(config);
  const index=await readReferenceIndex(vault),entry=index.entries.find(e=>e.input_id===packet.input_id);
  if(packet.action==='add')assert.deepEqual({title:entry?.title,by:entry?.added_by,mark:entry?.mark_id,removed:index.removed.some(e=>e.input_id===packet.input_id)},{title:packet.title??null,by:'person',mark:record.id,removed:false});
  else{assert.equal(entry,undefined);assert.equal(index.removed.find(e=>e.input_id===packet.input_id)?.mark_id,record.id);}
  assert.equal(index.marks_through,record.created_at);
 }else if(packet.operation==='git-draft-dismiss'){
  assert.deepEqual({draftId:ack.result.draftId,dismissed:ack.result.dismissed},{draftId:packet.draft_id,dismissed:true});
  assert.equal((await readGitDrafts(config)).find(d=>d.id===packet.draft_id).status,'dismissed');
 }else if(packet.kind==='action'){
  // 本人が追加した行動は、モデルで整理せずに本人の言葉のままNOWの次の一手へ載る。元の行（AIの読み取り）は欄から外れる。
  const saved=(await readInputs(config)).find(i=>i.id===ack.result.inputId);
  assert.deepEqual({kind:saved.kind,text:saved.text,project:saved.project,tool:saved.tool,meta:saved.meta},{kind:'action',text:packet.text,project:packet.project,tool:undefined,meta:packet.meta});
  // プロジェクトを指定しない行動は、プロジェクト未定の項目一覧（_unassigned）に載る。
  const scope=packet.project??'_unassigned',items=(await readNowItems(vault,scope)).items,item=items.find(i=>i.input_id===saved.id);
  assert.deepEqual({section:item.section,label:item.label,text:item.text,resolution:item.resolution},{section:'next',label:'本人が追加: ',text:packet.text,resolution:null});
  assert.deepEqual(item.action,packet.meta?{from:{input_id:packet.meta.action_from_input,text:packet.meta.action_from_text,...(packet.meta.action_from_key?{key:packet.meta.action_from_key}:{})}}:{});
  if(packet.meta?.action_from_key)assert.ok(!items.some(i=>i.key===packet.meta.action_from_key));
  // 追加と一緒に付けた手間の目安と札は、行動の記録として項目に載る。
  if(packet.effort!==undefined)assert.equal(item.effort,packet.effort);
  if(packet.contexts!==undefined)assert.deepEqual(item.contexts,packet.contexts);
  // 本人が追加した行動を移した（元の行が行動の）ときは、元の行動はどの置き場の一覧からも外れる。
  if(packet.meta)for(const p of ['_unassigned',...(await vault.files('90_system/now-items')).map(f=>basename(f,'.json')).filter(x=>x!=='_unassigned')])assert.ok(!((await readNowItems(vault,p))?.items??[]).some(i=>i.action&&i.input_id===packet.meta.action_from_input));
  const llm=new MockLlm();let calls=0;const complete=llm.complete.bind(llm);llm.complete=(...a)=>{calls++;return complete(...a);};
  await organize(config,llm);assert.equal(calls,0);
  if(packet.meta&&packet.project)assert.ok(!(await vault.read(`10_projects/${packet.project}/NOW.md`)).includes(`${packet.meta.action_from_text} [${packet.meta.action_from_input}](`));
 }else if(packet.continues!==undefined){
  // 続きは前のメモにつながり、プロジェクトを選ばなければ前のメモで指定したプロジェクトを引き継ぐ。
  const inputs=await readInputs(config),saved=inputs.find(i=>i.id===ack.result.inputId),parent=inputs.find(i=>i.id===packet.continues);
  assert.ok(parent);
  assert.deepEqual({continues:saved.continues_input_id,text:saved.text,kind:saved.kind},{continues:packet.continues,text:packet.text,kind:packet.kind??'memo'});
  assert.equal(saved.project,packet.project??parent.project);
  await organize(config,new MockLlm());
 }else if(packet.reference!==undefined){
  // 資料として保存したメモは、保存と同時に資料の記録が付き、AIの分類に関係なく資料棚に載る（アイデアにしない）。
  const saved=(await readInputs(config)).find(i=>i.id===ack.result.inputId);
  assert.deepEqual({text:saved.text,kind:saved.kind},{text:packet.text,kind:packet.kind??'memo'});
  const record=(await readReferenceMarks(vault)).records.find(r=>r.input_id===saved.id);
  assert.deepEqual({action:record.action,title:record.title,source:record.source},{action:'add',title:packet.reference_title??null,source:packet.source});
  await organize(config,new MockLlm());
  // モックのモデルはURLのあるメモを資料と読む。ファイルだけのメモは資料と読まないが、資料棚には載る（AIの分類に関係しない）。
  const receipt=(await readReceipts(config)).find(r=>r.input_id===saved.id);
  assert.equal(receipt?.status,'organized');
  if(!packet.attachment)assert.equal(receipt.result?.category,'reference');
  await rebuildReferences(config);
  const entry=(await readReferenceIndex(vault)).entries.find(e=>e.input_id===saved.id);
  assert.deepEqual({title:entry.title,by:entry.added_by},{title:packet.reference_title??null,by:'person'});
  if(packet.attachment){
   // 添えたファイルはVaultの05_filesに複製され、メモの記録と資料棚の一覧にファイルが載る。受け渡し場所の写しは消える。
   assert.deepEqual({name:saved.attachment.name,bytes:saved.attachment.bytes,sha256:saved.attachment.sha256},packet.attachment);
   assert.match(saved.attachment.path,/^05_files\/\d{4}-\d{2}\/[0-9a-f]{24}\//);
   const copied=await readFile(await vault.path(saved.attachment.path));
   assert.equal(createHash('sha256').update(copied).digest('hex'),packet.attachment.sha256);
   await assert.rejects(stat(transport),{code:'ENOENT'});
   assert.deepEqual(entry.file,{path:saved.attachment.path,name:packet.attachment.name,bytes:packet.attachment.bytes});
  }
 }else{
  // 下書きから作った入力は、確認した下書きのhashが一致すれば使用済みになる。
  await organize(config,new MockLlm());
  assert.equal((await readGitDrafts(config)).find(d=>d.id===packet.meta.git_draft).status,'used');
 }
 }
 assert.equal(await vault.read(path),raw);
 await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
 const snapshot={};for(const dir of ['00_inbox','10_projects','20_ideas','30_knowledge','90_system','Input'])for(const p of await vault.files(dir))snapshot[p]=await vault.read(p);
 for(const p of ['POLICY.md','REVIEW.md']){const v=await vault.read(p);if(v!==undefined)snapshot[p]=v;}
 await writeFile(out,JSON.stringify(snapshot));
 process.stdout.write(`DartのREQ（${packet.operation}）を受理し、反映と重複なしを確認\n`);
}finally{await rm(root,{recursive:true,force:true});}
