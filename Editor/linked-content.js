import {Editor,Extension} from '@tiptap/core';
import {Plugin,PluginKey} from '@tiptap/pm/state';
import {Decoration,DecorationSet} from '@tiptap/pm/view';
import {extensions,noteContent} from './schema.js';
import {isPageHref} from './page-links.js';
import {parseTasks,walkTasks,subtaskStatus,goalProgress} from './task-model.js';
import {completionRing,projectCompletion,taskCompletion} from './completion-ring.js';

const subscribers=new Map();let sequence=0,timer=null,latest='',scheduled=false;
function poll(){if(!subscribers.size||!window.omegaReferenceRequest)return;latest=String(++sequence);window.omegaReferenceRequest(latest,[...new Set([...subscribers.values()].map(s=>s.href))].slice(0,100));}
function requestPoll(){if(scheduled)return;scheduled=true;queueMicrotask(()=>{scheduled=false;poll();});}
function subscribe(href,callback){const key={};subscribers.set(key,{href,callback});if(!timer)timer=setInterval(poll,2000);requestPoll();return()=>{subscribers.delete(key);if(!subscribers.size){clearInterval(timer);timer=null;latest='';}};}
if(typeof window!=='undefined')window.omegaReferences={receive(request,rows){if(request!==latest)return;const byHref=new Map(rows.map(row=>[row.href,row]));for(const s of subscribers.values())if(byHref.has(s.href))s.callback(byHref.get(s.href));}};
export function linkedSummary(row){
 if(row.error)return {error:row.error};if(row.goalProgress)return row.goalProgress;const model=parseTasks(row.tasks||'');if(!model)return null;
 const match=row.href.match(/#folio-(task|goal)-([\w-]+)$/);if(!match){const p=projectCompletion(model);return p.total?{...p,status:p.completed===p.total?model.completed:'',name:row.name}:null;}
 if(match[1]==='goal'){const g=model.goals.find(g=>g.details.id===match[2]);if(!g)return {error:'This goal is no longer in its source page.'};const p=goalProgress(model,g);return {completed:p.total?p.completed:Number(p.done),total:p.total||1,status:p.done?'Done':p.completed?'In progress':'Not started',name:g.title};}
 const found=walkTasks(model).find(e=>e.item.details.id===match[2]);if(!found)return {error:'This task is no longer in its source page.'};return {...taskCompletion(model,found.item,found.parent),status:model.statuses[found.parent?subtaskStatus(model,found.item):found.item.status],name:found.item.title};
}
const key=new PluginKey('liveReferences');
function links(doc){const list=[];doc.descendants((node,pos)=>{if(!node.isText)return;const href=node.marks.find(m=>m.type.name==='link')?.attrs.href;if(!isPageHref(href))return;const last=list.at(-1);if(last?.href===href&&last.to===pos){last.to+=node.nodeSize;last.text+=node.text;}else list.push({href,from:pos,to:pos+node.nodeSize,text:node.text});});return list;}
function decorations(doc,data){const result=[];for(const link of links(doc)){const info=data.get(link.href);if(!info)continue;const only=/^(Status|Progress)$/.test(link.text);if(only)result.push(Decoration.inline(link.from,link.to,{class:'live-reference-placeholder'}));result.push(Decoration.widget(link.to,()=>{
 const badge=document.createElement('button');badge.type='button';badge.className='live-reference'+(info.error?' unavailable':'');badge.contentEditable='false';badge.dataset.referenceHref=link.href;
 badge.title=info.error||`${info.name} · ${info.status||'Progress'} · ${info.completed}/${info.total} complete · Open source`;
 badge.setAttribute('aria-label',badge.title);badge.onclick=e=>{e.preventDefault();e.stopPropagation();window.omegaReferenceOpen?.(link.href);};
 if(info.error){badge.textContent=only?'Unavailable':'!';return badge;}
 if(link.text!=='Status'){badge.append(completionRing(info.completed,info.total,{label:`${info.completed} of ${info.total} complete`}));const count=document.createElement('span');count.textContent=`${info.completed}/${info.total}`;badge.append(count);}
 if(info.status&&link.text!=='Progress'){const state=document.createElement('span');state.className='live-reference-status';state.textContent=info.status;badge.append(state);}return badge;
 },{side:1,marks:[],key:link.href+'|'+JSON.stringify(info)+'|'+link.from,stopEvent:()=>true}));}return DecorationSet.create(doc,result);}
export const LiveReferences=Extension.create({name:'liveReferences',addProseMirrorPlugins(){return [new Plugin({key,state:{init:()=>new Map(),apply(tr,value){return tr.getMeta(key)||value;}},props:{decorations:state=>decorations(state.doc,key.getState(state))},view(view){let dead=false,subscriptions=new Map(),data=new Map();
 const sync=()=>{const wanted=new Set(links(view.state.doc).map(l=>l.href));for(const [href,stop] of subscriptions)if(!wanted.has(href)){stop();subscriptions.delete(href);data.delete(href);}for(const href of [...wanted].slice(0,100))if(!subscriptions.has(href))subscriptions.set(href,subscribe(href,row=>{if(dead)return;const next=linkedSummary(row);if(JSON.stringify(next)===JSON.stringify(data.get(href)))return;if(next)data.set(href,next);else data.delete(href);view.dispatch(view.state.tr.setMeta(key,new Map(data)).setMeta('addToHistory',false));}));};sync();return {update:sync,destroy(){dead=true;for(const stop of subscriptions.values())stop();}};
 }})];}});

export function quoteNodeView({node,editor,getPos}){
 const dom=document.createElement('section');dom.className='linked-quote';const head=document.createElement('div');head.className='linked-quote-head';head.contentEditable='false';
 const open=document.createElement('button');open.type='button';open.className='linked-quote-origin';open.textContent='Linked section';
 const sourceButton=document.createElement('button');sourceButton.type='button';sourceButton.textContent='Source';sourceButton.setAttribute('aria-label','Edit linked section source');head.append(open,sourceButton);
 const preview=document.createElement('div');preview.className='linked-quote-preview';preview.contentEditable='false';preview.textContent='Loading linked section…';
 const pre=document.createElement('pre'),code=document.createElement('code');pre.append(code);pre.hidden=true;const input=document.createElement('textarea');input.className='linked-quote-input';input.hidden=true;input.value=node.textContent;input.setAttribute('aria-label','Linked section source');input.readOnly=!editor.isEditable;dom.append(head,preview,input,pre);
 let current=node,stop,child,last='',dead=false;
 sourceButton.onclick=()=>{input.hidden=!input.hidden;sourceButton.textContent=input.hidden?'Source':'Done';input.readOnly=!editor.isEditable;if(!input.hidden)input.focus();};
 input.oninput=()=>{if(!editor.isEditable)return;const pos=getPos();editor.view.dispatch(input.value?editor.state.tr.insertText(input.value,pos+1,pos+current.nodeSize-1):editor.state.tr.delete(pos+1,pos+current.nodeSize-1));};
 input.onkeydown=e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();window.folio?.command(e.shiftKey?'redo':'undo');}};
 function update(){stop?.();last='';child?.destroy();child=null;preview.textContent='Loading linked section…';const href=current.textContent.trim();open.onclick=()=>window.omegaReferenceOpen?.(href);if(!isPageHref(href)||/\s*\n/.test(href)){preview.textContent='Choose a page or heading with /linked section, or enter its relative Markdown link.';return;}
 stop=subscribe(href,row=>{if(dead)return;const signature=JSON.stringify(row);if(last===signature)return;last=signature;child?.destroy();child=null;preview.replaceChildren();open.textContent=(row.name||'Linked section')+' ↗';open.title='Open source · updates automatically';if(row.error){preview.textContent=row.error;preview.classList.add('unavailable');return;}preview.classList.remove('unavailable');
 // Nested live quotes render as source, never recursively fetch. Quoted images
 // remain placeholders so their paths cannot accidentally use this note's root.
 child=new Editor({element:preview,extensions:extensions({quoted:true}),...noteContent(row.markdown||''),editable:false,editorProps:{attributes:{'aria-label':'Live quote from '+row.name},handleClick:(view,pos,event)=>{const a=event.target.closest('a');if(!a)return false;event.preventDefault();window.omegaReferenceOpen?.(row.href);return true;}}});
 });}
 update();return {dom,contentDOM:code,update(next){if(next.type!==node.type||next.attrs.language!=='omega-quote')return false;const changed=next.textContent!==current.textContent;current=next;if(input.value!==next.textContent)input.value=next.textContent;if(changed)update();return true;},stopEvent:e=>!!e.target.closest('.linked-quote-head,.linked-quote-preview,.linked-quote-input'),ignoreMutation:m=>m.type!=='selection'&&!code.contains(m.target),destroy(){dead=true;stop?.();child?.destroy();}};
}
