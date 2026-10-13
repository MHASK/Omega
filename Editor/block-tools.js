import {TextSelection} from '@tiptap/pm/state';
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
export function moveBlock(editor,block,target){
 if(!editor.isEditable||editor.state.doc.nodeAt(block.from)!==block.node||target>=block.from&&target<=block.to)return false;
 try{const tr=editor.state.tr.delete(block.from,block.to),pos=tr.mapping.map(target);tr.insert(pos,block.node);tr.doc.check();editor.view.dispatch(tr.setSelection(TextSelection.near(tr.doc.resolve(pos+1))).scrollIntoView());return true;}catch{return false;}
}
export class BlockTools {
 constructor(host){
  this.host=host;this.tools=document.createElement('div');this.tools.className='block-tools';this.tools.hidden=true;
  this.add=quietButton('Insert a block below',()=>this.insert(),'+');this.handle=quietButton('Block actions · drag to move',()=>this.open(),'⠿');this.handle.draggable=true;this.tools.append(this.add,this.handle);document.body.append(this.tools);
  this.menu=document.createElement('div');this.menu.className='popover block-menu';this.menu.hidden=true;this.menu.setAttribute('role','menu');this.menu.setAttribute('aria-label','Block actions');document.body.append(this.menu);
  this.guide=document.createElement('div');this.guide.className='block-drop-guide';this.guide.hidden=true;document.body.append(this.guide);
  document.addEventListener('pointermove',e=>this.hover(e));document.addEventListener('pointerdown',e=>{if(!e.target.closest('.block-tools,.block-menu'))this.close();});
  document.addEventListener('scroll',()=>{if(this.menu.hidden)this.tools.hidden=true;this.guide.hidden=true;},true);
  this.handle.ondragstart=e=>{if(!this.block)return;this.drag={...this.block,doc:this.editor.state.doc};e.dataTransfer.setData('application/x-omega-block',String(this.block.from));e.dataTransfer.effectAllowed='move';this.close();};
  this.handle.ondragend=()=>{this.drag=null;this.guide.hidden=true;};
  document.addEventListener('dragover',e=>this.dragOver(e));document.addEventListener('drop',e=>this.drop(e));
  this.menu.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();this.close();this.editor.commands.focus();}if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();const b=[...this.menu.querySelectorAll('button,select')].filter(x=>!x.disabled),i=b.indexOf(document.activeElement);b[(i+(e.key==='ArrowDown'?1:-1)+b.length)%b.length]?.focus();}};
 }
 bind(editor){this.editor=editor;this.close();this.tools.hidden=true;this.drag=null;}
 reset(){this.editor=null;this.close();this.tools.hidden=true;this.drag=null;}
 close(){this.menu.hidden=true;}
 hover(e){
  if(!this.editor?.isEditable||this.host.disabled()){this.tools.hidden=true;return;}
  if(e.target.closest('.block-tools,.block-menu')||!this.menu.hidden)return;
  if(!this.editor.view.dom.contains(e.target)){if(this.tools.getBoundingClientRect().right+10<e.clientX)this.tools.hidden=true;return;}
  let pos;try{pos=this.editor.view.posAtDOM(e.target,0);}catch{return;}
  const block=blockAt(this.editor,pos+1);if(!block)return;
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
 dragOver(e){
  if(!this.drag||!this.editor?.isEditable)return;
  const hit=this.editor.view.posAtCoords({left:e.clientX,top:e.clientY});if(!hit)return;
  const target=blockAt(this.editor,hit.pos);if(!target)return;
  // Moving list items stays within their list; top-level blocks stay top-level.
  if(target.parent!==this.drag.parent)return;
  const dom=this.editor.view.nodeDOM(target.from),r=dom?.getBoundingClientRect();if(!r)return;
  e.preventDefault();this.dropPosition=e.clientY<r.top+r.height/2?target.from:target.to;e.dataTransfer.dropEffect='move';this.guide.hidden=false;this.guide.style.left=r.left+'px';this.guide.style.width=r.width+'px';this.guide.style.top=(this.dropPosition===target.from?r.top:r.bottom)+'px';
 }
 drop(e){if(!this.drag)return;const valid=!this.guide.hidden&&this.drag.doc.eq(this.editor.state.doc);e.preventDefault();this.guide.hidden=true;if(valid)moveBlock(this.editor,this.drag,this.dropPosition);this.drag=null;}
}
