import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight';
import {quoteNodeView} from './linked-content.js';

export const diagramExamples = {
 flowchart: 'flowchart LR\n  idea[An idea] --> draft[A first draft]\n  draft --> review{Ready to share?}\n  review -->|Yes| publish[Share it]\n  review -->|Not yet| draft',
 sequence: 'sequenceDiagram\n  participant You\n  participant Team\n  You->>Team: Share an idea\n  Team-->>You: Add a little feedback\n  You->>Team: Make it together',
 chart: 'xychart-beta\n  title "Weekly progress"\n  x-axis [Mon, Tue, Wed, Thu, Fri]\n  y-axis "Completed" 0 --> 20\n  bar [3, 7, 10, 14, 18]',
};
let renderer;
function renderDiagram(text, theme) {
 if (window.omegaRenderDiagram) return window.omegaRenderDiagram(text, theme);
 if (!renderer) renderer = new Promise((resolve,reject) => {
  const script=document.createElement('script');script.src='folio://app/diagrams.js';
  script.onload=()=>window.omegaRenderDiagram?resolve():reject(new Error('The diagram renderer could not start.'));
  script.onerror=()=>{script.remove();renderer=null;reject(new Error('The diagram renderer could not load.'));};
  document.head.append(script);
 });
 return renderer.then(()=>window.omegaRenderDiagram(text,theme));
}
const make=(tag,cls,text)=>{const n=document.createElement(tag);n.className=cls;if(text!==undefined)n.textContent=text;return n;};
const action=(label,fn)=>{const b=make('button','diagram-action',label);b.type='button';b.setAttribute('aria-label',label);b.onclick=fn;return b;};

// Keep Mermaid as an ordinary codeBlock in the document/CRDT. Only its node
// view changes: previews and errors never enter Markdown or the undo history.
export const DiagramCodeBlock=CodeBlockLowlight.extend({
 addNodeView(){return ({node,editor,getPos})=>{
  if(node.attrs.language==='omega-quote')return quoteNodeView({node,editor,getPos});
  const mermaid=String(node.attrs.language||'').toLowerCase()==='mermaid';
  const pre=make('pre',''),code=make('code','');pre.append(code);
  if(node.attrs.language)code.className='language-'+node.attrs.language;
  if(!mermaid)return {dom:pre,contentDOM:code,update(next){if(next.type!==node.type||next.attrs.language!==node.attrs.language)return false;node=next;return true;}};
  const dom=make('div','diagram-block'),toolbar=make('div','diagram-toolbar'),label=make('span','diagram-label','Diagram'),controls=make('div','diagram-controls');
  toolbar.contentEditable='false';toolbar.setAttribute('role','toolbar');toolbar.setAttribute('aria-label','Diagram controls');
  const preview=make('div','diagram-preview'),status=make('div','diagram-status','Drawing diagram…');
  preview.contentEditable='false';status.contentEditable='false';status.setAttribute('role','status');
  pre.className='diagram-source';pre.hidden=true;code.setAttribute('aria-label','Mermaid source');
  const input=make('textarea','diagram-input');input.hidden=true;input.value=node.textContent;input.spellcheck=false;input.setAttribute('aria-label','Mermaid source');input.readOnly=!editor.isEditable;
  let current=node,dead=false,serial=0,timer,lastKey='',editing=false,svgText='',overlay=null;
  const showPreview=()=>{editing=false;input.hidden=true;preview.hidden=false;sourceButton.setAttribute('aria-pressed','false');previewButton.setAttribute('aria-pressed','true');schedule(true);};
  const showSource=()=>{editing=true;input.hidden=false;preview.hidden=true;sourceButton.setAttribute('aria-pressed','true');previewButton.setAttribute('aria-pressed','false');input.readOnly=!editor.isEditable;input.focus();};
  const previewButton=action('Preview diagram',showPreview),sourceButton=action('Edit diagram source',showSource),expand=action('Expand diagram',()=>openExpanded());
  previewButton.textContent='Preview';sourceButton.textContent='Source';expand.textContent='⤢';expand.title='Expand diagram';expand.disabled=true;previewButton.setAttribute('aria-pressed','true');sourceButton.setAttribute('aria-pressed','false');
  controls.append(previewButton,sourceButton,expand);toolbar.append(label,controls);preview.append(status);dom.append(toolbar,preview,input,pre);
  input.oninput=()=>{if(!editor.isEditable)return;const pos=getPos();if(typeof pos!=='number')return;const from=pos+1,to=pos+current.nodeSize-1;editor.view.dispatch(input.value?editor.state.tr.insertText(input.value,from,to):editor.state.tr.delete(from,to));};
  input.onkeydown=e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='z'){e.preventDefault();if(window.folio?.command)window.folio.command(e.shiftKey?'redo':'undo');else editor.commands[e.shiftKey?'redo':'undo']?.();}if(e.key==='Tab'){e.preventDefault();input.setRangeText('  ',input.selectionStart,input.selectionEnd,'end');input.dispatchEvent(new Event('input'));}};
  function closeExpanded(){if(!overlay)return;overlay.remove();overlay=null;document.removeEventListener('keydown',overlayKeys,true);expand.focus();}
  function overlayKeys(e){if(e.key==='Escape'){e.preventDefault();e.stopPropagation();closeExpanded();}else if(e.key==='Tab'&&overlay){const buttons=[...overlay.querySelectorAll('button')],at=buttons.indexOf(document.activeElement);e.preventDefault();buttons[(at+(e.shiftKey?-1:1)+buttons.length)%buttons.length].focus();}}
  function openExpanded(){
   if(!svgText)return;overlay=make('section','diagram-expanded');overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-label','Expanded diagram');
   const bar=make('div','diagram-expanded-bar'),canvas=make('div','diagram-expanded-canvas');canvas.innerHTML=svgText;
   const svg=canvas.querySelector('svg'),box=svg.viewBox.baseVal;let scale=1;
   const value=make('span','diagram-zoom-value');
   const zoom=next=>{scale=Math.min(4,Math.max(.15,next));svg.style.width=box.width*scale+'px';svg.style.height=box.height*scale+'px';value.textContent=Math.round(scale*100)+'%';};
   const fit=()=>zoom(Math.min(1,(canvas.clientWidth-64)/Math.max(1,box.width),(canvas.clientHeight-64)/Math.max(1,box.height)));
   bar.append(make('span','diagram-label','Diagram'),action('Zoom out',()=>zoom(scale/1.25)),value,action('Zoom in',()=>zoom(scale*1.25)),action('Fit',fit),action('Close diagram',closeExpanded));
   overlay.append(bar,canvas);document.body.append(overlay);document.addEventListener('keydown',overlayKeys,true);fit();bar.lastChild.focus();
  }
  function schedule(force=false){
   const theme=document.documentElement.dataset.theme==='dark'?'dark':'light',text=current.textContent,key=theme+'\n'+text;
   if(key===lastKey&&!force)return;lastKey=key;const request=++serial;clearTimeout(timer);
   if(!text.trim()){preview.replaceChildren(make('div','diagram-status','Add Mermaid source to draw a diagram.'));expand.disabled=true;svgText='';return;}
   timer=setTimeout(async()=>{
    if(dead||request!==serial)return;
    preview.setAttribute('aria-busy','true');
    try{
     const svg=await renderDiagram(text,theme);if(dead||request!==serial)return;
     svgText=svg;preview.innerHTML=svg;preview.dataset.state='ready';expand.disabled=false;
    }catch(error){
     if(dead||request!==serial)return;svgText='';expand.disabled=true;preview.dataset.state='error';
     const message=make('div','diagram-error');message.setAttribute('role','status');message.append(make('strong','','Check the diagram syntax'),make('span','',String(error?.message||error).replace(/\s+/g,' ').slice(0,260)),action('Edit source',showSource));preview.replaceChildren(message);
    }finally{if(!dead&&request===serial)preview.removeAttribute('aria-busy');}
   },editing?350:0);
  }
  // Theme updates repaint previews, never the underlying document.
  const themeObserver=new MutationObserver(()=>schedule());themeObserver.observe(document.documentElement,{attributes:true,attributeFilter:['data-theme']});
  const selection=()=>{if(!editor.isFocused||!editor.isEditable)return;const pos=getPos(),s=editor.state.selection;if(typeof pos==='number'&&s.from>pos&&s.from<pos+current.nodeSize&&!editing){editing=true;input.hidden=false;preview.hidden=true;sourceButton.setAttribute('aria-pressed','true');previewButton.setAttribute('aria-pressed','false');}};
  editor.on('selectionUpdate',selection);schedule();
  return {dom,contentDOM:code,
   update(next){if(next.type!==node.type||String(next.attrs.language||'').toLowerCase()!=='mermaid')return false;current=next;if(input.value!==next.textContent){const start=input.selectionStart,end=input.selectionEnd;input.value=next.textContent;input.setSelectionRange(Math.min(start,input.value.length),Math.min(end,input.value.length));}input.readOnly=!editor.isEditable;schedule();return true;},
   stopEvent:event=>!!event.target.closest('.diagram-toolbar,.diagram-preview,.diagram-input'),
   ignoreMutation:mutation=>mutation.type!=='selection'&&!code.contains(mutation.target),
   destroy(){dead=true;serial++;clearTimeout(timer);themeObserver.disconnect();editor.off('selectionUpdate',selection);if(overlay){overlay.remove();document.removeEventListener('keydown',overlayKeys,true);}},
  };
 };},
});
