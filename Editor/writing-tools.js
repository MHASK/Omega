import {writingColors,commentRecords,commentRange,addComment,resolveComment} from './writing-schema.js';
const make=(tag,cls,text)=>{const el=document.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;};
export function quietButton(label,action,icon){const b=make('button','',icon||label);b.type='button';b.title=label;b.setAttribute('aria-label',label);b.onmousedown=e=>e.preventDefault();b.onclick=action;return b;}
export function positionPopover(el,rect){el.hidden=false;el.style.left=Math.max(8,Math.min(rect.left,innerWidth-el.offsetWidth-8))+'px';el.style.top=Math.max(8,Math.min(rect.bottom+7,innerHeight-el.offsetHeight-8))+'px';}

export class WritingTools {
 constructor(host){
  this.host=host;this.preferences={scale:1,font:'default',wide:false};this.author='You';
  this.tools=make('div','note-tools');this.tools.hidden=true;
  this.styleButton=quietButton('Document appearance',()=>this.openAppearance(),'Aa');
  this.commentsButton=quietButton('Comments',()=>this.openComments(),'');this.commentsButton.innerHTML='<span class="icon" aria-hidden="true">&#xf075;</span>';
  this.tools.append(this.commentsButton,this.styleButton);document.body.append(this.tools);
  this.panel=make('div','popover writing-panel');this.panel.hidden=true;this.panel.setAttribute('role','dialog');document.body.append(this.panel);
  this.onOutside=e=>{if(!this.panel.hidden&&!this.panel.contains(e.target)&&!e.target.closest('.note-tools,#bubble,.block-tools,.block-menu'))this.close();};
  document.addEventListener('pointerdown',this.onOutside);
  this.panel.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();this.close();this.host.editor()?.commands.focus();}};
 }
 get busy(){return !this.panel.hidden;}
 close(){this.panel.hidden=true;this.mode=null;this.range=null;this.doc=null;this.composing=false;}
 reset(){this.close();this.editor=null;this.tools.hidden=true;}
 bind(editor){this.editor=editor;editor.on('transaction',({transaction})=>{
   if(transaction.docChanged&&this.range){const from=transaction.mapping.mapResult(this.range.from,1),to=transaction.mapping.mapResult(this.range.to,-1);this.range={from:from.pos,to:Math.max(from.pos,to.pos)};}
   if(transaction.docChanged){this.updateCount();if(this.mode==='comments'&&!this.composing)this.renderComments();}
  });this.updateCount();}
 configure(config,{taskMode,sourceMode}){
  this.author=config.author||this.author;
  if(config.writingScale!==undefined)this.preferences.scale=Math.max(.8,Math.min(1.8,config.writingScale));
  if(['default','serif','mono'].includes(config.writingFont))this.preferences.font=config.writingFont;
  if(config.writingWide!==undefined)this.preferences.wide=!!config.writingWide;
  const root=document.documentElement;root.style.setProperty('--writing-scale',this.preferences.scale);root.dataset.writingFont=this.preferences.font;root.dataset.writingWide=String(this.preferences.wide);
  this.tools.hidden=taskMode;this.commentsButton.hidden=sourceMode;
  if(this.mode==='appearance')this.renderAppearance();
 }
 changePreferences(values){this.preferences={...this.preferences,...values};this.configure({writingScale:this.preferences.scale,writingFont:this.preferences.font,writingWide:this.preferences.wide},{taskMode:false,sourceMode:!this.editor});this.host.preferences(values);}
 open(mode,title,rect){this.close();this.host.hideMenus();this.mode=mode;this.panel.className='popover writing-panel writing-'+mode;this.panel.setAttribute('aria-label',title);this.panel.replaceChildren();this.anchor=rect||this.styleButton.getBoundingClientRect();}
 heading(title){const row=make('div','writing-panel-heading');row.append(make('span','',title),quietButton('Close',()=>this.close(),'×'));this.panel.append(row);}
 openAppearance(){this.open('appearance','Document appearance');this.renderAppearance();}
 renderAppearance(){
  this.panel.replaceChildren();this.heading('Document');const fonts=make('div','writing-fonts');
  for(const [value,title] of [['default','Default'],['serif','Serif'],['mono','Mono']]){const b=quietButton(title+' font',()=>this.changePreferences({font:value}));b.replaceChildren();b.dataset.font=value;b.classList.toggle('active',this.preferences.font===value);b.setAttribute('aria-pressed',String(this.preferences.font===value));b.append(make('span','font-sample','Ag'),make('small','',title));fonts.append(b);}this.panel.append(fonts);
  const size=make('div','writing-option');size.append(make('span','','Text size'));
  const step=make('div','writing-stepper');for(const direction of [-1,0,1]){const b=quietButton(direction<0?'Smaller document text':direction>0?'Larger document text':'Reset document text size',()=>this.changePreferences({scale:direction===0?1:Math.min(1.8,Math.max(.8,Math.round((this.preferences.scale+direction*.1)*10)/10))}),direction===0?Math.round(this.preferences.scale*100)+'%':direction<0?'−':'+');b.disabled=direction<0?this.preferences.scale<=.8:direction>0?this.preferences.scale>=1.8:false;step.append(b);}size.append(step);this.panel.append(size);
  const width=make('label','writing-option','Full width');const toggle=make('input');toggle.type='checkbox';toggle.checked=this.preferences.wide;toggle.onchange=()=>this.changePreferences({wide:toggle.checked});width.append(toggle);this.panel.append(width,make('p','writing-hint','Only your document changes. ⌥⌘ + / −'));positionPopover(this.panel,this.anchor);
 }
 openColors(range){
  const editor=this.host.editor();if(!editor?.isEditable)return;
  const saved=range||{from:editor.state.selection.from,to:editor.state.selection.to};
  const rect=editor.view.coordsAtPos(saved.from);this.open('colors','Text color and highlight',rect);this.range=saved;
  this.heading('Color');
  for(const [mark,title] of [['textColor','Text'],['highlight','Highlight']]){
   this.panel.append(make('div','writing-section-label',title));const grid=make('div','color-grid');
   const clear=quietButton('Default '+title.toLowerCase(),()=>this.applyColor(mark,null),'A');clear.className='color-swatch default-color';grid.append(clear);
   for(const [name,label,light,dark] of writingColors){const b=quietButton(label+' '+title.toLowerCase(),()=>this.applyColor(mark,name),'A');b.className='color-swatch '+(mark==='highlight'?'color-background':'');b.style.setProperty('--ink-light',light);b.style.setProperty('--ink-dark',dark);b.dataset.color=name;b.setAttribute('aria-pressed',String(editor.isActive(mark,{value:name})));grid.append(b);}this.panel.append(grid);
  }
  positionPopover(this.panel,rect);
 }
 applyColor(mark,color){const editor=this.host.editor(),range=this.range;if(!range||!editor?.isEditable)return;const chain=editor.chain().focus().setTextSelection(range);color?chain.setMark(mark,{value:color}).run():chain.unsetMark(mark).run();this.close();}
 updateCount(){if(!this.editor||this.editor.isDestroyed)return;const count=commentRecords(this.editor.state.doc).filter(x=>x.record.id===x.record.thread&&!x.record.resolved).length;this.commentsButton.dataset.count=count||'';this.commentsButton.setAttribute('aria-label',count?`${count} open comments`:'Comments');}
 startComment(range){
  const editor=this.host.editor();if(!editor?.isEditable)return;
  const selection=range||editor.state.selection,from=selection.from,to=selection.to;
  if(from===to){const {$from}=editor.state.selection;if(!$from.parent.isTextblock)return;range={from:$from.start(),to:$from.end()};}else range={from,to};
  if(range.from===range.to){this.openComments();return;}
  const rect=editor.view.coordsAtPos(range.from);this.open('compose','Add comment',rect);this.range=range;this.heading('Comment');
  const quote=editor.state.doc.textBetween(range.from,range.to,' ');this.panel.append(make('blockquote','comment-quote',quote));
  const input=make('textarea','comment-input');input.placeholder='Write a comment…';input.setAttribute('aria-label','Comment');input.rows=3;input.maxLength=12000;
  const actions=make('div','comment-actions');const save=quietButton('Add comment',()=>{if(!input.value.trim())return;const id=addComment(editor,{range:this.range,body:input.value,author:this.author});if(id)this.openComments(id);},'Add comment');save.disabled=true;input.oninput=()=>{save.disabled=!input.value.trim();};input.onkeydown=e=>{if(e.metaKey&&e.key==='Enter'){e.preventDefault();save.click();}};
  actions.append(make('small','','⌘↵ to add'),save);this.panel.append(input,actions);positionPopover(this.panel,rect);input.focus();
 }
 openComments(thread){this.open('comments','Comments',this.commentsButton.getBoundingClientRect());this.thread=thread;this.resolved=!!(thread&&commentRecords(this.host.editor()?.state.doc).find(x=>x.record.id===thread)?.record.resolved);this.renderComments();}
 renderComments(){
  const editor=this.host.editor();if(!editor)return;this.panel.replaceChildren();this.heading('Comments');
  const all=commentRecords(editor.state.doc),roots=all.filter(x=>x.record.id===x.record.thread&&x.record.resolved===this.resolved);
  const bar=make('div','comment-filter');const toggle=quietButton(this.resolved?'Show open comments':'Show resolved comments',()=>{this.resolved=!this.resolved;this.thread=null;this.renderComments();},this.resolved?'Resolved':'Open');bar.append(toggle,make('small','',String(roots.length)));this.panel.append(bar);
  const list=make('div','comment-list');
  if(!roots.length)list.append(make('p','comment-empty',this.resolved?'No resolved comments.':'A little room for a conversation. Select text, then choose Comment.'));
  for(const {record} of roots){
   const card=make('section','comment-thread');card.dataset.thread=record.id;if(record.id===this.thread)card.classList.add('active');
   const quote=quietButton('Go to commented text',()=>{const range=commentRange(editor.state.doc,record.id);if(range)editor.chain().focus().setTextSelection(range).scrollIntoView().run();},record.quote||'Comment');quote.className='comment-quote';card.append(quote);
   for(const {record:reply} of all.filter(x=>x.record.thread===record.id)){
    const message=make('div','comment-message');const info=make('div','comment-byline');info.append(make('strong','',reply.author),make('time','',new Date(reply.created).toLocaleDateString(undefined,{month:'short',day:'numeric'})));message.append(info,make('p','',reply.body));card.append(message);
   }
   const controls=make('div','comment-actions');const reply=quietButton('Reply',()=>this.reply(card,record.id),'Reply');const resolve=quietButton(record.resolved?'Reopen comment':'Resolve comment',()=>{resolveComment(editor,record.id,!record.resolved);this.renderComments();},record.resolved?'Reopen':'Resolve');reply.disabled=resolve.disabled=!editor.isEditable;controls.append(reply,resolve);card.append(controls);list.append(card);
  }
  this.panel.append(list);positionPopover(this.panel,this.anchor);if(this.thread)list.querySelector(`[data-thread="${this.thread}"]`)?.scrollIntoView({block:'nearest'});
 }
 reply(card,thread){
  if(card.querySelector('textarea'))return;this.composing=true;const input=make('textarea','comment-input');input.rows=2;input.maxLength=12000;input.placeholder='Reply…';input.setAttribute('aria-label','Reply');
  const send=quietButton('Send reply',()=>{if(!input.value.trim())return;this.composing=false;addComment(this.host.editor(),{body:input.value,author:this.author,thread});this.renderComments();},'Reply');send.disabled=true;input.oninput=()=>send.disabled=!input.value.trim();input.onkeydown=e=>{if(e.metaKey&&e.key==='Enter'){e.preventDefault();send.click();}};card.append(input,send);input.focus();
 }
}
