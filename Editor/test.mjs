import { closeHistory } from '@tiptap/pm/history';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { Editor } from '@tiptap/core';
import { extensions, needsSource, noteContent } from './schema.js';
import { tableContext, runTableAction, appendToTable } from './table-actions.js';
import { SearchMatch, matchKey, fold, words, documentWords, resolveSourceMatch, resolveRichMatch, showRichMatch, clearRichMatch } from './search-navigation.js';
const dom=new JSDOM('<div id="editor"></div>',{pretendToBeVisual:true,url:'https://test.invalid'});
for(const key of ['window','document','navigator','HTMLElement','Element','Node','MutationObserver','getComputedStyle','requestAnimationFrame','cancelAnimationFrame','KeyboardEvent'])Object.defineProperty(globalThis,key,{value:dom.window[key],configurable:true});
const source='# Hello 👋\n\nCafé **bold**, *italic*, ~~gone~~, `a|b` and [a link](https://example.com).\n\n## Second\n\n- One\n  - Nested\n- Two\n\n1. First\n2. Second\n\n- [ ] Pending\n- [x] Done\n\n> A quote\n\n```js\nconst x = "hi";\n```\n\n| Name | Value |\n| :--- | ---: |\n| Café | **42** |\n| a\\|b | `x|y` |\n\n---\n\n![Local](assets/a%20b.png)\n\nAn equation $x^2$\n\n$$\nE=mc^2\n$$\n';
const editor=new Editor({element:document.getElementById('editor'),extensions:extensions(),content:source,contentType:'markdown'});
editor.state.doc.check();
const json=editor.getJSON();const kinds=new Set();editor.state.doc.descendants(n=>{kinds.add(n.type.name)});
for(const kind of ['heading','bulletList','orderedList','taskList','blockquote','codeBlock','table','image','horizontalRule','inlineMath','blockMath'])assert(kinds.has(kind),kind);
let markdown=editor.getMarkdown();
for(const text of ['Café','**bold**','*italic*','~~gone~~','https://example.com','- [ ] Pending','- [x] Done','const x','**42**','a\\|b','x\\|y','assets/a%20b.png','$x^2$','E=mc^2'])assert(markdown.includes(text),text+' missing from '+markdown);
const round=editor.markdown.parse(markdown);
assert.deepEqual(editor.schema.nodeFromJSON(round).toJSON(),json,'Rich Markdown preserves the complete document structure across save/reopen');
let cellPosition;editor.state.doc.descendants((node,pos)=>{if(node.type.name==='tableCell'&&cellPosition===undefined)cellPosition=pos+2;});
editor.commands.setTextSelection(cellPosition);
assert(editor.commands.addRowAfter());assert(editor.commands.addColumnAfter());
const table=editor.getJSON().content.find(n=>n.type==='table');assert.equal(table.content.length,4);assert.equal(table.content[0].content.length,3);
editor.commands.undo();assert.equal(editor.getJSON().content.find(n=>n.type==='table').content[0].content.length,2);
for(const example of ['---\ntitle: Metadata\n---\n\nText','<!-- keep me -->\n\nHello','Text[^1]\n\n[^1]: Footnote','<details><summary>Test</summary>Text</details>'])assert(needsSource(example));
for(const example of ['# Heading\n\nNormal text','```html\n<div>code</div>\n```','A `<div>` example',source])assert(!needsSource(example),example);
editor.destroy();console.log('PASS: headings, marks, links, nested lists, tasks, code, tables, alignment, escaped pipes, local images, math, Unicode, save/reopen, table mutations, undo, and lossless source fallback.');

// Search arrival uses the same parser and schema as real notes; it must neither
// select replacement text nor create a document edit or an undo step.
const navigationCases = [
 ['# Harbor log\n\nThe harbor starts here.\n\n' + 'Quiet waters. '.repeat(200) + '\n\n## Destination\n\nMeet at the **harbor** after sunset.', 'harbor', 'Meet at the harbor after sunset.'],
 ['[Harbor](https://harbor.example/harbor) then a quiet morning.\n\nThe target harbor awaits.', 'harbor', 'The target harbor awaits.'],
 ['Earlier harbor.\n\n| Location | Task |\n| --- | --- |\n| North harbor | Meet at noon |', 'harbor', 'North harbor'],
 ['Earlier harbor.\n\n```js\nconst harbor = "destination";\n```', 'harbor', 'const harbor = "destination";'],
 ['# Café trip\n\nEarlier café.\n\nArrive at the **café** after sunset.', 'café', 'Arrive at the café after sunset.'],
 ['Earlier 日本語.\n\nVisit 日本語 after lunch.', '日本語', 'Visit 日本語 after lunch.'],
];
for (const [text, term, paragraph] of navigationCases) {
 const item = new Editor({element:document.createElement('div'),extensions:[...extensions(),SearchMatch],content:text,contentType:'markdown'});
 const tokens = words(text), tokenIndex = tokens.findLastIndex(t => t.word === fold(term)), token = tokens[tokenIndex];
 const anchor = {term:fold(term),location:token.from,length:token.to-token.from,before:tokens.slice(Math.max(0,tokenIndex-4),tokenIndex).map(t=>t.word),after:tokens.slice(tokenIndex+1,tokenIndex+5).map(t=>t.word)};
 const raw = resolveSourceMatch(text,anchor);
 assert.equal(text.slice(raw.from,raw.to),term);
 const match = resolveRichMatch(item,text,anchor);
 assert(match, text);
 assert.equal(item.state.doc.textBetween(match.from,match.to),term);
 assert.equal(item.state.doc.resolve(match.from).parent.textContent,paragraph);
 const before = item.state.doc, saved = item.getMarkdown();
 showRichMatch(item,match);
 assert(item.state.doc.eq(before));assert.equal(item.getMarkdown(),saved);
 assert(item.state.selection.empty);assert.equal(item.state.selection.from,match.from);
 assert.equal(matchKey.getState(item.state).find().length,1);
 clearRichMatch(item);assert.equal(matchKey.getState(item.state).find().length,0);
 assert.equal(item.commands.undo(),false,'Search must not add undo history');
 item.destroy();
}
const old = 'One harbor near dawn.\n\nMeet at the harbor after sunset.';
const shifted = 'A freshly inserted opening sentence.\n\n'+old;
const stale = {term:'harbor',location:old.lastIndexOf('harbor'),length:6,before:['meet','at','the'],after:['after','sunset']};
assert.equal(resolveSourceMatch(shifted,stale).from,shifted.lastIndexOf('harbor'));
// Mark boundaries are not word boundaries in the rendered document.
const split = new Editor({element:document.createElement('div'),extensions:[...extensions(),SearchMatch],content:'har**b**or',contentType:'markdown'});
assert.equal(documentWords(split.state.doc)[0].word,'harbor');split.destroy();
console.log('PASS: exact repeated matches, hidden link URLs, table/code targets, Unicode, stale offsets, inline marks, transient highlights, unchanged Markdown, collapsed carets and clean undo history.');

const blank = new Editor({element:document.createElement('div'),extensions:extensions(),...noteContent('')});
const outline = blank.state.doc;
assert.deepEqual(outline.content.content.map(n=>n.type.name),['heading','paragraph']);
assert.equal(outline.firstChild.attrs.level,1);
assert.equal(blank.view.dom.querySelector('h1').dataset.placeholder,'Title');
assert.equal(blank.view.dom.querySelector('p').dataset.placeholder,'Write something, or type /…');
assert.equal(blank.getText().trim(),'','Prompts never become note contents');
blank.commands.insertContent('A fresh café idea');
blank.view.someProp('handleKeyDown', handler => handler(blank.view, new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true})));
assert.equal(blank.state.doc.childCount,2,'Enter reuses the prepared body instead of adding a blank paragraph');
assert.equal(blank.state.selection.$from.parent.type.name,'paragraph');
blank.commands.insertContent('A small beginning.');
assert.equal(blank.getMarkdown().trim(),'# A fresh café idea\n\nA small beginning.');
const savedNote=blank.getMarkdown();
blank.commands.undo();
assert.equal(blank.state.doc.child(1).textContent,'');
blank.commands.undo();
assert(blank.state.doc.eq(outline),'Undo returns to the untouched empty outline');
const reopened=new Editor({element:document.createElement('div'),extensions:extensions(),...noteContent(savedNote)});
assert.equal(reopened.state.doc.firstChild.textContent,'A fresh café idea');
assert.equal(reopened.state.doc.child(1).textContent,'A small beginning.');
blank.destroy();reopened.destroy();
assert.equal(noteContent('Existing plain note').content,'Existing plain note');
console.log('PASS: blank title/body prompts, Enter into the prepared body, Unicode Markdown save/reopen, undo back to the empty outline, and existing notes preserved.');

import { runSlashTests } from './slash-test.mjs';
assert(needsSource('```database\n{"preserve":true}\n```'), 'Legacy database content stays intact in source mode');
runSlashTests().catch(error=>{console.error(error);process.exitCode=1;});

// Native undo owns the app editor; it must not also record a bounded JS stack.
const nativeUndoEditor = new Editor({element:document.createElement('div'),extensions:extensions({nativeHistory:true}),...noteContent('Original')});
assert.equal(nativeUndoEditor.commands.undo,undefined);
let previousSelection;
nativeUndoEditor.on('beforeTransaction',({editor,transaction})=>{if(transaction.docChanged)previousSelection=editor.state.selection.from;});
nativeUndoEditor.commands.setTextSelection(4);
nativeUndoEditor.commands.insertContent('x');
assert.equal(previousSelection,4);
nativeUndoEditor.destroy();

const { historyQueue } = require('./durable-undo.js');
let queueText='latest',queueID='note-a',locked=false,requests=[];
const durable=historyQueue({snapshot:()=>({id:queueID,text:queueText}),lock:x=>locked=x,send:x=>requests.push(x),apply:x=>queueText=x.text});
durable.request(false);durable.request(false);durable.request(true);
assert.equal(requests.length,1);assert(locked);
durable.result({id:'note-a',text:'middle'});
assert.equal(requests.length,2);assert.equal(requests[1].text,'middle');assert(locked);
durable.result({id:'note-a',text:'oldest'});
assert.equal(requests.length,3);assert(requests[2].redo);assert.equal(requests[2].text,'oldest');
durable.result({id:'note-a',text:'middle'});assert(!locked);
durable.request(false);queueID='note-b';durable.reset();durable.result({id:'note-a',text:'stale'});
assert.equal(queueText,'middle');assert(!locked);
console.log('PASS: native history ownership, pre-edit selection, rapid undo/redo serialization, stale note reply rejection.');

// Table controls target the hovered table, preserve neighboring content, and
// never turn a single-row/column removal into an implicit table deletion.
const tables = new Editor({element:document.createElement('div'),extensions:extensions(),content:'# Notes\n\n| Name | Status |\n| --- | --- |\n| First | Ready |\n| Second | Waiting |\n\nBetween tables.\n\n| Other | Value |\n| --- | --- |\n| Keep | Safe |',contentType:'markdown'});
const tableJSON = () => tables.getJSON().content.filter(n=>n.type==='table');
const neighbor = tableJSON()[1];
assert(appendToTable(tables,tables.view.dom.querySelector('table'),'row'));
assert.equal(tableContext(tables).rows,4);
assert.equal(tables.state.selection.$from.parent.textContent,'');
assert(appendToTable(tables,tables.view.dom.querySelector('table'),'column'));
assert.equal(tableContext(tables).columns,3);
assert(runTableAction(tables,'deleteColumn'));assert.equal(tableContext(tables).columns,2);
assert(runTableAction(tables,'deleteRow'));assert.equal(tableContext(tables).rows,3);
assert.deepEqual(tableJSON()[1],neighbor,'Editing one table preserves another');
const beforeDelete = tables.getJSON();
// Separate the undo event to exercise a destructive row edit on its own.

tables.view.dispatch(closeHistory(tables.state.tr));
assert(runTableAction(tables,'deleteRow'));assert(tables.commands.undo());
assert.deepEqual(tables.getJSON(),beforeDelete,'Removing a row is fully undoable');
while(tableContext(tables).rows>1) assert(runTableAction(tables,'deleteRow'));
while(tableContext(tables).columns>1) assert(runTableAction(tables,'deleteColumn'));
const lastCell = tables.getJSON();
assert.equal(runTableAction(tables,'deleteRow'),false);assert.equal(runTableAction(tables,'deleteColumn'),false);
assert.deepEqual(tables.getJSON(),lastCell);
const savedTable = tables.getMarkdown();
assert.deepEqual(tables.schema.nodeFromJSON(tables.markdown.parse(savedTable)).toJSON(),tables.getJSON());
tables.setEditable(false);assert.equal(appendToTable(tables,tables.view.dom.querySelector('table'),'row'),false);
tables.destroy();
console.log('PASS: edge row/column insertion, new-cell focus, targeted removal, final-cell protection, undo, neighboring table preservation, and Markdown roundtrip.');

// Page links remain portable Markdown, and inserting one preserves nearby text.
import {isPageHref, matchingPages, insertPageLink, PagePicker} from './page-links.js';
for(const href of ['./Caf%C3%A9%20%28plan%29.md','../Other/Notes.markdown','Decision%20log.md'])assert(isPageHref(href));
for(const href of ['https://example.com/a.md','javascript:alert(1)','//host/a.md','not%ZZ.md','./photo.png'])assert(!isPageHref(href));
const pageSource='Before [[ after.';
const pageEditor=new Editor({element:document.createElement('div'),extensions:extensions(),content:pageSource,contentType:'markdown'});
const page={name:'Café (plan)',location:'Work / Drafts',href:'../Work/Caf%C3%A9%20%28plan%29.md'};
const pageDoc=pageEditor.state.doc;
assert(insertPageLink(pageEditor,page,{from:8,to:10},pageDoc));
assert(pageEditor.getMarkdown().includes('Before [Café (plan)](../Work/Caf%C3%A9%20%28plan%29.md) after.'),pageEditor.getMarkdown());
assert(pageEditor.view.dom.querySelector('a[data-page-link]'));
const linkedJSON=pageEditor.getJSON();
assert.deepEqual(pageEditor.schema.nodeFromJSON(pageEditor.markdown.parse(pageEditor.getMarkdown())).toJSON(),linkedJSON);
assert(pageEditor.commands.undo());assert(pageEditor.state.doc.eq(pageDoc));
pageEditor.commands.insertContent('Changed ');
const changed=pageEditor.getMarkdown();
assert(!insertPageLink(pageEditor,page,{from:8,to:10},pageDoc));assert.equal(pageEditor.getMarkdown(),changed);
pageEditor.commands.setContent('Keep **these words** here.',{contentType:'markdown'});
assert(insertPageLink(pageEditor,page,{from:6,to:17},pageEditor.state.doc,true));
assert(pageEditor.getJSON().content[0].content.some(n=>n.text==='these words'&&n.marks?.some(m=>m.type==='bold')&&n.marks?.some(m=>m.type==='link')));
pageEditor.setEditable(false);assert(!insertPageLink(pageEditor,page,{from:1,to:1},pageEditor.state.doc));
pageEditor.destroy();
assert.equal(matchingPages([page,{name:'Other',location:'Café',href:'./Other.md'}],'cafe')[0],page);
const pickerDOM=document.createElement('div');pickerDOM.innerHTML='<input><button data-close></button><div role="listbox"></div>';
let chosen=null,canceled=false;
const picker=new PagePicker(pickerDOM,item=>chosen=item,()=>canceled=true);
picker.open();picker.setPages([page,{name:'Zoo',location:'Other',href:'./Zoo.md'}]);
for(const button of picker.list.querySelectorAll('button'))button.scrollIntoView=()=>{};
picker.input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',cancelable:true}));
picker.input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',cancelable:true}));assert.equal(chosen.name,'Zoo');
picker.input.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',cancelable:true}));assert(canceled&&pickerDOM.hidden);
console.log('PASS: local link classification, Unicode Markdown roundtrip, one-step undo, surrounding formatting, stale picker protection, read-only guard, filtering and keyboard choice.');

import {visualMarkdown} from './schema.js';
const template='# <Weekday>, <D Month YYYY>\n\n## Summary\n\nFill in <project>.\n';
assert(!needsSource(template));
const templateEditor=new Editor({element:document.createElement('div'),extensions:extensions(),...noteContent(template)});
assert.equal(templateEditor.state.doc.firstChild.textContent,'<Weekday>, <D Month YYYY>');
assert(templateEditor.state.doc.textContent.includes('<project>'));
assert.equal(visualMarkdown('`<Weekday>`'),'`<Weekday>`');
assert(needsSource('<details><summary>Keep HTML</summary>Body</details>'));
assert(needsSource('<my-widget value="x">'));
templateEditor.destroy();
import {parseTasks,serializeTasks,TaskPage,taskMarker} from './task-page.js';
const tasksSource=taskMarker+'\n# Release\n\n## Goals\n\n- [ ] Ship calmly\n\n## To do\n\n- [ ] Review copy\n  - [x] Opening\n  - [ ] Closing\n\n## In progress\n\n- [ ] Verify links\n\n## Done\n\n- [x] Plan\n';
const model=parseTasks(tasksSource);assert(model);assert.equal(model.tasks.length,3);assert.equal(model.tasks[0].children.length,2);
const normalized=m=>JSON.parse(JSON.stringify(m,(key,value)=>key==='id'?undefined:value));
assert.deepEqual(normalized(parseTasks(serializeTasks(model))),normalized(model));
assert.equal(parseTasks(tasksSource+'\nUnrecognized content must survive.\n'),null);
assert.equal(parseTasks('# Ordinary checklist\n\n- [ ] Keep as note'),null);
const explicitStatus=taskMarker+'\n# Outside edits\n\n## Goals\n- [ ] Goal\n\n## To do\n- [ ] Parent\n  <!-- folio:task {"id":"parent","status":"Done","description":"Keep **details**","labels":["Writing"]} -->\n  - [ ] Child\n    <!-- folio:task {"id":"child","status":"In progress"} -->\n\n## In progress\n\n## Done\n';
const explicitModel=parseTasks(explicitStatus);assert(explicitModel);assert.equal(explicitModel.tasks[0].status,2);assert.equal(explicitModel.tasks[0].done,true);assert.equal(explicitModel.tasks[0].details.status,undefined);assert.equal(explicitModel.tasks[0].details.description,'Keep **details**');assert.deepEqual(explicitModel.tasks[0].details.labels,['Writing']);assert.equal(explicitModel.tasks[0].children[0].details.status,'In progress');
const canonicalExplicit=serializeTasks(explicitModel);assert.deepEqual(normalized(parseTasks(canonicalExplicit)),normalized(explicitModel));assert(canonicalExplicit.indexOf('- [x] Parent')>canonicalExplicit.indexOf('## Done'));
assert.equal(parseTasks(explicitStatus.replace('"status":"Done"','"status":"Unknown"')),null);
assert.equal(parseTasks(explicitStatus.replace('- [ ] Goal','- [ ] Goal\n  <!-- folio:task {"status":"Done"} -->')),null);
console.log('PASS: explicit main-task statuses from outside editors preserve details/children and normalize into the correct section; invalid statuses remain protected.');
let taskChanges=0;const taskDOM=document.createElement('div');document.body.append(taskDOM);
const taskView=new TaskPage(taskDOM,()=>taskChanges++);assert(taskView.load(tasksSource));assert.equal(taskView.raw,tasksSource);assert.equal(taskChanges,0);
taskDOM.querySelector('[aria-label="Board view"]').click();assert.equal(taskChanges,0);assert(taskDOM.querySelector('.board'));
const input=(selector,value)=>{const field=taskDOM.querySelector(selector);assert(field,selector);if(field.classList.contains('task-description')&&field.tagName!=='TEXTAREA'){taskView.description.commands.setContent(value,{contentType:'markdown'});return field;}field.value=value;field.dispatchEvent(new window.Event('input',{bubbles:true}));return field;};
taskView.addTask();assert(taskDOM.querySelector('[role=dialog]'));assert.equal(taskView.model.tasks.length,3);
input('.task-composer-title','Café 👋');input('.task-composer .task-description','A description.\n\n**Markdown** stays intact.');
assert.equal(taskView.model.tasks.length,4);assert(parseTasks(taskView.raw).tasks.some(t=>t.details.draft));
const draftID=taskView.composer.item.id,draftMarkdown=taskView.raw;
const draftReopen=new TaskPage(document.createElement('div'),()=>{});assert(draftReopen.load(draftMarkdown));draftReopen.openDetail(draftReopen.lookup(draftID).item);assert.equal(draftReopen.composer.item.details.description,'A description.\n\n**Markdown** stays intact.');
draftReopen.composer.item.children.push({id:'kept-child',title:'Keep this subtask',done:false,details:{id:'kept-child'}});draftReopen.change();
const withChild=draftReopen.raw;draftReopen.reparentDraft(draftReopen.model.tasks[0].id);assert.equal(draftReopen.raw,withChild);assert.equal(draftReopen.composer.parentID,null);
taskDOM.querySelector('[aria-label="Expand task composer"]').click();assert(taskDOM.querySelector('.is-full'));assert.equal(taskView.raw,draftMarkdown);
taskDOM.querySelector('[aria-label="Dock task composer"]').click();assert(taskDOM.querySelector('.task-dock'));assert.equal(taskView.raw,draftMarkdown);
taskDOM.querySelector('[aria-label="Restore task composer"]').click();assert.equal(taskDOM.querySelector('.task-composer-title').value,'Café 👋');
taskDOM.querySelector('[aria-label="Save draft and close"]').click();assert.equal(taskView.raw,draftMarkdown);assert(taskDOM.querySelector('.draft'));
taskView.openComposerFor(taskView.lookup(draftID).item);taskDOM.querySelector('[aria-label="Create task"]').click();assert(!taskView.composer);assert(!taskView.lookup(draftID).item.details.draft);
const added=taskView.lookup(draftID).item;taskView.openDetail(added);assert(taskDOM.querySelector('.task-detail'));assert.equal(taskView.description.getMarkdown(),'A description.\n\n**Markdown** stays intact.');
input('.task-detail-title','Renamed task');input('.task-description','Details stay safe.');
const due=taskDOM.querySelector('[aria-label="Due date"]');due.value='2026-10-20';due.dispatchEvent(new window.Event('change'));taskDOM.querySelector('[aria-label="Labels"]').click();
input('[aria-label="Find or create a label"]','Writing');taskDOM.querySelector('[aria-label="Create label: Writing"]').click();
input('[aria-label="Find or create a label"]','Launch');taskDOM.querySelector('[aria-label="Create label: Launch"]').click();
assert.deepEqual(parseTasks(taskView.raw).tasks.find(t=>t.title==='Renamed task').details.labels,['Writing','Launch']);
assert(!taskDOM.querySelector('.task-label-picker').hidden);
taskDOM.querySelector('[aria-label="Find or create a label"]').dispatchEvent(new window.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
assert(taskDOM.querySelector('.task-label-picker').hidden);assert(taskDOM.querySelector('.task-detail')); 
assert.equal(parseTasks(taskView.raw).tasks.find(t=>t.title==='Renamed task').details.due,'2026-10-20');
taskView.addChild(added);input('.task-composer-title','First subtask');taskView.commitComposer();
assert.equal(added.children.length,1);taskView.move(added.children[0],1,added);assert.equal(parseTasks(taskView.raw).tasks.find(t=>t.title==='Renamed task').children[0].details.status,'In progress');
taskView.closeDetail();assert(taskDOM.querySelector('.task-parent-context'));assert(taskDOM.querySelector('.subtask-card'));
taskView.openDetail(added.children[0]);assert(taskDOM.querySelector('[aria-label="Open parent task"]'));assert(taskDOM.querySelector('[aria-label="Subtask status"]'));
taskView.closeDetail();const saved=taskView.raw;const reopenedTasks=new TaskPage(document.createElement('div'),()=>{});assert(reopenedTasks.load(saved));assert.equal(reopenedTasks.raw,saved);
assert.equal(reopenedTasks.model.tasks.find(t=>t.title==='Renamed task').details.description,'Details stay safe.');
taskView.setReadOnly(true);taskView.addTask();taskView.move(added,0);assert.equal(taskView.raw,saved);
console.log('PASS: task composer, durable drafts, expand/dock, detail pages, due dates/labels, independent subtasks, saved metadata and read-only protection.');

const customSource=taskMarker+'\n<!-- folio:completed "Shipped" -->\n# Project\n\n## Goals\n\n- [ ] Launch\n\n## Backlog\n\n- [ ] Draft\n\n## Review\n\n- [ ] Check\n  - [x] Copy\n\n## Shipped\n\n- [x] Plan\n';
const custom=parseTasks(customSource);assert.deepEqual(custom.statuses,['Backlog','Review','Shipped']);assert.equal(custom.completed,'Shipped');
assert.deepEqual(normalized(parseTasks(serializeTasks(custom))),normalized(custom));
assert.equal(parseTasks(customSource+'\n## backlog\n'),null);
assert.equal(parseTasks(customSource.replace('## Review','## Goals')),null);
assert.equal(parseTasks(customSource.replace('"Shipped"','23')),null);
assert.equal(parseTasks(customSource.replace('- [ ] Draft','- [ ] Draft\n  <!-- folio:task {"unknown": "keep me"} -->')),null);
assert.equal(parseTasks(customSource.replace('- [ ] Draft','- [ ] Draft\n  <!-- folio:task {"due": "2026-02-30"} -->')),null);
const customView=new TaskPage(document.createElement('div'),()=>{});document.body.append(customView.element);assert(customView.load(customSource));
customView.element.querySelector('[aria-label="Complete task"]').click();
assert.equal(parseTasks(customView.raw).tasks.find(t=>t.title==='Draft').status,2);
assert.equal(customView.element.querySelector('.status-complete').dataset.status,'2');
customView.element.querySelector('.status-complete [aria-label="Complete task"]').click();
assert.equal(parseTasks(customView.raw).tasks.find(t=>t.title==='Draft').status,0);
console.log('PASS: custom status/complete marker roundtrip, unknown metadata fallback, invalid dates, duplicate/reserved names, custom completion and reopen behavior.');

// A move is a single model mutation, preserving the full tree and every field.
import {reparentTask,walkTasks,subtaskStatus} from './task-model.js';
const moving=parseTasks(serializeTasks(taskView.model));
const movingTask=moving.tasks.find(t=>t.title==='Renamed task'),target=moving.tasks.find(t=>t!==movingTask);
const snapshot=structuredClone(movingTask),targetID=target.id;
assert(reparentTask(moving,movingTask.id,targetID));
let after=walkTasks(moving).find(e=>e.item.id===snapshot.id);
assert.equal(after.parent.id,targetID);assert.equal(after.item.details.description,snapshot.details.description);
assert.deepEqual(after.item.details.labels,snapshot.details.labels);assert.equal(after.item.details.due,snapshot.details.due);
assert.deepEqual(after.item.children,snapshot.children);
const nested=serializeTasks(moving),reloaded=parseTasks(nested);assert(reloaded);assert.equal(serializeTasks(reloaded),nested);
const childID=movingTask.children[0].id;
assert.equal(reparentTask(moving,targetID,childID),false,'cycles must be refused');assert.equal(serializeTasks(moving),nested);
assert(reparentTask(moving,movingTask.id,null));after=walkTasks(moving).find(e=>e.item.id===snapshot.id);assert.equal(after.parent,null);assert.equal(after.item.status,snapshot.status);assert.deepEqual(after.item.details,snapshot.details);assert.deepEqual(after.item.children,snapshot.children);
assert(reparentTask(moving,childID,null));assert(moving.tasks.some(t=>t.id===childID));
const moveDOM=document.createElement('div');document.body.append(moveDOM);let moveChanges=0;
const moveView=new TaskPage(moveDOM,()=>moveChanges++);moveView.load(nested);const sub=walkTasks(moveView.model).find(e=>e.item.id===snapshot.id);moveView.openDetail(sub.item);
moveDOM.querySelector('[aria-label="More task actions"]').click();moveDOM.querySelector('[aria-label="Make main task"]').click();assert.equal(moveChanges,1);assert(moveView.model.tasks.some(t=>t.id===snapshot.id));
moveDOM.querySelector('[aria-label="More task actions"]').click();moveDOM.querySelector('[aria-label="Move under task"]').click();assert(moveDOM.querySelector('[aria-label="Find a parent task"]'));assert(!moveDOM.querySelector('[aria-label="Move under Renamed task"]'));
moveView.setReadOnly(true);const beforeReadOnly=moveView.raw;moveView.promote(moveView.model.tasks[0]);assert.equal(moveView.raw,beforeReadOnly);
const goalModel=parseTasks(taskMarker+'\n# Goals\n\n## Goals\n- [ ] First\n  <!-- folio:task {"id":"goal-one"} -->\n\n## To do\n');assert.equal(goalModel.goals[0].details.id,'goal-one');assert.equal(parseTasks(serializeTasks(goalModel)).goals[0].details.id,'goal-one');
const linkEditor=new Editor({element:document.createElement('div'),extensions:extensions(),content:'Link here',contentType:'markdown'});
for(const kind of ['task','goal']){const ref={name:'Keep details',href:'./Tasks.md#folio-'+kind+'-stable-id'};assert(insertPageLink(linkEditor,ref,{from:1,to:1},linkEditor.state.doc));assert(linkEditor.view.dom.querySelector('a[data-item-link='+kind+']'));}
assert(linkEditor.getMarkdown().includes('#folio-task-stable-id'));assert(linkEditor.getMarkdown().includes('#folio-goal-stable-id'));linkEditor.destroy();
console.log('PASS: promotion, reparenting complete subtrees, cycle rejection, preserved metadata/status/IDs, stable goals, linked task/goal marks, UI controls and read-only protection.');

import {goalProgress,linkGoal,removeGoal} from './task-model.js';
const goalDOM=document.createElement('div');document.body.append(goalDOM);
let goalChanges=0;const goalsView=new TaskPage(goalDOM,()=>goalChanges++);goalsView.load(tasksSource);
assert(!goalDOM.querySelector('.task-goals'));assert(goalDOM.querySelector('[aria-label="Manage goals"]'));assert.equal(goalChanges,0);
let goal=goalsView.model.goals[0],parentGoalTask=goalsView.model.tasks[0],childGoalTask=parentGoalTask.children[0];
goalsView.openDetail(childGoalTask);goalDOM.querySelector('[aria-label="Choose goals"]').click();goalDOM.querySelector('[aria-label="Link goal: Ship calmly"]').click();
assert.equal(goalProgress(goalsView.model,goal).total,1);assert.equal(goalProgress(goalsView.model,goal).completed,1);assert(!goalDOM.querySelector('.goal-picker').hidden);
assert.equal(childGoalTask.details.goals[0],goal.details.id);assert(goal.details.id);
linkGoal(goalsView.model,parentGoalTask,goal,true);goalsView.change();assert.equal(goalProgress(goalsView.model,goal).total,2);assert.equal(goalProgress(goalsView.model,goal).done,false);
goalsView.openGoal(goal);assert(goalDOM.querySelector('.goal-detail'));assert.equal(goalDOM.querySelectorAll('.goal-linked-row').length,2);assert(!goalDOM.querySelector('[aria-label="Complete unlinked goal"]'));
goalsView.move(parentGoalTask,2);assert.equal(goalProgress(goalsView.model,goal).done,true);assert.equal(parseTasks(goalsView.raw).goals[0].done,true);
const durableGoals=parseTasks(goalsView.raw);assert.equal(goalProgress(durableGoals,durableGoals.goals[0]).completed,2);
const movingGoalChild=durableGoals.tasks.find(t=>t.details.id===parentGoalTask.details.id).children[0];assert(reparentTask(durableGoals,movingGoalChild.id,null));assert.equal(goalProgress(durableGoals,durableGoals.goals[0]).total,2);assert.equal(goalProgress(durableGoals,durableGoals.goals[0]).completed,2);
goalsView.openGoals();const beforeGoalsView=goalsView.raw;goalDOM.querySelector('[aria-label="Open goal: Ship calmly"]').click();assert.equal(goalsView.raw,beforeGoalsView);
goalDOM.querySelector('[aria-label="Link tasks"]').click();const searchGoal=goalDOM.querySelector('[aria-label="Find tasks to link"]');searchGoal.value='Closing';searchGoal.dispatchEvent(new window.Event('input'));goalDOM.querySelector('[aria-label="Link task: Closing"]').click();assert.equal(goalProgress(goalsView.model,goal).total,3);assert.equal(goalProgress(goalsView.model,goal).completed,2);
goalsView.render();goalDOM.querySelector('[aria-label="Unlink task: Closing"]').click();assert.equal(goalProgress(goalsView.model,goal).total,2);
goalsView.openDetail(childGoalTask);goalDOM.querySelector('[aria-label="Choose goals"]').click();const goalInput=goalDOM.querySelector('[aria-label="Find or create a goal"]');goalInput.value='Another outcome';goalInput.dispatchEvent(new window.Event('input'));goalDOM.querySelector('[aria-label="Create goal: Another outcome"]').click();assert.equal(childGoalTask.details.goals.length,2);assert.equal(goalsView.model.goals.length,2);
goalsView.openGoal(goal);goalDOM.querySelector('[aria-label="Remove goal"]').click();goalDOM.querySelector('[aria-label="Keep goal"]').click();assert.equal(goalsView.model.goals.length,2);
const keptDescription=childGoalTask.details.description;removeGoal(goalsView.model,goal);goalsView.change(true);assert.equal(childGoalTask.details.goals.length,1);assert.equal(childGoalTask.details.description,keptDescription);assert.equal(walkTasks(goalsView.model).length,5);
goalsView.setReadOnly(true);const protectedGoals=goalsView.raw;goalsView.addGoal();assert.equal(goalsView.raw,protectedGoals);
assert.equal(parseTasks(tasksSource.replace('- [ ] Review copy','- [ ] Review copy\n  <!-- folio:task {"goals":["bad id"]} -->')),null);
console.log('PASS: linked goal progress, main/subtask relationships, multi-goal picker, removal cleanup, durable Markdown, promotion, read-only protection and no persistent goals section.');

import {labelTone,configureLabelColors} from './task-labels.js';
assert.equal(labelTone('ads'),labelTone(' ADS '));
assert(new Set(['ads','claude','code','decision','integrations','meta','notes'].map(labelTone)).size>=4);
const labelDOM=document.createElement('div');document.body.append(labelDOM);const labelView=new TaskPage(labelDOM,()=>{});labelView.load(tasksSource);
const labelTask=labelView.model.tasks[0];labelTask.details.labels=['ads','claude','code'];labelView.change(true);
const originalLabelNames=[...labelTask.details.labels];
assert.equal(labelDOM.querySelector('.task-row-labels .task-label').dataset.labelTone,labelTone('ads'));
labelView.view='board';labelView.render();assert.equal(labelDOM.querySelector('.task-card-labels .task-label').dataset.labelTone,labelTone('ads'));
labelView.openDetail(labelTask);assert.equal(labelDOM.querySelector('[aria-label="Labels"]').dataset.labelTone,labelTone('ads'));
labelDOM.querySelector('[aria-label="Labels"]').click();assert.equal(labelDOM.querySelector('[aria-label="Remove label: ads"] .task-label').dataset.labelTone,labelTone('ads'));
assert.deepEqual(parseTasks(labelView.raw).tasks[0].details.labels,originalLabelNames);
labelDOM.querySelector('[aria-label="Remove label: ads"]').click();assert.equal(labelDOM.querySelector('[aria-label="Labels"]').dataset.labelTone,labelTone('claude'));
assert.equal(labelTask.details.labels[0],'claude');
console.log('PASS: shared stable pastel tags across lists, cards, task properties and label choices without rewriting label names.');

const beforeCustomColor=labelView.raw;
configureLabelColors({claude:1,you:3,invalid:8});
assert.equal(labelTone('CLAUDE'),'1');
assert.equal(labelDOM.querySelector('[aria-label="Labels"]').dataset.labelTone,'1');
assert.equal(labelView.raw,beforeCustomColor);
labelView.view='list';labelView.detail=null;labelView.render();
assert.equal(labelDOM.querySelector('.task-row-labels [data-label-name="claude"]').dataset.labelTone,'1');
configureLabelColors({});assert.equal(labelView.raw,beforeCustomColor);
console.log('PASS: label color preferences update existing controls and newly rendered tags without editing Markdown.');

// Progress is derived, so viewing a ring never adds metadata or an undo step.
import {completionRing,taskCompletion} from './completion-ring.js';
const ringDOM=document.createElement('div');document.body.append(ringDOM);let ringChanges=0;
const ringView=new TaskPage(ringDOM,()=>ringChanges++);ringView.load(tasksSource);
const ringParent=ringView.model.tasks[0],ringChild=ringParent.children[1];
const ringValue=selector=>ringDOM.querySelector(selector+' .completion-ring').dataset.progress;
assert.equal(ringValue('.task-row-progress'),'0.5');
assert.equal(taskCompletion(ringView.model,ringParent).label,'1 of 2 subtasks complete');
for(const entry of walkTasks(ringView.model).filter(e=>!e.item.children.length)){
 const p=taskCompletion(ringView.model,entry.item,entry.parent);
 assert.equal(p.completed,(entry.parent?subtaskStatus(ringView.model,entry.item):entry.item.status)===2?1:0);
 assert.equal(p.total,1);
}
ringView.setView('board');assert.equal(ringValue('.task-progress'),'0.5');
ringView.openDetail(ringParent);assert.equal(ringValue('.task-detail-actions'),'0.5');assert.equal(ringValue('.task-subtasks-label'),'0.5');
assert.equal(ringChanges,0);assert.equal(ringView.raw,tasksSource);
ringView.move(ringChild,2,ringParent);assert.equal(ringValue('.task-detail-actions'),'1');
ringView.move(ringParent.children[0],0,ringParent);assert.equal(ringValue('.task-detail-actions'),'0.5');
ringView.move(ringChild,0,ringParent);assert.equal(ringValue('.task-detail-actions'),'0');
ringView.load(tasksSource);assert.equal(ringValue('.task-detail-actions'),'0.5','external refresh restores derived progress');
const rg=ringView.model.goals[0],rp=ringView.model.tasks[0];
linkGoal(ringView.model,rp,rg,true);linkGoal(ringView.model,rp.children[0],rg,true);ringView.change();
ringView.openGoal(rg);assert.equal(ringValue('.goal-progress'),'0.5');
ringView.openGoals();assert.equal(ringValue('.goal-overview-row'),'0.5');
ringView.closeDetail();assert.equal(ringValue('.task-goal-badge'),'0.5');
ringView.move(rp,2);ringView.openGoal(rg);assert.equal(ringValue('.goal-progress'),'1');
linkGoal(ringView.model,rp,rg,false);linkGoal(ringView.model,rp.children[0],rg,false);rg.done=false;ringView.change(true);
assert.equal(ringValue('.goal-progress'),'0');ringDOM.querySelector('[aria-label="Complete unlinked goal"]').click();assert.equal(ringValue('.goal-progress'),'1');
const customParent=custom.tasks.find(t=>t.title==='Check');assert.equal(taskCompletion(custom,customParent).completed,1);
assert.equal(taskCompletion(custom,custom.tasks.find(t=>t.title==='Plan')).completed,1);
assert.equal(completionRing(0,0).dataset.progress,'0');assert.equal(completionRing(10,2).dataset.progress,'1');
assert.equal(completionRing(1,2,{label:'1 of 2 subtasks complete'}).getAttribute('aria-valuenow'),'50');
assert.equal(completionRing(0,2).querySelector('.completion-ring-fill').getAttribute('visibility'),'hidden','zero progress must not render a round-cap dot');
console.log('PASS: goal/task rings show empty, partial and complete progress across list, board, details and linked goal badges; custom statuses, unlinked goals, external refresh and unchanged files.');

import {projectCompletion} from './completion-ring.js';
const projectDOM=document.createElement('div');document.body.append(projectDOM);let projectChanges=0;
const projectView=new TaskPage(projectDOM,()=>projectChanges++);projectView.load(tasksSource);
const pageRing=()=>projectDOM.querySelector('.tasks-heading .completion-ring');
assert.equal(pageRing().dataset.progress,'0.4');assert.equal(pageRing().title,'40% complete · 2 of 5 tasks and subtasks complete');
projectView.toggleList(projectView.model.tasks[0]);projectView.setView('board');
assert.equal(pageRing().dataset.progress,'0.4');assert.equal(projectChanges,0);assert.equal(projectView.raw,tasksSource);
const projectParent=projectView.model.tasks[0];projectView.move(projectParent.children[1],2,projectParent);
assert.equal(pageRing().dataset.progress,'0.6');
projectView.load(tasksSource);assert.equal(pageRing().dataset.progress,'0.4');
const projectModel=parseTasks(tasksSource);projectModel.tasks.push({title:'Saved draft',status:2,details:{draft:true},children:[{title:'Draft child',done:true,details:{},children:[]}]});
assert.equal(projectCompletion(projectModel).total,5);assert.equal(projectCompletion(projectModel).completed,2);
const beforeProjectMove=projectCompletion(projectModel);reparentTask(projectModel,projectModel.tasks[0].children[0].id,null);
assert.deepEqual(projectCompletion(projectModel),beforeProjectMove,'promotion preserves the project count');
assert.equal(projectCompletion(custom).completed,2);assert.equal(projectCompletion(custom).total,4);
for(const {item,parent} of walkTasks(projectView.model))projectView.move(item,2,parent);
assert.equal(pageRing().dataset.progress,'1');
projectView.load(taskMarker+'\n# Empty\n\n## Goals\n\n## To do\n\n## In progress\n\n## Done\n');
assert.equal(pageRing().dataset.progress,'0');assert.equal(pageRing().title,'No tasks yet');
console.log('PASS: whole-project progress counts every saved task/subtask once, omits drafts/goals, respects custom statuses and stays current after edits, moves and refresh.');
import {testLive} from './live-test.mjs';
testLive();

import {runWritingTests} from './writing-test.mjs';
runWritingTests();
import {runWritingCollaborationTests} from './writing-test.mjs';
runWritingCollaborationTests();

// Git merges the same durable CRDT states used by the live editor. Offline edits
// and assistant changes in Markdown must survive without duplicate baselines.
import {mergeGitCheckpoints,sharedText,patchShared} from './git-checkpoints.js';
import {Y,seedModel,encode,decode} from './live-model.js';
const cp=doc=>({state:encode(Y.encodeStateAsUpdate(doc)),text:sharedText(doc),accepted:true});
const fork=doc=>{const next=new Y.Doc({gc:false});Y.applyUpdate(next,Y.encodeStateAsUpdate(doc));return next;};
const common=seedModel('Shared words.\n','source'),left=fork(common),right=fork(common);
left.getText('source').insert(0,'Left ');right.getText('source').insert(right.getText('source').length,'Right\n');
let joined=mergeGitCheckpoints({mine:cp(left),incoming:cp(right)});
assert(joined.text.includes('Left Shared words.')&&joined.text.includes('Right'));
assert.equal(mergeGitCheckpoints({mine:joined,incoming:cp(right)}).text,joined.text,'Repeated Git imports are idempotent');
const external=mergeGitCheckpoints({mine:cp(left),mineText:'Left Shared words.\nAssistant\n',incoming:cp(right)});
assert(external.text.includes('Assistant')&&external.text.includes('Right'),'Outside Markdown edits enter the shared history before merging');
const decided=mergeGitCheckpoints({mine:cp(left),incoming:cp(right),resolvedText:'A reviewed result.\n'});
assert.equal(decided.text,'A reviewed result.\n');
const final=new Y.Doc();Y.applyUpdate(final,decode(decided.state));Y.applyUpdate(final,Y.encodeStateAsUpdate(right));
assert.equal(sharedText(final),decided.text,'A resolved choice has seen and superseded both states');
const unrelated=seedModel('Another baseline','source');assert.equal(mergeGitCheckpoints({mine:cp(left),incoming:cp(unrelated)}),null);
assert.equal(mergeGitCheckpoints({mine:{state:'invalid',text:'Keep me'}}),null);
const richEditor=new Editor({element:document.createElement('div'),extensions:extensions({nativeHistory:true}),content:'# Title\n\nWords here.\n',contentType:'markdown'});
import {prosemirrorToYDoc} from '@tiptap/y-tiptap';
const rich=prosemirrorToYDoc(richEditor.state.doc,'body');rich.gc=false;rich.getMap('meta').set('version',1);rich.getMap('meta').set('kind','rich');rich.getMap('meta').set('lineage','git-rich-fixture');richEditor.destroy();
const ra=fork(rich),rb=fork(rich);patchShared(ra,'# Title changed\n\nWords here.\n');patchShared(rb,'# Title\n\nWords here and there.\n');
const rj=mergeGitCheckpoints({mine:cp(ra),incoming:cp(rb)});
assert(rj.text.includes('Title changed')&&rj.text.includes('Words here and there.'),'Rich shared state preserves independent offline edits');
for(const doc of [common,left,right,final,unrelated,rich,ra,rb])doc.destroy();
console.log('PASS: Git CRDT merge, idempotence, outside edits, reviewed resolution, lineage rejection, and rich text projection.');

// Block moves are a single, lossless transaction, including nested list content.
import {blockAt,moveBlock} from './block-tools.js';
function movingNote(markdown){return new Editor({element:document.createElement('div'),extensions:extensions(),content:markdown,contentType:'markdown'});}
function namedBlock(e,text){let at;e.state.doc.descendants((n,p)=>{if(n.isText&&n.text.includes(text))at=p;});return blockAt(e,at);}
for(const [note,sourceName,targetName] of [
 ['# Title\n\nFirst **bold**.\n\n## Last','First','Last'],
 ['# Title\n\n- First\n  - Nested **child**\n- Second\n- Third','First','Third'],
 ['# Title\n\n- [x] Finished\n  - Child\n- [ ] Pending','Finished','Pending'],
 ['# Title\n\n- Only\n  - Nested\n\n## Last','Only','Last'],
 ['# Title\n\n- First\n\n## Between\n\n- Last','First','Last'],
 ['# Title\n\n| Name | Value |\n| --- | --- |\n| Alpha | **42** |\n\n## Last','Alpha','Last'],
]){
 const e=movingNote(note),before=e.state.doc,sourceBlock=namedBlock(e,sourceName),target=namedBlock(e,targetName).to;
 // jsdom has no layout; inspect model changes without the view's scroll routine.
 e.view.scrollToSelection=()=>{};
 assert(moveBlock(e,sourceBlock,target));e.state.doc.check();
 const after=e.state.doc;
 let occurrences=0;after.descendants(n=>{if(n.eq(sourceBlock.node))occurrences++;});
 assert.equal(occurrences,1,'Moved block stays intact exactly once');
 assert(after.textContent.indexOf(sourceName)>after.textContent.indexOf(targetName));
 assert(e.commands.undo());assert(e.state.doc.eq(before),'One undo restores the complete original document');
 assert(e.commands.redo());assert(e.state.doc.eq(after));
 assert.deepEqual(e.schema.nodeFromJSON(e.markdown.parse(e.getMarkdown())).toJSON(),after.toJSON(),'Move survives save/reopen');
 e.destroy();
}
const safeMove=movingNote('# Start\n\n- One\n- Two\n\nEnd'),safeBefore=safeMove.state.doc,one=namedBlock(safeMove,'One');
for(const target of [one.from,one.from+2,one.to,-1,safeBefore.content.size+1])assert.equal(moveBlock(safeMove,one,target),false);
assert(safeMove.state.doc.eq(safeBefore));
safeMove.commands.insertContent('Changed');const movedStale=safeMove.state.doc;assert.equal(moveBlock(safeMove,one,movedStale.content.size),false);assert(safeMove.state.doc.eq(movedStale));safeMove.destroy();
console.log('PASS: block moves preserve nested content and formatting, remove empty lists, move across lists and tables, save/reopen, reject stale/invalid positions, and undo/redo in one step.');

import {runExternalTests} from './external-test.mjs';
runExternalTests();
