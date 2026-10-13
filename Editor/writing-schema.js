import {Mark,Node} from '@tiptap/core';

export const writingColors = [
 ['gray','Gray','#6f747b','#b0b4ba'],['brown','Brown','#976b4f','#cba78c'],
 ['orange','Orange','#ad671f','#e5b477'],['yellow','Yellow','#8e741a','#e1cd83'],
 ['green','Green','#3e805e','#9ec8b0'],['blue','Blue','#387da6','#97c3de'],
 ['purple','Purple','#8260a1','#c2abd9'],['pink','Pink','#a2597c','#d9a6bc'],
 ['red','Red','#af5956','#dfa4a0'],
];
export const colorNames = new Set(writingColors.map(c=>c[0]));
const validID = s => typeof s==='string' && /^[a-zA-Z0-9-]{1,80}$/.test(s);
export function encodeRecord(data){return btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(data)))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');}
export function decodeRecord(raw){
 try{return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(raw.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0))));}catch{return null;}
}
export function validComment(c){return c&&validID(c.id)&&validID(c.thread)&&typeof c.body==='string'&&c.body.length<=12000&&typeof c.author==='string'&&c.author.length<=120&&typeof c.quote==='string'&&c.quote.length<=2000&&typeof c.created==='string'&&typeof c.resolved==='boolean';}

// Delimited inline HTML keeps ordinary Markdown content readable in other apps.
// Only our exact, allowlisted attributes enter visual mode; other HTML continues
// to use Omega's lossless source editor. Balanced tags support nested styling.
function inlineToken(src,tag,opening,name,lexer){
 const match=src.match(opening);if(!match)return;
 const tags=new RegExp(`<\\/?${tag}(?:\\s[^>]*|\\s*)>`,'g');tags.lastIndex=match[0].length;let depth=1,next;
 while((next=tags.exec(src))){depth+=next[0].startsWith('</')?-1:1;if(!depth){const text=src.slice(match[0].length,next.index);return {type:name,raw:src.slice(0,tags.lastIndex),value:match[1]||null,tokens:lexer.inlineTokens(text)};}}
}
function styledMark(name,tag,attribute){
 const opening=attribute?new RegExp(`^<${tag} ${attribute}="([a-zA-Z0-9-]+)">`):new RegExp(`^<${tag}>`);
 return Mark.create({name,inclusive:name!=='commentAnchor',excludes:name,
  addAttributes(){return attribute?{value:{default:null,parseHTML:el=>el.getAttribute(attribute)}}:{};},
  parseHTML(){return [{tag:attribute?`${tag}[${attribute}]`:tag,getAttrs:el=>!attribute|| (name==='commentAnchor'?validID(el.getAttribute(attribute)):colorNames.has(el.getAttribute(attribute)))?null:false}];},
  renderHTML({mark}){return [tag,attribute?{[attribute]:mark.attrs.value}:{},0];},
  markdownTokenName:name,
  markdownTokenizer:{name,level:'inline',start:`<${tag}`,tokenize(src,_tokens,lexer){const t=inlineToken(src,tag,opening,name,lexer);if(t&&(!attribute||(name==='commentAnchor'?validID(t.value):colorNames.has(t.value))))return t;}},
  parseMarkdown(token,h){return h.applyMark(name,h.parseInline(token.tokens||[]),attribute?{value:token.value}:{});},
  renderMarkdown(node,h){return `<${tag}${attribute?' '+attribute+'="'+node.attrs.value+'"':''}>${h.renderChildren(node)}</${tag}>`;},
 });
}
export const TextColor=styledMark('textColor','span','data-omega-color');
export const Highlight=styledMark('highlight','mark','data-omega-highlight');
export const Underline=styledMark('underline','u',null).extend({addKeyboardShortcuts(){return {'Mod-u':()=>this.editor.commands.toggleMark('underline')};}});
export const CommentAnchor=styledMark('commentAnchor','span','data-omega-comment');
export const CommentRecord=Node.create({
 name:'commentRecord',group:'block',atom:true,selectable:false,draggable:false,
 addAttributes(){return {record:{default:null}};},
 parseHTML(){return [];},
 renderHTML({node}){return ['div',{'data-comment-record':node.attrs.record?.id,hidden:'',contenteditable:'false'}];},
 markdownTokenName:'commentRecord',
 markdownTokenizer:{name:'commentRecord',level:'block',start:'<!-- omega-comment:',tokenize(src){const m=src.match(/^<!-- omega-comment:([A-Za-z0-9_-]+) -->[ \t]*(?:\n|$)/);const record=m&&decodeRecord(m[1]);if(validComment(record))return {type:'commentRecord',raw:m[0],record};}},
 parseMarkdown(token){return {type:'commentRecord',attrs:{record:token.record}};},
 renderMarkdown(node){return `<!-- omega-comment:${encodeRecord(node.attrs.record)} -->`;},
});
// Leave malformed metadata in source mode instead of dropping it on the next edit.
export function withoutWritingMarkup(markdown){
 const clean=markdown.replace(/<!-- omega-comment:([A-Za-z0-9_-]+) -->/g,(full,raw)=>validComment(decodeRecord(raw))?'':full);
 const tokens=/<\/?(?:span|mark|u)\b[^>]*>/g,stack=[],remove=[];let m;
 while((m=tokens.exec(clean))){
  const tag=m[0].match(/^<\/?(\w+)/)[1];
  if(m[0]===`</${tag}>`){const open=stack.pop();if(!open||open.tag!==tag)return clean;remove.push([open.start,open.end],[m.index,tokens.lastIndex]);}
  else {
   const color=m[0].match(/^<span data-omega-color="([a-z]+)">$/),highlight=m[0].match(/^<mark data-omega-highlight="([a-z]+)">$/),comment=m[0].match(/^<span data-omega-comment="([a-zA-Z0-9-]+)">$/);
   if(!(m[0]==='<u>'||color&&colorNames.has(color[1])||highlight&&colorNames.has(highlight[1])||comment&&validID(comment[1])))return clean;
   stack.push({tag,start:m.index,end:tokens.lastIndex});
  }
 }
 if(stack.length)return clean;
 let result=clean;for(const [from,to] of remove.sort((a,b)=>b[0]-a[0]))result=result.slice(0,from)+result.slice(to);return result;
}
export function commentRecords(doc){const result=[];doc?.descendants((node,pos)=>{if(node.type.name==='commentRecord'&&validComment(node.attrs.record))result.push({record:node.attrs.record,pos,node});});return result;}
export function commentRange(doc,id){let from=null,to=null;doc.descendants((node,pos)=>{if(node.isText&&node.marks.some(m=>m.type.name==='commentAnchor'&&m.attrs.value===id)){from??=pos;to=pos+node.nodeSize;}});return from===null?null:{from,to};}
export function addComment(editor,{range,body,author,thread}){
 if(!editor?.isEditable||!body.trim()||body.length>12000)return false;
 const id=crypto.randomUUID(),quote=thread?'':editor.state.doc.textBetween(range.from,range.to,' ').slice(0,2000);
 const record={id,thread:thread||id,body:body.trim(),author:author.slice(0,120),created:new Date().toISOString(),quote,resolved:false};
 let tr=editor.state.tr;
 if(!thread&&range.from<range.to)tr=tr.addMark(range.from,range.to,editor.schema.marks.commentAnchor.create({value:id}));
 tr=tr.insert(tr.doc.content.size,editor.schema.nodes.commentRecord.create({record}));
 editor.view.dispatch(tr);return id;
}
export function resolveComment(editor,id,resolved){
 const item=commentRecords(editor.state.doc).find(x=>x.record.id===id);if(!item||!editor.isEditable)return false;
 editor.view.dispatch(editor.state.tr.setNodeMarkup(item.pos,undefined,{record:{...item.record,resolved}}));return true;
}
