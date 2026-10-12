import {Extension} from '@tiptap/core';
import {yCursorPlugin} from '@tiptap/y-tiptap';
import {Awareness,applyAwarenessUpdate,encodeAwarenessUpdate,removeAwarenessStates} from 'y-protocols/awareness';
import {Y,encode,decode} from './live-model.js';

const safeColor=user=>/^#[a-f\d]{6}$/i.test(user?.color||'')?user.color:'#BDA9DC';
export function cursorElement(user,client){
 const caret=document.createElement('span');caret.className='live-caret';caret.contentEditable='false';caret.dataset.peer=String(client);caret.style.setProperty('--peer-color',safeColor(user));caret.setAttribute('aria-label',(user?.name||'Collaborator')+'’s cursor');
 const label=document.createElement('span');label.className='live-caret-name';label.textContent=user?.name||'Collaborator';caret.append(label);return caret;
}
// Awareness is deliberately separate from the Y.Doc: names, selections and
// cursor positions never enter Markdown, Git checkpoints, or undo history.
export class LivePresence {
 constructor(session){
  this.session=session;this.awareness=new Awareness(session.doc);this.enabled=false;this.stopped=false;
  this.layer=document.createElement('div');this.layer.className='live-presence-layer';this.layer.setAttribute('aria-hidden','true');document.body.append(this.layer);
  this.awareness.on('update',(change,origin)=>{
   if(origin!=='relay'&&[...change.added,...change.updated,...change.removed].includes(this.awareness.clientID))this.schedule();
  });
  this.awareness.on('change',()=>this.drawSoon());
  this.onSelection=()=>queueMicrotask(()=>this.capture());this.onLayout=()=>this.drawSoon();
  for(const event of ['selectionchange','focusin','focusout','input','keyup','pointerup'])document.addEventListener(event,this.onSelection,true);
  window.addEventListener('resize',this.onLayout);document.addEventListener('scroll',this.onLayout,true);
  this.onBlur=()=>{this.awareness.setLocalStateField('cursor',null);this.awareness.setLocalStateField('field',null);};window.addEventListener('blur',this.onBlur);
  this.docChanged=()=>{this.drawSoon();queueMicrotask(()=>this.capture());};session.doc.on('update',this.docChanged);
 }
 extension(){const self=this;return Extension.create({name:'liveCursors',addProseMirrorPlugins(){return [yCursorPlugin(self.awareness,{cursorBuilder:cursorElement,selectionBuilder:user=>({class:'live-selection',style:'background-color:'+safeColor(user)+'30'})})];}});}
 activate(enabled=true){this.enabled=enabled;this.capture();this.awareness.setLocalState({...this.awareness.getLocalState()});this.schedule();}
 schedule(){if(!this.enabled||this.stopped||this.timer)return;this.timer=setTimeout(()=>{this.timer=null;if(this.enabled&&!this.stopped)this.session.host.send('liveAwareness',{lineage:this.session.doc.getMap('meta').get('lineage'),update:encode(encodeAwarenessUpdate(this.awareness,[this.awareness.clientID]))});},60);}
 receive(update){if(this.stopped)return;applyAwarenessUpdate(this.awareness,decode(update),'relay');}
 offline(){this.enabled=false;clearTimeout(this.timer);this.timer=null;removeAwarenessStates(this.awareness,[...this.awareness.getStates().keys()].filter(id=>id!==this.awareness.clientID),'relay');this.layer.replaceChildren();}
 textFor(field){if(field==='source')return this.session.doc.getText('source');if(field==='title')return this.session.doc.getText('title');const match=field?.match(/^item:(.+):(title|description)$/);return match?this.session.doc.getMap('items').get(match[1])?.get(match[2]):null;}
 restoreSelection(){
  const state=this.awareness.getLocalState(),active=document.activeElement;
  if(!state?.cursor||typeof active?.selectionStart!=='number')return;
  const field=active.id==='source'?'source':active.dataset.liveField;if(field!==state.field)return;
  try{const a=Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(state.cursor.anchor),this.session.doc),b=Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(state.cursor.head),this.session.doc),text=this.textFor(field);if(a?.type===text&&b?.type===text)active.setSelectionRange(Math.min(a.index,b.index),Math.max(a.index,b.index),a.index>b.index?'backward':'forward');}catch{}
 }
 capture(){
  if(this.stopped||this.session.kind==='rich')return;
  const active=document.activeElement,source=document.getElementById('source'),host=active?.closest('[data-live-field]');
  const field=this.session.kind==='source'&&active===source?'source':this.session.kind==='tasks'?host?.dataset.liveField:null;
  const text=this.textFor(field);let cursor=null;
  if(text&&typeof active.selectionStart==='number'){const backward=active.selectionDirection==='backward',start=Math.min(active.selectionStart,text.length),end=Math.min(active.selectionEnd,text.length);cursor={anchor:Y.createRelativePositionFromTypeIndex(text,backward?end:start),head:Y.createRelativePositionFromTypeIndex(text,backward?start:end)};}
  const next={...(this.awareness.getLocalState()||{}),field:field||null,cursor};
  if(JSON.stringify(next)!==JSON.stringify(this.awareness.getLocalState()))this.awareness.setLocalState(next);
 }
 drawSoon(){if(this.stopped||this.frame)return;this.frame=setTimeout(()=>{this.frame=null;this.draw();},16);}
 draw(){
  this.layer.replaceChildren();if(this.stopped||!this.enabled||this.session.kind==='rich')return;
  const groups=new Map();
  for(const [client,state] of this.awareness.getStates()){
   if(client===this.awareness.clientID||!state.field)continue;
   const target=state.field==='source'?document.getElementById('source'):[...document.querySelectorAll('[data-live-field]')].find(n=>n.dataset.liveField===state.field);
   if(!target||!target.getClientRects().length)continue;
   if(!groups.has(target))groups.set(target,[]);groups.get(target).push({client,state});
  }
  for(const [target,peers] of groups){
   const rect=target.getBoundingClientRect();if(rect.bottom<0||rect.top>innerHeight)continue;
   if(target.tagName==='TEXTAREA')this.drawText(target,peers,rect);
   else{
    const badge=document.createElement('span');badge.className='live-field-presence';badge.style.setProperty('--peer-color',safeColor(peers[0].state.user));badge.textContent=peers.map(p=>p.state.user?.name||'Collaborator').join(', ')+' editing';badge.style.left=Math.max(4,Math.min(rect.left,innerWidth-180))+'px';badge.style.top=Math.max(2,rect.top-20)+'px';this.layer.append(badge);
   }
  }
 }
 drawText(target,peers,rect){
  const wrapper=document.createElement('div');wrapper.className='live-text-overlay';Object.assign(wrapper.style,{left:rect.left+'px',top:rect.top+'px',width:target.clientWidth+'px',height:target.clientHeight+'px'});
  const pre=document.createElement('pre'),style=getComputedStyle(target),text=target.value,ranges=[];
  for(const prop of ['font','lineHeight','letterSpacing','paddingTop','paddingRight','paddingBottom','paddingLeft','tabSize','textIndent','textAlign','wordSpacing'])pre.style[prop]=style[prop];
  pre.style.width=target.clientWidth+'px';pre.style.transform=`translate(${-target.scrollLeft}px,${-target.scrollTop}px)`;
  for(const {client,state} of peers){
   if(!state.cursor)continue;
   try{const a=Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(state.cursor.anchor),this.session.doc),b=Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(state.cursor.head),this.session.doc),field=this.textFor(state.field);
    if(a?.type===field&&b?.type===field)ranges.push({from:Math.min(a.index,b.index,text.length),to:Math.min(Math.max(a.index,b.index),text.length),head:Math.min(b.index,text.length),client,user:state.user});
   }catch{}
  }
  const points=[...new Set([0,text.length,...ranges.flatMap(r=>[r.from,r.to,r.head])])].sort((a,b)=>a-b);
  points.forEach((at,index)=>{
   for(const r of ranges.filter(r=>r.head===at)){const caret=cursorElement(r.user,r.client);caret.classList.add('live-text-caret');caret.dataset.offset=String(at);pre.append(caret);}
   const end=points[index+1];if(end===undefined)return;const span=document.createElement('span'),hit=ranges.find(r=>r.from<=at&&r.to>=end&&r.from!==r.to);span.textContent=text.slice(at,end);if(hit){span.className='live-selection';span.style.backgroundColor=safeColor(hit.user)+'30';}pre.append(span);
  });
  pre.append(document.createTextNode('\u200b'));wrapper.append(pre);this.layer.append(wrapper);
 }
 destroy(){
  if(this.stopped)return;this.offline();this.stopped=true;clearTimeout(this.frame);this.layer.remove();
  for(const event of ['selectionchange','focusin','focusout','input','keyup','pointerup'])document.removeEventListener(event,this.onSelection,true);
  window.removeEventListener('resize',this.onLayout);document.removeEventListener('scroll',this.onLayout,true);window.removeEventListener('blur',this.onBlur);this.session.doc.off('update',this.docChanged);this.awareness.destroy();
 }
}
