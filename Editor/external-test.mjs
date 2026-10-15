import {safeCombinedImport,tableIssue} from './import-health.js';
import assert from 'node:assert/strict';
import {Editor} from '@tiptap/core';
import {extensions} from './schema.js';
import {mergeExternal,patchRichDocument,ExternalEditHighlight,externalEditKey} from './external-edits.js';

export function runExternalTests(){
 const base='Alpha 👋\n\nMiddle paragraph\n\nLast thought';
 assert.equal(mergeExternal(base,base+' local',base.replace('Alpha','Incoming')),base.replace('Alpha','Incoming')+' local');
 assert.equal(mergeExternal(base,base.replace('Middle','My'),base.replace('Middle','Their')),null);
 assert.equal(mergeExternal('Hello','Hello A','Hello B'),null);
 assert.equal(mergeExternal('Hello','Hello A','Hello A'),'Hello A');
 assert.equal(mergeExternal('one two three','ONE two three','one two THREE'),'ONE two THREE');
 assert.equal(mergeExternal('abc','ac','aXbc'),null,'Insertion at a deletion boundary needs a choice');
 const tasks='<!-- folio:tasks -->\n# Work\n## To do\n- [ ] Parent\n  <!-- folio:task {"id":"parent"} -->\n  - [ ] Child\n    <!-- folio:task {"id":"child"} -->\n';
 const localIDs=tasks.replace('"id":"parent"','"id":"shared"'),remoteIDs=tasks.replace('"id":"child"','"id":"shared"');
 const combinedIDs=mergeExternal(tasks,localIDs,remoteIDs);assert(combinedIDs!==null);
 assert.equal(safeCombinedImport(tasks,localIDs,remoteIDs,combinedIDs),false,'Individually valid ID changes must not create duplicate IDs in a merge');
 assert.equal(tableIssue('| A | B |\n|---|---|\n| 1 | 2 |'),null);
 assert(tableIssue('| A | B |\n|---|---|\n| 1 | 2 |\n\nA paragraph.\n\n| 3 | 4 |'));
 assert.equal(tableIssue('```md\n| A | B |\n```'),null);
 const make=text=>new Editor({element:document.createElement('div'),extensions:[...extensions(),ExternalEditHighlight],content:text,contentType:'markdown'});
 const e=make(base),n=make(base.replace('Alpha','Incoming').replace('Last','Final'));
 let middle;e.state.doc.descendants((node,pos)=>{if(node.isText&&node.text.includes('Middle'))middle=pos+3;});
 e.commands.setTextSelection({from:middle,to:middle+4});const selected=e.state.doc.textBetween(e.state.selection.from,e.state.selection.to);
 patchRichDocument(e,e.schema.nodeFromJSON(n.getJSON()),{highlight:true});
 assert.equal(e.state.doc.textBetween(e.state.selection.from,e.state.selection.to),selected,'Selection stays between two independent incoming edits');
 assert(e.view.dom.querySelector('.external-edit-highlight'));assert(!e.getMarkdown().includes('external-edit'),'Highlights are ephemeral');
 assert(e.commands.undo());assert.equal(e.state.doc.textContent,'Alpha 👋Middle paragraphLast thought');
 assert(e.commands.redo());assert.deepEqual(e.getJSON(),n.getJSON());
 e.view.dispatch(e.state.tr.setMeta(externalEditKey,null));assert(!e.view.dom.querySelector('.external-edit-highlight'));
 e.destroy();n.destroy();
 const examples=[
  ['# Title\n\nA **bold** word.','# Renamed\n\nA *quiet* word.'],
  ['- One\n  - Nested\n- Two','- First\n  - Nested\n  - More\n- Two'],
  ['| A | B |\n|---|---|\n| 1 | 2 |','| A | B |\n|---|---|\n| 3 | 2 |\n| 4 | 5 |'],
  ['A paragraph\n\nEnd','## New heading\n\nA paragraph\n\nEnd'],
  ['![A](a.png)\n\nEnd','![B](b.png)\n\nEnd'],
  ['Hello 👋 there','Hello 🧑🏽‍💻 there'],
  ['# Title\n\nText',''],
 ];
 for(const [before,after] of examples){const a=make(before),b=make(after);patchRichDocument(a,a.schema.nodeFromJSON(b.getJSON()),{highlight:true});a.state.doc.check();assert.deepEqual(a.getJSON(),b.getJSON());a.destroy();b.destroy();}
 console.log('PASS: external merges preserve disjoint typing, reject overlapping edits, retain selections, patch formatted blocks/tables/Unicode, support undo, and never save edit highlights.');
}
