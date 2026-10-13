import {checkpointDoc} from './git-checkpoints.js';
import {LivePresence} from './live-presence.js';
import Collaboration from '@tiptap/extension-collaboration';
import {Editor} from '@tiptap/core';
import {prosemirrorToYDoc,yDocToProsemirrorJSON} from '@tiptap/y-tiptap';
import {extensions} from './schema.js';
import {Y,localOrigin,remoteOrigin,encode,decode,changeText,seedModel,updateTasks,readTasks,taskText} from './live-model.js';
import {parseTasks} from './task-model.js';

// Network and durable storage live in the native host, not in the web view.
// A cold client adopts one server seed; independently seeded documents never
// merge. Returning clients merge updates from their persisted shared baseline.
export class LiveEditor {
 constructor(host,config){
  this.host=host;this.config=config;this.accepted=!!config.accepted;this.joined=false;this.remote=false;this.stopped=false;this.pending=[];this.updates=[];
  this.kind=config.kind;this.doc=new Y.Doc({gc:false});
  if(config.state){Y.applyUpdate(this.doc,decode(config.state),remoteOrigin);this.kind=this.doc.getMap('meta').get('kind');}
  else if(this.kind==='rich'){this.doc.destroy();this.doc=prosemirrorToYDoc(host.editor().state.doc,'body');this.doc.gc=false;this.doc.getMap('meta').set('version',1);this.doc.getMap('meta').set('kind','rich');this.doc.getMap('meta').set('lineage',crypto.randomUUID());}
  else{this.doc.destroy();this.doc=seedModel(host.value(),this.kind);}
  this.attach();
  host.send('liveReady',{state:this.state(),text:host.value(),accepted:this.accepted});
 }
 state(){return encode(Y.encodeStateAsUpdate(this.doc));}
 checkpoint(extra={}){this.host.send('liveCheckpoint',{state:this.state(),text:this.host.value(),accepted:this.accepted,lineage:this.doc.getMap('meta').get('lineage'),...extra});}
 attach(){
  this.kind=this.doc.getMap('meta').get('kind');
  this.presence=new LivePresence(this);
  this.host.mount(this);
  if(this.kind!=='rich')this.undo=new Y.UndoManager(this.kind==='tasks'?[this.doc.getMap('items'),this.doc.getMap('meta'),this.doc.getText('title')]:this.doc.getText('source'),{trackedOrigins:new Set([localOrigin]),captureTimeout:450});
  this.previous=this.kind==='tasks'?readTasks(this.doc):null;
  this.doc.on('update',this.onUpdate=(update,origin)=>{
   if(this.stopped)return;
   this.needsSend ||= origin!==remoteOrigin;
   if(origin!==remoteOrigin)this.updates.push(update);
   if(this.queued)return;this.queued=true;
   queueMicrotask(()=>{this.queued=false;if(this.stopped)return;const push=this.needsSend,updates=this.updates;this.needsSend=false;this.updates=[];this.checkpoint({push:this.joined&&!!push,...(updates.length?{update:encode(Y.mergeUpdates(updates))}:{})});});
  });
 }
 extensions(){return [Collaboration.configure({document:this.doc,field:'body'}),this.presence.extension()];}
 text(){return this.kind==='source'?this.doc.getText('source').toString():this.kind==='tasks'?taskText(this.doc):this.host.editor().getMarkdown()+'\n';}
 changed(text){
  if(this.remote||this.stopped)return;
  if(this.kind==='source')this.doc.transact(()=>changeText(this.doc.getText('source'),text),localOrigin);
  else if(this.kind==='tasks'){
   const next=parseTasks(text);if(!next)return;
   updateTasks(this.doc,next,this.previous);this.previous=readTasks(this.doc);
  }
 }
 incomingText(doc){
  const kind=doc.getMap('meta').get('kind');
  if(kind==='source')return doc.getText('source').toString();if(kind==='tasks')return taskText(doc);
  const temp=new Editor({element:document.createElement('div'),extensions:extensions({nativeHistory:true}),content:yDocToProsemirrorJSON(doc,'body')});
  try{return temp.getMarkdown()+'\n';}finally{temp.destroy();}
 }
 receive(message){
  if(this.stopped)return;
  if(message.type==='offline'){this.presence.offline();return;}
  if(message.type==='awareness'){if(this.joined&&!this.conflict)this.presence.receive(message.update);return;}
  if(message.type==='state')this.supportsPresence=!!message.presence;
  if(this.host.composing()){this.pending.push(message);clearTimeout(this.retry);this.retry=setTimeout(()=>this.flush(),80);return;}
  if(this.conflict&&message.type==='update'){
   Y.applyUpdate(this.conflict.incoming,decode(message.update),remoteOrigin);return;
  }
  if(message.type==='state'){
   this.joined=false;
   const incoming=new Y.Doc({gc:false});Y.applyUpdate(incoming,decode(message.state),remoteOrigin);
   const sharedLineage=incoming.getMap('meta').get('lineage'),localLineage=this.doc.getMap('meta').get('lineage');
   if(!message.created&&(!sharedLineage||sharedLineage!==localLineage)){
    const text=this.incomingText(incoming);
    if(text.trimEnd()!==this.text().trimEnd()){
     this.conflict?.incoming.destroy();this.conflict={incoming,text};this.host.send('liveConflict',{});return;
    }
    this.adopt(incoming);return;
   }
   incoming.destroy();this.joined=true;
  }
  this.remote=true;
  try{Y.applyUpdate(this.doc,decode(message.state||message.update),remoteOrigin);this.accepted=true;if(this.kind!=='rich'){this.host.refresh(this);this.presence.restoreSelection();}this.previous=this.kind==='tasks'?readTasks(this.doc):null;}
  finally{this.remote=false;}
  this.checkpoint({push:message.type==='state'});
  if(message.type==='state')this.presence.activate(this.supportsPresence);
 }
 importGit(checkpoint){
  if(this.stopped||this.conflict||this.host.composing())return false;
  let incoming;
  try{
   incoming=checkpointDoc(checkpoint);
   if(incoming.getMap('meta').get('lineage')!==this.doc.getMap('meta').get('lineage')||incoming.getMap('meta').get('kind')!==this.kind)return false;
   // Merge into this document; never remount it or reset awareness/undo/cursors.
   this.remote=true;
   try{Y.applyUpdate(this.doc,Y.encodeStateAsUpdate(incoming),remoteOrigin);if(this.kind!=='rich'){this.host.refresh(this);this.presence.restoreSelection();}this.previous=this.kind==='tasks'?readTasks(this.doc):null;}
   finally{this.remote=false;}
   this.checkpoint({push:this.joined});return true;
  }catch{return false;}finally{incoming?.destroy();}
 }
 flush(){const pending=this.pending;this.pending=[];for(const message of pending)this.receive(message);}
 adopt(incoming){
  this.presence.destroy();this.doc.off('update',this.onUpdate);this.undo?.destroy();const old=this.doc;this.doc=incoming;this.accepted=true;this.joined=true;this.remote=true;
  try{this.attach();}finally{this.remote=false;old.destroy();}
  this.checkpoint({push:true});this.presence.activate(this.supportsPresence);
 }
 accept(){if(!this.conflict)return;const {incoming}=this.conflict;this.conflict=null;this.adopt(incoming);}
 undoChange(redo){if(this.kind==='rich')this.host.editor().commands[redo?'redo':'undo']();else{this.undo[redo?'redo':'undo']();this.host.refresh(this);this.previous=this.kind==='tasks'?readTasks(this.doc):null;} }
 destroy(){this.presence.destroy();this.stopped=true;clearTimeout(this.retry);this.doc.off('update',this.onUpdate);this.undo?.destroy();this.conflict?.incoming.destroy();this.doc.destroy();}
}
