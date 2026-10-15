import {TaskPage} from './task-page.js';
import {walkTasks,serializeTasks,newTaskID} from './task-model.js';
import {taskIcon} from './task-icons.js';
import {PagePicker,insertPageLink} from './page-links.js';
import {configureLabelColors} from './task-labels.js';
import './folder-tasks.css';
const send=(type,data={})=>window.webkit?.messageHandlers.folderTasks.postMessage({type,...data});
const el=(tag,cls='',text)=>{const n=document.createElement(tag);n.className=cls;if(text!==undefined)n.textContent=text;return n;};
const button=(title,action,cls='',icon)=>{const b=el('button',cls);b.type='button';b.title=title;b.setAttribute('aria-label',title);if(icon)b.append(taskIcon(icon));b.onclick=action;return b;};
let sources=[],token='',lastSaved='',pending=null,inflight=null,timer=null,error='',warnings=[],query='',filter='',destination='',leaving=null;
let linkRequest=null;
let undo=[],redo=[],historyAction=null,lastHistory=0;
const sourceOf=item=>sources.find(s=>s.key===item?.details?._folderSource);
const virtual=(source,id)=>source+'_'+id;
function prepare(item,parent){
 item.details??={};if(item.details._folderSource)return;
 const source=sourceOf(parent)||sourceOf(view.lookup(view.detail)?.item)||sources.find(s=>s.key===destination)||sources.find(s=>s.taskPage)||sources[0];
 if(!source)return;
 const old=item.id,id=item.details.id||item.id||newTaskID();item.details._folderSource=source.key;item.details._folderID=id;item.id=virtual(source.key,id);item.details.id=item.id;
 if(view.detail===old)view.detail=item.id;if(view.goalView===old)view.goalView=item.id;
}
function sourceBadge(item,{textOnly=false}={}){
 const source=sourceOf(item);if(!source)return null;
 const node=textOnly?el('span','folder-source'):button('Open source page: '+source.name,()=>leave(()=>send('source',{source:source.key,item:item.details._folderID})),'folder-source','page');
 if(textOnly)node.append(taskIcon('page'));node.append(el('span','',source.name));node.title=source.name;return node;
}
function leave(action){if(error){notice(error);return;}if(inflight||pending){leaving=action;flush();}else action();}
function beforeChange(model){for(const g of model.goals)prepare(g);for(const {item,parent} of walkTasks(model))prepare(item,parent);return true;}
function changed(text,typing){
 if(error)return;
 const now=Date.now();if(!historyAction&&(!typing||now-lastHistory>1100)){undo.push(lastSaved||text);if(undo.length>80)undo.shift();redo=[];}lastHistory=now;
 pending=text;clearTimeout(timer);timer=setTimeout(flush,typing?220:0);updateSaveLabel();
}
function flush(){
 clearTimeout(timer);if(inflight||!pending||error)return;
 if(pending===lastSaved){pending=null;updateSaveLabel();if(leaving){const fn=leaving;leaving=null;fn();}return;}
 inflight=pending;pending=null;send('change',{text:inflight,token});updateSaveLabel();
}
function updateSaveLabel(){const label=document.querySelector('.folder-save-state');if(label)label.textContent=error?'Not saved':inflight||pending?'Saving…':'Saved in source pages';}
function notice(message){error=message;view.setReadOnly(true);if(view.model)view.render();else{const panel=el('div','folder-filter-empty');panel.setAttribute('role','alert');panel.append(el('strong','','Could not load folder tasks'),el('p','',message));const retry=button('Try again',()=>{error='';view.setReadOnly(false);send('refresh');},'folder-notice-action');retry.textContent='Try again';panel.append(retry);view.element.replaceChildren(panel);}}
const view=new TaskPage(document.getElementById('task-page'),changed,{
 readOnlyTitle:true,prepareItem:prepare,beforeChange,sourceBadge,
 canReparent:(item,parent)=>sourceOf(item)?.key===sourceOf(parent)?.key,
 heading:heading=>heading.append(button('Back to note',()=>leave(()=>send('back')),'task-quiet-action','back')),
 pick:(editor,range,kind)=>{const item=view.composer?.item||view.lookup(view.detail)?.item;linkRequest={editor,range,doc:editor.state.doc,source:sourceOf(item)?.key};picker.open(kind);picker.element.style.right='16px';picker.element.style.top='70px';picker.input.focus();send('pages',{source:linkRequest.source,kind});},
 picking:()=>!!linkRequest,
 open:href=>{const item=view.lookup(view.detail)?.item;send('link',{source:sourceOf(item)?.key,url:href});},
 composerSource:(container,c,parent)=>{
  const label=el('label','task-property folder-destination');label.append(taskIcon('page'));
  const select=el('select');select.setAttribute('aria-label','Source page');
  for(const source of sources){const option=el('option','',source.name);option.value=source.key;select.append(option);}
  select.value=sourceOf(c.item)?.key||'';select.disabled=!!parent||c.inserted;
  select.onchange=()=>{const old=c.item.id;delete c.item.details._folderSource;destination=select.value;c.item.id=c.item.details._folderID; c.item.details.id=c.item.id;prepare(c.item);if(view.detail===old)view.detail=c.item.id;};label.append(select);container.append(label);
 },afterRender:afterRender
});
// New goals have a source before their first edit, including goals created from
// a task's goal picker. Existing tasks never silently move between documents.
const pickerNode=el('div','popover');pickerNode.id='page-picker';pickerNode.hidden=true;pickerNode.setAttribute('role','dialog');
pickerNode.innerHTML='<div class="page-picker-input"><input aria-label="Find a page" placeholder="Find a page…"><button data-close aria-label="Close page picker">×</button></div><div id="page-results" role="listbox"></div>';
document.body.append(pickerNode);
const picker=new PagePicker(pickerNode,page=>{if(linkRequest){const {editor,range,doc}=linkRequest;insertPageLink(editor,page,range,doc);linkRequest=null;picker.close();}},()=>{linkRequest?.editor?.commands.focus();linkRequest=null;});
const addGoal=view.addGoal.bind(view);
view.addGoal=()=>chooseDestination(()=>addGoal());
function chooseDestination(action){
 if(sources.length===1){destination=sources[0].key;action();return;}
 if(!sources.length){send('newPage');return;}
 const overlay=el('div','task-overlay folder-destination-overlay'),dialog=el('section','folder-destination-dialog');dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label','Choose source page');
 dialog.append(el('h2','','Where should this goal live?'),el('p','','It stays in this page and appears in the folder’s goals.'));
 const list=el('div','folder-destination-list');for(const source of sources){const row=button('Use '+source.name,()=>{destination=source.key;overlay.remove();action();},'folder-destination-choice','page');row.append(el('span','',source.name));list.append(row);}dialog.append(list);
 const cancel=button('Cancel',()=>overlay.remove(),'folder-destination-cancel');cancel.textContent='Cancel';dialog.append(cancel);overlay.append(dialog);view.element.append(overlay);list.querySelector('button')?.focus();
 overlay.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();overlay.remove();}if(e.key==='Tab'){const buttons=[...dialog.querySelectorAll('button')],i=buttons.indexOf(document.activeElement);e.preventDefault();buttons[(i+(e.shiftKey?-1:1)+buttons.length)%buttons.length]?.focus();}};
}
function afterRender(){
 const content=view.element.querySelector('.task-content');if(!content)return;
 if(error||warnings.length){
  const notice=el('aside','folder-notice');notice.setAttribute('role','alert');notice.append(el('span','',error||`${warnings.length} page${warnings.length===1?'':'s'} need attention. Last readable tasks are kept when available. ${warnings[0]}`));
  if(error){const copy=button('Copy pending changes',()=>{send('copy',{text:serializeTasks(view.model)});},'folder-notice-action');copy.textContent='Copy changes';const reload=button('Reload folder tasks',()=>{const text=serializeTasks(view.model);send('recover',{text});error='';inflight=null;pending=null;lastSaved='';token='';view.setReadOnly(false);send('refresh');},'folder-notice-action');reload.textContent='Reload';notice.append(copy,reload);}content.insertBefore(notice,content.children[1]||null);
 }
 if(!view.detail&&!view.goalView){
  const toolbar=el('div','folder-task-toolbar'),search=el('label','folder-task-search');search.append(taskIcon('search'));
  const input=el('input');input.type='search';input.placeholder='Find a task…';input.setAttribute('aria-label','Find folder tasks');input.value=query;input.oninput=()=>{query=input.value;let expanded=false;if(query.trim())for(const entry of walkTasks(view.model)){if((entry.item.title+' '+(entry.item.details.labels||[]).join(' ')).toLowerCase().includes(query.trim().toLowerCase()))for(const parent of entry.ancestors)if(!view.expandedList.has(parent.id)){view.expandedList.add(parent.id);expanded=true;}}if(expanded){view.render();const replacement=view.element.querySelector('[aria-label="Find folder tasks"]');replacement.focus();}else applyFilter();};search.append(input);
  const source=el('select','folder-source-filter');source.setAttribute('aria-label','Filter by source page');const all=el('option','','All pages');all.value='';source.append(all);
  for(const page of sources){const option=el('option','',page.name);option.value=page.key;source.append(option);}source.value=filter;source.onchange=()=>{filter=source.value;if(filter)destination=filter;applyFilter();};
  toolbar.append(search,source,el('span','folder-filter-count'),el('span','folder-save-state'));content.insertBefore(toolbar,content.querySelector('.tasks-body'));applyFilter();
  if(!sources.length){const empty=view.element.querySelector('.task-page-empty');if(empty){empty.querySelector('p').textContent='Add a task page to this folder to start planning your work.';const add=empty.querySelector('button');add.onclick=()=>send('newPage');}}
 }
 if(view.composer){const select=view.element.querySelector('[aria-label="Source page"]');if(select)select.disabled=!!view.composer.parentID||view.composer.inserted;}
 updateSaveLabel();
}
function applyFilter(){
 const entries=walkTasks(view.model),match=item=>(!filter||item.details._folderSource===filter)&&(!query.trim()||(item.title+' '+(item.details.labels||[]).join(' ')+' '+(sourceOf(item)?.name||'')).toLowerCase().includes(query.trim().toLowerCase()));
 const familyMatch=item=>match(item)||item.children.some(familyMatch);
 for(const card of view.element.querySelectorAll('.task-card[data-task]')){const item=view.lookup(card.dataset.task)?.item;if(item)card.hidden=!match(item);}
 for(const family of [...view.element.querySelectorAll('.task-list-family,.task-family')].reverse()){const id=family.querySelector('[data-task]')?.dataset.task,item=id&&view.lookup(id)?.item;if(item)family.hidden=!familyMatch(item);}
 const count=view.element.querySelector('.folder-filter-count');if(count)count.textContent=filter||query?`${entries.filter(e=>match(e.item)).length} of ${entries.length}`:`${sources.filter(s=>entries.some(e=>e.item.details._folderSource===s.key)||view.model.goals.some(g=>g.details._folderSource===s.key)).length} pages`;
 let empty=view.element.querySelector('.folder-filter-empty');if(empty)empty.remove();
 if((filter||query)&&!entries.some(e=>match(e.item))){empty=el('div','folder-filter-empty');empty.append(el('strong','','No matching tasks'),el('p','','Try a different search or source page.'));view.element.querySelector('.tasks-body')?.prepend(empty);}
}
function history(direction){
 if(inflight||pending||error)return;
 const from=direction==='undo'?undo:redo,to=direction==='undo'?redo:undo;if(!from.length)return;
 const text=from.pop();to.push(lastSaved);historyAction=direction;view.load(text,{identity:'folder'});pending=text;flush();
}
window.folio={command:command=>{if(command==='find'){view.closeDetail();view.element.querySelector('[aria-label="Find folder tasks"]')?.focus();}else history(command);}};
view.element.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();history(e.shiftKey?'redo':'undo');}});
window.folderTasks={
 load(config){
  if(inflight||pending||error||view.composer||view.element.contains(document.activeElement)&&document.activeElement.matches('input,textarea,[contenteditable=true]'))return false;
  if(lastSaved&&lastSaved!==config.text){undo=[];redo=[];}
  sources=config.sources;warnings=config.warnings||[];token=config.token;lastSaved=config.text;
  if(!sources.some(s=>s.key===destination))destination=sources.find(s=>s.taskPage)?.key||sources[0]?.key||'';
  if(!sources.some(s=>s.key===filter))filter='';
  view.load(config.text,{identity:'folder'});return true;
 },
 saved(config){token=config.token;lastSaved=inflight;inflight=null;historyAction=null;updateSaveLabel();if(pending)flush();else if(leaving){const fn=leaving;leaving=null;fn();}},
 failed(message){pending=pending||inflight;inflight=null;historyAction=null;notice(message);},
 notice,
 configure(config){document.documentElement.dataset.theme=config.theme;view.element.style.setProperty('--task-accent',config.accent);configureLabelColors(config.labels);},
 pages(pages){if(linkRequest)picker.setPages(pages);},
 flush(){flush();return {pending:!!pending||!!inflight,failed:!!error};},
 snapshot(){return {text:serializeTasks(view.model),pending:!!pending||!!inflight,error,token};},
};
send('ready');
