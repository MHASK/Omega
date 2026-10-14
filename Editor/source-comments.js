import {Node} from '@tiptap/core';

// Assistant markers are opaque data, never executable HTML. Reserved records
// keep their own validation; malformed comments still open losslessly as source.
export function ordinaryComment(raw) {
  return /^<!--[\s\S]*-->$/.test(raw) && !raw.slice(4,-3).includes('<!--')
    && !/^<!--\s*(?:folio:|omega-comment:)/i.test(raw);
}
export function withoutSourceComments(text) {
  return text.replace(/<!--[\s\S]*?-->/g, raw => ordinaryComment(raw) ? '' : raw);
}
function commentNode(block) {
  const name = block ? 'sourceComment' : 'inlineSourceComment';
  return Node.create({
    name, group: block ? 'block' : 'inline', inline: !block,
    atom: true, selectable: false, draggable: false,
    addAttributes(){return {raw:{default:''}};},
    parseHTML(){return [];},
    renderHTML(){return [block?'div':'span', {'data-source-comment':'',hidden:'',contenteditable:'false','aria-hidden':'true'}];},
    markdownTokenName:name,
    markdownTokenizer:{name,level:block?'block':'inline',start:block ? (src=>{const m=/^ {0,3}<!--/m.exec(src);return m?.index;}) : '<!--',tokenize(src){
      const m=src.match(block ? /^ {0,3}(<!--[\s\S]*?-->)[ \t]*(?:\r?\n|$)/ : /^(<!--[\s\S]*?-->)/);
      if(m && ordinaryComment(m[1]))return {type:name,raw:m[0],comment:m[1]};
    }},
    parseMarkdown(token){return {type:name,attrs:{raw:token.comment}};},
    renderMarkdown(node){return node.attrs.raw;},
  });
}
export const SourceComment=commentNode(true);
export const InlineSourceComment=commentNode(false);
