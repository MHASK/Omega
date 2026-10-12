import { Extension } from '@tiptap/core';
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';

export const matchKey = new PluginKey('folioSearchMatch');
export const SearchMatch = Extension.create({
 name: 'folioSearchMatch',
 addProseMirrorPlugins() {
  return [new Plugin({
   key: matchKey,
   state: {
    init: () => DecorationSet.empty,
    apply(tr, current) {
     const match = tr.getMeta(matchKey);
     if (match === null || tr.docChanged) return DecorationSet.empty;
     if (match) {
      const decoration = match.atom
       ? Decoration.node(match.from, match.to, {class: 'folio-search-hit'})
       : Decoration.inline(match.from, match.to, {class: 'folio-search-hit'});
      return DecorationSet.create(tr.doc, [decoration]);
     }
     return current;
    },
   },
   props: { decorations: state => matchKey.getState(state) },
  })];
 },
});

export const fold = text => text.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase();
export function words(text) {
 return [...text.matchAll(/[\p{L}\p{M}\p{N}]+/gu)].map(m => ({word: fold(m[0]), from: m.index, to: m.index + m[0].length}));
}
export function documentWords(doc) {
 let text = '', positions = [], atoms = [];
 function append(value, pos, atom = false) {
  text += value;
  for (let i = 0; i < value.length; i++) { positions.push(atom ? pos : pos + i); atoms.push(atom); }
 }
 doc.descendants((node, pos) => {
  if (node.isBlock || node.type.name === 'hardBreak') append('\n', pos);
  if (node.isText) append(node.text, pos);
  else if (node.isAtom && (node.attrs.alt || node.attrs.latex)) {
   append(' ', pos); append(node.attrs.alt || node.attrs.latex, pos, true); append(' ', pos);
  }
 });
 return words(text).map(w => ({...w, from: positions[w.from], to: positions[w.to - 1] + 1, atom: atoms[w.from]}));
}
function contextScore(tokens, index, anchor) {
 let score = 0;
 (anchor.before || []).slice().reverse().forEach((word, i) => { if (tokens[index - 1 - i]?.word === word) score += 4 - i * 0.5; });
 (anchor.after || []).forEach((word, i) => { if (tokens[index + 1 + i]?.word === word) score += 4 - i * 0.5; });
 return score;
}
export function resolveSourceMatch(source, anchor) {
 const tokens = words(source), candidates = [];
 const exact = tokens.find(token => token.from === anchor.location && token.to === anchor.location + anchor.length && token.word === anchor.term);
 if (exact) return exact;
 tokens.forEach((token, index) => {
  if (token.word === anchor.term) candidates.push({token, score: contextScore(tokens, index, anchor) * 1000 - Math.abs(token.from - anchor.location) / Math.max(1, source.length)});
 });
 candidates.sort((a, b) => b.score - a.score);
 return candidates[0]?.token || null;
}
export function resolveRichMatch(editor, source, anchor) {
 const raw = resolveSourceMatch(source, anchor);
 const tokens = documentWords(editor.state.doc), candidates = tokens.filter(t => t.word === anchor.term);
 if (!candidates.length) return null;
 if (raw) {
  // Parse the prefix with the same Markdown parser as the open document. This
  // preserves the occurrence number while excluding hidden link destinations
  // and syntax, and works across inline marks, lists, tables, and code blocks.
  try {
   const prefix = editor.schema.nodeFromJSON(editor.markdown.parse(source.slice(0, raw.to)));
   const preceding = documentWords(prefix);
   const occurrence = preceding.filter(t => t.word === anchor.term).length;
   if (preceding.at(-1)?.word === anchor.term && candidates[occurrence - 1]) return candidates[occurrence - 1];
  } catch {}
 }
 // If an outside edit invalidated the old position, recover from nearby words.
 return tokens.map((token, index) => ({token, score: contextScore(tokens, index, anchor)}))
  .filter(item => item.token.word === anchor.term).sort((a, b) => b.score - a.score)[0]?.token || null;
}
export function showRichMatch(editor, match) {
 const tr = editor.state.tr.setSelection(TextSelection.near(editor.state.doc.resolve(match.from)))
  .setMeta(matchKey, match).setMeta('addToHistory', false);
 editor.view.dispatch(tr);
}
export function clearRichMatch(editor) {
 if (editor && !editor.isDestroyed) editor.view.dispatch(editor.state.tr.setMeta(matchKey, null).setMeta('addToHistory', false));
}
