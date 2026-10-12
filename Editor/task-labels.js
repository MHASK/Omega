// Display-only styling: stored label names remain unchanged.
let colors = new Map();
const key = name => String(name).trim().toLowerCase();
export function configureLabelColors(value){
 colors=new Map(Object.entries(value||{}).filter(([,tone])=>Number.isInteger(tone)&&tone>=0&&tone<7).map(([name,tone])=>[key(name),tone]));
 for(const node of document.querySelectorAll("[data-label-name]"))applyLabelTone(node,node.dataset.labelName);
}
export function labelTone(name){
 if(colors.has(key(name)))return String(colors.get(key(name)));
 const value=String(name).trim().toLowerCase();let hash=2166136261;
 for(const char of value){hash^=char.codePointAt(0);hash=Math.imul(hash,16777619);}
 return String((hash>>>0)%7);
}
export function applyLabelTone(element,name){
 if(name){element.dataset.labelTone=labelTone(name);element.dataset.labelName=name;}else{delete element.dataset.labelTone;delete element.dataset.labelName;}
 return element;
}
export function labelChip(name){
 const chip=document.createElement('span');chip.className='task-label';chip.textContent=name;chip.title=name;
 return applyLabelTone(chip,name);
}
