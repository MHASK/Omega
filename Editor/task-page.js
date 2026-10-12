import {labelChip,applyLabelTone} from './task-labels.js';
import {completionRing,projectCompletion,taskCompletion,taskCompletionRing} from './completion-ring.js';
import {goalPicker,goalBadge,renderGoals,renderGoal} from './task-goals.js';
import { descriptionEditor } from './task-description.js';
import { taskIcon } from './task-icons.js';
import {parseTasks,serializeTasks,taskMarker,newTaskID,subtaskStatus,walkTasks,reparentTask} from './task-model.js';
export {parseTasks,serializeTasks,taskMarker};
const el=(tag,cls='',text)=>{const n=document.createElement(tag);n.className=cls;if(text!==undefined)n.textContent=text;return n;};
function button(text,label,action,cls='',icon){const n=el('button',cls);n.type='button';n.title=label;n.setAttribute('aria-label',label);if(icon)n.append(taskIcon(icon));if(text)n.append(el('span','',text));n.onclick=action;return n;}
const formControl=n=>{n.dataset.mutates='true';return n;};
const doneStatus=model=>model.statuses.indexOf(model.completed);
const firstOpen=model=>Math.max(0,model.statuses.findIndex(s=>s!==model.completed));

export class TaskPage {
 constructor(element,onChange,options={}){
  this.options=options;this.description=null;this.descriptions=[];
  this.element=element;this.onChange=onChange;this.view='list';this.collapsed=new Set();this.expandedList=new Set();this.collapsedGroups=new Set();this.readOnly=false;this.model=null;this.raw='';this.detail=null;this.goalView=null;this.composer=null;this.createAnother=false;this.removeConfirm=false;this.popovers=[];
  this.element.addEventListener('keydown',e=>this.keydown(e));
  if(typeof ResizeObserver!=='undefined'){this.observer=new ResizeObserver(()=>{if(this.width===element.clientWidth)return;this.width=element.clientWidth;this.resizeFields();});this.observer.observe(element);}
 }
 load(text,{identity=this.identity}={}){
  const model=parseTasks(text);if(!model)return false;
  if(this.identity!==identity){this.detail=null;this.goalView=null;this.composer=null;this.removeConfirm=false;this.collapsed.clear();this.expandedList.clear();this.collapsedGroups.clear();}
  this.identity=identity;this.model=model;this.raw=text;
  if(this.goalView&&this.goalView!=='all'&&!model.goals.some(g=>g.id===this.goalView))this.goalView='all';
  if(this.detail&&!this.lookup(this.detail)){this.detail=null;this.removeConfirm=false;}
  if(this.composer){const existing=this.lookup(this.composer.item.id);if(existing)this.composer.item=existing.item;else this.composer=null;}
  this.render();return true;
 }
 lookup(id){return this.model?walkTasks(this.model).find(e=>e.item.id===id)||null:null;}
 reference(ref){if(ref.startsWith('g:'))return this.model.goals[Number(ref.slice(2))];let item;for(const [depth,index] of ref.slice(2).split('.').map(Number).entries())item=(depth?item?.children:this.model.tasks)?.[index];return item;}
 promote(item){this.reparent(item,null);}
 reparent(item,parentID){if(this.readOnly)return;const moved=reparentTask(this.model,item.id,parentID);if(moved){this.detail=moved.id;this.change(true);}}
 revealItem(id,kind){
  if(kind==='goal'){const goal=this.model.goals.find(g=>g.details.id===id);if(!goal)return false;this.openGoal(goal);return true;}
  const found=this.lookup(id);if(!found)return false;this.openDetail(found.item);const title=this.element.querySelector('.task-detail-title,.task-composer-title');title?.classList.add('folio-search-hit');setTimeout(()=>title?.classList.remove('folio-search-hit'),2300);return true;
 }
 descriptionField(item,onChange){const host=el('div','task-description-host');this.description=descriptionEditor(host,item,onChange,{readOnly:this.readOnly,...this.options});this.descriptions.push(this.description);return host;}
 touch(item){item.details??={};if(!item.details.id){const previous=item.id;item.id=newTaskID();item.details.id=item.id;if(this.detail===previous)this.detail=item.id;if(this.goalView===previous)this.goalView=item.id;if(this.expandedList.delete(previous))this.expandedList.add(item.id);}return item;}
 change(render=false,typing=false){if(this.readOnly)return;this.raw=serializeTasks(this.model);this.onChange(this.raw,typing);if(render)this.render();}
 setReadOnly(value){this.readOnly=value;this.descriptions.forEach(editor=>editor.setEditable(!value,false));if(value)this.popovers.forEach(close=>close());this.element.querySelectorAll('[data-mutates]').forEach(n=>n.disabled=value);this.element.querySelectorAll('.task-card').forEach(n=>n.draggable=!value);}
 get busy(){return !!this.composer||this.removeConfirm;}
 resizeFields(){this.element.querySelectorAll('textarea').forEach(n=>{n.style.height='auto';n.style.height=n.scrollHeight+'px';});}
 textField(item,key,placeholder,cls,onInput){
  const input=formControl(el('textarea',cls));input.rows=1;input.value=item[key]||'';input.placeholder=placeholder;input.setAttribute('aria-label',placeholder);input.dataset.field=key;input.maxLength=key==='description'?100000:10000;
  const size=()=>{input.classList.toggle('is-empty',!input.value.trim());input.style.height='auto';input.style.height=input.scrollHeight+'px';};queueMicrotask(size);
  input.oninput=()=>{item[key]=input.value;size();onInput?.();};
  if(key==='title')input.onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();this.description?.commands?.focus();}};
  return input;
 }
 check(checked,label,action){const input=formControl(el('input','task-check'));input.type='checkbox';input.checked=checked;input.setAttribute('aria-label',label);input.onchange=()=>{if(!this.readOnly)action(input.checked);};return input;}
 statusOf(item,parent){return parent?subtaskStatus(this.model,item):item.status;}
 move(item,status,parent=null){if(this.readOnly)return;this.touch(item);if(parent)item.details.status=this.model.statuses[status];else item.status=status;item.done=status===doneStatus(this.model);this.change(true);}
 statusSelect(item,parent,onChange){const select=formControl(el('select','task-status-select'));select.setAttribute('aria-label',parent?'Subtask status':'Task status');this.model.statuses.forEach((name,i)=>{const option=el('option','',name);option.value=String(i);select.append(option);});select.value=String(this.statusOf(item,parent));select.onchange=()=>onChange?onChange(Number(select.value)):this.move(item,Number(select.value),parent);return select;}
 setView(view){this.view=view;this.render();}
 openGoals(){this.detail=null;this.goalView='all';this.render();}
 openGoal(goal){this.detail=null;this.goalView=goal.id;this.render();}
 addGoal(){if(this.readOnly)return;const goal={id:newTaskID(),title:'',done:false,details:{},children:[]};goal.details.id=goal.id;this.model.goals.push(goal);this.detail=null;this.goalView=goal.id;this.change(true);this.element.querySelector('.goal-title')?.focus();}
 addTask(status=firstOpen(this.model)){this.openComposer(null,status);}
 addChild(parent){this.openComposer(parent,firstOpen(this.model));}
 openDetail(item){this.goalView=null;if(item.details?.draft){this.openComposerFor(item);return;}this.detail=item.id;this.removeConfirm=false;this.savedScroll=this.element.querySelector('.tasks-body')?.scrollTop||this.savedScroll||0;this.render();this.element.querySelector('.task-detail-back')?.focus();}
 closeDetail(){this.goalView=null;this.detail=null;this.removeConfirm=false;this.render();const body=this.element.querySelector('.tasks-body');if(body)body.scrollTop=this.savedScroll||0;}
 render(){
  this.descriptions.forEach(editor=>editor.destroy());this.descriptions=[];this.description=null;this.popovers.forEach(close=>close());this.popovers=[];
  const root=this.element;root.replaceChildren();if(!this.model)return;
  if(this.goalView&&this.goalView!=='all'&&!this.model.goals.some(g=>g.id===this.goalView))this.goalView='all';
  const content=el('div','task-content');root.append(content);
  if(this.goalView==='all')renderGoals(this,content);else if(this.goalView)renderGoal(this,content,this.model.goals.find(g=>g.id===this.goalView));else if(this.detail&&this.lookup(this.detail))this.renderDetail(content);else this.renderOverview(content);
  if(this.composer)this.renderComposer(root);
  this.setReadOnly(this.readOnly);this.resizeFields();
 }
 renderOverview(root){
  const header=el('header','tasks-header'),heading=el('div','tasks-heading'),p=projectCompletion(this.model),ring=completionRing(p.completed,p.total,{label:p.label});ring.classList.add('tasks-page-progress');
  heading.append(ring,this.textField(this.model,'title','Task page title','tasks-title',()=>this.change(false,true)));header.append(heading);
  const controls=el('div','tasks-controls'),tabs=el('div','tasks-tabs');tabs.setAttribute('role','tablist');
  for(const view of ['list','board']){const tab=button(view==='list'?'List':'Board',view==='list'?'List view':'Board view',()=>this.setView(view),this.view===view?'active':'',view);tab.setAttribute('role','tab');tab.setAttribute('aria-selected',String(this.view===view));tabs.append(tab);}
  const actions=el('div','tasks-actions');actions.append(button('Goals'+(this.model.goals.length?' · '+this.model.goals.length:''),'Manage goals',()=>this.openGoals(),'task-goals-trigger','goal'));this.addMenu(actions);controls.append(tabs,actions);header.append(controls);root.append(header);
  const body=el('div','tasks-body'+(this.view==='list'?' tasks-list-body':''));root.append(body);root=body;
  if(!this.model.tasks.length){const empty=el('section','task-page-empty');empty.append(taskIcon('task'),el('h2','','No tasks yet'),el('p','',this.model.goals.length?'Turn your goal into a few small steps.':'Start with one thing you’d like to get done.'),formControl(button('Add your first task','Add your first task',()=>this.addTask(),'task-empty-action','add')));root.append(empty);return;}
  if(this.view==='list'){this.renderList(root);return;}
  const groups=el('div','task-groups '+this.view);groups.style.setProperty('--status-count',this.model.statuses.length);
  this.model.statuses.forEach((status,index)=>{
   const group=el('section','task-group');group.dataset.status=String(index);if(status===this.model.completed)group.classList.add('status-complete');
   const entries=walkTasks(this.model),parents=entries.filter(e=>!e.parent&&e.item.status===index),children=entries.filter(e=>e.parent&&subtaskStatus(this.model,e.item)===index);
   const heading=el('div','task-group-heading');heading.append(el('span','task-status-dot'),el('span','task-status-name',status),el('span','task-count',String(parents.length+children.length)),formControl(button('','Add task to '+status,()=>this.addTask(index),'task-quiet-action','add')));group.append(heading);
   group.ondragover=e=>{if(this.readOnly||!e.dataTransfer.types.includes('application/x-folio-task'))return;e.preventDefault();e.dataTransfer.dropEffect='move';group.classList.add('drop-target');};
   group.ondragleave=e=>{if(!group.contains(e.relatedTarget))group.classList.remove('drop-target');};
   group.ondrop=e=>{e.preventDefault();group.classList.remove('drop-target');const found=this.lookup(e.dataTransfer.getData('application/x-folio-task'));if(found)this.move(found.item,index,found.parent);};
   const containsStatus=(item,parent)=>this.statusOf(item,parent)===index||(item.children||[]).some(c=>containsStatus(c,item));
   const familyView=(item,parent=null)=>{
    if(!containsStatus(item,parent))return null;
    const family=el('div','task-family'+(item.children.length?' has-subtasks':''));
    if(this.statusOf(item,parent)===index)family.append(this.card(item,parent));
    else family.append(button(item.title||'Untitled task','Open parent task: '+(item.title||'Untitled task'),()=>this.openDetail(item),'task-parent-context','task'));
    if(item.children.length&&!this.collapsed.has(item.id)){const stack=el('div','task-subtask-stack');for(const child of item.children){const nested=familyView(child,item);if(nested)stack.append(nested);}family.append(stack);}
    return family;
   };
   for(const task of this.model.tasks){const family=familyView(task);if(family)group.append(family);}
   if(!parents.length&&!children.length)group.append(el('p','task-lane-empty',status===this.model.completed?'Completed tasks will appear here.':'No tasks here yet.'));
   group.append(formControl(button('Create task','Create task in '+status,()=>this.addTask(index),'task-create-row','add')));groups.append(group);
  });root.append(groups);
 }
 // The list is its own compact hierarchy; board cards keep their independent layout.
 renderList(root){
  const groups=el('div','task-groups list');
  this.model.statuses.forEach((status,index)=>{
   const tasks=this.model.tasks.filter(t=>t.status===index),group=el('section','task-group'+(status===this.model.completed?' status-complete':''));group.dataset.status=String(index);
   const open=!this.collapsedGroups.has(status),heading=el('div','task-group-heading');
   const toggle=button('',(open?'Collapse ':'Expand ')+status,()=>{open?this.collapsedGroups.add(status):this.collapsedGroups.delete(status);this.renderListPreservingScroll();this.element.querySelector(`.list .task-group[data-status="${index}"] .task-group-toggle`)?.focus({preventScroll:true});},'task-group-toggle');toggle.setAttribute('aria-expanded',String(open));
   const chevron=taskIcon('chevron');chevron.classList.add('task-disclosure-icon');toggle.append(chevron,el('span','task-status-dot'),el('span','task-status-name',status),el('span','task-count',String(tasks.length)));heading.append(toggle,formControl(button('','Add task to '+status,()=>this.addTask(index),'task-quiet-action','add')));group.append(heading);
   group.ondragover=e=>{if(this.readOnly||!e.dataTransfer.types.includes('application/x-folio-task'))return;e.preventDefault();e.dataTransfer.dropEffect='move';group.classList.add('drop-target');};
   group.ondragleave=e=>{if(!group.contains(e.relatedTarget))group.classList.remove('drop-target');};
   group.ondrop=e=>{e.preventDefault();group.classList.remove('drop-target');const found=this.lookup(e.dataTransfer.getData('application/x-folio-task'));if(found)this.move(found.item,index,found.parent);};
   if(open){
    const rows=el('div','task-list-rows');
    const family=(item,parent=null,depth=0)=>{const wrap=el('div','task-list-family');wrap.append(this.listRow(item,parent,depth));if(item.children.length&&this.expandedList.has(item.id)){const children=el('div','task-list-children');for(const child of item.children)children.append(family(child,item,depth+1));wrap.append(children);}return wrap;};
    for(const task of tasks)rows.append(family(task));
    if(!tasks.length)rows.append(el('p','task-lane-empty',status===this.model.completed?'Completed tasks will appear here.':'No tasks here yet.'));
    rows.append(formControl(button('Add task','Create task in '+status,()=>this.addTask(index),'task-create-row','add')));group.append(rows);
   }
   groups.append(group);
  });root.append(groups);
 }
 renderListPreservingScroll(focusID){const scroll=this.element.querySelector('.tasks-body')?.scrollTop||0;this.render();const body=this.element.querySelector('.tasks-body');if(body)body.scrollTop=scroll;if(focusID)[...this.element.querySelectorAll('.task-list-row')].find(row=>row.dataset.task===focusID)?.querySelector('.task-row-disclosure,.task-card-title')?.focus({preventScroll:true});}
 toggleList(item){this.expandedList.has(item.id)?this.expandedList.delete(item.id):this.expandedList.add(item.id);this.renderListPreservingScroll(item.id);}
 listRow(item,parent,depth){
  const status=this.statusOf(item,parent),done=status===doneStatus(this.model),row=el('article','task-card task-list-row'+(parent?' subtask-card':'')+(done?' complete':'')+(item.details?.draft?' draft':''));row.dataset.task=item.id;row.style.setProperty('--task-depth',Math.min(depth,8));
  row.onclick=e=>{if(!e.target.closest('button,input,select'))this.openDetail(item);};
  row.draggable=!this.readOnly;row.ondragstart=e=>{if(this.readOnly){e.preventDefault();return;}e.dataTransfer.setData('application/x-folio-task',item.id);e.dataTransfer.effectAllowed='move';e.dataTransfer.setDragImage(row,10,10);};
  const leading=el('div','task-row-leading');
  if(item.children.length){const toggle=button('',(this.expandedList.has(item.id)?'Collapse':'Expand')+' subtasks: '+(item.title||'Untitled task'),()=>this.toggleList(item),'task-row-disclosure','chevron');toggle.setAttribute('aria-expanded',String(this.expandedList.has(item.id)));leading.append(toggle);}else leading.append(el('span','task-disclosure-space'));
  leading.append(this.check(done,parent?'Complete subtask':'Complete task',v=>this.move(item,v?doneStatus(this.model):firstOpen(this.model),parent)));row.append(leading);
  const title=button(item.title||'Untitled task',`Open ${parent?'subtask':'task'}: ${item.title||'Untitled task'}`,()=>this.openDetail(item),'task-card-title task-row-title');title.title=item.title||'Untitled task';row.append(title);
  const progress=el('div','task-row-progress');if(item.children.length){const p=taskCompletion(this.model,item,parent),toggle=button(`${p.completed}/${p.total}`,p.label,()=>this.toggleList(item),'task-row-progress-button');toggle.prepend(taskCompletionRing(this.model,item,parent,true));toggle.setAttribute('aria-expanded',String(this.expandedList.has(item.id)));progress.append(toggle);}else progress.append(taskCompletionRing(this.model,item,parent));if(item.details?.draft)progress.append(el('span','task-draft-badge','Draft'));row.append(progress);
  const labels=el('div','task-row-labels');const badge=goalBadge(this,item);if(badge)labels.append(badge);for(const name of(item.details?.labels||[]).slice(0,2)){labels.append(labelChip(name));}if(item.details?.labels?.length>2){const extra=el('span','task-label task-label-overflow','+'+(item.details.labels.length-2));extra.title=item.details.labels.slice(2).join(', ');labels.append(extra);}row.append(labels);
  const due=el('span','task-row-date');if(item.details?.due){due.append(taskIcon('calendar'),el('span','',this.dateLabel(item.details.due)));due.title=item.details.due;}row.append(due);
  const state=el('div','task-row-state');state.append(el('span','task-status-dot'+(done?' is-done':status===firstOpen(this.model)?'':' is-active')));const select=this.statusSelect(item,parent);select.title=this.model.statuses[status];state.append(select);row.append(state,button('','Open task details',()=>this.openDetail(item),'task-quiet-action task-row-more','more'));
  row.onkeydown=e=>{if(e.target!==title&&!e.target.classList.contains('task-row-disclosure'))return;if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();const titles=[...this.element.querySelectorAll('.task-row-title')],index=titles.indexOf(title);titles[Math.max(0,Math.min(titles.length-1,index+(e.key==='ArrowDown'?1:-1)))]?.focus();}else if(e.key==='ArrowRight'&&item.children.length&&!this.expandedList.has(item.id)){e.preventDefault();this.toggleList(item);}else if(e.key==='ArrowLeft'){if(this.expandedList.has(item.id)){e.preventDefault();this.toggleList(item);}else if(parent){e.preventDefault();[...this.element.querySelectorAll('.task-list-row')].find(r=>r.dataset.task===parent.id)?.querySelector('.task-row-title')?.focus();}}};
  return row;
 }
 card(item,parent=null){
  const status=this.statusOf(item,parent),done=status===doneStatus(this.model),card=el('article','task-card'+(parent?' subtask-card':'')+(done?' complete':'')+(item.details?.draft?' draft':''));card.dataset.task=item.id;
  card.tabIndex=0;card.setAttribute('role','button');card.setAttribute('aria-label',`Open ${parent?'subtask':'task'}: ${item.title||'Untitled task'}`);card.onclick=e=>{if(!e.target.closest('button,input,select'))this.openDetail(item);};card.onkeydown=e=>{if(e.target===card&&['Enter',' '].includes(e.key)){e.preventDefault();this.openDetail(item);}};
  card.draggable=!this.readOnly;card.ondragstart=e=>{if(this.readOnly){e.preventDefault();return;}e.dataTransfer.setData('application/x-folio-task',item.id);e.dataTransfer.effectAllowed='move';e.dataTransfer.setDragImage(card,10,10);};
  const title=button(item.title||'Untitled task',`Open ${parent?'subtask':'task'}: ${item.title||'Untitled task'}`,()=>this.openDetail(item),'task-card-title');card.append(title);
  if(item.details?.labels?.length){const labels=el('div','task-card-labels');for(const name of item.details.labels.slice(0,3))labels.append(labelChip(name));if(item.details.labels.length>3)labels.append(el('span','task-label',`+${item.details.labels.length-3}`));card.append(labels);}
  const goal=goalBadge(this,item);if(goal){const row=el('div','task-card-goals');row.append(goal);card.append(row);}
  const meta=el('div','task-card-meta');const kind=el('span','task-kind');kind.append(this.check(done,parent?'Complete subtask':'Complete task',v=>this.move(item,v?doneStatus(this.model):firstOpen(this.model),parent)),taskIcon(parent?'subtasks':'task'),el('span','',parent?'Subtask':'Task'));meta.append(kind);
  if(item.details?.draft)meta.append(el('span','task-draft-badge','Draft'));
  if(item.details?.due){const due=el('span','task-date');due.append(taskIcon('calendar'),el('span','',this.dateLabel(item.details.due)));due.title=item.details.due;meta.append(due);}
  if(item.children.length){const p=taskCompletion(this.model,item,parent),toggle=button(`${p.completed}/${p.total}`,p.label+' · Show subtasks',()=>{this.collapsed.has(item.id)?this.collapsed.delete(item.id):this.collapsed.add(item.id);this.render();},'task-progress');toggle.prepend(taskCompletionRing(this.model,item,parent,true));toggle.setAttribute('aria-expanded',String(!this.collapsed.has(item.id)));meta.append(toggle);}else{const progress=el('span','task-progress');progress.append(taskCompletionRing(this.model,item,parent));meta.append(progress);}
  if(this.view==='list')meta.append(this.statusSelect(item,parent));
  meta.append(button('','Open task details',()=>this.openDetail(item),'task-quiet-action task-more','more'));card.append(meta);return card;
 }
 dateLabel(date){const d=new Date(date+'T12:00:00');return isNaN(d)?date:d.toLocaleDateString(undefined,{month:'short',day:'numeric'});}
 bindPopover(container,trigger,menu,onOpen,keyboardMenu=false,alignStart=false){
  menu.hidden=true;trigger.setAttribute('aria-haspopup',keyboardMenu?'menu':'dialog');trigger.setAttribute('aria-expanded','false');
  const place=()=>{if(menu.hidden)return;const r=trigger.getBoundingClientRect(),width=window.innerWidth,height=window.innerHeight;menu.style.left=Math.max(8,Math.min(alignStart?r.left:r.right-menu.offsetWidth,width-menu.offsetWidth-8))+'px';menu.style.top=Math.max(8,Math.min(r.bottom+5,height-menu.offsetHeight-8))+'px';};
  const close=(focus=false)=>{menu.hidden=true;trigger.setAttribute('aria-expanded','false');document.removeEventListener('pointerdown',outside,true);window.removeEventListener('resize',place);if(focus&&trigger.isConnected)trigger.focus();};
  const outside=e=>{if(!container.contains(e.target))close();};
  const open=(last=false)=>{if(this.readOnly)return;this.popovers.forEach(dismiss=>dismiss());onOpen?.();menu.hidden=false;trigger.setAttribute('aria-expanded','true');place();document.addEventListener('pointerdown',outside,true);window.addEventListener('resize',place);const controls=menu.querySelectorAll('input,button');controls.item(last?controls.length-1:0)?.focus();};
  trigger.onclick=()=>menu.hidden?open():close(true);
  trigger.onkeydown=e=>{if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();open(e.key==='ArrowUp');}};
  menu.addEventListener('keydown',e=>{if(e.defaultPrevented)return;const items=[...menu.querySelectorAll('button')],i=items.indexOf(document.activeElement);if(keyboardMenu&&items.length&&['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();items[e.key==='Home'?0:e.key==='End'?items.length-1:(i+(e.key==='ArrowDown'?1:-1)+items.length)%items.length].focus();}else if(e.key==='Escape'){e.preventDefault();e.stopPropagation();close(true);}else if(keyboardMenu&&e.key==='Tab'){close(true);}});
  menu.onfocusout=e=>{if(!container.contains(e.relatedTarget))close();};
  this.popovers.push(close);container.append(trigger,menu);return {close,open,place};
 }
 addMenu(container){
  const menu=el('div','task-add-menu');menu.setAttribute('role','menu');menu.setAttribute('aria-label','Add to task page');
  const trigger=formControl(button('Add','Add',null,'task-new','add')),popover=this.bindPopover(container,trigger,menu,null,true);
  for(const [title,icon,action] of [['Task','task',()=>this.addTask()],['Goal','goal',()=>this.addGoal()]]){const item=formControl(button(title,'Add '+title.toLowerCase(),()=>{popover.close();action();},'',icon));item.setAttribute('role','menuitem');menu.append(item);}
 }
 detailMenu(container,item,parent){
  const menu=el('div','task-add-menu');menu.setAttribute('role','menu');menu.setAttribute('aria-label','Task actions');const trigger=formControl(button('','More task actions',null,'task-quiet-action','more')),popover=this.bindPopover(container,trigger,menu,null,true);
  if(parent){const promote=formControl(button('Make main task','Make main task',()=>{popover.close();this.promote(item);},'','promote'));promote.setAttribute('role','menuitem');menu.append(promote);}
  const move=formControl(button(parent?'Move to another task…':'Move under task…','Move under task',()=>{popover.close();this.openParentPicker(item);},'','subtasks'));move.setAttribute('role','menuitem');menu.append(move);
  const remove=formControl(button('Remove '+(parent?'subtask':'task')+'…','Remove task',()=>{popover.close();this.removeConfirm=true;this.render();},'','trash'));remove.setAttribute('role','menuitem');menu.append(remove);
 }
 openParentPicker(item){
  const actions=this.element.querySelector('.task-detail-actions'),wrap=el('div','task-parent-picker-wrap'),trigger=button('','Choose parent task',null,'task-parent-anchor'),panel=el('div','task-label-picker task-parent-picker');panel.setAttribute('role','dialog');panel.setAttribute('aria-label','Move under task');
  const input=el('input','task-label-search');input.placeholder='Find a parent task…';input.setAttribute('aria-label','Find a parent task');const list=el('div','task-label-choices');panel.append(input,list,el('p','task-picker-empty','Details and subtasks move with this task.'));
  const choices=walkTasks(this.model).filter(e=>e.item!==item&&!e.ancestors.includes(item)&&!e.item.details.draft&&e.item!==this.lookup(item.id)?.parent);
  const render=()=>{list.replaceChildren();for(const entry of choices.filter(e=>(e.item.title+' '+e.ancestors.map(a=>a.title).join(' ')).toLowerCase().includes(input.value.trim().toLowerCase()))){const row=button(entry.item.title||'Untitled task','Move under '+(entry.item.title||'Untitled task'),()=>this.reparent(item,entry.item.id),'task-parent-choice','task');if(entry.ancestors.length)row.append(el('small','',entry.ancestors.map(a=>a.title||'Untitled task').join(' / ')));list.append(row);}if(!list.children.length)list.append(el('p','task-picker-empty',choices.length?'No matching tasks.':'No other tasks available.'));};
  actions.append(wrap);const popover=this.bindPopover(wrap,trigger,panel,render);input.oninput=()=>{render();popover.place();};panel.onkeydown=e=>{if(e.key==='Enter'&&e.target===input){e.preventDefault();list.querySelector('button')?.click();}if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();const items=[input,...list.querySelectorAll('button')],i=items.indexOf(document.activeElement);items[(i+(e.key==='ArrowDown'?1:-1)+items.length)%items.length]?.focus();}};popover.open();
 }
 labelPicker(container,item,onChange){
  const wrap=el('div','task-label-control'),trigger=formControl(button('Labels','Labels',null,'task-property task-label-trigger','tag')),panel=el('div','task-label-picker');panel.setAttribute('role','dialog');panel.setAttribute('aria-label','Choose labels');
  const input=formControl(el('input','task-label-search'));input.type='text';input.placeholder='Find or create a label…';input.setAttribute('aria-label','Find or create a label');input.maxLength=40;
  const choices=el('div','task-label-choices');panel.append(input,choices);
  const known=()=>[...new Set(walkTasks(this.model).flatMap(({item})=>item.details.labels||[]))].sort((a,b)=>a.localeCompare(b));
  const updateTrigger=()=>{const labels=item.details.labels||[],text=labels.length?labels[0]+(labels.length>1?' +'+(labels.length-1):''):'Labels';trigger.querySelector('span:last-child').textContent=text;trigger.title=labels.length?labels.join(', '):'Add labels';applyLabelTone(trigger,labels[0]);};
  const toggle=name=>{if(this.readOnly)return;const labels=item.details.labels||[];if(labels.includes(name))item.details.labels=labels.filter(v=>v!==name);else if(labels.length<12)item.details.labels=[...labels,name];else return;onChange();updateTrigger();renderChoices();input.focus();popover.place();};
  const renderChoices=()=>{if(choices.contains(document.activeElement))input.focus();choices.replaceChildren();const query=input.value.trim(),labels=known().filter(name=>name.toLowerCase().includes(query.toLowerCase()));
   if(!labels.length)choices.append(el('p','task-picker-empty',query?'No matching labels.':'No labels yet. Type a name to create one.'));
   for(const name of labels){const selected=(item.details.labels||[]).includes(name),choice=formControl(button('',(selected?'Remove label: ':'Add label: ')+name,()=>toggle(name),'task-label-choice'));choice.setAttribute('aria-pressed',String(selected));choice.append(labelChip(name),taskIcon('check'));choices.append(choice);}
   if(query&&!known().some(name=>name.toLowerCase()===query.toLowerCase())){const create=formControl(button('Create “'+query.toLocaleUpperCase()+'”','Create label: '+query,()=>{toggle(query);input.value='';renderChoices();popover.place();},'task-label-choice','add'));create.disabled=this.readOnly||(item.details.labels||[]).length>=12;choices.append(create);}
   if((item.details.labels||[]).length>=12)choices.append(el('p','task-picker-empty','12 labels selected. Remove one to add another.'));
  };
  const popover=this.bindPopover(wrap,trigger,panel,()=>{input.value='';renderChoices();},false,true);input.oninput=()=>{renderChoices();popover.place();};
  input.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();choices.querySelector('button:not(:disabled)')?.click();}else if(e.key==='ArrowDown'){e.preventDefault();choices.querySelector('button:not(:disabled)')?.focus();}};
  panel.addEventListener('keydown',e=>{if(e.defaultPrevented||!['ArrowDown','ArrowUp'].includes(e.key)||!choices.contains(e.target))return;const items=[input,...choices.querySelectorAll('button:not(:disabled)')],index=items.indexOf(document.activeElement);e.preventDefault();items[(index+(e.key==='ArrowDown'?1:-1)+items.length)%items.length]?.focus();});
  updateTrigger();container.append(wrap);
 }
 renderDetail(root){
  const found=this.lookup(this.detail);if(!found)return;const {item,parent}=found;
  const header=el('header','task-detail-header');root.append(header);
  const nav=el('nav','task-detail-nav');nav.setAttribute('aria-label','Task navigation');nav.append(button(this.model.title||'Tasks','Back to tasks',()=>this.closeDetail(),'task-detail-back','back'));
  if(parent){nav.append(taskIcon('chevron'),button(parent.title||'Untitled task','Open parent task',()=>{this.detail=parent.id;this.render();},'task-breadcrumb'));}nav.append(taskIcon('chevron'),el('span','task-type-caption',parent?'Subtask':'Task'));const actions=el('div','task-detail-actions');actions.append(taskCompletionRing(this.model,item,parent),this.statusSelect(item,parent));this.detailMenu(actions,item,parent);header.append(nav,actions);
  const scroller=el('div','task-detail-scroller'),detail=el('section','task-detail');scroller.append(detail);root.append(scroller);
  detail.append(this.textField(item,'title','Task title','task-detail-title',()=>{this.touch(item);this.change(false,true);}));
  const props=el('div','task-detail-properties');
  this.addProperties(props,item,parent,()=>{this.touch(item);this.change(false,true);});detail.append(props);
  const description=el('div','task-description-section');description.append(el('div','task-section-label','Description'),this.descriptionField(item,()=>{this.touch(item);this.change(false,true);}),el('p','task-field-hint','Type / to link a task, goal, or page.'));detail.append(description);
  {const section=el('section','task-detail-children');const head=el('div','task-section-heading'),label=el('span','task-section-label task-subtasks-label','Subtasks');if(item.children.length){const p=taskCompletion(this.model,item,parent);label.append(taskCompletionRing(this.model,item,parent),el('span','',`${p.completed}/${p.total}`));}head.append(label,formControl(button('Add subtask','Add subtask',()=>this.addChild(item),'','add')));section.append(head);
   for(const child of item.children){const row=el('div','task-detail-child');row.append(this.check(subtaskStatus(this.model,child)===doneStatus(this.model),'Complete subtask',v=>this.move(child,v?doneStatus(this.model):firstOpen(this.model),item)),taskIcon('subtasks'),button(child.title||'Untitled subtask','Open subtask: '+(child.title||'Untitled subtask'),()=>this.openDetail(child),'task-child-title'),this.statusSelect(child,item));section.append(row);}
   if(!item.children.length){const empty=el('div','task-subtasks-empty');empty.append(taskIcon('subtasks'),el('p','','No subtasks yet'),el('span','','Break this task into a few smaller steps.'));section.append(empty);}detail.append(section);
  }
  if(this.removeConfirm){const overlay=el('div','task-overlay task-remove-overlay'),dialog=el('section','task-remove-dialog');dialog.setAttribute('role','alertdialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label',parent?'Remove subtask?':'Remove task?');const count=walkTasks({tasks:item.children||[]}).length;dialog.append(el('h2','',parent?'Remove subtask?':'Remove task?'),el('p','',count?`This also removes its ${count} subtask${count===1?'':'s'}.`:'This removes the task from this page.'),el('p','task-remove-hint','You can restore it with ⌘Z.'));const controls=el('div','task-remove-actions');const keep=button('Keep','Keep task',()=>{this.removeConfirm=false;this.render();this.element.querySelector('[aria-label="More task actions"]')?.focus();});controls.append(keep,formControl(button('Remove','Confirm remove task',()=>this.removeItem(item,parent),'task-primary')));dialog.append(controls);overlay.append(dialog);root.inert=true;this.element.append(overlay);queueMicrotask(()=>keep.focus());}
 }
 addProperties(container,item,parent,onChange,composer=false){
  const dateWrap=el('label','task-property task-date-property'+(item.details.due?' has-date':''));dateWrap.append(taskIcon('calendar'),el('span','task-date-placeholder','Due date'));const date=formControl(el('input'));date.type='date';date.value=item.details.due||'';date.setAttribute('aria-label','Due date');date.onchange=()=>{if(date.value)item.details.due=date.value;else delete item.details.due;dateWrap.classList.toggle('has-date',!!date.value);onChange();};dateWrap.append(date);container.append(dateWrap);
  this.labelPicker(container,item,onChange);goalPicker(this,container,item,onChange);
  if(composer&&!item.children?.length){const wrap=el('label','task-property task-parent-property');wrap.append(taskIcon('task'));const select=formControl(el('select'));select.setAttribute('aria-label','Parent task');const none=el('option','','No parent');none.value='';select.append(none);for(const task of this.model.tasks){if(task===item||task.details.draft)continue;const option=el('option','',task.title||'Untitled task');option.value=task.id;select.append(option);}select.value=parent?.id||'';select.onchange=()=>this.reparentDraft(select.value);wrap.append(select);container.append(wrap);}
 }
 openComposer(parent=null,status=firstOpen(this.model)){
  if(this.readOnly)return;if(this.composer){this.composer.mode='modal';this.render();return;}
  const item={id:newTaskID(),title:'',done:false,status,children:[],details:{draft:true}};item.details.id=item.id;if(parent)item.details.status=this.model.statuses[status];
  this.composer={item,parentID:parent?.id||null,mode:'modal',inserted:false};this.render();this.focusComposer();
 }
 openComposerFor(item){const found=this.lookup(item.id);if(!found)return;this.composer={item,parentID:found.parent?.id||null,mode:'modal',inserted:true};this.render();this.focusComposer();}
 focusComposer(){queueMicrotask(()=>this.element.querySelector('.task-composer-title')?.focus());}
 persistDraft(){
  const c=this.composer;if(!c||this.readOnly)return;
  if(!c.inserted){if(!c.item.title&&!c.item.details.description&&!c.item.details.due&&!c.item.details.labels?.length&&!c.item.details.goals?.length)return;const parent=this.lookup(c.parentID)?.item;if(parent)parent.children.push(c.item);else this.model.tasks.push(c.item);c.inserted=true;}
  this.change(false,true);
 }
 reparentDraft(parentID){
  const c=this.composer;if(!c||this.readOnly)return;const next=this.model.tasks.find(t=>t.id===parentID)||null,previous=this.lookup(c.parentID)?.item||null;
  if(next&&(next===c.item||c.item.children?.length||next.details.draft))return;
  if(c.inserted){if(previous)previous.children=previous.children.filter(i=>i!==c.item);else this.model.tasks=this.model.tasks.filter(i=>i!==c.item);}
  const status=previous?subtaskStatus(this.model,c.item):c.item.status;
  c.parentID=next?.id||null;
  if(next)c.item.details.status=this.model.statuses[status];else{delete c.item.details.status;c.item.status=status;c.item.children??=[];}
  if(c.inserted){if(next)next.children.push(c.item);else this.model.tasks.push(c.item);this.change();}
  this.render();this.focusComposer();
 }
 closeComposer(){this.persistDraft();this.composer=null;this.render();}
 commitComposer(){
  const c=this.composer;if(!c||this.readOnly)return;if(!c.item.title.trim()){this.element.querySelector('.task-composer-error').textContent='Give this task a title.';this.focusComposer();return;}
  this.persistDraft();delete c.item.details.draft;const parent=this.lookup(c.parentID)?.item,status=this.statusOf(c.item,parent);this.composer=null;this.change(true);
  if(this.createAnother)this.openComposer(parent,status);
 }
 renderComposer(root){
  const c=this.composer,parent=this.lookup(c.parentID)?.item||null;
  if(c.mode==='docked'){const dock=el('div','task-dock');dock.append(taskIcon(parent?'subtasks':'task'),button(c.item.title||'New task','Restore task composer',()=>{c.mode='modal';this.render();this.focusComposer();},'task-dock-title'),button('','Close task composer',()=>this.closeComposer(),'task-quiet-action','close'));root.append(dock);return;}
  const overlay=el('div','task-overlay '+(c.mode==='full'?'is-full':'')),dialog=el('section','task-composer');dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label',parent?'New subtask':'New task');
  root.querySelector('.task-content').inert=true;
  const top=el('div','task-composer-top'),location=el('div','task-composer-location');location.append(taskIcon('task'),el('span','',this.model.title||'Tasks'),el('span','task-location-divider','/'),el('span','',parent?'Subtask':'Task'));
  const actions=el('div','task-composer-actions');actions.append(button('','Dock task composer',()=>{c.mode='docked';this.render();},'task-quiet-action','dock'),button('',c.mode==='full'?'Exit full page':'Expand task composer',()=>{c.mode=c.mode==='full'?'modal':'full';this.render();this.focusComposer();},'task-quiet-action',c.mode==='full'?'compress':'expand'),button('','Save draft and close',()=>this.closeComposer(),'task-quiet-action','close'));top.append(location,actions);dialog.append(top);
  const body=el('div','task-composer-body');body.append(this.textField(c.item,'title','Title','task-composer-title',()=>this.persistDraft()),this.descriptionField(c.item,()=>this.persistDraft()));
  const props=el('div','task-composer-properties');props.append(this.statusSelect(c.item,parent,status=>{if(parent)c.item.details.status=this.model.statuses[status];else c.item.status=status;this.persistDraft();}));this.addProperties(props,c.item,parent,()=>this.persistDraft(),true);body.append(props);dialog.append(body);
  const footer=el('div','task-composer-footer');footer.append(el('span','task-composer-error',''));
  footer.append(el('span','task-draft-saved','Drafts save on this Mac'));
  const another=el('label','task-create-another');another.append(this.check(this.createAnother,'Create another',v=>this.createAnother=v),el('span','','Create another'));footer.append(another,formControl(button('Create','Create task',()=>this.commitComposer(),'task-primary')));dialog.append(footer);overlay.append(dialog);root.append(overlay);
 }
 removeItem(item,parent){if(this.readOnly)return;if(parent)parent.children=parent.children.filter(c=>c!==item);else this.model.tasks=this.model.tasks.filter(t=>t!==item);this.detail=parent?.id||null;this.removeConfirm=false;this.change(true);}
 keydown(e){
  if(e.defaultPrevented)return;
  if(this.removeConfirm){if(e.key==='Escape'){e.preventDefault();this.removeConfirm=false;this.render();this.element.querySelector('[aria-label="More task actions"]')?.focus();}else if(e.key==='Tab'){const items=[...this.element.querySelectorAll('.task-remove-dialog button')];if(items.length){e.preventDefault();items[(items.indexOf(document.activeElement)+(e.shiftKey?-1:1)+items.length)%items.length].focus();}}return;}
  if(this.composer&&this.composer.mode!=='docked'){
   if(e.key==='Escape'){e.preventDefault();e.stopPropagation();this.closeComposer();return;}
   if(e.metaKey&&e.key==='Enter'){e.preventDefault();this.commitComposer();return;}
   if(e.key==='Tab'){const controls=[...this.element.querySelectorAll('.task-composer button,.task-composer input,.task-composer textarea,.task-composer select,.task-composer [contenteditable=true]')].filter(n=>!n.disabled&&n.getClientRects().length);if(!controls.length)return;const first=controls[0],last=controls.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}
  }else if(e.key==='Escape'&&(this.detail||this.goalView)){e.preventDefault();this.closeDetail();}
 }
 find(term){
  const query=term.toLowerCase();for(const {item} of walkTasks(this.model))if((item.title+'\n'+(item.details.description||'')).toLowerCase().includes(query)){this.detail=item.id;this.render();const field=[...this.element.querySelectorAll('textarea')].find(n=>n.value.toLowerCase().includes(query));if(field){field.scrollIntoView({block:'center'});field.focus();const pos=field.value.toLowerCase().indexOf(query);field.setSelectionRange(pos,pos+query.length);field.classList.add('folio-search-hit');setTimeout(()=>field.classList.remove('folio-search-hit'),2300);}else{const body=this.element.querySelector('.task-description');body?.scrollIntoView({block:'center'});body?.classList.add('folio-search-hit');setTimeout(()=>body?.classList.remove('folio-search-hit'),2300);}return true;}return false;
 }
}
