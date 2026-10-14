export const taskMarker='<!-- folio:tasks -->';
export const defaultStatuses=['To do','In progress','Done'];
const validStatus=name=>typeof name==='string'&&!!name&&name.length<=40&&name===name.trim()&&!/[\r\n<>#]/.test(name)&&name.toLowerCase()!=='goals';
let sequence=0;
export const newTaskID=()=>globalThis.crypto?.randomUUID?.()||`folio-${Date.now().toString(36)}-${++sequence}`;
const clean=text=>String(text).replace(/[\r\n]+/g,' ');
const detailKeys=new Set(['id','description','due','labels','status','draft','goals']);
export function validDetails(value,child=false){
 if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!detailKeys.has(k)))return false;
 if(value.id!==undefined&&(typeof value.id!=='string'||!/^[\w-]{1,80}$/.test(value.id)))return false;
 if(value.description!==undefined&&(typeof value.description!=='string'||value.description.length>100000))return false;
 if(value.due!==undefined&&(typeof value.due!=='string'||!/^\d{4}-\d\d-\d\d$/.test(value.due)||isNaN(Date.parse(value.due+'T12:00:00Z'))||new Date(value.due+'T12:00:00Z').toISOString().slice(0,10)!==value.due))return false;
 if(value.labels!==undefined&&(!Array.isArray(value.labels)||value.labels.length>12||value.labels.some(v=>typeof v!=='string'||!v.trim()||v.length>40||/[\r\n]/.test(v))))return false;
 if(value.goals!==undefined&&(!Array.isArray(value.goals)||value.goals.length>32||new Set(value.goals).size!==value.goals.length||value.goals.some(id=>typeof id!=='string'||!/^[\w-]{1,80}$/.test(id))))return false;
 if(value.status!==undefined&&(!child||!validStatus(value.status)))return false;
 if(value.draft!==undefined&&typeof value.draft!=='boolean')return false;
 return true;
}
export function walkTasks(model){
 const entries=[];
 const visit=(items,parent=null,ancestors=[])=>{for(const item of items){entries.push({item,parent,ancestors});visit(item.children||[],item,[...ancestors,item]);}};
 visit(model.tasks);return entries;
}
export function parseTasks(text){
 const lines=text.replace(/\r\n/g,'\n').split('\n');if(lines[0]!==taskMarker)return null;
 const model={title:'',goals:[],tasks:[],statuses:[],completed:'Done'};let section=null,target=null,titleSeen=false,legacy=0,metadataSeen=false,stack=[];
 const seen=new Set(),ids=new Set();
 for(const line of lines.slice(1)){
  if(!line.trim())continue;
  if(!titleSeen&&line.startsWith('<!-- folio:completed ')&&line.endsWith(' -->')){try{model.completed=JSON.parse(line.slice(21,-4));}catch{return null;}if(!validStatus(model.completed))return null;continue;}
  if(!titleSeen&&line.startsWith('# ')){model.title=line.slice(2);titleSeen=true;continue;}
  if(line.startsWith('## ')){section=line.slice(3);if(!titleSeen||(section!=='Goals'&&!validStatus(section))||seen.has(section.toLowerCase()))return null;seen.add(section.toLowerCase());if(section!=='Goals')model.statuses.push(section);stack=[];target=null;continue;}
  const meta=line.match(/^( +)<!-- folio:task (.*) -->$/);
  if(meta){
   if(!target||metadataSeen||meta[1].length!==(target.depth+1)*2)return null;
   let details;try{details=JSON.parse(meta[2]);}catch{return null;}
   // Outside editors may write an explicit status on a main task too.
   // Resolve it after all section names are known; goals still have no status.
   if(!validDetails(details,target.depth>0||section!=='Goals')||details.id&&ids.has(details.id))return null;
   if(details.id){ids.add(details.id);target.item.id=details.id;}
   target.item.details=details;metadataSeen=true;continue;
  }
  const match=line.match(/^( *)- \[([ xX])\](?: (.*))?$/);if(!titleSeen||!section||!match||match[1].length%2)return null;
  const depth=match[1].length/2;if(depth>32)return null;
  const item={id:`legacy-${++legacy}`,title:match[3]||'',done:match[2]!==' ',details:{},children:[]};metadataSeen=false;
  if(depth){if(section==='Goals'||!stack[depth-1])return null;stack[depth-1].children.push(item);}
  else if(section==='Goals')model.goals.push(item);
  else{item.status=model.statuses.indexOf(section);model.tasks.push(item);}
  stack.length=depth;stack.push(item);target={item,depth};
 }
 if(!model.statuses.length)model.statuses=[...defaultStatuses];
 if(!model.statuses.includes(model.completed))model.statuses.push(model.completed);
 if(model.statuses.length>12||!titleSeen)return null;
 for(const {item,parent} of walkTasks(model))if(parent&&item.details.status&&!model.statuses.includes(item.details.status))return null;
 for(const item of model.tasks)if(item.details.status!==undefined){
  const status=model.statuses.indexOf(item.details.status);if(status<0)return null;
  item.status=status;item.done=item.details.status===model.completed;delete item.details.status;
 }
 return model;
}
export function subtaskStatus(model,child){return model.statuses.indexOf(child.details?.status||(child.done?model.completed:model.statuses.find(s=>s!==model.completed)||model.completed));}
// Move the same object and subtree; never rebuild a task from visible fields.
export function reparentTask(model,id,parentID=null){
 const entries=walkTasks(model),found=entries.find(e=>e.item.id===id),next=parentID?entries.find(e=>e.item.id===parentID):null;
 if(!found||parentID&&!next||next&&(next.item===found.item||next.ancestors.includes(found.item)||next.item.details.draft))return false;
 if((found.parent?.id||null)===(parentID||null))return false;
 const height=item=>1+Math.max(0,...(item.children||[]).map(height));
 if((next?next.ancestors.length+1:0)+height(found.item)>33)return false;
 const status=found.parent?subtaskStatus(model,found.item):found.item.status;
 const previous=found.parent?found.parent.children:model.tasks;
 previous.splice(previous.indexOf(found.item),1);
 if(!found.item.details.id){found.item.id=newTaskID();found.item.details.id=found.item.id;}
 found.item.done=status===model.statuses.indexOf(model.completed);
 if(next){found.item.details.status=model.statuses[status];next.item.children.push(found.item);delete found.item.status;}
 else{delete found.item.details.status;found.item.status=status;model.tasks.push(found.item);}
 return found.item;
}
export function serializeTasks(model){
 const check=(item,done=item.done)=>`- [${done?'x':' '}] ${clean(item.title)}`;
 const metadata=(item,depth)=>{
  const details={...item.details};if(!Object.keys(details).length)return '';
  const json=JSON.stringify(details).replace(/</g,'\\u003c').replace(/>/g,'\\u003e');
  return '\n'+'  '.repeat(depth+1)+'<!-- folio:task '+json+' -->';
 };
 const row=(item,depth,status)=>'  '.repeat(depth)+check(item,status===model.statuses.indexOf(model.completed))+metadata(item,depth)+(item.children||[]).map(child=>'\n'+row(child,depth+1,subtaskStatus(model,child))).join('');
 let text=taskMarker+'\n'+(model.completed!=='Done'?'<!-- folio:completed '+JSON.stringify(model.completed)+' -->\n':'')+'# '+clean(model.title)+'\n\n## Goals\n\n';
 text+=model.goals.map(item=>check(item,goalProgress(model,item).done)+metadata(item,0)).join('\n');
 model.statuses.forEach((status,index)=>{text+='\n\n## '+status+'\n\n';text+=model.tasks.filter(task=>task.status===index).map(task=>row(task,0,index)).join('\n');});
 return text.trimEnd()+'\n';
}

// A goal measures its explicitly linked tasks and subtasks. Status is the source
// of truth; linking a parent never silently completes or links its descendants.
export function goalProgress(model,goal){
 const entries=walkTasks(model).filter(({item})=>goal.details.id&&(item.details.goals||[]).includes(goal.details.id));
 const completed=entries.filter(({item,parent})=>(parent?subtaskStatus(model,item):item.status)===model.statuses.indexOf(model.completed)).length;
 return {entries,total:entries.length,completed,done:entries.length?completed===entries.length:goal.done};
}
export function linkGoal(model,item,goal,linked){
 if(!model.goals.includes(goal))return false;
 if(linked&&!goal.details.id){goal.id=newTaskID();goal.details.id=goal.id;}
 const ids=new Set(item.details.goals||[]),id=goal.details.id;
 if(linked){if(ids.size>=32&&!ids.has(id))return false;ids.add(id);}else ids.delete(id);
 if(!item.details.id){item.id=newTaskID();item.details.id=item.id;}
 if(ids.size)item.details.goals=[...ids];else delete item.details.goals;
 return true;
}
export function removeGoal(model,goal){
 model.goals=model.goals.filter(g=>g!==goal);
 for(const {item} of walkTasks(model))if(item.details.goals?.includes(goal.details.id)){
  item.details.goals=item.details.goals.filter(id=>id!==goal.details.id);
  if(!item.details.goals.length)delete item.details.goals;
 }
}
