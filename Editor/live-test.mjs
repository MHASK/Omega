import assert from 'node:assert/strict';
import {Editor} from '@tiptap/core';
import Collaboration from '@tiptap/extension-collaboration';
import {prosemirrorToYDoc} from '@tiptap/y-tiptap';
import {extensions} from './schema.js';
import {Y,localOrigin,remoteOrigin,seedModel,updateTasks,readTasks,taskText,changeText} from './live-model.js';
import {parseTasks,reparentTask} from './task-model.js';
export function testLive(){
 const seed=new Editor({element:document.createElement('div'),extensions:extensions({nativeHistory:true}),content:'# Shared\n\nHello world',contentType:'markdown'}),initial=prosemirrorToYDoc(seed.state.doc,'body');seed.destroy();
 const a=new Y.Doc({gc:false}),b=new Y.Doc({gc:false});Y.applyUpdate(a,Y.encodeStateAsUpdate(initial));Y.applyUpdate(b,Y.encodeStateAsUpdate(initial));
 const editorFor=doc=>new Editor({element:document.createElement('div'),extensions:[...extensions({nativeHistory:true}),Collaboration.configure({document:doc,field:'body'})]});
 const ea=editorFor(a),eb=editorFor(b);ea.commands.insertContentAt(10,'Alice ');eb.commands.insertContentAt(20,' Bob');
 Y.applyUpdate(a,Y.encodeStateAsUpdate(b),remoteOrigin);Y.applyUpdate(b,Y.encodeStateAsUpdate(a),remoteOrigin);
 assert.equal(ea.getMarkdown(),eb.getMarkdown());assert.ok(ea.getMarkdown().includes('Alice'));assert.ok(ea.getMarkdown().includes('Bob'));
 ea.commands.undo();Y.applyUpdate(b,Y.encodeStateAsUpdate(a),remoteOrigin);assert.ok(!eb.getMarkdown().includes('Alice'));assert.ok(eb.getMarkdown().includes('Bob'),'local undo retains peer edit');ea.commands.redo();
 ea.destroy();eb.destroy();a.destroy();b.destroy();initial.destroy();
 const text='<!-- folio:tasks -->\n# Plan\n\n## Goals\n\n- [ ] Launch\n  <!-- folio:task {"id":"goal"} -->\n\n## To do\n\n- [ ] Task\n  <!-- folio:task {"id":"task","description":"A shared description","labels":["one"]} -->\n  - [ ] Child\n    <!-- folio:task {"id":"child","description":"Child description","labels":["child"]} -->\n\n## In progress\n\n## Done\n';
 const base=seedModel(text,'tasks'),left=new Y.Doc({gc:false}),right=new Y.Doc({gc:false});Y.applyUpdate(left,Y.encodeStateAsUpdate(base));Y.applyUpdate(right,Y.encodeStateAsUpdate(base));
 let before=readTasks(left),next=structuredClone(before);next.tasks[0].title='Better task';next.tasks[0].details.labels.push('two');updateTasks(left,next,before);
 before=readTasks(right);next=structuredClone(before);next.tasks[0].details.description+=' together';next.tasks[0].status=1;next.tasks[0].details.labels.push('three');next.tasks[0].details.goals=['goal'];updateTasks(right,next,before);
 Y.applyUpdate(left,Y.encodeStateAsUpdate(right),remoteOrigin);Y.applyUpdate(right,Y.encodeStateAsUpdate(left),remoteOrigin);
 assert.equal(taskText(left),taskText(right));const merged=readTasks(left).tasks[0];assert.equal(merged.title,'Better task');assert.equal(merged.status,1);assert.equal(merged.details.description,'A shared description together');assert.deepEqual(merged.details.labels,['one','three','two']);assert.deepEqual(merged.details.goals,['goal']);assert.ok(parseTasks(taskText(left)));
 before=readTasks(left);next=structuredClone(before);reparentTask(next,'child',null);updateTasks(left,next,before);Y.applyUpdate(right,Y.encodeStateAsUpdate(left));assert.equal(readTasks(right).tasks.find(t=>t.id==='child').details.description,'Child description');
 const undo=new Y.UndoManager(left.getMap('items'),{trackedOrigins:new Set([localOrigin])});before=readTasks(left);next=structuredClone(before);next.tasks[0].title='Temporary';updateTasks(left,next,before);undo.undo();assert.equal(readTasks(left).tasks[0].title,'Better task');
 const src=seedModel('😀 Café\n日本語','source');src.transact(()=>changeText(src.getText('source'),'😀 New Café\n日本語!'),localOrigin);assert.equal(src.getText('source').toString(),'😀 New Café\n日本語!');
 for(const d of [base,left,right,src])d.destroy();
 console.log('PASS: live rich-text concurrent edits and author-local undo, independent task fields, descriptions, additive labels, goals, promotion, task undo, Unicode source.');
}
