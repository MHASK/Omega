import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {parseTasks,taskImport,serializeTasks,walkTasks,subtaskStatus,goalProgress,isCompleted} from '../Editor/task-model.js';
const base='<!-- folio:tasks -->\n# Shared plan\n\n## Goals\n- [ ] Launch\n  <!-- folio:task {"id":"goal-a","status":"Planning","vendor":{"ticket":42,"archived":false,"empty":null}} -->\n\n## To do\n- [ ] Parent 👋\n  <!-- folio:task {"id":"parent","description":"Keep **formatting** and \\nnewlines","labels":["Writing"],"goals":["goal-a"],"owner":"claude","extra":[1,2.5,null,{"keep":true}]} -->\n  - [x] Child\n    <!-- folio:task {"id":"child","due":"2028-02-29","status":"Review","vendor":{"url":"https://example.com"}} -->\n\n## Done\n- [x] Complete\n';
const fixtures=[];
const add=(name,text,accepted,mutate=false)=>fixtures.push({name,text,...(accepted===undefined?{}:{accepted}),mutate});
add('baseline',base,true);
for(const [extra,accepted] of [[['Review'],true],[['Done'],false],[['Missing'],false],[[],false],['Review',false]])add('multiple completed '+JSON.stringify(extra),base.replace('\n# Shared plan','\n<!-- folio:completed-also '+JSON.stringify(extra)+' -->\n# Shared plan'),accepted,true);

add('mutation preserves unknown metadata',base,true,true);
add('BOM and whitespace','\uFEFF\n\n'+base,true);
add('tight closing comments',base.replaceAll('} -->','}-->'),true);
add('metadata begins next line',base.replaceAll('folio:task {','folio:task\n  {'),true);
add('CRLF',base.replace(/\n/g,'\r\n'),true);
add('CR',base.replace(/\n/g,'\r'),true);
for(const bullet of ['*','+'])add('bullet '+bullet,base.replace(/- \[/g,bullet+' ['),true);
add('multiline JSON',base.replace(/<!-- folio:task (.*?) -->/g,(_,json)=>'<!-- folio:task '+JSON.stringify(JSON.parse(json),null,2)+' -->'),true);
add('nullable optional fields',base.replace('"labels":["Writing"]','"labels":null,"due":null,"draft":null'),true);
add('prototype-shaped JSON keys',base.replace('"owner":"claude"','"__proto__":{"safe":true},"constructor":"still data"'),true);
add('explicit ID conflicts with generated UI ID',base.replace('"id":"parent"','"id":"legacy-4"'),true);
for(const [name,from,to] of [
 ['duplicate ID','"id":"child"','"id":"parent"'],['invalid date','2028-02-29','2027-02-29'],
 ['wrong label type','"labels":["Writing"]','"labels":"Writing"'],['wrong boolean','"archived":false','"archived":false,"draft":1'],
 ['unsafe number','"ticket":42','"ticket":9007199254740993'],['invalid status','"status":"Review"','"status":"#oops"'],
 ['orphan child','- [ ] Parent 👋','  - [ ] Parent 👋'],['odd indent','  - [x] Child','   - [x] Child'],
 ['wrong metadata placement','  <!-- folio:task {"id":"parent"','<!-- folio:task {"id":"parent"'],
 ['invalid JSON','"owner":"claude"','"owner":'],['unknown prose','## To do','## To do\nA paragraph outside the model'],
 ['repeated heading','## Done','## To do'],['ambiguous case','"status":"Review"','"status":"done"'],
 ])add(name,base.replace(from,to),name==='wrong boolean'); // boolean in vendor metadata is opaque
add('duplicate JSON key',base.replace('"owner":"claude"','"owner":"first","owner":"second"'),false);
add('escaped duplicate JSON key',base.replace('"owner":"claude"','"owner":"first","ow\\u006eer":"second"'),false);
add('wrong draft type',base.replace('"owner":"claude"','"draft":1'),false);
add('deep JSON',base.replace('"owner":"claude"','"owner":'+JSON.stringify(Array.from({length:18}).reduce(v=>[v],0))),false);
add('too many statuses',base+'\n'+Array.from({length:13},(_,i)=>`## Phase ${i}\n`).join(''),false);
add('oversized metadata',base.replace('"owner":"claude"','"owner":"'+'x'.repeat(131073)+'"'),false);
// Coordination metadata has the same validation and round-trip on every host.
for(const [details,accepted] of [
 [{omegaAssignee:'Claude',omegaHandoff:'Tests passed',omegaReview:true,omegaDependencies:[{id:'child'}]},true],
 [{omegaClaim:{owner:'Codex',token:'receipt',at:'2026-10-18'}},true],
 [{omegaDependencies:[{id:'remote',path:'../Plan.md'}]},true],
 [{omegaDependencies:[{id:'bad.id'}]},false],
 [{omegaDependencies:[{id:'child'},{id:'child'}]},false],
 [{omegaDependencies:[{id:'child',path:'/absolute'}]},false],
 [{omegaDependencies:[{id:'child',path:'back\\slash'}]},false],
 [{omegaDependencies:[{id:'child',path:null}]},false],
 [{omegaDependencies:'task'},false],
 [{omegaClaim:{owner:'Codex'}},false],
 [{omegaAssignee:'x'.repeat(201)},false],
 [{omegaHandoff:'x'.repeat(12001)},false],
 [{omegaReview:1},false],
 [{omegaAudience:'human'},true],[{omegaAudience:'agent'},true],[{omegaAudience:'robot'},false],[{omegaClaim:{owner:'A',token:'x',at:'now',expires:1234}},true],[{omegaClaim:{owner:'A',token:'x',at:'now',expires:-1}},false],[{omegaClaim:{owner:'A',token:'x',at:'now',expires:'yesterday'}},false],
 [{omegaPriority:0},true],[{omegaPriority:4},true],[{omegaPriority:-1},false],[{omegaPriority:5},false],[{omegaPriority:1.5},false],[{omegaPriority:true},false],[{omegaPriority:'P1'},false]
])add('coordination '+JSON.stringify(details).slice(0,90),base.replace('"owner":"claude"',JSON.stringify(details).slice(1,-1)),accepted,true);
// Every truncation boundary, not a single hand-picked broken record.
const characters=Array.from(base);for(let i=0;i<characters.length;i++)add('truncated '+i,characters.slice(0,i).join(''));
for(let i=0;i<80;i++){
 const details={id:'external-'+i,status:['To do','Done','Review'][i%3],description:'Unicode 🧑🏽‍💻 '+i,labels:['label'+i],integration:{owner:'outside',number:i,flags:[true,false,null],text:'<b>data</b>'}};
 add('generated metadata '+i,base.replace(/  <!-- folio:task .*"id":"parent".*? -->/, '  <!-- folio:task '+JSON.stringify(details)+' -->'),true,true);
}
function normalized(model){
 const item=(v,parent=false)=>({title:v.title,details:v.details,done:parent?isCompleted(model,subtaskStatus(model,v)):isCompleted(model,v.status),status:parent?model.statuses[subtaskStatus(model,v)]:model.statuses[v.status],children:v.children.map(c=>item(c,true))});
 return {title:model.title,statuses:model.statuses,completed:model.completed,completedAlso:model.completedAlso||[],goals:model.goals.map(g=>({title:g.title,details:g.details,done:goalProgress(model,g).done})),tasks:model.tasks.map(v=>item(v)).sort((a,b)=>model.statuses.indexOf(a.status)-model.statuses.indexOf(b.status))};
}
if(process.argv[2]==='--fixtures'){fs.writeFileSync(process.argv[3],JSON.stringify(fixtures));process.exit();}
let results;
if(process.argv[2]==='--verify')results=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
else{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'omega-import-'));
 try{const file=path.join(dir,'fixtures.json'),binary=path.join(dir,'check');fs.writeFileSync(file,JSON.stringify(fixtures));execFileSync('swiftc',['Core.swift','Coordination.swift','Tests/TaskImportContract.swift','-o',binary]);results=JSON.parse(execFileSync(binary,[file],{maxBuffer:20e6}).toString());}
 finally{fs.rmSync(dir,{recursive:true,force:true});}
}
assert.equal(results.length,fixtures.length);
for(const [i,fixture] of fixtures.entries()){
 const {model,issue}=taskImport(fixture.text),native=results[i];
 assert.equal(native.accepted,!!model,fixture.name+': Swift/JS disagree: '+native.error);
 if(fixture.accepted!==undefined)assert.equal(!!model,fixture.accepted,fixture.name);
 if(!model){assert(issue?.message&&issue.line>0,fixture.name);continue;}
 const ids=[...model.goals,...walkTasks(model).map(e=>e.item)].map(v=>v.id);assert.equal(new Set(ids).size,ids.length,fixture.name+' IDs');
 if(fixture.mutate&&model.tasks.length)model.tasks[0].title+=' edited';
 const canonical=parseTasks(serializeTasks(model));assert(canonical,fixture.name);
 assert.deepEqual(normalized(parseTasks(native.text)),normalized(canonical),fixture.name+' round trip and metadata');
}
console.log(`PASS: ${fixtures.length} shared Swift/JavaScript import contracts, including every truncation boundary, metadata mutations, Unicode, IDs, and precision limits.`);
