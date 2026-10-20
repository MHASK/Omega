import {Extension} from '@tiptap/core';
import {Plugin,PluginKey,TextSelection} from '@tiptap/pm/state';
import {Decoration,DecorationSet} from '@tiptap/pm/view';
import {calculatePage} from './table-formulas.js';
const key=new PluginKey('tableFormulas'),pending=new Map();let sequence=0;
export function receiveFormulaPage(request,result){const callback=pending.get(request);if(callback){pending.delete(request);callback(result);}}
function decorations(state,result){
 const output=[];let table=0;
 state.doc.forEach((node,pos)=>{
  if(node.type.name!=='table')return;const computed=result?.tables?.[table++];if(!computed)return;
  node.forEach((row,rowPos,r)=>row.forEach((cell,cellPos,c)=>{
   const item=computed.rows[r]?.[c];if(!item?.source?.startsWith('=')||r===0)return;
   const start=pos+1+rowPos+1+cellPos,from=start+2,to=start+cell.nodeSize-2;
   const active=state.selection.from>=start&&state.selection.to<=start+cell.nodeSize;
   const message=item.message||'Click to edit formula';
   output.push(Decoration.node(start,start+cell.nodeSize,{class:'formula-cell'+(item.error?' formula-error':''),title:`${item.address} · ${item.source}\n${message}`}));
   if(active)return;
   if(to>from)output.push(Decoration.inline(from,to,{class:'formula-source'}));
   output.push(Decoration.widget(to,view=>{const el=document.createElement('span');el.className='formula-result';el.textContent=item.display||'…';el.contentEditable='false';el.setAttribute('role','button');el.setAttribute('aria-label',`${item.address}: ${item.display||'Calculating'}. ${item.error?message:'Edit formula'}`);el.tabIndex=0;
    const edit=e=>{if(!view.editable)return;e.preventDefault();view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc,from)));view.focus();};
    el.onmousedown=edit;el.onkeydown=e=>{if(e.key==='Enter')edit(e);};return el;
   },{side:1,marks:[],key:item.address+'|'+item.source+'|'+item.display+'|'+message,stopEvent:()=>true}));
  }));
 });
 return DecorationSet.create(state.doc,output);
}
export const TableFormulas=Extension.create({name:'tableFormulas',addProseMirrorPlugins(){const editor=this.editor;return [new Plugin({key,state:{init:()=>null,apply(tr,old){return tr.getMeta(key)||(tr.docChanged?null:old);}},props:{decorations:state=>decorations(state,key.getState(state))},view(view){
 let destroyed=false,lastDoc=null,textDoc=null,lastText='',timer=null,latest='',waiting=false,requestTime=0,schedule=null;
 const display=result=>{if(!destroyed)view.dispatch(view.state.tr.setMeta(key,result).setMeta('addToHistory',false));};
 const poll=()=>{
  if(destroyed||textDoc!==view.state.doc||!lastText||!window.omegaFormulaRequest||waiting&&Date.now()-requestTime<6000)return;
  pending.delete(latest);latest='formula-'+(++sequence);waiting=true;requestTime=Date.now();const text=lastText,request=latest,doc=textDoc;
  pending.set(request,result=>{if(destroyed||request!==latest)return;waiting=false;if(text===lastText&&doc===view.state.doc)display(result);else poll();});window.omegaFormulaRequest(request,text);
 };
 const sync=()=>{if(lastDoc===view.state.doc)return;lastDoc=view.state.doc;clearTimeout(schedule);schedule=setTimeout(()=>{
  if(destroyed)return;lastText=editor.getMarkdown();textDoc=view.state.doc;
  const result=calculatePage('',lastText);const hasFormulas=result.tables?.some(t=>t.rows.some(row=>row.some(c=>c.source.startsWith('='))));
  // Local arithmetic is immediate; cross-page results arrive from the native
  // notebook reader. Do not flash a false missing-reference error meanwhile.
  if(window.omegaFormulaRequest)for(const table of result.tables||[])for(const row of table.rows)for(const cell of row){
   if(cell.error==='#REF!'&&cell.message?.startsWith('Source page unavailable:')){delete cell.error;cell.display='…';cell.message='Calculating referenced page…';}
  }
  display(result);clearInterval(timer);timer=null;if(hasFormulas&&window.omegaFormulaRequest){poll();timer=setInterval(poll,2000);}
 },120);};sync();return {update:sync,destroy(){destroyed=true;clearTimeout(schedule);clearInterval(timer);pending.delete(latest);}};
 }})];}});
