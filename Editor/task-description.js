import { Editor } from '@tiptap/core';
import { extensions, needsSource, visualMarkdown } from './schema.js';
import { isPageHref } from './page-links.js';
import { SlashMenu } from './slash-menu.js';

// Descriptions use the same Markdown/link marks as notes. The original string is
// retained until a real edit, and extended dialects keep a lossless text field.
export function descriptionEditor(host,item,onChange,options={}){
 const text=item.details.description||'';
 if(needsSource(text)){
  const field=document.createElement('textarea');field.className='task-description';field.value=text;field.rows=4;field.setAttribute('aria-label','Task description');field.oninput=()=>{item.details.description=field.value;onChange();};host.append(field);
  return {setEditable:enabled=>field.disabled=!enabled,destroy(){},focus:()=>field.focus()};
 }
 const area=document.createElement('div');area.className='task-description';host.append(area);
 const menu=document.createElement('div');menu.className='popover task-description-slash';menu.hidden=true;menu.setAttribute('role','listbox');host.append(menu);
 let range=null,dismissed='',editor;
 const commands=[['tasklink','Link to task','task subtask',null],['goallink','Link to goal','goal',null],['page','Link to page','note document',null]];
 const dismiss=()=>{dismissed=editor.state.selection.$from.parent.textContent;menu.hidden=true;};
 const slash=new SlashMenu(menu,commands,{tasklink:'\uf0ae',goallink:'\uf11e',page:'\uf15b'},command=>{menu.hidden=true;options.pick?.(editor,range,command[0]==='page'?'page':command[0]==='goallink'?'goal':'task');},dismiss);
 const update=()=>{
  area.classList.toggle('is-empty',editor.isEmpty);
  if(options.picking?.()||!editor.isEditable||!editor.isFocused){menu.hidden=true;return;}
  const {selection}=editor.state,{$from,empty,from}=selection;
  if(!empty||editor.isActive('codeBlock')){menu.hidden=true;return;}
  const before=$from.parent.textContent.slice(0,$from.parentOffset);
  if(before.endsWith('[[')&&dismissed!==$from.parent.textContent){menu.hidden=true;options.pick?.(editor,{from:from-2,to:from},'all');return;}
  const match=before.match(/(?:^|\s)(\/([\w ]*))$/);
  if(!match||dismissed===$from.parent.textContent){menu.hidden=true;return;}
  range={from:from-match[1].length,to:from};slash.update(match[2]);menu.hidden=false;
  const rect=editor.view.coordsAtPos(range.from);menu.style.left=Math.max(8,Math.min(rect.left,innerWidth-menu.offsetWidth-8))+'px';menu.style.top=Math.max(8,Math.min(rect.bottom+6,innerHeight-menu.offsetHeight-8))+'px';
 };
 editor=new Editor({element:area,extensions:extensions({nativeHistory:true}),content:visualMarkdown(text),contentType:'markdown',editable:!options.readOnly,
  editorProps:{attributes:{role:'textbox','aria-label':'Task description','aria-multiline':'true'},handleKeyDown(_view,event){
   if(slash.keyDown(event))return true;
   if(event.metaKey&&event.key.toLowerCase()==='z'){event.preventDefault();window.folio?.command(event.shiftKey?'redo':'undo');return true;}
   return false;
  },handleDOMEvents:{click(_view,event){const a=event.target.closest('a');if(a&&(isPageHref(a.getAttribute('href'))||event.metaKey||options.readOnly)){event.preventDefault();options.open?.(a.getAttribute('href'));return true;}return false;}}},
  onUpdate(){item.details.description=editor.getMarkdown();onChange();update();},onSelectionUpdate:update,onFocus:update,onBlur(){setTimeout(()=>{menu.hidden=true;},100);}
 });
 editor.folioDismissLink=()=>{dismissed=editor.state.selection.$from.parent.textContent;};
 area.classList.toggle('is-empty',editor.isEmpty);
 // Kept on the instance so the page can reveal search results and restore focus.
 return editor;
}
