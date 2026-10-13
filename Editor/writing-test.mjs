import assert from 'node:assert/strict';
import {Editor} from '@tiptap/core';
import {extensions,needsSource} from './schema.js';
import {commentRecords,commentRange,addComment,resolveComment,encodeRecord} from './writing-schema.js';
import {blockAt,duplicateBlock,moveBlock} from './block-tools.js';
import {closeHistory} from '@tiptap/pm/history';
export function runWritingTests(){
 const make=content=>new Editor({element:document.createElement('div'),extensions:extensions(),content,contentType:'markdown'});
 const e=make('# Quiet notes\n\nCafé with **friends**.\n\n- First\n- Second\n');
 let pos;e.state.doc.descendants((n,p)=>{if(n.isText&&n.text.startsWith('Café'))pos=p;});
 e.commands.setTextSelection({from:pos,to:pos+4});e.commands.setMark('textColor',{value:'blue'});e.commands.setMark('highlight',{value:'yellow'});e.commands.toggleMark('underline');
 const id=addComment(e,{range:{from:pos,to:pos+4},body:'A thought 👋',author:'Alice'});assert(id);addComment(e,{body:'Yes, agreed.',author:'Bob',thread:id});
 const md=e.getMarkdown();assert(!needsSource(md),'Omega formatting is visually editable');
 const opened=make(md);assert.deepEqual(opened.getJSON(),e.getJSON(),'Save/reopen preserves all colors, underline, anchors and Unicode comment records');
 assert.equal(commentRecords(opened.state.doc).length,2);assert.equal(opened.state.doc.textBetween(...Object.values(commentRange(opened.state.doc,id))),'Café');
 opened.view.dispatch(closeHistory(opened.state.tr));resolveComment(opened,id,true);assert(commentRecords(opened.state.doc)[0].record.resolved);opened.commands.undo();assert(!commentRecords(opened.state.doc)[0].record.resolved,'Resolve is undoable');
 const block=blockAt(e,pos);assert(duplicateBlock(e,block));assert.equal(commentRecords(e.state.doc).length,2,'Duplicate does not duplicate comment records');let anchors=0;e.state.doc.descendants(n=>{if(n.isText&&n.marks.some(m=>m.type.name==='commentAnchor'))anchors++;});assert.equal(anchors,1,'Duplicate does not ambiguously anchor a thread twice');
 const h=blockAt(e,1);assert(moveBlock(e,h,e.state.doc.child(0).nodeSize+e.state.doc.child(1).nodeSize));e.state.doc.check();assert.equal(e.state.doc.child(1).type.name,'heading');
 for(const text of ['<span data-omega-color="blue">unclosed','<mark data-omega-highlight="evil">x</mark>','x</span>','<span style="color:red">x</span>','<!-- omega-comment:invalid -->'])assert(needsSource(text),text);
 for(const text of ['<span data-omega-color="blue">**bold** and *italic*</span>','<span data-omega-color="pink"><u>text</u></span>','- <mark data-omega-highlight="green">List **item**</mark>','| Name |\n| --- |\n| <span data-omega-color="blue">Blue</span> |']){const a=make(text),b=make(a.getMarkdown());assert(!needsSource(text),text);assert.deepEqual(a.getJSON(),b.getJSON(),text);a.destroy();b.destroy();}
 e.destroy();opened.destroy();console.log('PASS: text color/highlight/underline, Unicode comments + replies + resolve undo, exact save/reopen, block movement, duplication without shared anchors, and malformed-format protection.');
}

import Collaboration from '@tiptap/extension-collaboration';
import {prosemirrorToYDoc} from '@tiptap/y-tiptap';
import {Y,remoteOrigin} from './live-model.js';
import {liveMentions,insertPageLink} from './page-links.js';
export function runWritingCollaborationTests(){
 const seed=new Editor({element:document.createElement('div'),extensions:extensions({nativeHistory:true}),content:'A shared thought.',contentType:'markdown'});
 const id=addComment(seed,{range:{from:1,to:9},body:'Discuss here',author:'Alice'}),initial=prosemirrorToYDoc(seed.state.doc,'body');seed.destroy();
 const docs=[new Y.Doc({gc:false}),new Y.Doc({gc:false})];docs.forEach(d=>Y.applyUpdate(d,Y.encodeStateAsUpdate(initial)));
 const editors=docs.map(d=>new Editor({element:document.createElement('div'),extensions:[...extensions({nativeHistory:true}),Collaboration.configure({document:d,field:'body'})]}));
 addComment(editors[0],{thread:id,body:'Reply one',author:'Alice'});addComment(editors[1],{thread:id,body:'Reply two',author:'Bob'});editors[1].commands.insertContentAt(1,'New ');
 docs.forEach((d,i)=>Y.applyUpdate(d,Y.encodeStateAsUpdate(docs[1-i]),remoteOrigin));assert.equal(editors[0].getMarkdown(),editors[1].getMarkdown());assert.equal(commentRecords(editors[0].state.doc).length,3);assert.equal(commentRange(editors[0].state.doc,id).from,5,'Anchor moves when a peer inserts before it');
 const people=liveMentions([{user:{name:'Alice'}},{user:{name:'Alice'}},{user:{name:'Bøb'}}]);assert.equal(people.length,2);
 assert(insertPageLink(editors[0],people[1],{from:1,to:1},editors[0].state.doc));assert(editors[0].view.dom.querySelector('[data-omega-person]'));assert(editors[0].getMarkdown().includes('#omega-person-B%C3%B8b'));
 for(const e of editors)e.destroy();for(const d of [...docs,initial])d.destroy();
 console.log('PASS: simultaneous replies are retained, comment anchors track peer edits, and live-person mentions use portable Markdown.');
}
