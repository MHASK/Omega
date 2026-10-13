import {Editor} from '@tiptap/core';
import Collaboration from '@tiptap/extension-collaboration';
import {yDocToProsemirrorJSON} from '@tiptap/y-tiptap';
import {extensions,visualMarkdown,needsSource} from './schema.js';
import {Y,encode,decode,changeText,updateTasks,readTasks,taskText,remoteOrigin,localOrigin} from './live-model.js';
import {parseTasks} from './task-model.js';

export function checkpointDoc(checkpoint){
 if(!checkpoint?.state||checkpoint.state.length>16*1024*1024)throw Error('Invalid shared history');
 const doc=new Y.Doc({gc:false});
 try{Y.applyUpdate(doc,decode(checkpoint.state),remoteOrigin);const meta=doc.getMap('meta');if(meta.get('version')!==1||!['rich','source','tasks'].includes(meta.get('kind'))||!meta.get('lineage'))throw Error('Invalid shared history');return doc;}catch(error){doc.destroy();throw error;}
}
export function sharedText(doc){
 const kind=doc.getMap('meta').get('kind');
 if(kind==='source')return doc.getText('source').toString();
 if(kind==='tasks')return taskText(doc);
 const editor=new Editor({element:document.createElement('div'),extensions:extensions({nativeHistory:true}),content:yDocToProsemirrorJSON(doc,'body')});
 try{return editor.getMarkdown()+'\n';}finally{editor.destroy();}
}
export function patchShared(doc,text){
 if(sharedText(doc)===text)return;
 const kind=doc.getMap('meta').get('kind');
 if(kind==='source'){doc.transact(()=>changeText(doc.getText('source'),text),localOrigin);return;}
 if(kind==='tasks'){const next=parseTasks(text);if(!next)throw Error('Document format changed');updateTasks(doc,next,readTasks(doc));return;}
 if(parseTasks(text)||needsSource(text))throw Error('Document format changed');
 const editor=new Editor({element:document.createElement('div'),extensions:[...extensions({nativeHistory:true}),Collaboration.configure({document:doc,field:'body'})]});
 try{
  const next=editor.schema.nodeFromJSON(editor.markdown.parse(visualMarkdown(text))),current=editor.state.doc,start=current.content.findDiffStart(next.content);
  if(start!==null){const end=current.content.findDiffEnd(next.content);let a=end.a,b=end.b;if(a<start){b+=start-a;a=start;}if(b<start){a+=start-b;b=start;}editor.view.dispatch(editor.state.tr.replace(start,a,next.slice(start,b)));}
 }finally{editor.destroy();}
}
export function mergeGitCheckpoints(config){
 let left,right;
 try{
  left=checkpointDoc(config.mine);if(config.mineText!==undefined&&config.mineText!==config.mine.text)patchShared(left,config.mineText);
  if(config.incoming){
   right=checkpointDoc(config.incoming);if(config.incomingText!==undefined&&config.incomingText!==config.incoming.text)patchShared(right,config.incomingText);
   if(left.getMap('meta').get('lineage')!==right.getMap('meta').get('lineage')||left.getMap('meta').get('kind')!==right.getMap('meta').get('kind')){
    if(config.resolvedText===undefined)return null; // Human choice is applied to our existing lineage.
   }else Y.applyUpdate(left,Y.encodeStateAsUpdate(right),remoteOrigin);
  }
  if(config.resolvedText!==undefined)patchShared(left,config.resolvedText);
  return {state:encode(Y.encodeStateAsUpdate(left)),text:sharedText(left),accepted:!!config.mine.accepted||!!config.incoming?.accepted};
 }catch{return null;}finally{left?.destroy();right?.destroy();}
}
