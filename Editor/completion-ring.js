import {subtaskStatus,walkTasks} from './task-model.js';

// Each saved task and subtask contributes once, regardless of which groups are
// visible. Goals summarize the same work and must not count a second time.
export function projectCompletion(model){
 const entries=walkTasks(model).filter(({item,ancestors})=>!item.details?.draft&&!ancestors.some(a=>a.details?.draft));
 const total=entries.length,done=model.statuses.indexOf(model.completed);
 const completed=entries.filter(({item,parent})=>(parent?subtaskStatus(model,item):item.status)===done).length;
 const percent=total?Math.round(completed/total*100):0;
 return {completed,total,label:total?`${percent}% complete · ${completed} of ${total} tasks and subtasks complete`:'No tasks yet'};
}

// Match the existing subtask counts: each immediate child is one step.
// Leaf tasks follow their own status, never an assumed amount of work in progress.
export function taskCompletion(model,item,parent=null){
 const children=item.children||[],done=model.statuses.indexOf(model.completed);
 const total=children.length||1;
 const completed=children.length?children.filter(child=>subtaskStatus(model,child)===done).length:Number((parent?subtaskStatus(model,item):item.status)===done);
 return {completed,total,label:children.length?`${completed} of ${total} subtasks complete`:(completed?'Completed':'Not completed')};
}

export function completionRing(completed,total,{label='Completion',decorative=false}={}){
 const fraction=Number.isFinite(completed)&&Number.isFinite(total)&&total>0?Math.max(0,Math.min(1,completed/total)):0;
 const ring=document.createElement('span');ring.className='completion-ring';ring.dataset.progress=String(fraction);ring.title=label;
 if(decorative)ring.setAttribute('aria-hidden','true');
 else{ring.setAttribute('role','progressbar');ring.setAttribute('aria-label',label);ring.setAttribute('aria-valuemin','0');ring.setAttribute('aria-valuemax','100');ring.setAttribute('aria-valuenow',String(Math.round(fraction*100)));ring.setAttribute('aria-valuetext',label);}
 const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 20 20');svg.setAttribute('aria-hidden','true');svg.setAttribute('focusable','false');
 for(const track of [true,false]){
  const circle=document.createElementNS(svg.namespaceURI,'circle');circle.setAttribute('cx','10');circle.setAttribute('cy','10');circle.setAttribute('r','8');circle.setAttribute('class',track?'completion-ring-track':'completion-ring-fill');
  if(!track){const circumference=16*Math.PI;circle.setAttribute('stroke-dasharray',String(circumference));circle.setAttribute('stroke-dashoffset',String(circumference*(1-fraction)));if(!fraction)circle.setAttribute('visibility','hidden');}
  svg.append(circle);
 }
 ring.append(svg);return ring;
}

export function taskCompletionRing(model,item,parent=null,decorative=false){
 const progress=taskCompletion(model,item,parent);return completionRing(progress.completed,progress.total,{label:progress.label,decorative});
}
