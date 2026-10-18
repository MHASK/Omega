export const taskMarker='<!-- folio:tasks -->';
export const defaultStatuses=['To do','In progress','Done'];
const validStatus=name=>typeof name==='string'&&!!name&&name.length<=40&&name===name.trim()&&!/[\r\n<>#]/.test(name)&&name.toLowerCase()!=='goals';
let sequence=0;
export const newTaskID=()=>globalThis.crypto?.randomUUID?.()||`folio-${Date.now().toString(36)}-${++sequence}`;
const clean=text=>String(text).replace(/[\r\n]+/g,' ');
export const detailKeys=new Set(['id','description','due','labels','status','draft','goals']);
// Extra metadata belongs to the file, even when Omega has no control for it.
// Bound nesting and numeric precision so both desktop readers preserve it.
export function validJSON(value,depth=0){
 if(depth>16)return false;
 if(value===null||typeof value==='string'||typeof value==='boolean')return true;
 if(typeof value==='number')return Number.isFinite(value)&&(!Number.isInteger(value)||Number.isSafeInteger(value));
 if(Array.isArray(value))return value.every(v=>validJSON(v,depth+1));
 return !!value&&typeof value==='object'&&Object.values(value).every(v=>validJSON(v,depth+1));
}
export function uniqueJSONKeys(json){
 const tokens=json.match(/"(?:\\.|[^"\\])*"|[{}\[\]:,]/g)||[],stack=[];
 for(let i=0;i<tokens.length;i++){
  const token=tokens[i];
  if(token==='{')stack.push(new Set());else if(token==='[')stack.push(null);
  else if(token==='}'||token===']')stack.pop();
  else if(token[0]==='"'&&tokens[i+1]===':'&&stack.at(-1)){
   const key=JSON.parse(token);if(stack.at(-1).has(key))return false;stack.at(-1).add(key);
  }
 }
 return true;
}
export const isTaskDocument=text=>text.replace(/^\uFEFF/,'').trimStart().startsWith(taskMarker);
export function taskImport(text){
 let lineNumber=1;
 const fail=message=>({model:null,issue:{line:lineNumber,message}});
 try{return parseTaskDocument(text,fail,n=>lineNumber=n);}catch{return fail('The task metadata could not be read. The original file is preserved.');}
}
export function parseTasks(text){return taskImport(text).model;}
export function validDetails(value,child=false){
 if(!value||typeof value!=='object'||Array.isArray(value)||!validJSON(value))return false;
 if(value.id!==undefined&&(typeof value.id!=='string'||!/^[\w-]{1,80}$/.test(value.id)))return false;
 if(value.description!==undefined&&(typeof value.description!=='string'||value.description.length>100000))return false;
 if(value.due!==undefined&&(typeof value.due!=='string'||!/^\d{4}-\d\d-\d\d$/.test(value.due)||isNaN(Date.parse(value.due+'T12:00:00Z'))||new Date(value.due+'T12:00:00Z').toISOString().slice(0,10)!==value.due))return false;
 if(value.labels!==undefined&&(!Array.isArray(value.labels)||value.labels.length>12||value.labels.some(v=>typeof v!=='string'||!v.trim()||v.length>40||/[\r\n]/.test(v))))return false;
 if(value.goals!==undefined&&(!Array.isArray(value.goals)||value.goals.length>32||new Set(value.goals).size!==value.goals.length||value.goals.some(id=>typeof id!=='string'||!/^[\w-]{1,80}$/.test(id))))return false;
 if(value.status!==undefined&&(!child||!validStatus(value.status)))return false;
 if(value.draft!==undefined&&typeof value.draft!=='boolean')return false;
 for(const key of ['omegaAssignee','omegaBlocker','omegaHandoff','omegaRepository','omegaBranch','omegaSession','omegaPR'])if(value[key]!==undefined&&(typeof value[key]!=='string'||value[key].length>(key==='omegaHandoff'?12000:200)||value[key].includes('\0')))return false;
 if(value.omegaReview!==undefined&&typeof value.omegaReview!=='boolean')return false;
 if(value.omegaClaim!==undefined&&(!value.omegaClaim||typeof value.omegaClaim!=='object'||['owner','token','at'].some(k=>typeof value.omegaClaim[k]!=='string'||!value.omegaClaim[k]||value.omegaClaim[k].length>200||value.omegaClaim[k].includes('\0'))))return false;
 if(value.omegaDependencies!==undefined){const ds=value.omegaDependencies;if(!Array.isArray(ds)||ds.length>32||ds.some(d=>!d||typeof d!=='object'||Object.keys(d).some(k=>!['id','path'].includes(k))||typeof d.id!=='string'||! /^[\w-]{1,80}$/.test(d.id)||d.path!==undefined&&(typeof d.path!=='string'||d.path.length>2000||d.path.startsWith('/')||/[\\\0]/.test(d.path)))||new Set(ds.map(d=>(d.path||'')+'#'+d.id)).size!==ds.length)return false;}

 return true;
}
export function walkTasks(model){
 const entries=[];
 const visit=(items,parent=null,ancestors=[])=>{for(const item of items){entries.push({item,parent,ancestors});visit(item.children||[],item,[...ancestors,item]);}};
 visit(model.tasks);return entries;
}
function parseTaskDocument(text,fail,setLine){
 const lines=text.replace(/^\uFEFF/,'').replace(/\r\n?/g,'\n').split('\n');
 let first=lines.findIndex(line=>line.trim());if(first<0||lines[first].trim()!==taskMarker)return fail('This note is not a task page.');
 const model={title:'',goals:[],tasks:[],statuses:[],completed:'Done'};let section=null,target=null,titleSeen=false,legacy=0,metadataSeen=false,stack=[];
 const seen=new Set(),ids=new Set();
 for(let index=first+1;index<lines.length;index++){
  setLine(index+1);let line=lines[index];if(!line.trim())continue;
  if(!titleSeen&&line.startsWith('<!-- folio:completed ')&&line.trimEnd().endsWith(' -->')){try{model.completed=JSON.parse(line.trimEnd().slice(21,-4));}catch{return fail('The completed status must be a quoted name.');}if(!validStatus(model.completed))return fail('The completed status name is invalid.');continue;}
  if(!titleSeen&&line.startsWith('# ')){model.title=line.slice(2);titleSeen=true;continue;}
  if(line.startsWith('## ')){section=line.slice(3);if(!titleSeen)return fail('Add the page title before its sections.');if(section!=='Goals'&&!validStatus(section))return fail('Use a valid status name for this section.');if(seen.has(section.toLowerCase()))return fail('This section name is repeated.');seen.add(section.toLowerCase());if(section!=='Goals')model.statuses.push(section);stack=[];target=null;continue;}
  if(/^ *<!-- folio:task(?:\s|$)/.test(line)){
   const spaces=line.match(/^ */)[0].length;
   if(!target||metadataSeen||spaces!==(target.depth+1)*2)return fail('Place one metadata record directly below its task, indented two more spaces.');
   while(!line.trimEnd().endsWith('-->')&&index+1<lines.length){line+='\n'+lines[++index];if(line.length>131072)return fail('This metadata record is too large.');}
   const meta=line.trimEnd().match(/^ *<!-- folio:task\s+([\s\S]*?)\s*-->$/);
   if(!meta||line.length>131072)return fail('Finish the task metadata with a closing -->.');
   if(!uniqueJSONKeys(meta[1]))return fail('This metadata repeats a JSON field. Keep one value for each field.');
   let details;try{details=JSON.parse(meta[1]);}catch{return fail('This task has incomplete or invalid JSON metadata.');}
   if(details&&typeof details==='object'&&!Array.isArray(details))for(const key of detailKeys)if(details[key]===null)delete details[key];
   if(!validDetails(details,true))return fail('Check the task metadata: field types, dates, IDs, labels, and status names must be valid.');
   if(details.id&&ids.has(details.id))return fail('Two items use the same task ID. Give each item a different ID.');
   if(details.id){ids.add(details.id);target.item.id=details.id;}
   target.item.details=details;metadataSeen=true;continue;
  }
  const match=line.match(/^( *)[-*+] \[([ xX])\](?: (.*))?$/);
  if(!titleSeen)return fail('Add a title beginning with # before the tasks.');
  if(!section)return fail('Place tasks under a status heading beginning with ##.');
  if(!match)return fail('This line is outside the task format. Keep prose in a task description, or edit the original Markdown.');
  if(match[1].length%2||match[1].length/2>32)return fail('Indent subtasks by two spaces per level, up to 32 levels.');
  const depth=match[1].length/2;
  const item={id:`legacy-${++legacy}`,title:match[3]||'',done:match[2]!==' ',details:{},children:[]};metadataSeen=false;
  if(depth){if(section==='Goals'||!stack[depth-1])return fail('A subtask must follow its parent task.');stack[depth-1].children.push(item);}
  else if(section==='Goals')model.goals.push(item);
  else{item.status=model.statuses.indexOf(section);model.tasks.push(item);}
  stack.length=depth;stack.push(item);target={item,depth};
 }
 if(!titleSeen)return fail('Add a title beginning with # before the tasks.');
 if(!model.statuses.length)model.statuses=[...defaultStatuses];
 if(!model.statuses.includes(model.completed))model.statuses.push(model.completed);
 for(const {item} of walkTasks(model))if(item.details.status&&!model.statuses.includes(item.details.status))model.statuses.push(item.details.status);
 if(model.statuses.length>12||new Set(model.statuses.map(s=>s.toLowerCase())).size!==model.statuses.length)return fail('Use at most 12 status names, with no names differing only in capitalization.');
 for(const item of model.tasks)if(item.details.status!==undefined){
  item.status=model.statuses.indexOf(item.details.status);item.done=item.details.status===model.completed;delete item.details.status;
 }
 // Temporary UI identities must never collide with a real externally assigned ID.
 for(const item of [...model.goals,...walkTasks(model).map(e=>e.item)])if(!item.details.id){let id=item.id;while(ids.has(id))id=`legacy-${++legacy}`;item.id=id;ids.add(id);}
 return {model,issue:null};
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
