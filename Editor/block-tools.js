import {TextSelection} from '@tiptap/pm/state';
import {Fragment} from '@tiptap/pm/model';
import {closeHistory} from '@tiptap/pm/history';
import {quietButton,positionPopover} from './writing-tools.js';

export function blockAt(editor,pos){
 const $pos=editor.state.doc.resolve(Math.min(pos,editor.state.doc.content.size));if(!$pos.depth)return null;
 let depth=1;for(let d=$pos.depth;d>0;d--)if(['listItem','taskItem'].includes($pos.node(d).type.name)){depth=d;break;}
 const node=$pos.node(depth);if(node.type.name==='commentRecord')return null;
 return {from:$pos.before(depth),to:$pos.after(depth),node,parent:$pos.node(depth-1),index:$pos.index(depth-1),depth};
}
export function duplicateBlock(editor,block){
 if(!editor.isEditable||editor.state.doc.nodeAt(block.from)!==block.node)return false;
 const strip=node=>({...node,...(node.marks?{marks:node.marks.filter(m=>m.type!=='commentAnchor')}:{}) ,...(node.content?{content:node.content.map(strip)}:{})});
 const copy=editor.schema.nodeFromJSON(strip(block.node.toJSON()));const tr=editor.state.tr.insert(block.to,copy);editor.view.dispatch(tr.setSelection(TextSelection.near(tr.doc.resolve(block.to+1))));return true;
}
const isItem=node=>['listItem','taskItem'].includes(node.type.name);
function moveTransaction(editor,block,target){
 if(!editor.isEditable||editor.state.doc.nodeAt(block.from)!==block.node||!Number.isInteger(target)||target<0||target>editor.state.doc.content.size||target>=block.from&&target<=block.to)return null;
 try{
  const $target=editor.state.doc.resolve(target);if($target.textOffset)return null;
  // An item dropped outside a list carries its original list style and children.
  const content=Fragment.from(isItem(block.node)&&!$target.parent.canReplace($target.index(),$target.index(),Fragment.from(block.node))?block.parent.copy(Fragment.from(block.node)):block.node);
  if(!$target.parent.canReplace($target.index(),$target.index(),content))return null;
  // Remove an emptied list wrapper too, rather than leaving an empty bullet.
  const onlyItem=isItem(block.node)&&block.parent.childCount===1;
  const tr=editor.state.tr.delete(block.from-(onlyItem?1:0),block.to+(onlyItem?1:0)),pos=tr.mapping.map(target);
  const $pos=tr.doc.resolve(pos);if(!$pos.parent.canReplace($pos.index(),$pos.index(),content))return null;
  tr.insert(pos,content);tr.doc.check();
  return closeHistory(tr).setSelection(TextSelection.near(tr.doc.resolve(pos+1))).setMeta('uiEvent','drop');
 }catch{return null;}
}
export function moveBlock(editor,block,target){
 const tr=moveTransaction(editor,block,target);if(!tr)return false;
 editor.view.dispatch(tr.scrollIntoView());return true;
}
export class BlockTools {
 constructor(host){
  this.host=host;this.tools=document.createElement('div');this.tools.className='block-tools';this.tools.hidden=true;
  this.add=quietButton('Insert a block below',()=>this.insert(),'+');this.handle=quietButton('Block actions · drag to move',()=>{if(performance.now()>(this.suppressClickUntil||0))this.open();},'⠿');this.tools.append(this.add,this.handle);document.body.append(this.tools);
  this.menu=document.createElement('div');this.menu.className='popover block-menu';this.menu.hidden=true;this.menu.setAttribute('role','menu');this.menu.setAttribute('aria-label','Block actions');document.body.append(this.menu);
  this.guide=document.createElement('div');this.guide.className='block-drop-guide';this.guide.hidden=true;document.body.append(this.guide);
  this.announcement=document.createElement('div');this.announcement.className='block-drag-status';this.announcement.setAttribute('role','status');document.body.append(this.announcement);
  document.addEventListener('pointermove',e=>this.drag?this.dragMove(e):this.hover(e));
  document.addEventListener('pointerdown',e=>{if(!e.target.closest('.block-tools,.block-menu'))this.close();});
  document.addEventListener('pointerup',e=>this.endDrag(e),true);
  document.addEventListener('pointercancel',()=>this.cancelDrag(),true);
  window.addEventListener('blur',()=>this.cancelDrag());
  document.addEventListener('keydown',e=>{if(this.drag&&e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();this.cancelDrag();}},true);
  document.addEventListener('scroll',()=>{if(this.drag?.active)this.showDrop();else if(!this.drag&&this.menu.hidden)this.tools.hidden=true;},true);
  // Pointer capture avoids WebKit's native HTML drag competing with editor drops.
  this.handle.onpointerdown=e=>this.beginDrag(e);
  this.handle.onlostpointercapture=()=>this.cancelDrag();
  this.handle.ondragstart=e=>e.preventDefault();
  this.menu.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();this.close();this.editor.commands.focus();}if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();const b=[...this.menu.querySelectorAll('button,select')].filter(x=>!x.disabled),i=b.indexOf(document.activeElement);b[(i+(e.key==='ArrowDown'?1:-1)+b.length)%b.length]?.focus();}};
 }
 bind(editor){this.cancelDrag();this.editor=editor;this.close();this.tools.hidden=true;}
 reset(){this.cancelDrag();this.editor=null;this.close();this.tools.hidden=true;}
 close(){this.menu.hidden=true;}
 hover(e){
  if(!this.editor?.isEditable||this.host.disabled()){this.tools.hidden=true;return;}
  if(e.target.closest('.block-tools,.block-menu')||!this.menu.hidden)return;
  if(!this.editor.view.dom.contains(e.target)){if(this.tools.getBoundingClientRect().right+10<e.clientX)this.tools.hidden=true;return;}
  let pos;try{pos=this.editor.view.posAtDOM(e.target,0);}catch{return;}
  const $pos=this.editor.state.doc.resolve(pos),node=this.editor.state.doc.nodeAt(pos);
  const block=$pos.depth===0&&node?.isAtom&&node.isBlock?{from:pos,to:pos+node.nodeSize,node,parent:$pos.parent,index:$pos.index(),depth:1}:blockAt(this.editor,pos+1);if(!block)return;
  const dom=this.editor.view.nodeDOM(block.from);if(!dom?.getBoundingClientRect)return;
  const rect=dom.getBoundingClientRect();this.block=block;this.tools.hidden=false;this.tools.style.left=Math.max(2,rect.left-40)+'px';this.tools.style.top=Math.max(2,rect.top+1)+'px';
 }
 range(){const b=this.block;return b?{from:b.from+1,to:b.to-1}:null;}
 select(){if(!this.block||this.editor.state.doc.nodeAt(this.block.from)!==this.block.node)return false;this.editor.commands.setTextSelection(this.range());return true;}
 insert(){if(!this.select())return;this.close();const at=this.block.to,paragraph={type:'paragraph',content:[{type:'text',text:'/'}]},list=['listItem','taskItem'].includes(this.block.node.type.name);this.editor.chain().focus().insertContentAt(at,list?{type:this.block.node.type.name,attrs:this.block.node.type.name==='taskItem'?{checked:false}:undefined,content:[paragraph]}:paragraph).setTextSelection(at+(list?3:2)).run();this.editor.view.focus();this.host.refresh?.();}
 open(){
  if(!this.select())return;this.host.hideMenus();this.menu.replaceChildren();
  const row=(label,action)=>{const b=quietButton(label,()=>{action();this.close();},label);b.setAttribute('role','menuitem');this.menu.append(b);return b;};
  const select=document.createElement('select');select.setAttribute('aria-label','Turn block into');
  for(const [value,label] of [['','Turn into…'],['paragraph','Text'],['h1','Heading 1'],['h2','Heading 2'],['h3','Heading 3'],['bullet','Bullet list'],['numbered','Numbered list'],['checklist','Checklist'],['quote','Quote'],['code','Code block']]){const option=document.createElement('option');option.value=value;option.textContent=label;select.append(option);}select.onchange=()=>{this.host.turnInto(select.value);this.close();};select.disabled=this.block.node.type.name==='table';this.menu.append(select);
  row('Color & highlight',()=>this.host.color(this.range()));row('Comment',()=>this.host.comment(this.range()));
  row('Duplicate',()=>duplicateBlock(this.editor,this.block));
  row('Move up',()=>{const b=this.block;if(b.index>0)moveBlock(this.editor,b,b.from-b.parent.child(b.index-1).nodeSize);}).disabled=this.block.index===0;
  row('Move down',()=>{const b=this.block;if(b.index<b.parent.childCount-1)moveBlock(this.editor,b,b.to+b.parent.child(b.index+1).nodeSize);}).disabled=this.block.index>=this.block.parent.childCount-1;
  row('Delete',()=>this.editor.chain().focus().deleteRange({from:this.block.from,to:this.block.to}).run());
  const count=document.createElement('small'),text=this.block.node.textContent;count.textContent=`${text.trim().split(/\s+/).filter(Boolean).length} words · ${[...text].length} characters`;this.menu.append(count);positionPopover(this.menu,this.tools.getBoundingClientRect());
 }
 beginDrag(e){
  if(e.button!==0||!this.block||!this.editor?.isEditable||this.host.disabled())return;
  if(this.editor.state.doc.nodeAt(this.block.from)!==this.block.node)return;
  e.preventDefault();this.suppressClickUntil=0;
  this.drag={...this.block,doc:this.editor.state.doc,pointer:e.pointerId,startX:e.clientX,startY:e.clientY,x:e.clientX,y:e.clientY,active:false};
  try{this.handle.setPointerCapture(e.pointerId);}catch{} // Synthetic events in WebKit checks have no active pointer.
 }
 dragMove(e){
  const d=this.drag;if(e.pointerId!==d.pointer)return;
  if(!this.editor?.isEditable||this.host.disabled()||!d.doc.eq(this.editor.state.doc)){this.cancelDrag();return;}
  d.x=e.clientX;d.y=e.clientY;
  if(!d.active&&Math.hypot(d.x-d.startX,d.y-d.startY)<5)return;
  e.preventDefault();
  if(!d.active){
   d.active=true;this.host.hideMenus();this.close();document.body.classList.add('block-dragging');
   d.dom=this.editor.view.nodeDOM(d.from);d.dom?.classList.add('block-drag-source');
   this.announcement.textContent='Moving block. Release to place it, or press Escape to cancel.';
   this.autoScroll();
  }
  this.showDrop();
 }
 showDrop(){
  const d=this.drag;this.guide.hidden=true;this.dropPosition=null;if(!d?.active)return;
  if(!this.editor?.isEditable||this.host.disabled()||!d.doc.eq(this.editor.state.doc)){this.cancelDrag();return;}
  const scroller=document.querySelector('#scroller'),bounds=scroller.getBoundingClientRect();
  if(d.x<bounds.left||d.x>bounds.right||d.y<bounds.top||d.y>bounds.bottom)return;
  const candidates=[];
  this.editor.state.doc.descendants((node,pos,parent)=>{
   if(node.type.name==='commentRecord')return false;
   if(parent!==this.editor.state.doc&&!(isItem(d.node)&&isItem(node)&&node.type===d.node.type))return true;
   const r=this.editor.view.nodeDOM(pos)?.getBoundingClientRect();if(!r||!r.height)return true;
   // Top-level blocks remain whole, including tables and nested lists.
   for(const [target,y] of [[pos,r.top],[pos+node.nodeSize,r.bottom]]){
    const insideX=d.x>=r.left-40&&d.x<=r.right+40;
    candidates.push({target,y,r,score:Math.abs(d.y-y)+(insideX?0:12),depth:this.editor.state.doc.resolve(pos).depth});
   }
   return isItem(d.node);
  });
  candidates.sort((a,b)=>a.score-b.score||b.depth-a.depth);
  const best=candidates[0];if(!best||!moveTransaction(this.editor,d,best.target))return;
  this.dropPosition=best.target;this.guide.hidden=false;
  this.guide.style.left=Math.max(bounds.left+8,best.r.left)+'px';
  this.guide.style.width=Math.max(0,Math.min(bounds.right-8,best.r.right)-Math.max(bounds.left+8,best.r.left))+'px';
  this.guide.style.top=best.y+'px';
 }
 autoScroll(){
  if(!this.drag?.active)return;
  const d=this.drag,scroller=document.querySelector('#scroller'),r=scroller.getBoundingClientRect(),edge=Math.min(56,r.height/4);
  if(d.x>=r.left&&d.x<=r.right&&d.y>=r.top&&d.y<=r.bottom){
   const speed=d.y<r.top+edge?-14*(1-(d.y-r.top)/edge):d.y>r.bottom-edge?14*(1-(r.bottom-d.y)/edge):0;
   if(speed){scroller.scrollTop+=speed;this.showDrop();}
  }
  this.dragFrame=requestAnimationFrame(()=>this.autoScroll());
 }
 endDrag(e){
  const d=this.drag;if(!d||e.pointerId!==d.pointer)return;
  if(d.active){
   e.preventDefault();e.stopImmediatePropagation();d.x=e.clientX;d.y=e.clientY;this.showDrop();
   const target=this.dropPosition,valid=this.drag&&target!==null&&d.doc.eq(this.editor.state.doc);
   this.cancelDrag();
   if(valid&&moveBlock(this.editor,d,target)){this.editor.view.focus();this.announcement.textContent='Block moved. Undo restores its previous position.';}
  }else this.cancelDrag();
 }
 cancelDrag(){
  const d=this.drag;this.drag=null;this.dropPosition=null;this.guide.hidden=true;cancelAnimationFrame(this.dragFrame);
  document.body.classList.remove('block-dragging');d?.dom?.classList.remove('block-drag-source');
  if(d?.active){this.suppressClickUntil=performance.now()+350;this.tools.hidden=true;this.announcement.textContent='Block move cancelled.';}
  if(d){try{this.handle.releasePointerCapture(d.pointer);}catch{}}
 }
}
