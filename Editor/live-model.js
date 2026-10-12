import * as Y from 'yjs';
import {diffChars} from 'diff';
import {parseTasks,serializeTasks,walkTasks,subtaskStatus} from './task-model.js';
export {Y};
export const localOrigin=Object.freeze({local:true});
export const remoteOrigin=Object.freeze({remote:true});
export const encode=bytes=>{let text='';for(let i=0;i<bytes.length;i+=8192)text+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(text);};
export const decode=text=>Uint8Array.from(atob(text),c=>c.charCodeAt(0));
export function changeText(text,value){let at=0;for(const part of diffChars(text.toString(),value)){if(part.removed)text.delete(at,part.value.length);else{if(part.added)text.insert(at,part.value);at+=part.value.length;}}}
const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
function flatten(model){
 const items=new Map();
 for(const {item,parent} of [...model.goals.map(item=>({item,parent:null,goal:true})),...walkTasks(model)]){
  const goal=model.goals.includes(item),siblings=goal?model.goals:parent?.children||model.tasks;
  items.set(item.id,{title:item.title,description:item.details.description||'',labels:item.details.labels||[],goals:item.details.goals||[],due:item.details.due||'',draft:!!item.details.draft,done:item.done,goal,parent:parent?.id||'',order:siblings.indexOf(item),status:goal?'':model.statuses[parent?subtaskStatus(model,item):item.status]});
 }return items;
}
export function updateTasks(doc,next,previous){
 const meta=doc.getMap('meta'),items=doc.getMap('items'),before=previous?flatten(previous):new Map(),after=flatten(next);
 doc.transact(()=>{
  if(!previous||next.title!==previous.title)changeText(doc.getText('title'),next.title);
  for(const key of ['statuses','completed'])if(!previous||!equal(next[key],previous[key]))meta.set(key,next[key]);
  for(const [id,data] of after){
   let item=items.get(id);if(!item){item=new Y.Map();items.set(id,item);}const prior=before.get(id);
   if(!prior)item.set('deleted',false);
   for(const [key,value] of Object.entries(data)){
    if(prior&&equal(prior[key],value))continue;
    if(['title','description'].includes(key)){if(!item.has(key))item.set(key,new Y.Text());changeText(item.get(key),value);}
    else if(['labels','goals'].includes(key)){if(!item.has(key))item.set(key,new Y.Map());const set=item.get(key);for(const v of prior?.[key]||[])if(!value.includes(v))set.delete(v);for(const v of value)if(!prior?.[key]?.includes(v))set.set(v,true);}
    else item.set(key,value);
   }
  }
  for(const id of before.keys())if(!after.has(id))items.get(id)?.set('deleted',true);
 },localOrigin);
}
export function readTasks(doc){
 const meta=doc.getMap('meta'),entries=[...doc.getMap('items')].filter(([,item])=>!item.get('deleted')).sort(([a,x],[b,y])=>(x.get('order')||0)-(y.get('order')||0)||a.localeCompare(b));
 const statuses=[...(meta.get('statuses')||['To do','In progress','Done'])],completed=meta.get('completed')||'Done';
 for(const [,v] of entries){const s=v.get('status');if(s&&!statuses.includes(s))statuses.push(s);}if(!statuses.includes(completed))statuses.push(completed);
 const model={title:doc.getText('title').toString(),statuses,completed,goals:[],tasks:[]},byID=new Map();
 for(const [id,v] of entries){
  const details={id},description=v.get('description')?.toString()||'';if(description)details.description=description;
  for(const key of ['labels','goals']){const values=[...(v.get(key)?.keys()||[])].sort();if(values.length)details[key]=values.slice(0,key==='labels'?12:32);}
  if(v.get('due'))details.due=v.get('due');if(v.get('draft'))details.draft=true;
  byID.set(id,{id,title:v.get('title')?.toString()||'',done:!!v.get('done'),details,children:[],status:Math.max(0,statuses.indexOf(v.get('status')))});
 }
 const records=new Map(entries);
 for(const [id,v] of entries){
  const item=byID.get(id);if(v.get('goal')){model.goals.push(item);continue;}
  let parent=v.get('parent'),cursor=parent,seen=new Set([id]),depth=0;
  while(cursor){if(seen.has(cursor)||++depth>32){parent='';break;}seen.add(cursor);cursor=records.get(cursor)?.get('parent');}
  if(parent&&byID.has(parent)&&!records.get(parent).get('goal')){item.details.status=statuses[item.status];byID.get(parent).children.push(item);delete item.status;}
  else model.tasks.push(item);
 }
 return model;
}
export function seedModel(text,kind){const doc=new Y.Doc({gc:false});doc.getMap('meta').set('version',1);doc.getMap('meta').set('lineage',crypto.randomUUID());doc.getMap('meta').set('kind',kind);if(kind==='tasks')updateTasks(doc,parseTasks(text));else if(kind==='source')doc.getText('source').insert(0,text);return doc;}
export const taskText=doc=>serializeTasks(readTasks(doc));
