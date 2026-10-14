import assert from 'node:assert/strict';
import {Editor} from '@tiptap/core';
import {extensions,needsSource,noteContent} from './schema.js';
export function runSourceCommentTests(){
 const cases=[
  '# Now\n\n<!-- timeline:start -->\n## Timeline\n\n- **Latest** update\n- [ ] Follow up\n\n<!-- timeline:end -->\n\n## Next\n\nKeep writing.',
  'Before <!-- assistant: café <Weekday> <script>alert(1)</script> --> after.',
  '<!-- multi\nline 日本語 -->\n\n| Name | State |\n| --- | --- |\n| One | <mark data-omega-highlight="brown">Done</mark> |',
  '- A list item <!-- keep here -->\n- Another item',
  '> A quote <!-- context -->',
  '<!-- first -->\n<!-- second -->\n\nText',
  '```html\n<!-- code sample -->\n```\n\nA `<!-- literal -->` example.',
 ];
 for(const source of cases){
  assert(!needsSource(source),source);
  const e=new Editor({element:document.createElement('div'),extensions:extensions(),...noteContent(source)});
  const saved=e.getMarkdown();
  for(const raw of source.match(/<!--[\s\S]*?-->/g)||[])assert(saved.includes(raw),'Preserved exact marker: '+raw+' in '+saved);
  assert(!e.view.dom.querySelector('script'),'Comment payload must never become HTML');
  assert.deepEqual(e.schema.nodeFromJSON(e.markdown.parse(saved)).toJSON(),e.getJSON(),'Save/reopen preserves every node');
  e.commands.insertContentAt(e.state.doc.content.size,{type:'paragraph',content:[{type:'text',text:'New thought'}]});
  for(const raw of source.match(/<!--[\s\S]*?-->/g)||[])assert(e.getMarkdown().includes(raw));
  assert(e.commands.undo());assert.equal(e.getMarkdown(),saved);e.destroy();
 }
 for(const bad of ['<!-- unclosed','<!-- outer <!-- nested -->','<!-- folio:unknown -->','<!-- omega-comment:broken -->','<!-- okay -->\n<details>Unsupported</details>'])assert(needsSource(bad),bad);
 console.log('PASS: assistant markers remain invisible and exact across editing, undo, save/reopen; reserved/malformed metadata stays lossless; code and styled tables survive.');
}
