import {diffChars, diffArrays} from 'diff';
import {Extension} from '@tiptap/core';
import {Plugin, PluginKey} from '@tiptap/pm/state';
import {Decoration, DecorationSet} from '@tiptap/pm/view';
import {closeHistory} from '@tiptap/pm/history';

function edits(base,next){
 const diff=diffChars(base,next,{timeout:80});if(!diff)return null;
 const result=[];let at=0,change=null;
 for(const part of diff){
  if(!part.added&&!part.removed){if(change)result.push(change);change=null;at+=part.value.length;continue;}
  change??={from:at,to:at,text:''};
  if(part.removed){at+=part.value.length;change.to=at;}else change.text+=part.value;
 }
 if(change)result.push(change);return result;
}

// Only combine independent changes. Ambiguous edits remain on disk and in the
// local recovery journal until the user chooses; neither author wins silently.
export function mergeExternal(base,local,incoming){
 if(local===base||local===incoming)return incoming;if(incoming===base)return local;
 const a=edits(base,local),b=edits(base,incoming);if(!a||!b)return null;
 const all=[...a];
 for(const next of b){
  let duplicate=false;
  for(const current of a){
   if(current.from===next.from&&current.to===next.to&&current.text===next.text){duplicate=true;continue;}
   const overlap=Math.max(current.from,next.from)<Math.min(current.to,next.to);
   const touchingInsertion=(current.from===current.to&&current.from>=next.from&&current.from<=next.to)||(next.from===next.to&&next.from>=current.from&&next.from<=current.to);
   if(overlap||touchingInsertion)return null;
  }
  if(!duplicate)all.push(next);
 }
 let result=base;for(const change of all.sort((a,b)=>b.from-a.from))result=result.slice(0,change.from)+change.text+result.slice(change.to);
 return result;
}

export const externalEditKey=new PluginKey('omegaExternalEdit');
export const ExternalEditHighlight=Extension.create({
 name:'omegaExternalEdit',
 addProseMirrorPlugins(){return [new Plugin({key:externalEditKey,state:{init:()=>DecorationSet.empty,apply(tr,current){
  const ranges=tr.getMeta(externalEditKey);
  if(ranges===null)return DecorationSet.empty;
  if(ranges)return DecorationSet.create(tr.doc,ranges.filter(r=>r.to>r.from).map(r=>Decoration.inline(r.from,r.to,{class:'external-edit-highlight'})));
  return current.map(tr.mapping,tr.doc);
 }},props:{decorations:state=>externalEditKey.getState(state)}})];},
});

// Preserve unchanged nodes (and the user's selection between edits) instead of
// replacing the whole document. Positions below refer to the original tree.
export function patchRichDocument(editor,next,{highlight=false}={}){
 const patches=[];
 function children(oldNode,newNode,start){
  const a=[],b=[];oldNode.forEach(n=>a.push(n));newNode.forEach(n=>b.push(n));
  const diff=diffArrays(a,b,{comparator:(a,b)=>a.eq(b),timeout:80});
  if(!diff){patches.push({from:start,to:start+oldNode.content.size,nodes:b});return;}
  let at=start,removed=[],added=[],begin=start;
  function flush(){
   if(!removed.length&&!added.length)return;
   if(removed.length===added.length&&removed.every((n,i)=>n.sameMarkup(added[i]))){
    let pos=begin;
    removed.forEach((old,i)=>{const value=added[i];
     if(old.isText){const changes=edits(old.text,value.text);if(changes)for(const c of changes)patches.push({from:pos+c.from,to:pos+c.to,nodes:c.text?editor.schema.text(c.text,old.marks):[]});else patches.push({from:pos,to:pos+old.nodeSize,nodes:[value]});}
     else if(!old.isLeaf)children(old,value,pos+1);
     pos+=old.nodeSize;
    });
   }else patches.push({from:begin,to:at,nodes:added});
   removed=[];added=[];
  }
  for(const part of diff){
   if(!part.added&&!part.removed){flush();at+=part.value.reduce((sum,n)=>sum+n.nodeSize,0);begin=at;}
   else if(part.removed){removed.push(...part.value);at+=part.value.reduce((sum,n)=>sum+n.nodeSize,0);}
   else added.push(...part.value);
  }flush();
 }
 children(editor.state.doc,next,0);if(!patches.length)return false;
 let tr=closeHistory(editor.state.tr);
 for(const p of patches.sort((a,b)=>b.from-a.from))tr.replaceWith(p.from,p.to,p.nodes);
 if(!tr.doc.eq(next))throw new Error('External document could not be applied safely');
 if(highlight){const ranges=patches.map(p=>({from:tr.mapping.map(p.from,-1),to:tr.mapping.map(p.to,1)}));tr.setMeta(externalEditKey,ranges);}
 editor.view.dispatch(tr);return true;
}
