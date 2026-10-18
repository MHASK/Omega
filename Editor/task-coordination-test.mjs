import assert from 'node:assert/strict';
import * as Y from 'yjs';
import {TaskPage} from './task-page.js';
import {parseTasks,serializeTasks,validDetails} from './task-model.js';
import {workGraph,workState,setDependencies} from './task-coordination.js';
import {seedModel,readTasks,updateTasks,taskText} from './live-model.js';

export function runCoordinationTests(){
 const task=(id,details={},status=0)=>({id,title:id,status,done:status===2,details:{id,...details},children:[]});
 const model={title:'Agent plan',statuses:['To do','In progress','Done'],completed:'Done',goals:[],tasks:[
  task('foundation',{omegaPriority:3}),task('release',{omegaDependencies:[{id:'foundation'}]}),
  task('review',{omegaReview:true}),task('owner',{omegaAssignee:'Claude'}),
  task('claimed',{omegaAssignee:'Codex',omegaClaim:{owner:'Codex',token:'receipt',at:'2026-10-18'}}),
  task('missing',{omegaDependencies:[{id:'unavailable'}]}),task('external',{omegaDependencies:[{id:'foundation',path:'Other.md'}]}),
  task('draft',{draft:true}),task('working',{},1),task('done',{},2)
 ]};
 let graph=workGraph(model);
 assert.deepEqual(model.tasks.map(t=>graph(t).state),['ready','blocked','review','assigned','claimed','blocked','blocked','draft','working','done']);
 const before=serializeTasks(model);
 assert.throws(()=>setDependencies(model,model.tasks[0],[{id:'release'}]),/loop/);
 assert.equal(serializeTasks(model),before,'Rejected dependency is nonmutating');
 model.tasks[0].status=2;assert.equal(workState(model,model.tasks[1]).state,'ready');
 model.tasks[0].status=0;
 setDependencies(model,model.tasks[1],[{id:'foundation'},{id:'outside',path:'../Other.md'}]);
 assert.equal(workState(model,model.tasks[1]).blockers.length,2);
 delete model.tasks[1].details.omegaDependencies;model.tasks[1].details.omegaPriority=0;
 const child=task('child',{status:'In progress'});model.tasks[0].children.push(child);
 assert.equal(workState(model,child).state,'working');
 const loop=structuredClone(model);loop.tasks[0].details.omegaDependencies=[{id:'release'}];loop.tasks[1].details.omegaDependencies=[{id:'foundation'}];
 assert.equal(workState(loop,loop.tasks[0]).cyclic,true);
 assert.equal(workState(loop,loop.tasks[1]).state,'blocked');
 assert.equal(workState(loop,loop.tasks[9]).state,'done');
 for(const details of [{omegaPriority:-1},{omegaPriority:5},{omegaPriority:1.5},{omegaPriority:true},{omegaReview:'yes'},{omegaDependencies:[{id:'x',path:'/abs.md'}]},{omegaDependencies:[{id:'x'},{id:'x'}]},{omegaClaim:{owner:'A'}},{omegaHandoff:'x'.repeat(12001)}])assert.equal(validDetails(details),false);
 const roundtrip=parseTasks(serializeTasks(model));assert.deepEqual(roundtrip.tasks.find(t=>t.id==='claimed').details,model.tasks[4].details);

 const root=document.createElement('div');document.body.append(root);let changes=0;
 const view=new TaskPage(root,()=>changes++);assert(view.load(serializeTasks(model)));view.setView('ready');
 assert.equal(root.querySelectorAll('.task-list-row').length,2,'Ready only contains available unassigned work');
 assert(!root.querySelector('[data-task=claimed]'));assert.equal(root.querySelector('.task-list-row').dataset.task,'release','Urgent work sorts first');assert(root.querySelector('[aria-label="Priority P0 · Urgent"]'));
 view.openDetail(view.lookup('foundation').item);
 const panel=root.querySelector('.task-work-panel');assert(panel);
 const priority=root.querySelector('[aria-label="Task priority"]');assert.equal(priority.value,'3');priority.value='1';priority.dispatchEvent(new window.Event('change',{bubbles:true}));assert.equal(parseTasks(view.raw).tasks.find(t=>t.id==='foundation').details.omegaPriority,1);
 const owner=root.querySelector('[aria-label="Assigned to"]');owner.value='Claude / foundation';owner.dispatchEvent(new window.Event('input',{bubbles:true}));
 const handoff=root.querySelector('[aria-label="Handoff"]');handoff.value='Tests pass. Review migration.';handoff.dispatchEvent(new window.Event('input',{bubbles:true}));
 assert(changes>0);assert.equal(parseTasks(view.raw).tasks.find(t=>t.id==='foundation').details.omegaHandoff,'Tests pass. Review migration.');
 view.closeDetail();assert(!root.querySelector('[data-task=foundation]'));
 view.setView('list');view.openDetail(view.lookup('claimed').item);assert(root.querySelector('[aria-label="Assigned to"]').disabled);
 view.setReadOnly(true);assert([...root.querySelectorAll('[data-mutates]')].every(n=>n.disabled));
 view.setReadOnly(false);assert(root.querySelector('[aria-label="Assigned to"]').disabled,'Read-only recovery cannot unlock a claimed owner');
 root.remove();view.descriptions.forEach(e=>e.destroy());

 // Concurrent title and handoff edits survive the existing Yjs checkpoint path.
 const a=seedModel(serializeTasks(model),'tasks'),b=new Y.Doc();Y.applyUpdate(b,Y.encodeStateAsUpdate(a));
 const oldA=readTasks(a),oldB=readTasks(b),nextA=structuredClone(oldA),nextB=structuredClone(oldB);
 nextA.tasks.find(t=>t.id==='foundation').details.omegaHandoff='Keep this review summary';
 nextB.tasks.find(t=>t.id==='foundation').details.omegaPriority=0;nextB.tasks.find(t=>t.id==='foundation').title='Foundation, updated by a teammate';
 updateTasks(a,nextA,oldA);updateTasks(b,nextB,oldB);
 Y.applyUpdate(a,Y.encodeStateAsUpdate(b));Y.applyUpdate(b,Y.encodeStateAsUpdate(a));
 assert.equal(taskText(a),taskText(b));const merged=parseTasks(taskText(a)).tasks.find(t=>t.id==='foundation');
 assert.equal(merged.details.omegaPriority,0);assert.equal(merged.details.omegaHandoff,'Keep this review summary');assert.equal(merged.title,'Foundation, updated by a teammate');a.destroy();b.destroy();

 const wide={...model,tasks:Array.from({length:3000},(_,i)=>task('n'+i,{omegaDependencies:[...new Set([i-1,i-2].filter(n=>n>=0))].map(n=>({id:'n'+n}))},2))};
 wide.tasks.at(-1).status=0;graph=workGraph(wide);assert.equal(graph(wide.tasks.at(-1)).state,'ready');
 wide.tasks[0].details.omegaDependencies=[{id:'n2999'}];assert.equal(workState(wide,wide.tasks.at(-1)).cyclic,true);
 console.log('PASS: Ready queue states, cyclic/missing prerequisites, subtask status, setup UI, read-only ownership, Markdown persistence, concurrent handoffs and large dependency graphs.');
}
