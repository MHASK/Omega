import { Extension, Node, mergeAttributes } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { Markdown } from '@tiptap/markdown';
import { Table, TableRow, TableHeader, TableCell } from '@tiptap/extension-table';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import Image from '@tiptap/extension-image';
import Placeholder from '@tiptap/extension-placeholder';
import {DiagramCodeBlock} from './diagrams.js';
import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight';
import {LiveReferences} from './linked-content.js';
import {TableFormulas} from './table-formula-view.js';
import { common, createLowlight } from 'lowlight';
import katex from 'katex';
import { PageLink } from './page-links.js';
import {TextColor,Highlight,Underline,CommentAnchor,CommentRecord,withoutWritingMarkup} from './writing-schema.js';
import {SourceComment,InlineSourceComment,withoutSourceComments} from './source-comments.js';

// Empty notes get an editable outline, while the editor retains the original
// empty file until the user actually writes. Placeholders are never saved.
export function noteContent(text) {
  return text.trim() ? {content: visualMarkdown(text), contentType: 'markdown'} : {
    content: {type: 'doc', content: [{type: 'heading', attrs: {level: 1}}, {type: 'paragraph'}]},
    contentType: 'json',
  };
}

const NoteStart = Extension.create({
  name: 'noteStart',
  addKeyboardShortcuts() {
    return {
      Enter: () => {
        const {selection, doc} = this.editor.state, first = doc.firstChild, next = doc.maybeChild(1);
        if (!selection.empty || selection.$from.depth !== 1 || selection.$from.index(0) !== 0
            || first?.type.name !== 'heading' || first.attrs.level !== 1
            || selection.$from.parentOffset !== first.content.size
            || next?.type.name !== 'paragraph' || next.content.size !== 0) return false;
        return this.editor.commands.setTextSelection(first.nodeSize + 1);
      },
    };
  },
});

// Plain angle-bracket template placeholders are text, not HTML. Preserve real
// tags and code verbatim; the untouched file remains the source of truth.
const htmlTags=new Set('a abbr address area article aside audio b base bdi bdo blockquote body br button canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hgroup hr html i iframe img input ins kbd label legend li link main map mark menu meta meter nav noscript object ol optgroup option output p picture pre progress q rp rt ruby s samp script search section select slot small source span strong style sub summary sup table tbody td template textarea tfoot th thead time title tr track u ul var video wbr svg math'.split(' '));
export function visualMarkdown(text) {
  const code=[];
  text.replace(/^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[^\n]*(?:\n|$)|`+[^`\n]*`+/gm,(match,_,offset)=>{code.push([offset,offset+match.length]);return match;});
  return text.replace(/<([A-Za-z][\w]*(?:[ \t]+[\w]+)*)>/g,(match,label,offset)=>{
    if(code.some(([start,end])=>offset>=start&&offset<end)||text.lastIndexOf('<!--',offset)>text.lastIndexOf('-->',offset)||htmlTags.has(label.split(/\s/)[0].toLowerCase())||text.toLowerCase().includes('</'+label.toLowerCase()+'>'))return match;
    return '&lt;'+label+'&gt;';
  });
}

// Extended dialects open losslessly in source mode; never silently discard them.
export function needsSource(markdown) {
  return sourceIssue(markdown)!==null;
}
export function sourceIssue(markdown) {
  const issue=(text,match,message)=>match ? {line:text.slice(0,match.index).split('\n').length,message} : null;
  const database=issue(markdown,/^ {0,3}(?:`{3,}|~{3,})[ \t]*database(?:\s|$)/mi.exec(markdown),'This database block is preserved in Markdown. Visual editing is not supported yet.');
  if(database)return database;
  if(/^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)\s*(?:\n|$)/.test(markdown))return {line:1,message:'This note has front matter that the visual editor cannot edit yet.'};
  // Keep line numbers while ignoring code and records that have lossless nodes.
  // Bare breaks are supported by hardBreak, including table save/reopen. HTML
  // with attributes still needs source mode so no attributes are silently lost.
  const clean=withoutWritingMarkup(withoutSourceComments(visualMarkdown(markdown)))
    .replace(/^(`{3,}|~{3,}).*\n[\s\S]*?^\1\s*$/gm,raw=>raw.replace(/[^\n]/g,''))
    .replace(/`[^`\n]*`/g,'').replace(/<br[ \t]*\/?>/gi,'');
  const html=/<!--|<\/?[a-z][\w-]*(?:\s[^>]*|\s*\/?)>/i.exec(clean);
  if(html){
    const tag=html[0].match(/^<\/?[\w-]+/)?.[0]+'>';
    return issue(clean,html,html[0]==='<!--'?'An unfinished or unsupported comment needs Markdown editing. Your text is preserved.':`The ${tag} HTML tag${/^<br\b/i.test(html[0])?' has attributes that need':' needs'} Markdown editing. Your text is preserved.`);
  }
  const extended=/^[ \t]*\[\^[^\]]+\]:|^:::+[ \t]*\w|^[ \t]*:[ \t]+\S/m.exec(clean);
  return issue(clean,extended,'This Markdown extension is not supported by the visual editor yet. Your text is preserved.');
}

const LocalImage = Image.extend({
  addNodeView() {
    return ({ node }) => {
      const box = document.createElement('span');
      box.className = 'image-block';
      const image = document.createElement('img');
      const label = document.createElement('span');
      label.className = 'image-label';
      label.textContent = node.attrs.alt || 'Image';
      const source = node.attrs.src || '';
      if (!/^[a-z][a-z0-9+.-]*:/i.test(source) && !source.startsWith('//')) {
        image.src = 'folio://asset/' + encodeURIComponent(source);
        image.alt = node.attrs.alt || '';
        image.title = node.attrs.title || '';
        image.onload = () => { label.hidden = true; };
        image.onerror = () => { image.hidden = true; label.textContent += ' · Image unavailable'; };
        box.append(image, label);
      } else {
        label.textContent += ' · Remote image';
        label.title = source;
        box.append(label);
        if (/^https?:\/\//i.test(source)) {
          const load = document.createElement('button');
          load.className = 'load-image'; load.textContent = 'Load image';
          load.onclick = () => {
            image.referrerPolicy = 'no-referrer'; image.alt = node.attrs.alt || '';
            image.onload = () => { label.hidden = true; load.hidden = true; };
            image.onerror = () => { image.hidden = true; label.textContent = 'Image unavailable'; };
            image.src = source; box.prepend(image);
          };
          box.append(load);
        }
      }
      return { dom: box };
    };
  },
  renderMarkdown(node) {
    const escape = s => String(s || '').replace(/([\\\[\]])/g, '\\$1');
    const src = String(node.attrs.src || '').replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');
    const title = node.attrs.title ? ` "${String(node.attrs.title).replace(/["\\]/g, '\\$&')}"` : '';
    return `![${escape(node.attrs.alt)}](${src}${title})`;
  },
}).configure({ inline: false });

function mathNode(block) {
  const name = block ? 'blockMath' : 'inlineMath';
  return Node.create({
    name, group: block ? 'block' : 'inline', inline: !block, atom: true,
    addAttributes() { return { latex: { default: '' } }; },
    parseHTML() { return [{ tag: `${block ? 'div' : 'span'}[data-math="${name}"]` }]; },
    renderHTML({ HTMLAttributes }) { return [block ? 'div' : 'span', mergeAttributes(HTMLAttributes, { 'data-math': name }), HTMLAttributes.latex || '']; },
    markdownTokenName: name,
    markdownTokenizer: {
      name, level: block ? 'block' : 'inline', start: block ? '$$' : '$',
      tokenize(src) {
        const match = src.match(block ? /^\$\$[ \t]*\n([\s\S]+?)\n\$\$[ \t]*(?:\n|$)/ : /^\$(?!\$|\s)([^$\s](?:[^$\n]*?[^$\s])?)\$(?![\d$])/);
        if (match) return { type: name, raw: match[0], latex: match[1] };
      },
    },
    parseMarkdown(token) { return { type: name, attrs: { latex: token.latex } }; },
    renderMarkdown(node) { return block ? `$$\n${node.attrs.latex}\n$$` : `$${node.attrs.latex}$`; },
    addNodeView() {
      return ({ node, getPos, editor }) => {
        const dom = document.createElement(block ? 'div' : 'span');
        dom.className = block ? 'math-block' : 'math-inline';
        dom.title = 'Double-click to edit equation';
        dom.innerHTML = katex.renderToString(node.attrs.latex, { displayMode: block, throwOnError: false, trust: false });
        dom.ondblclick = () => window.folioEditMath?.(node.attrs.latex, value => editor.chain().focus().setNodeSelection(getPos()).updateAttributes(name, { latex: value }).run());
        return { dom };
      };
    },
  });
}

export function extensions({nativeHistory = false, quoted = false} = {}) {
  return [
    StarterKit.configure({ undoRedo: nativeHistory ? false : {}, codeBlock: false, underline: false, trailingNode: false, link: false }), PageLink, TextColor, Highlight, Underline, CommentAnchor, CommentRecord, SourceComment, InlineSourceComment,
    Markdown.configure({ markedOptions: { gfm: true, breaks: false } }),
    Table.configure({ resizable: true, lastColumnResizable: false, cellMinWidth: 90 }), TableRow,
    TableHeader.extend({ content: 'paragraph' }), TableCell.extend({ content: 'paragraph' }),
    TaskList, TaskItem.configure({ nested: true }), quoted ? LocalImage.extend({addNodeView(){return ({node})=>{const dom=document.createElement("span");dom.className="image-label";dom.textContent=node.attrs.alt||"Image in source note";return {dom};};}}) : LocalImage,
    (quoted ? CodeBlockLowlight : DiagramCodeBlock).configure({ lowlight: createLowlight(common), defaultLanguage: null }),
    ...(quoted ? [] : [LiveReferences,TableFormulas]),
    NoteStart,
    Placeholder.configure({
      showOnlyCurrent: false,
      placeholder: ({node, pos, editor, hasAnchor}) => {
        if (pos === 0 && node.type.name === 'heading' && node.attrs.level === 1) return 'Title';
        const first = editor.state.doc.firstChild;
        const starterBody = editor.state.doc.childCount === 2 && first?.type.name === 'heading'
          && first.attrs.level === 1 && pos === first.nodeSize;
        return node.type.name === 'paragraph' && (hasAnchor || starterBody) ? 'Write something, or type /…' : '';
      },
    }),
    mathNode(true), mathNode(false),
  ];
}
