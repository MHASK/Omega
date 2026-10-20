// One bounded, read-only decimal evaluator for the editor and native/MCP host.
// Formula text is data: never eval, execute HTML, fetch a URL or write a note.
import Decimal from 'decimal.js';
import {marked} from 'marked';
const D=Decimal.clone({precision:40,rounding:Decimal.ROUND_HALF_UP,toExpNeg:-20,toExpPos:40});
class FormulaError extends Error { constructor(code,message){super(message);this.code=code;} }
const fail=(code,message)=>{throw new FormulaError(code,message);};
const ref=message=>fail('#REF!',message);
function plain(tokens=[]){return tokens.map(t=>t.type==='image'?t.text:t.tokens?plain(t.tokens):t.text??t.raw??'').join('').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'").trim();}
function cellText(cell){const t=cell.tokens||[];return t.length===1&&t[0].type==='codespan'?t[0].text:cell.text.trim().startsWith('=')?cell.text.trim():plain(t);}
export function parseTables(markdown){
 if(typeof markdown!=='string'||markdown.length>2_000_000)fail('#LIMIT!','A formula source must be at most 2 MB.');
 let heading='',cells=0;const tables=[];
 for(const token of marked.lexer(markdown,{gfm:true})){
  if(token.type==='heading')heading=plain(token.tokens);
  if(token.type!=='table')continue;
  const rows=[token.header,...token.rows].map(row=>row.map(cellText));cells+=rows.length*rows[0].length;
  if(cells>10000||tables.length>=100)fail('#LIMIT!','A formula page supports at most 100 tables and 10,000 cells.');
  tables.push({index:tables.length+1,name:heading,rows});
 }
 return tables;
}
function address(raw){const m=String(raw).match(/^\$?([A-Z]{1,3})\$?([1-9]\d{0,4})$/i);if(!m)return null;let c=0;for(const ch of m[1].toUpperCase())c=c*26+ch.charCodeAt(0)-64;return {r:Number(m[2])-1,c:c-1};}
export function columnName(c){let s='';for(c++;c>0;c=Math.floor((c-1)/26))s=String.fromCharCode(65+(c-1)%26)+s;return s;}
function number(value){
 if(value instanceof D)return value;
 if(value==null||value==='')return fail('#VALUE!','This cell is empty. Use a number, or an aggregate that skips empty cells.');
 const raw=String(value).trim();
 const m=raw.match(/^([+-]?)\s*[$€£₹¥]?\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)([eE][+-]?\d{1,3})?(%)?$/);
 if(!m)fail('#VALUE!',`Expected a number; found “${raw.slice(0,60)}”. Text and currencies are never silently converted.`);
 const n=new D(m[1]+m[2].replace(/,/g,'')+(m[3]||''));return bounded(m[4]?n.div(100):n);
}
function bounded(n){if(!n.isFinite()||Math.abs(n.e)>100)fail('#NUM!','The result is outside the supported numeric range.');return n;}
function tokenize(raw){
 if(raw.length>4096)fail('#LIMIT!','Formula exceeds 4,096 characters.');
 const tokens=[];let rest=raw.trim().replace(/^=/,'');
 while(rest.length){
  const space=rest.match(/^\s+/);if(space){rest=rest.slice(space[0].length);continue;}
  const m=rest.match(/^(?:"(?:[^"\\]|\\["\\nrt])*"|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|\$?[A-Za-z_][A-Za-z_0-9$]*|<=|>=|<>|!=|==|[+\-*/^%(),:<> =])/);
  if(!m)fail('#SYNTAX!',`Unexpected character near “${rest.slice(0,30)}”.`);
  tokens.push(m[0]);rest=rest.slice(m[0].length);if(tokens.length>1024)fail('#LIMIT!','Formula is too complex.');
 }
 let i=0,depth=0;const peek=()=>tokens[i],take=()=>tokens[i++];
 function expr(min=0){
  if(++depth>64)fail('#LIMIT!','Formula nesting is too deep.');
  let token=take(),node;
  if(token==='+'||token==='-')node={op:'unary',sign:token,arg:expr(4)};
  else if(token==='('){node=expr();if(take()!==')')fail('#SYNTAX!','Expected a closing parenthesis.');}
  else if(token?.startsWith('"')){try{node={op:'literal',value:JSON.parse(token)};}catch{fail('#SYNTAX!','Invalid quoted string.');}}
  else if(token&&/^(?:\d|\.\d)/.test(token))node={op:'number',value:token};
  else if(token&&/^[A-Za-z_$]/.test(token)){
   if(peek()==='('){take();const args=[];if(peek()!==')'){do{args.push(expr());if(peek()!==',')break;take();}while(true);}if(take()!==')')fail('#SYNTAX!','Expected a comma or closing parenthesis.');node={op:'call',name:token.toUpperCase(),args};}
   else if(address(token)){node={op:'cell',value:token};if(peek()===':'){take();const end=take();if(!address(end))fail('#SYNTAX!','A range needs two cell addresses.');node={op:'range',value:token+':'+end};}}
   else fail('#NAME!',`Unknown name “${token}”.`);
  }else fail('#SYNTAX!','Expected a number, cell, or function.');
  while(i<tokens.length){
   const op=peek();if(op==='%'){take();node={op:'percent',arg:node};continue;}
   const power=({'=':1,'==':1,'!=':1,'<>':1,'<':1,'>':1,'<=':1,'>=':1,'+':2,'-':2,'*':3,'/':3,'^':4})[op];
   if(power===undefined||power<min)break;take();node={op,left:node,right:expr(power+(op==='^'?0:1))};
  }
  depth--;return node;
 }
 const ast=expr();if(i!==tokens.length)fail('#SYNTAX!','Unexpected text after the formula.');return ast;
}
export class FormulaWorkbook {
 constructor(path,markdown,loadPage=()=>null){this.path=path;this.loadPage=loadPage;this.pages=new Map([[path,parseTables(markdown)]]);this.loaded=new Map();this.cache=new Map();this.visiting=new Set();this.steps=0;this.bytes=markdown.length;}
 tick(){if(++this.steps>100000)fail('#LIMIT!','Calculation exceeded 100,000 operations. Split this calculation into smaller tables.');}
 page(from,raw){
  if(typeof raw!=='string')ref('A source page must be a quoted path.');if(!raw)return from;
  if(/^[a-z][a-z0-9+.-]*:/i.test(raw)||raw.startsWith('//')||raw.includes('\0')||raw.length>4096)ref('Only local Markdown pages in open notebooks can be referenced.');
  const key=from+'\0'+raw;if(this.loaded.has(key))return this.loaded.get(key);
  if(this.pages.size>=32)fail('#LIMIT!','A calculation can read at most 32 pages.');
  const result=this.loadPage(from,raw);
  if(!result||result.error)ref(result?.error||`Source page unavailable: ${raw}`);
  if(!this.pages.has(result.path)){
   this.bytes+=result.markdown.length;if(this.bytes>8_000_000)fail('#LIMIT!','Calculation sources exceed 8 MB.');
   this.pages.set(result.path,parseTables(result.markdown));
  }
  this.loaded.set(key,result.path);return result.path;
 }
 table(path,selector){
  const list=this.pages.get(path)||[];
  if(selector instanceof D){if(!selector.isInteger())ref('A table number must be an integer.');selector=selector.toNumber();}
  if(typeof selector==='number'){if(!Number.isInteger(selector)||selector<1||!list[selector-1])ref(`Table ${selector} is unavailable.`);return list[selector-1];}
  const matches=list.filter(t=>t.name===selector);if(matches.length!==1)ref(matches.length?'Table heading is ambiguous; use a unique heading or table number.':`No table under heading “${selector}”.`);return matches[0];
 }
 index(table,selector,axis){
  if(selector instanceof D){if(!selector.isInteger())ref('Row and column numbers must be integers.');return selector.toNumber()-1;}
  if(typeof selector==='number')return selector-1;
  const entries=axis==='row'?table.rows.slice(1).map(r=>r[0]):table.rows[0];const matches=entries.map((v,i)=>v===selector?i:-1).filter(i=>i>=0);
  if(matches.length!==1)ref(`${axis==='row'?'Row label':'Column header'} “${selector}” is missing or ambiguous.`);return matches[0]+(axis==='row'?1:0);
 }
 cell(path,table,r,c){
  this.tick();if(!Number.isInteger(r)||!Number.isInteger(c)||r<0||c<0||r>=table.rows.length||c>=table.rows[0].length)ref('Cell is outside this table.');
  const key=path+'\0'+table.index+'\0'+r+','+c;if(this.cache.has(key)){const x=this.cache.get(key);if(x instanceof Error)throw x;return x;}
  if(this.visiting.has(key))fail('#CYCLE!','Circular reference: a calculation depends on itself.');
  if(this.visiting.size>=64)fail('#LIMIT!','Formula dependency chain exceeds 64 cells.');
  this.visiting.add(key);
  try{const text=table.rows[r][c];const value=r>0&&text.startsWith('=')?this.evaluate(text,path,table):text;this.cache.set(key,value);return value;}
  catch(error){this.cache.set(key,error);throw error;}finally{this.visiting.delete(key);}
 }
 range(path,table,raw){
  if(typeof raw!=='string')ref('A range must be a quoted address, such as "B2:C5".');const parts=raw.split(':');if(parts.length>2)ref('Invalid range.');
  const a=address(parts[0]),b=address(parts[1]||parts[0]);if(!a||!b)ref('Invalid cell address.');
  if(a.r>b.r||a.c>b.c)ref('Range start must precede its end.');if((b.r-a.r+1)*(b.c-a.c+1)>10000)fail('#LIMIT!','Range exceeds 10,000 cells.');
  const out=[];for(let r=a.r;r<=b.r;r++)for(let c=a.c;c<=b.c;c++)out.push(this.cell(path,table,r,c));return out;
 }
 evaluate(formula,path=this.path,table=this.table(path,1)){
  const ast=tokenize(formula);const scalar=x=>Array.isArray(x)?fail('#VALUE!','Use SUM or another aggregate for a range.'):number(x);
  const run=node=>{
   this.tick();if(node.op==='number')return bounded(new D(node.value));if(node.op==='literal')return node.value;
   if(node.op==='cell'){const p=address(node.value);return this.cell(path,table,p.r,p.c);}if(node.op==='range')return this.range(path,table,node.value);
   if(node.op==='unary'){const n=scalar(run(node.arg));return node.sign==='-'?n.neg():n;}if(node.op==='percent')return scalar(run(node.arg)).div(100);
   if(node.op==='call'){
    const name=node.name;
    if(name==='IF'){if(node.args.length!==3)fail('#ARGS!','IF needs condition, then, else.');return run(scalar(run(node.args[0])).isZero()?node.args[2]:node.args[1]);}
    const a=node.args.map(run);const count=(min,max=min)=>{if(a.length<min||a.length>max)fail('#ARGS!',`${name} expects ${min}${max!==min?'–'+max:''} arguments.`);};
    if(['CELL','RANGE','COLUMN','ROW'].includes(name)){
     count(3,name==='CELL'?4:3);const p=this.page(path,a[0]),t=this.table(p,a[1]);
     if(name==='CELL'){if(a.length===4)return this.cell(p,t,this.index(t,a[2],'row'),this.index(t,a[3],'column'));if(typeof a[2]!=='string'||!address(a[2]))ref('CELL needs an address such as "B2", or a row label and column header.');const v=address(a[2]);return this.cell(p,t,v.r,v.c);}
     if(name==='RANGE')return this.range(p,t,a[2]);
     if(name==='COLUMN'){const c=this.index(t,a[2],'column');if(c<0||c>=t.rows[0].length)ref('Column is outside this table.');return t.rows.slice(1).map((_,i)=>this.cell(p,t,i+1,c));}
     const r=this.index(t,a[2],'row');if(r<0||r>=t.rows.length)ref('Row is outside this table.');return t.rows[0].slice(1).map((_,i)=>this.cell(p,t,r,i+1));
    }
    if(name==='ROUND'){count(1,2);const places=a.length===2?scalar(a[1]).toNumber():0;if(!Number.isInteger(places)||places<0||places>12)fail('#ARGS!','ROUND decimal places must be 0–12.');return scalar(a[0]).toDecimalPlaces(places);}
    if(name==='ABS'){count(1);return scalar(a[0]).abs();}
    if(name==='SUMPRODUCT'){count(2,10);const arrays=a.map(x=>Array.isArray(x)?x:[x]);if(arrays.some(x=>x.length!==arrays[0].length))fail('#ARGS!','SUMPRODUCT ranges must have the same size.');let total=new D(0);for(let i=0;i<arrays[0].length;i++)total=total.plus(arrays.reduce((n,x)=>n.times(scalar(x[i])),new D(1)));return bounded(total);}
    if(['SUM','AVERAGE','MIN','MAX','COUNT'].includes(name)){
     count(1,100);const values=a.flat().filter(x=>x!=='').map(scalar);
     if(name==='COUNT')return new D(values.length);if(!values.length){if(name==='SUM')return new D(0);fail('#VALUE!','This aggregate has no numeric values.');}
     if(name==='MIN')return D.min(...values);if(name==='MAX')return D.max(...values);const sum=values.reduce((x,y)=>x.plus(y),new D(0));return bounded(name==='AVERAGE'?sum.div(values.length):sum);
    }
    fail('#NAME!',`Unknown function “${name}”.`);
   }
   const a=scalar(run(node.left)),b=scalar(run(node.right));
   if(node.op==='+')return bounded(a.plus(b));if(node.op==='-')return bounded(a.minus(b));if(node.op==='*')return bounded(a.times(b));
   if(node.op==='/'){if(b.isZero())fail('#DIV/0!','Cannot divide by zero.');return bounded(a.div(b));}
   if(node.op==='^'){if(!b.isInteger()||b.abs().greaterThan(100))fail('#NUM!','Exponent must be an integer from -100 to 100.');return bounded(a.pow(b));}
   const cmp=a.cmp(b);return new D(({ '=':cmp===0,'==':cmp===0,'!=':cmp!==0,'<>':cmp!==0,'<':cmp<0,'>':cmp>0,'<=':cmp<=0,'>=':cmp>=0})[node.op]?1:0);
  };
  return bounded(scalar(run(ast)));
 }
 result(fn){try{const n=number(fn());return {value:n.toString(),display:n.toString()};}catch(e){return {error:e.code||'#ERROR!',message:e.message,display:e.code||'#ERROR!'};}}
 inspect(){return {path:this.path,tables:(this.pages.get(this.path)||[]).map(t=>({index:t.index,name:t.name,headers:t.rows[0],rows:t.rows.map((row,r)=>row.map((text,c)=>({address:columnName(c)+(r+1),source:text,...(r>0&&text.startsWith('=')?this.result(()=>this.cell(this.path,t,r,c)): {})})))})),sources:[...this.pages.keys()]};}
}
export function calculatePage(path,markdown,load){try{return new FormulaWorkbook(path,markdown,load).inspect();}catch(e){return {path,error:e.code||'#ERROR!',message:e.message,tables:[]};}}
export function calculateExpression(path,markdown,table,expression,load){try{const w=new FormulaWorkbook(path,markdown,load);return {...w.result(()=>w.evaluate(expression,path,w.table(path,table))),sources:[...w.pages.keys()]};}catch(e){return {error:e.code||'#ERROR!',message:e.message};}}
