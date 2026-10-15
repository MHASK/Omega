import Link from '@tiptap/extension-link';

export function isPageHref(href) {
  if (typeof href !== 'string' || !href || href.startsWith('//') || /^[a-z][\w+.-]*:/i.test(href)) return false;
  try { return /\.(md|markdown|txt)$/i.test(decodeURIComponent(href.split(/[?#]/)[0])); }
  catch { return false; }
}

export function isPersonHref(href){try{return typeof href==='string'&&href.startsWith('#omega-person-')&&decodeURIComponent(href.slice(14)).length>0&&decodeURIComponent(href.slice(14)).length<=80;}catch{return false;}}
export function liveMentions(states){const names=new Set();for(const state of states||[]){const name=state?.user?.name;if(typeof name==='string'&&name.trim()&&name.length<=80)names.add(name);}return [...names].map(name=>({name:'@'+name,location:'Live collaborator · reference only',href:'#omega-person-'+encodeURIComponent(name),kind:'person'}));}
export function itemLinkKind(href){return isPageHref(href)?href.match(/#folio-(task|goal)-[\w-]+$/)?.[1]||null:null;}
export const PageLink = Link.extend({
  renderHTML(props) {
    const rendered = this.parent(props);
    if (isPageHref(rendered[1].href)) {
      rendered[1]['data-page-link'] = '';
      const kind=itemLinkKind(rendered[1].href);
      if(kind)rendered[1]['data-item-link']=kind;
      rendered[1].title = kind?'Open linked '+kind:'Open linked note';
    }
    if(isPersonHref(rendered[1].href)){rendered[1]['data-omega-person']='';rendered[1].title='Collaborator reference';}
    return rendered;
  },
}).configure({openOnClick:false,autolink:true,defaultProtocol:'https'});

const fold = text => text.normalize('NFD').replace(/\p{M}/gu,'').toLocaleLowerCase();
export function matchingPages(pages, query) {
  const q=fold(query.trim()), words=q.split(/\s+/).filter(Boolean);
  return pages.filter(page=>words.every(word=>fold(page.name+' '+page.location).includes(word)))
    .sort((a,b)=>Number(fold(b.name).startsWith(q))-Number(fold(a.name).startsWith(q)) || a.name.localeCompare(b.name))
    .slice(0,50);
}

// The saved range is only applied if the document has not changed underneath
// the picker. Choosing a page is one normal, undoable Markdown edit.
export function insertPageLink(editor, page, range, doc, preserveText=false) {
  if (!editor?.isEditable || !editor.state.doc.eq(doc) || !(isPageHref(page.href)||isPersonHref(page.href))) return false;
  const chain=editor.chain().focus().setTextSelection(range);
  if (preserveText && range.from!==range.to) return chain.setLink({href:page.href}).run();
  return chain.insertContent({type:'text',text:page.name,marks:[{type:'link',attrs:{href:page.href}}]})
    .command(({tr})=>{tr.removeStoredMark(editor.schema.marks.link);return true;}).run();
}

export class PagePicker {
  constructor(element, onChoose, onClose) {
    Object.assign(this,{element,onChoose,onClose});
    this.input=element.querySelector('input');this.list=element.querySelector('[role=listbox]');
    this.pages=[];this.items=[];this.index=0;this.ready=false;
    this.input.oninput=()=>this.render();
    this.input.onkeydown=event=>{
      if (event.isComposing) return;
      if (['ArrowDown','ArrowUp'].includes(event.key)) {
        event.preventDefault();if(this.items.length)this.select((this.index+(event.key==='ArrowDown'?1:-1)+this.items.length)%this.items.length,true);
      } else if (event.key==='Enter') {event.preventDefault();if(this.items[this.index])this.onChoose(this.items[this.index]);}
      else if (event.key==='Escape') {event.preventDefault();this.close();this.onClose();}
    };
    element.querySelector('[data-close]').onclick=()=>{this.close();this.onClose();};
  }
  open(kind='page') {this.kind=kind;this.pages=[];this.ready=false;this.input.value='';this.input.placeholder=kind==='section'?'Quote a page or heading…':kind==='status'?'Link a task or goal status…':kind==='progress'?'Link completion progress…':kind==='mention'?'Mention a page or live collaborator…':kind==='goal'?'Link to a goal…':kind==='task'?'Link to a task or subtask…':kind==='all'?'Link to a page, task, or goal…':'Link to a page…';this.input.setAttribute('aria-label',this.input.placeholder);this.element.setAttribute('aria-label',this.input.placeholder);this.element.hidden=false;this.render();}
  close() {this.element.hidden=true;}
  setPages(pages) {this.pages=pages;this.ready=true;this.render();}
  render() {
    this.items=matchingPages(this.pages,this.input.value);this.index=0;this.list.replaceChildren();
    if (!this.items.length) {
      const empty=document.createElement('div');empty.className='empty';
      empty.textContent=this.ready?(this.pages.length?'No matching items':this.kind==='goal'?'No goals yet':this.kind==='task'?'No tasks yet':'No pages yet'):'Loading…';this.list.append(empty);
      this.input.removeAttribute('aria-activedescendant');return;
    }
    this.items.forEach((page,index)=>{
      const button=document.createElement('button');button.type='button';button.tabIndex=-1;button.setAttribute('role','option');button.id=`page-option-${index}`;
      const icon=document.createElement('span');icon.className='icon';icon.textContent=page.kind==='person'?'\uf007':page.kind==='goal'?'\uf11e':page.kind==='subtask'?'\uf0c5':page.kind==='task'?'\uf0ae':'\uf15b';icon.setAttribute('aria-hidden','true');
      const label=document.createElement('span');label.className='page-result-label';
      const name=document.createElement('span');name.textContent=page.name;
      const location=document.createElement('small');location.textContent=page.location;
      label.append(name,location);button.append(icon,label);button.title=page.location+' / '+page.name;
      button.onmousedown=e=>e.preventDefault();button.onclick=()=>this.onChoose(page);
      button.onpointermove=e=>{if(e.movementX||e.movementY)this.select(index);};this.list.append(button);
    });
    this.select(0);this.list.scrollTop=0;
  }
  select(index, scroll=false) {
    this.index=index;
    [...this.list.querySelectorAll('button')].forEach((button,i)=>{
      button.classList.toggle('selected',i===index);button.setAttribute('aria-selected',String(i===index));
      if(i===index) {this.input.setAttribute('aria-activedescendant',button.id);if(scroll)button.scrollIntoView({block:'nearest'});}
    });
  }
}
