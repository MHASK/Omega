import {walkTasks,subtaskStatus} from './task-model.js';

// Coordination is stored with the original task, including inline checklists.
// Claims are issued by the native authority, never by a CRDT last-write-wins edit.
export const dependencies=item=>item?.details?.omegaDependencies||[];
export function workGraph(model){
 const entries=walkTasks(model),byID=new Map(entries.map(e=>[e.item.id,e])),remaining=new Map(),dependents=new Map();
 // Peel acyclic leaves once. Remaining nodes reach a loop; no recursive walk
 // or exponential traversal when a large plan has many shared prerequisites.
 for(const {item} of entries){const edges=dependencies(item).filter(d=>!d.path&&byID.has(d.id));remaining.set(item.id,edges.length);for(const d of edges){if(!dependents.has(d.id))dependents.set(d.id,[]);dependents.get(d.id).push(item.id);}}
 const queue=[...remaining].filter(([,n])=>n===0).map(([id])=>id);
 for(let i=0;i<queue.length;i++)for(const id of dependents.get(queue[i])||[]){remaining.set(id,remaining.get(id)-1);if(remaining.get(id)===0)queue.push(id);}
 const completed=model.statuses.indexOf(model.completed),first=model.statuses.findIndex(s=>s!==model.completed),status=e=>e.parent?subtaskStatus(model,e.item):e.item.status;
 return item=>{
  const found=byID.get(item.id),blockers=dependencies(item).filter(dep=>dep.path||!byID.has(dep.id)||status(byID.get(dep.id))!==completed),cyclic=(remaining.get(item.id)||0)>0;
  const state=!found||item.details?.draft?'draft':status(found)===completed?'done':cyclic||blockers.length||item.details?.omegaBlocker?'blocked':item.details?.omegaReview?'review':item.details?.omegaClaim?'claimed':item.details?.omegaAssignee?'assigned':status(found)!==first?'working':'ready';
  return {state,blockers,cyclic,ready:state==='ready'};
 };
}
export const workState=(model,item)=>workGraph(model)(item);
export function setDependencies(model,item,targets){
 if(targets.length>32)throw Error('A task can have up to 32 dependencies.');
 const entries=walkTasks(model),byID=new Map(entries.map(e=>[e.item.id,e.item]));
 const reaches=id=>{const queue=[id],seen=new Set();for(let i=0;i<queue.length;i++){const next=queue[i];if(next===item.id)return true;if(seen.has(next))continue;seen.add(next);for(const d of dependencies(byID.get(next)))if(!d.path)queue.push(d.id);}return false;};
 if(targets.some(t=>!t.path&&byID.has(t.id)&&reaches(t.id)))throw Error('That dependency would create a loop.');
 if(targets.length)item.details.omegaDependencies=targets.map(t=>({...t}));else delete item.details.omegaDependencies;
}
const el=(tag,cls='',text)=>{const n=document.createElement(tag);n.className=cls;if(text!==undefined)n.textContent=text;return n;};
const control=n=>{n.dataset.mutates='true';return n;};
export function priorityBadge(item){
 if(!Number.isInteger(item.details?.omegaPriority))return null;
 const badge=el('span','task-priority','P'+item.details.omegaPriority);badge.title=['Urgent','High','Normal','Low','Backlog'][item.details.omegaPriority];badge.setAttribute('aria-label','Priority '+badge.textContent+' · '+badge.title);return badge;
}
export function workBadge(view,item){
 const {state,blockers,cyclic}=(view.workGraph||workGraph(view.model))(item),owner=item.details.omegaClaim?.owner||item.details.omegaAssignee;
 if(!owner&&!['blocked','review'].includes(state))return null;
 const badge=el('span','task-work-badge '+state,cyclic?'Dependency loop':state==='blocked'?'Blocked':state==='review'?'Needs review':owner);
 badge.title=cyclic?'Remove a circular dependency':item.details.omegaBlocker|| (blockers.some(d=>d.path)?'Open the folder task view to check prerequisites from other pages.':blockers.length?`${blockers.length} unfinished or unavailable dependencies`:owner||'Ready for human review');return badge;
}
export function coordinationPanel(view,item){
 const section=el('details','task-work-panel');section.open=!!(dependencies(item).length||item.details.omegaAssignee||item.details.omegaClaim||item.details.omegaHandoff||item.details.omegaBlocker||item.details.omegaReview);
 section.append(el('summary','','Work & handoff'));
 const body=el('div','task-work-body'),save=()=>{view.touch(item);view.change(false,true);};section.append(body);
 const field=(label,key,placeholder,multiline=false,container=body)=>{
  const wrap=el('label','task-work-field');wrap.append(el('span','',label));const input=control(el(multiline?'textarea':'input'));input.value=item.details[key]||'';input.placeholder=placeholder;input.setAttribute('aria-label',label);input.maxLength=multiline?12000:200;input.rows=3;
  input.oninput=()=>{if(input.value)item.details[key]=input.value;else delete item.details[key];save();};wrap.append(input);container.append(wrap);return input;
 };
 const priority=el('label','task-work-field');priority.append(el('span','','Priority'));const choice=control(el('select'));choice.setAttribute('aria-label','Task priority');
 for(const [value,label] of [[-1,'No priority'],[0,'P0 · Urgent'],[1,'P1 · High'],[2,'P2 · Normal'],[3,'P3 · Low'],[4,'P4 · Backlog']]){const option=el('option','',label);option.value=String(value);choice.append(option);}
 choice.value=String(item.details.omegaPriority??-1);choice.onchange=()=>{const value=Number(choice.value);if(value<0)delete item.details.omegaPriority;else item.details.omegaPriority=value;save();};priority.append(choice);body.append(priority);
 const owner=field('Assigned to','omegaAssignee','Person or agent');
 field('Waiting on','omegaBlocker','Describe a blocker, if there is one');
 if(item.details.omegaClaim){owner.disabled=true;delete owner.dataset.mutates;body.append(el('p','task-work-hint',`Claimed by ${item.details.omegaClaim.owner}. Release through the coordinating Omega connection.`));}
 const deps=el('div','task-work-dependencies');deps.append(el('span','task-section-label','Blocked by'));
 for(const dep of dependencies(item)){
  const target=!dep.path&&view.lookup(dep.id)?.item,row=el('div','task-dependency-row'),open=el('button','',target?.title||(dep.path?'Open '+dep.path+' ↗':'Unavailable task · '+dep.id));open.type='button';open.disabled=!target&&!(dep.path&&view.options.open);open.title=dep.path?'Check readiness in the folder task view · '+dep.id:'';open.onclick=()=>target?view.openDetail(target):view.options.open?.(dep.path.split('/').map(encodeURIComponent).join('/')+'#folio-task-'+dep.id);row.append(open);
  const remove=control(el('button','task-dependency-remove','×'));remove.type='button';remove.setAttribute('aria-label','Remove dependency: '+(target?.title||dep.id));remove.onclick=()=>{item.details.omegaDependencies=dependencies(item).filter(d=>d!==dep);view.touch(item);view.change(true);};row.append(remove);deps.append(row);
 }
 const select=control(el('select'));select.setAttribute('aria-label','Add dependency');select.append(el('option','','Add a dependency…'));
 const entries=walkTasks(view.model).filter(e=>e.item!==item&&!e.item.details.draft&&!dependencies(item).some(d=>!d.path&&d.id===e.item.id));
 for(const {item:target} of entries){const option=el('option','',target.title||'Untitled task');option.value=target.id;select.append(option);}
 const error=el('p','task-work-error');error.setAttribute('role','alert');
 select.onchange=()=>{const target=view.lookup(select.value)?.item;if(!target)return;try{view.touch(item);view.touch(target);setDependencies(view.model,item,[...dependencies(item),{id:target.id}]);view.change(true);}catch(e){error.textContent=e.message;select.selectedIndex=0;}};
 deps.append(select,error);body.append(deps);
 field('Handoff','omegaHandoff','What changed, decisions made, tests run, and what to do next.',true);
 const execution=el('details','task-work-execution'),references=el('div','task-work-references');
 execution.open=['omegaRepository','omegaBranch','omegaSession','omegaPR'].some(k=>!!item.details[k]);execution.append(el('summary','','Code & session links'),references);body.append(execution);
 field('Repository','omegaRepository','Repository URL or local path',false,references);field('Branch','omegaBranch','Branch managed by your coding tool',false,references);field('Session','omegaSession','Session reference',false,references);field('Pull request','omegaPR','https://…',false,references);
 const review=el('label','task-work-review'),check=control(el('input'));check.type='checkbox';check.checked=!!item.details.omegaReview;check.onchange=()=>{if(check.checked)item.details.omegaReview=true;else delete item.details.omegaReview;save();};review.append(check,el('span','','Ready for human review'));body.append(review);
 body.append(el('p','task-work-hint','Your coding tool manages worktrees and execution. Omega keeps the plan and handoff here.'));
 return section;
}
