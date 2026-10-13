import {LiveEditor} from './live-editor.js';
import {configureLabelColors} from './task-labels.js';
import { Editor } from '@tiptap/core';
import { TextSelection } from '@tiptap/pm/state';
import { extensions, needsSource, noteContent, visualMarkdown } from './schema.js';
import './editor.css';
import { SlashMenu, installScrollIndicators } from './slash-menu.js';
import { SearchMatch, resolveSourceMatch, resolveRichMatch, showRichMatch, clearRichMatch } from './search-navigation.js';
import { historyQueue } from './durable-undo.js';
import { tableContext, runTableAction, appendToTable } from './table-actions.js';
import { isPageHref, isPersonHref, liveMentions, insertPageLink, PagePicker } from './page-links.js';
import { TaskPage, parseTasks } from './task-page.js';
import {WritingTools} from './writing-tools.js';
import {BlockTools,blockAt,duplicateBlock} from './block-tools.js';
import {writingColors} from './writing-schema.js';

const $ = id => document.getElementById(id);
const send = (type, data = {}) => window.webkit?.messageHandlers.folio.postMessage({ type, ...data });
let taskMode = false, live = null;
let editor, identity = '', original = '', initialDoc, sourceMode = false, forcedSource = false, loading = false, readOnly = false;
let slashRange = null, dismissedSlash = null, entryCallback, lastScale = 1, toastTimer;
const scroller = $('scroller'), bubble = $('bubble'), slash = $('slash'), tableTools = $('table-tools'), source = $('source');
let beforeSelection = '', typingEdit = false;
let edgeTable = null, pageRequest = null, dismissedPage = null, pageSequence = 0;
const writing=new WritingTools({editor:()=>editor,hideMenus:()=>{hideMenus();blocks.close();},preferences:values=>send('writingPreferences',{id:identity,...values})});
const blocks=new BlockTools({refresh:()=>requestAnimationFrame(updateMenus),disabled:()=>sourceMode||taskMode||undoHistory.busy||writing.busy,hideMenus:()=>{hideMenus();writing.close();},turnInto:kind=>turnInto(kind),color:range=>writing.openColors(range),comment:range=>writing.startComment(range)});
function turnInto(kind){const command=commandList.find(c=>c[0]===(kind==='paragraph'?'text':kind));if(command?.[3])command[3](editor.chain().focus()).run();}
const rowAdd = $('table-add-row'), columnAdd = $('table-add-column');
const taskPage=new TaskPage($('task-page'),(_text,typing)=>{beforeSelection=JSON.stringify({tasks:true});typingEdit=!!typing;emitChange();cursor();},{pick:(target,range,kind)=>openPagePicker(range,false,target,kind),picking:()=>!pagePicker.element.hidden,open:href=>send('link',{id:identity,url:href})});
function selectionState() {
 if(taskMode)return JSON.stringify({tasks:true});
 return JSON.stringify(sourceMode ? {source:true,from:source.selectionStart,to:source.selectionEnd}
   : {source:false,from:editor?.state.selection.from||1,to:editor?.state.selection.to||1});
}
const undoHistory = historyQueue({
 snapshot:()=>({id:identity,text:value()}),
 lock:locked=>{taskPage.setReadOnly(readOnly||locked);source.readOnly=readOnly||locked;editor?.setEditable(!readOnly&&!locked,false);},
 send:request=>send('history',request),
 apply:result=>{
  let selection;try{selection=JSON.parse(result.selection);}catch{}
  const scroll=scroller.scrollTop, sourceScroll=source.scrollTop;
  loading=true;hideMenus();writing.reset();blocks.reset();clearMatch();original=result.text;
  if(!selection?.source&&parseTasks(original)){taskMode=true;sourceMode=false;forcedSource=false;editor?.destroy();editor=null;source.hidden=true;scroller.hidden=true;$('mode').hidden=true;taskPage.element.hidden=false;taskPage.load(original,{identity});loading=false;cursor();return;}
  taskMode=false;taskPage.element.hidden=true;
  forcedSource=needsSource(original);
  sourceMode=forcedSource||(selection ? !!selection.source : sourceMode);
  source.value=original;source.hidden=!sourceMode;scroller.hidden=sourceMode;
  $('mode').hidden=!sourceMode;$('mode').textContent='Markdown';
  if(sourceMode){editor?.destroy();editor=null;writing.configure({},{taskMode,sourceMode});}
  else createEditor(original);
  loading=false;
  if(sourceMode){
   source.focus();const from=Math.min(selection?.from||0,source.value.length),to=Math.min(selection?.to??from,source.value.length);
   source.setSelectionRange(from,to);source.scrollTop=sourceScroll;
  }else{
   const end=Math.max(1,editor.state.doc.content.size-1),from=Math.min(selection?.from||1,end),to=Math.min(selection?.to||from,end);
   editor.commands.setTextSelection({from,to});scroller.scrollTop=scroll;
   // Focus after the queue unlocks this newly created editor.
   queueMicrotask(()=>editor?.commands.focus());
   editor.commands.scrollIntoView();
  }
  cursor();
 },
});
let matchTimer, matchVisible = false;
const sourceHighlight = document.createElement('pre');
sourceHighlight.id = 'source-highlight'; sourceHighlight.hidden = true; sourceHighlight.setAttribute('aria-hidden', 'true');
document.body.insertBefore(sourceHighlight, source);
const icons = { tasklink:'\uf0ae', goallink:'\uf11e', page: '\uf15b', text: '\uf031', h1: 'H₁', h2: 'H₂', h3: 'H₃', h4: 'H₄', h5: 'H₅', h6: 'H₆', bullet: '\uf0ca', numbered: '\uf0cb', checklist: '\uf14a', quote: '\uf10d', code: '\uf121', table: '\uf0ce', divider: '\uf068', image: '\uf03e', equation: '∑' };
Object.assign(icons,{color:'\uf53f',comment:'\uf075',duplicate:'\uf0c5',delete:'\uf2ed',mention:'\uf1fa'});
const commandList = [
 ['text','Text','A plain paragraph',c=>c.setParagraph()],
 ['h1','Heading 1','A big heading',c=>c.setHeading({level:1})],
 ['h2','Heading 2','A medium heading',c=>c.setHeading({level:2})],
 ['h3','Heading 3','A small heading',c=>c.setHeading({level:3})],
 ['bullet','Bullet list','A simple list',c=>c.toggleBulletList()],
 ['numbered','Numbered list','One thing after another',c=>c.toggleOrderedList()],
 ['checklist','Checklist','Keep track of the little things',c=>c.toggleTaskList()],
 ['table','Table','Organize things into rows and columns',c=>c.insertTable({rows:3,cols:3,withHeaderRow:true})],
 ['quote','Quote','Give a thought some space',c=>c.toggleBlockquote()],
 ['code','Code block','Code with syntax highlighting',c=>c.toggleCodeBlock()],
 ['divider','Divider','A quiet break',c=>c.setHorizontalRule()],
 ['page','Link to page','Link to another note or document',null],
 ['tasklink','Link to task','Link to a task or subtask',null],
 ['goallink','Link to goal','Link to a goal',null],
 ['image','Image','Choose an image from your Mac',null],
 ['equation','Equation','A typeset math expression',null],
 ['color','Color & highlight','Change the color of this text',null],
 ['comment','Comment','Start a conversation about this block',null],
 ['duplicate','Duplicate block','Make a copy of this block',null],
 ['delete','Delete block','Remove this block; undo is available',null],
 ['mention','Mention','Link a page, task, goal, or live collaborator',null],
 ...writingColors.flatMap(([name,label])=>{icons['color-'+name]='\uf031';icons['highlight-'+name]='\uf591';return [['color-'+name,label+' text','Text color',null],['highlight-'+name,label+' highlight','Background color',null]];}),
 ['h4','Heading 4','A smaller heading',c=>c.setHeading({level:4})],
 ['h5','Heading 5','A subtle heading',c=>c.setHeading({level:5})],
 ['h6','Heading 6','The smallest heading',c=>c.setHeading({level:6})],
];
const slashMenu = new SlashMenu(slash, commandList, icons, runSlash, () => {
 dismissedSlash=`${editor.state.selection.$from.start()}:${editor.state.selection.$from.parent.textContent}`;
 slash.hidden=true;
});
installScrollIndicators();
function value() {
 if(live?.kind==='rich')return editor?.getMarkdown()+'\n';
 if(taskMode)return taskPage.raw;
 if (sourceMode) return source.value;
 if (!editor || editor.state.doc.eq(initialDoc)) return original;
 return editor.getMarkdown() + (original.endsWith('\n') || !original ? '\n' : '');
}
function emitChange() { if(!loading)live?.changed(value()); if (!loading && !undoHistory.busy) send('change', { id: identity, text: value(), beforeSelection, afterSelection:selectionState(), typing:typingEdit }); typingEdit=false; }
function cursor() {
 if(taskMode){send('cursor',{id:identity,line:1,column:1});return;}
 if (sourceMode) {
   const before=source.value.slice(0,source.selectionStart), lines=before.split('\n');
   send('cursor',{id:identity,line:lines.length,column:[...lines.at(-1)].length+1}); return;
 }
 if (!editor) return;
 const before=editor.state.doc.textBetween(0,editor.state.selection.from,'\n'), lines=before.split('\n');
 send('cursor',{id:identity,line:lines.length,column:[...lines.at(-1)].length+1});
}
function hideMenus() { bubble.hidden=true;slash.hidden=true;tableTools.hidden=true;hideTableEdges();pagePicker.close();pageRequest=null; }
function place(el, x, y, above=false) {
 el.hidden=false;
 const rect=el.getBoundingClientRect();
 el.style.left=Math.max(8,Math.min(x,innerWidth-rect.width-8))+'px';
 el.style.top=Math.max(7,Math.min(above?y-rect.height-9:y+8,innerHeight-rect.height-8))+'px';
}
function rectAtSelection() {
 const selection=window.getSelection();
 if (selection?.rangeCount) { const rect=selection.getRangeAt(0).getBoundingClientRect(); if (rect.width||rect.height) return rect; }
 const coords=editor.view.coordsAtPos(editor.state.selection.from);
 return {left:coords.left,right:coords.right,top:coords.top,bottom:coords.bottom,width:0};
}
function finishLink(page){
 const request=pageRequest;pagePicker.close();pageRequest=null;
 if(request?.id===identity&&request.editor&&!request.editor.isDestroyed)insertPageLink(request.editor,page,request.range,request.doc,request.preserveText);
}
const pagePicker = new PagePicker($('page-picker'), page=>{
 const request=pageRequest;if(!request||request.pending)return;
 if(page.reference){
  if(page.current==='true'&&taskMode){const item=taskPage.reference(page.reference);if(!item)return;taskPage.touch(item);taskPage.change();finishLink({...page,href:page.href.split('#')[0]+'#folio-'+(page.kind==='goal'?'goal':'task')+'-'+item.id});}
  else{request.pending=true;send('prepareItemLink',{id:identity,request:request.request,href:page.href,reference:page.reference,revision:page.revision});}
 }else finishLink(page);
}, ()=>{
 const target=pageRequest?.editor;
 if(target&&!target.isDestroyed){const {$from}=target.state.selection;dismissedPage=`${$from.start()}:${$from.parent.textContent}`;dismissedSlash=dismissedPage;}
 target?.folioDismissLink?.();pageRequest=null;target?.commands.focus();
});
function openPagePicker(range, preserveText=true, target=editor, kind='page') {
 if(!target?.isEditable||undoHistory.busy)return;
 range??=target.state.selection;
 const rect=target.view.coordsAtPos(range.from);hideMenus();
 pageRequest={id:identity,request:String(++pageSequence),rect,range:{from:range.from,to:range.to},doc:target.state.doc,preserveText,editor:target,kind};
 pagePicker.open(kind);place(pagePicker.element,rect.left,rect.bottom);
 if(rect.bottom+pagePicker.element.offsetHeight+8>innerHeight)place(pagePicker.element,rect.left,rect.top,true);
 pagePicker.input.focus({preventScroll:true});
 send('pages',{id:identity,request:pageRequest.request,kind:kind==='mention'?'all':kind});
}
function updateMenus() {
 if(writing.busy||!blocks.menu.hidden){bubble.hidden=true;slash.hidden=true;tableTools.hidden=true;hideTableEdges();return;}
 if(!pagePicker.element.hidden){bubble.hidden=true;slash.hidden=true;tableTools.hidden=true;hideTableEdges();return;}
 if (matchVisible||sourceMode||readOnly||!editor||(!editor.isFocused&&!editor.isActive('table'))||!$('entry').hidden) { hideMenus();return; }
 const {selection}=editor.state, {$from,empty,from,to}=selection;
 const prefix=$from.parent.textContent.slice(0,$from.parentOffset);
 if(empty&&!editor.isActive('codeBlock')&&!editor.isActive('code')&&/(?:^|\s)@$/.test(prefix)&&dismissedPage!==`${$from.start()}:${$from.parent.textContent}`){openPagePicker({from:from-1,to:from},false,editor,'mention');return;}
 const pageMatch=empty&&!editor.isActive('codeBlock')&&!editor.isActive('code')&&$from.parent.textContent.slice(0,$from.parentOffset).endsWith('[[');
 if(pageMatch&&dismissedPage!==`${$from.start()}:${$from.parent.textContent}`){openPagePicker({from:from-2,to:from},false,editor,'all');return;}
 const match=empty && $from.parent.type.name==='paragraph' && !editor.isActive('table') && $from.parent.textContent.slice(0,$from.parentOffset).match(/(?:^|\s)\/([\w ]*)$/);
 if (match && dismissedSlash!==`${$from.start()}:${match[0]}`) {
   bubble.hidden=true;tableTools.hidden=true;
   const range={from:from-match[1].length-1,to:from};
   const query=match[1].toLowerCase();
   slashRange=range;slashMenu.update(query);
   const pos=editor.view.coordsAtPos(range.from);place(slash,pos.left,pos.bottom);
   if (pos.bottom+slash.offsetHeight+8>innerHeight) place(slash,pos.left,pos.top,true);
   return;
 }
 slash.hidden=true;slashRange=null;
 if (!empty && editor.state.doc.textBetween(from,to).trim()) {
   const rect=rectAtSelection();bubble.hidden=false;place(bubble,rect.left+(rect.width-bubble.offsetWidth)/2,rect.top,true);
   for(const button of bubble.querySelectorAll('[data-mark]'))button.classList.toggle('active',editor.isActive(button.dataset.mark));
   const heading=editor.getAttributes('heading').level;
   $('block-type').value=heading?String(heading):'0';
   $('block-type').disabled=editor.isActive('table');
 } else bubble.hidden=true;
 tableTools.hidden=true;hideTableEdges();
 if (editor.isActive('table') && empty) {
   const element=editor.view.domAtPos(from).node;
   const table=(element.nodeType===1?element:element.parentElement)?.closest('table');
   if(table){
     const context=tableContext(editor);
     $('table-rows').querySelector('[value=deleteRow]').disabled=context.rows<=1;
     $('table-columns').querySelector('[value=deleteColumn]').disabled=context.columns<=1;
     const rect=table.closest('.tableWrapper').getBoundingClientRect();
     if(rect.bottom>0&&rect.top<innerHeight){tableTools.hidden=false;place(tableTools,rect.right-tableTools.offsetWidth,rect.top,true);showTableEdges(table);}
   }
 }
}
function hideTableEdges(){edgeTable=null;rowAdd.hidden=true;columnAdd.hidden=true;}
function showTableEdges(table){
 if(sourceMode||readOnly||undoHistory.busy||!editor?.isEditable||!editor.view.dom.contains(table)){hideTableEdges();return;}
 edgeTable=table;
 const wrapper=table.closest('.tableWrapper'), rect=wrapper.getBoundingClientRect();
 const left=Math.max(8,rect.left),right=Math.min(innerWidth-8,rect.right);
 const bottom=table.getBoundingClientRect().bottom;
 rowAdd.hidden=bottom<8||bottom+25>innerHeight;
 columnAdd.hidden=rect.top<0||rect.top+25>innerHeight;
 rowAdd.style.left=Math.max(8,Math.min((left+right)/2-10,innerWidth-28))+'px';
 rowAdd.style.top=bottom+3+'px';
 columnAdd.style.left=Math.max(8,Math.min(rect.right+3,innerWidth-24))+'px';
 columnAdd.style.top=rect.top+Math.max(0,Math.min(table.rows[0]?.getBoundingClientRect().height||24,rect.height)/2-10)+'px';
}
for(const [button,axis] of [[rowAdd,'row'],[columnAdd,'column']]){
 button.onmousedown=event=>event.preventDefault();
 button.onclick=()=>{if(edgeTable)appendToTable(editor,edgeTable,axis);requestAnimationFrame(updateMenus);};
}
document.addEventListener('pointermove',event=>{
 const target=event.target;
 if(target.closest('.table-edge,#table-tools'))return;
 const table=target.closest('.tiptap table')||target.closest('.tableWrapper')?.querySelector('table');
 if(table){showTableEdges(table);return;}
 if(edgeTable){
  const rect=edgeTable.closest('.tableWrapper')?.getBoundingClientRect();
  if(rect&&event.clientX>=rect.left-28&&event.clientX<=rect.right+28&&event.clientY>=rect.top-28&&event.clientY<=rect.bottom+28)return;
 }
 if(!editor?.isActive('table'))hideTableEdges();
});
document.addEventListener('scroll',event=>{
 if(event.target.classList?.contains('tableWrapper')){hideMenus();requestAnimationFrame(updateMenus);}
},true);
function runSlash(command){
 if(!slashRange)return;
 const range=slashRange;slashRange=null;slash.hidden=true;dismissedSlash=null;
 if(['page','tasklink','goallink','mention'].includes(command[0])){openPagePicker(range,false,editor,command[0]==='mention'?'mention':command[0]==='page'?'page':command[0]==='goallink'?'goal':'task');return;}
 const name=command[0];
 if(['color','comment','duplicate','delete'].includes(name)||name.startsWith('color-')||name.startsWith('highlight-')){
  editor.chain().focus().deleteRange(range).run();const block=blockAt(editor,editor.state.selection.from);if(!block)return;const selection={from:block.from+1,to:block.to-1};
  if(name==='color')writing.openColors(selection);else if(name==='comment')writing.startComment(selection);else if(name==='duplicate')duplicateBlock(editor,block);else if(name==='delete')editor.chain().focus().deleteRange({from:block.from,to:block.to}).run();else {const [kind,color]=name.split('-');editor.chain().focus().setTextSelection(selection).setMark(kind==='color'?'textColor':'highlight',{value:color}).setTextSelection(Math.min(range.from,editor.state.doc.content.size-1)).run();}return;
 }
 const chain=editor.chain().focus().deleteRange(range);
 if(command[3])command[3](chain).run();
 else {chain.run();if(command[0]==='image')send('image');else showEntry('Equation','E = mc^2','',latex=>{if(latex)editor.chain().focus().insertContent({type:'blockMath',attrs:{latex}}).run();});}
}
function keyDown(view,event){
 if(event.metaKey&&event.key.toLowerCase()==='z'){event.preventDefault();window.folio.command(event.shiftKey?'redo':'undo');return true;}
 if(event.metaKey&&['=','+','-','0'].includes(event.key)){event.preventDefault();send(event.altKey?'writingZoom':'zoom',{id:identity,direction:event.key==='-'?-1:event.key==='0'?0:1});return true;}
 if(slashMenu.keyDown(event))return true;
 if(event.key==='Escape'){hideMenus();$('entry').hidden=true;$('find').hidden=true;return false;}
 if(editor.isActive('table')&&event.key==='Enter'&&!event.metaKey){event.preventDefault();editor.commands.goToNextCell();return true;}
 return false;
}
function createEditor(text,shared=null){
 writing.reset();blocks.reset();editor?.destroy();$('editor').replaceChildren();
 editor=new Editor({element:$('editor'),extensions:[...extensions({nativeHistory:true}),SearchMatch,...(shared?shared.extensions():[])],...(shared?{}:noteContent(text)),editable:!readOnly&&!undoHistory.busy,
  editorProps:{attributes:{role:'textbox','aria-label':'Note body','aria-multiline':'true',spellcheck:'true'},handleKeyDown:keyDown,
   handlePaste(view,event){
    const text=event.clipboardData?.getData('text/plain');const html=event.clipboardData?.getData('text/html');
    if(text&&!html&&/\n|^#{1,6} |\*\*|^[-*] |^> |\|.*\|/.test(text)&&!editor.isActive('codeBlock')){
      if(needsSource(text))return false;
      event.preventDefault();editor.commands.insertContent(text,{contentType:'markdown'});return true;
    }return false;
   },
   handleDOMEvents:{click(view,event){const comment=event.target.closest('[data-omega-comment]');if(comment&&!event.metaKey){writing.openComments(comment.dataset.omegaComment);return true;}const anchor=event.target.closest('a');if(anchor&&isPersonHref(anchor.getAttribute('href'))){event.preventDefault();return true;}if(anchor&&(isPageHref(anchor.getAttribute('href'))||event.metaKey||readOnly)){event.preventDefault();send('link',{id:identity,url:anchor.getAttribute('href')});return true;}return false;}},
  },
  onUpdate(){emitChange();cursor();updateMenus();requestAnimationFrame(updateMenus);},
  onSelectionUpdate(){cursor();updateMenus();requestAnimationFrame(updateMenus);},
  onFocus(){updateMenus();requestAnimationFrame(updateMenus);},
  onBlur(){setTimeout(()=>{if(!document.activeElement?.closest('.popover,.table-edge')){if(editor?.isActive('table'))updateMenus();else hideMenus();}},100);},
 });initialDoc=editor.state.doc;writing.bind(editor);blocks.bind(editor);writing.configure({},{taskMode,sourceMode});
 editor.on('beforeTransaction',({editor:current,transaction})=>{
  if(transaction.docChanged)beforeSelection=JSON.stringify({source:false,from:current.state.selection.from,to:current.state.selection.to});
 });
}
function showEntry(label,placeholder,current,callback){
 hideMenus();$('entry-input').hidden=false;$('entry').querySelector('.actions').hidden=false;entryCallback=callback;$('entry-label').textContent=label;$('entry-input').placeholder=placeholder;$('entry-input').value=current||'';
 const rect=editor&&!sourceMode?rectAtSelection():{left:innerWidth/2-145,bottom:50};place($('entry'),rect.left,rect.bottom);$('entry-input').focus();$('entry-input').select();
}
function link(){const current=editor.getAttributes('link').href||'';showEntry('Link','https://…',current,url=>{const c=editor.chain().focus().extendMarkRange('link');if(!url)c.unsetLink().run();else if(isPageHref(url)||/^(https?:\/\/|mailto:|#|\.\.?\/)/i.test(url))c.setLink({href:url}).run();else c.setLink({href:'https://'+url}).run();});}
window.folioEditMath=(latex,callback)=>showEntry('Equation','E = mc^2',latex,callback);
$('entry').onsubmit=e=>{e.preventDefault();const callback=entryCallback;$('entry').hidden=true;callback?.($('entry-input').value.trim());};
$('entry-cancel').onclick=()=>{$('entry').hidden=true;editor?.commands.focus();};
$('entry-input').onkeydown=e=>{if(e.key==='Escape'){$('entry').hidden=true;editor?.commands.focus();}};
for(const el of document.querySelectorAll('[data-command]')){
 el.onmousedown=e=>e.preventDefault();el.onclick=()=>window.folio.command(el.dataset.command);
}
$('block-type').onchange=e=>{const level=Number(e.target.value);level?editor.chain().focus().setHeading({level}).run():editor.chain().focus().setParagraph().run();};
for(const id of ['table-rows','table-columns','table-more'])$(id).onchange=e=>{
 const action=e.target.value;e.target.value='';
 if(action.startsWith('align-'))editor.chain().focus().setCellAttribute('align',action.slice(6)).run();
 else runTableAction(editor,action);
 requestAnimationFrame(updateMenus);
};
source.oninput=()=>{clearMatch();emitChange();cursor();};source.onselect=cursor;
source.onkeydown=e=>{if(e.metaKey&&e.key.toLowerCase()==='z'){e.preventDefault();window.folio.command(e.shiftKey?'redo':'undo');return;}if(e.metaKey&&['=','+','-','0'].includes(e.key)){e.preventDefault();send(e.altKey?'writingZoom':'zoom',{id:identity,direction:e.key==='-'?-1:e.key==='0'?0:1});}};
document.addEventListener('beforeinput',event=>{
 if(event.target!==source&&!event.target.closest?.('.tiptap'))return;
 if(event.inputType==='historyUndo'||event.inputType==='historyRedo'){
  event.preventDefault();window.folio.command(event.inputType==='historyRedo'?'redo':'undo');return;
 }
 if(undoHistory.busy){event.preventDefault();return;}
 beforeSelection=selectionState();typingEdit=['insertText','deleteContentBackward','deleteContentForward','insertCompositionText'].includes(event.inputType);
},true);
$('mode').onclick=()=>window.folio.command('source');
scroller.addEventListener('scroll',()=>{hideMenus();$('entry').hidden=true;if(editor?.isActive('table'))updateMenus();},{passive:true});
window.addEventListener('resize',()=>{hideMenus();clearMatch();});
source.addEventListener('scroll',()=>{sourceHighlight.scrollTop=source.scrollTop;sourceHighlight.scrollLeft=source.scrollLeft;},{passive:true});
document.addEventListener('keydown',clearMatch,{capture:true});
taskPage.element.addEventListener('keydown',event=>{if(event.metaKey&&event.key.toLowerCase()==='z'){event.preventDefault();window.folio.command(event.shiftKey?'redo':'undo');}if(event.metaKey&&['=','+','-','0'].includes(event.key)){event.preventDefault();send(event.altKey?'writingZoom':'zoom',{id:identity,direction:event.key==='-'?-1:event.key==='0'?0:1});}});
document.addEventListener('pointerdown',event=>{if(!pagePicker.element.hidden&&!event.target.closest('#page-picker')){pagePicker.close();pageRequest=null;}},{capture:true});
document.addEventListener('pointerdown',clearMatch,{capture:true});
document.addEventListener('mousedown',e=>{if(!e.target.closest('#entry'))$('entry').hidden=true;});
function clearMatch() {
 clearTimeout(matchTimer);
 if (!matchVisible) return;
 matchVisible=false;clearRichMatch(editor);sourceHighlight.hidden=true;sourceHighlight.replaceChildren();source.classList.remove('search-revealed');
}
function revealMatch(request) {
 if(request.id!==identity||!request.anchor)return false;
 clearMatch();hideMenus();$('find').hidden=true;$('entry').hidden=true;
 const anchor=request.anchor;
 if(taskMode)return taskPage.find(anchor.term);
 if(sourceMode) {
  const match=resolveSourceMatch(source.value,anchor);if(!match)return false;
  const mark=document.createElement('mark');mark.className='folio-search-hit';mark.textContent=source.value.slice(match.from,match.to);
  sourceHighlight.replaceChildren(document.createTextNode(source.value.slice(0,match.from)),mark,document.createTextNode(source.value.slice(match.to)+'\n'));
  sourceHighlight.style.width=source.clientWidth+'px';sourceHighlight.hidden=false;source.classList.add('search-revealed');
  sourceHighlight.scrollTop=0;
  const top=mark.getBoundingClientRect().top-sourceHighlight.getBoundingClientRect().top;
  source.focus({preventScroll:true});source.setSelectionRange(match.from,match.from);
  source.scrollTop=Math.max(0,top-source.clientHeight*0.4);sourceHighlight.scrollTop=source.scrollTop;
  cursor();
 } else {
  if(!editor)return false;
  const match=resolveRichMatch(editor,value(),anchor);if(!match)return false;
  matchVisible=true;showRichMatch(editor,match);editor.view.focus();
  const target=editor.view.dom.querySelector('.folio-search-hit');
  target?.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
  cursor();
 }
 matchVisible=true;hideMenus();matchTimer=setTimeout(clearMatch,2300);
 return true;
}
function find(forward=true){
 const query=$('find-input').value;if(!query)return;
 if(taskMode){taskPage.find(query);return;}
 if(sourceMode){const start=forward?source.selectionEnd:source.selectionStart-1;const pos=forward?source.value.toLowerCase().indexOf(query.toLowerCase(),start):source.value.toLowerCase().lastIndexOf(query.toLowerCase(),start);const at=pos<0?source.value.toLowerCase().indexOf(query.toLowerCase()):pos;if(at>=0){source.focus();source.setSelectionRange(at,at+query.length);}}
 else{const results=[];editor.state.doc.descendants((node,pos)=>{if(node.isText){let at=0;while((at=node.text.toLowerCase().indexOf(query.toLowerCase(),at))>=0){results.push({from:pos+at,to:pos+at+query.length});at+=query.length;}}});const selection=editor.state.selection;const result=forward?(results.find(r=>r.from>=selection.to)||results[0]):([...results].reverse().find(r=>r.to<=selection.from)||results.at(-1));if(result)editor.chain().focus().setTextSelection(result).scrollIntoView().run();}
}
$('find-input').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();find(!e.shiftKey);}if(e.key==='Escape'){$('find').hidden=true;editor?.commands.focus();}};$('find-next').onclick=()=>find();$('find-close').onclick=()=>{$('find').hidden=true;editor?.commands.focus();};
window.folio={
 load(config){
  if(live){live.destroy();live=null;send('liveStopped');}
  undoHistory.reset();writing.reset();blocks.reset();
  clearMatch();loading=true;identity=config.id;original=config.text||'';readOnly=!!config.reading;hideMenus();$('entry').hidden=true;$('find').hidden=true;
  if(!config.source&&parseTasks(original)){taskMode=true;sourceMode=false;editor?.destroy();editor=null;source.hidden=true;scroller.hidden=true;$('mode').hidden=true;taskPage.element.hidden=false;taskPage.load(original,{identity});this.configure(config);loading=false;cursor();return;}
  taskMode=false;taskPage.element.hidden=true;
  forcedSource=needsSource(original);sourceMode=!!config.source||forcedSource;
  source.value=original;source.hidden=!sourceMode;source.readOnly=readOnly;scroller.hidden=sourceMode;
  $('mode').hidden=!sourceMode;$('mode').textContent='Markdown';$('mode').title=forcedSource?'This note uses extended Markdown. Source mode keeps every character intact.':'Return to visual editing';
  if(!sourceMode)createEditor(original);else{editor?.destroy();editor=null;}
  scroller.scrollTop=0;source.scrollTop=0;dismissedSlash=null;dismissedPage=null;this.configure(config);loading=false;cursor();
 },
 configure(config){
  writing.configure(config,{taskMode,sourceMode});
  if(config.labelColors!==undefined)configureLabelColors(config.labelColors);
  document.documentElement.dataset.theme=config.theme==='dark'?'dark':'light';
  if(config.accent)taskPage.element.style.setProperty('--task-accent',config.accent);
  // WebKit pageZoom scales the document and every editing control together.
  document.documentElement.style.setProperty('--scale',1);
  if(lastScale!==(config.zoom||1)){$('toast').textContent=Math.round((config.zoom||1)*100)+'%';$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,1100);lastScale=config.zoom||1;}
  readOnly=!!config.reading;taskPage.setReadOnly(readOnly||undoHistory.busy);source.readOnly=readOnly||undoHistory.busy;editor?.setEditable(!readOnly&&!undoHistory.busy,false);
 },
 snapshot(){return {id:identity,text:value()};},
 liveStart(config){
  if(config.id!==identity||live)return false;
  const host={editor:()=>editor,value,send:(type,data)=>send(type,{id:identity,...data}),composing:()=>editor?.view.composing||taskPage.descriptions.some(e=>e.view?.composing),
   mount(session){loading=true;hideMenus();sourceMode=session.kind==='source';taskMode=session.kind==='tasks';scroller.hidden=sourceMode||taskMode;source.hidden=!sourceMode;taskPage.element.hidden=!taskMode;$('mode').hidden=true;
    if(session.kind==='rich')createEditor('',session);else{writing.reset();blocks.reset();editor?.destroy();editor=null;if(taskMode)taskPage.load(session.text(),{identity});else source.value=session.text();}writing.configure({},{taskMode,sourceMode});loading=false;},
   refresh(session){
    loading=true;const active=document.activeElement,field=active?.dataset?.liveField||active?.dataset?.field||active?.getAttribute('aria-label'),from=active?.selectionStart,to=active?.selectionEnd,scroll=scroller.scrollTop;
    if(taskMode){const viewScroll=taskPage.element.querySelector('.tasks-body,.task-detail-scroller')?.scrollTop||0;taskPage.load(session.text(),{identity});const container=taskPage.element.querySelector('.tasks-body,.task-detail-scroller');if(container)container.scrollTop=viewScroll;
     if(field){const target=[...taskPage.element.querySelectorAll('textarea,input,[role=textbox]')].find(n=>(n.dataset.liveField||n.dataset.field||n.getAttribute('aria-label'))===field);target?.focus({preventScroll:true});if(target?.setSelectionRange&&from!==undefined)target.setSelectionRange(Math.min(from,target.value.length),Math.min(to,target.value.length));}
    }else{const start=source.selectionStart,end=source.selectionEnd;source.value=session.text();source.setSelectionRange(Math.min(start,source.value.length),Math.min(end,source.value.length));}
    scroller.scrollTop=scroll;loading=false;
   }};
  live=new LiveEditor(host,{...config,kind:taskMode?'tasks':sourceMode?'source':'rich'});
  if(config.externalText!==undefined){const applied=this.replaceForAssistant({id:identity,expected:value(),text:config.externalText});if(!applied){this.liveStop();send('liveNotice',{message:'This file changed its document format. Live editing is paused; both its local file and shared history are preserved.'});return false;}}return true;
 },
 liveMessage(message){live?.receive(message);},
 liveAccept(){live?.accept();},
 liveStop(){if(!live)return;const text=value();live.destroy();live=null;this.load({id:identity,text,reading:readOnly,theme:document.documentElement.dataset.theme,zoom:lastScale});},
 linkReady(result){if(result.id!==identity||result.request!==pageRequest?.request)return;if(result.page)finishLink(result.page);else{pageRequest.pending=false;pagePicker.list.textContent=result.error||'This item changed. Close the picker and try again.';}},
 revealItem(config){return config.id===identity&&taskMode&&taskPage.revealItem(config.item,config.kind);},
 pageResults(result){if(result.id===identity&&result.request===pageRequest?.request&&!pagePicker.element.hidden){pagePicker.setPages([...(pageRequest.kind==='mention'?liveMentions(live?.presence.awareness.getStates().values()):[]),...(result.pages||[])]);const rect=pageRequest.rect;place(pagePicker.element,rect.left,rect.bottom);if(rect.bottom+pagePicker.element.offsetHeight+8>innerHeight)place(pagePicker.element,rect.left,rect.top,true);}},
 historyResult(result){undoHistory.result(result);},
 replaceForAssistant(config){
  if(config.id!==identity || config.expected!==value() || taskPage.busy || undoHistory.busy || writing.busy || !blocks.menu.hidden || editor?.view.composing || !$('entry').hidden || !pagePicker.element.hidden)return false;
  // Compare and replace in one JavaScript turn. A keystroke cannot land between them.
  if(live?.kind==='rich'){try{const next=editor.schema.nodeFromJSON(editor.markdown.parse(visualMarkdown(config.text))),current=editor.state.doc,start=current.content.findDiffStart(next.content);if(start!==null){const end=current.content.findDiffEnd(next.content);let a=end.a,b=end.b;if(a<start){b+=start-a;a=start;}if(b<start){a+=start-b;b=start;}editor.view.dispatch(editor.state.tr.replace(start,a,next.slice(start,b)));}return true;}catch{return false;}}
  if(live){if(live.kind==='tasks'&&!parseTasks(config.text))return false;live.changed(config.text);live.host.refresh(live);emitChange();return true;}
  const scroll=scroller.scrollTop, sourceScroll=source.scrollTop;
  const selection=editor?.state.selection.from || 1;
  if(taskMode || parseTasks(config.text) || sourceMode || needsSource(config.text)){
   this.load({id:identity,text:config.text,source:sourceMode,reading:readOnly,theme:document.documentElement.dataset.theme,zoom:lastScale});
  }else{
   loading=true;editor.commands.setContent(visualMarkdown(config.text),{contentType:'markdown',emitUpdate:false});
   original=config.text;initialDoc=editor.state.doc;loading=false;
   editor.commands.setTextSelection(Math.min(selection,Math.max(1,editor.state.doc.content.size-1)));
  }
  scroller.scrollTop=scroll;source.scrollTop=sourceScroll;emitChange();return true;
 },
 revealMatch,
 focus(){if(taskMode){taskPage.element.querySelector('.tasks-title')?.focus();return;}sourceMode?source.focus():editor?.commands.focus();},
 insertImage(path){if(!sourceMode)editor.chain().focus().setImage({src:path,alt:path.split('/').at(-1).replace(/\.[^.]+$/,'')}).run();},
 command(name){
  if((name==='undo'||name==='redo')&&live){if(!readOnly&&!editor?.view.composing)live.undoChange(name==='redo');return;}
  if(name==='undo'||name==='redo'){
   if(taskMode&&taskPage.composer&&!taskPage.composer.inserted){document.execCommand(name);return;}
   if(!taskMode&&document.activeElement?.matches('input,textarea')&&document.activeElement!==source){document.execCommand(name);return;}
   if(!readOnly&&!editor?.view.composing)undoHistory.request(name==='redo');return;
  }
  if(name==='find'){$('find').hidden=false;$('find-input').focus();return;}
  if(name==='source'&&live){send('liveNotice',{message:'Leave live editing before switching document formats.'});return;}
  if(name==='source'){
    const text=value();if(sourceMode&&needsSource(text)&&!parseTasks(text)){$('toast').textContent='Extended Markdown · source view';$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,2200);return;}
    const wasSource=sourceMode;this.load({id:identity,text,source:!wasSource,reading:readOnly,theme:document.documentElement.dataset.theme,zoom:lastScale});this.focus();return;
  }
  if(name==='appearance'&&!taskMode){writing.openAppearance();return;}
  if(taskMode||readOnly)return;
  if(sourceMode){
   const marks={bold:['**','**'],italic:['*','*'],strike:['~~','~~'],underline:['<u>','</u>'],code:['`','`'],heading:['## ',''],task:['- [ ] ','']};
   if(marks[name]){const [a,b]=marks[name],start=source.selectionStart,end=source.selectionEnd;source.focus();document.execCommand('insertText',false,a+source.value.slice(start,end)+b);source.setSelectionRange(start+a.length,end+a.length);emitChange();}return;
  }
  if(!editor||readOnly)return;
  if(name==='color'){writing.openColors();return;}
  if(name==='comment'){writing.startComment();return;}
  if(name==='underline'){editor.chain().focus().toggleMark('underline').run();return;}
  if(name==='page'){openPagePicker();return;}
  if(name==='link'){link();return;}
  const actions={bold:'toggleBold',italic:'toggleItalic',strike:'toggleStrike',code:'toggleCode',task:'toggleTaskList',bullet:'toggleBulletList',numbered:'toggleOrderedList',quote:'toggleBlockquote',undo:'undo',redo:'redo',addRowAfter:'addRowAfter',addColumnAfter:'addColumnAfter'};
  if(actions[name])editor.chain().focus()[actions[name]]().run();
  else if(name==='heading'&&!editor.isActive('table'))editor.chain().focus().toggleHeading({level:2}).run();
 }
};
send('ready');
