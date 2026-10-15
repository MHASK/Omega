import {isTaskDocument,taskImport,parseTasks} from './task-model.js';
import {needsSource} from './schema.js';

// Diagnostics never repair or rewrite the source. An outside editor owns its
// bytes until a user deliberately changes them in Omega.
export function importIssue(text){
 if(isTaskDocument(text))return taskImport(text).issue;
 if(needsSource(text)){
  const message=/^---\r?\n/.test(text)?'This note has front matter that the visual editor cannot edit yet.':
   /^\s*\[\^[^\]]+\]:/m.test(text)?'This note uses footnotes that the visual editor cannot edit yet.':
   'This note contains extended Markdown or an unfinished HTML record that the visual editor cannot safely edit.';
  return {message};
 }
 return null;
}
export function tableIssue(text){
 let fenced=null,inTable=false;
 const lines=text.split(/\r?\n/);
 for(let i=0;i<lines.length;i++){
  const line=lines[i],fence=line.match(/^ {0,3}(`{3,}|~{3,})/);
  if(fence){if(!fenced)fenced=fence[1][0];else if(fenced===fence[1][0])fenced=null;inTable=false;continue;}
  if(fenced||/^ {4}|^\t/.test(line))continue;
  if(/^\s*\|?\s*:?-{3,}:?\s*\|(?:\s*:?-{3,}:?\s*\|?)+\s*$/.test(lines[i+1]||'')){inTable=true;i++;continue;}
  const row=/^\s*\|.*\|\s*$/.test(line)&&(line.match(/(?<!\\)\|/g)||[]).length>=3;
  if(row&&!inTable)return {line:i+1,message:'A table row is separated from its table. It is shown as text so none of its contents are lost.',warning:true};
  if(!row)inTable=false;
 }
 return null;
}

// Two valid edits must not produce an invalid combined document. Keep both
// versions for review if their combination breaks structure or identities.
export function safeCombinedImport(base,local,incoming,merged){
 if(local===base||incoming===base||local===incoming)return true;
 if(parseTasks(local)&&parseTasks(incoming)&&!parseTasks(merged))return false;
 if(!importIssue(local)&&!importIssue(incoming)&&importIssue(merged))return false;
 if(!tableIssue(local)&&!tableIssue(incoming)&&tableIssue(merged))return false;
 return true;
}
