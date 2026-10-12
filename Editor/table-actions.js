export function tableContext(editor) {
  if (!editor) return null;
  const {$from} = editor.state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    const node = $from.node(depth);
    if (node.type.name === 'table') return {node, rows:node.childCount, columns:node.firstChild?.childCount || 0};
  }
  return null;
}

const actions = new Set(['addRowBefore','addRowAfter','addColumnBefore','addColumnAfter','deleteRow','deleteColumn','deleteTable']);
export function runTableAction(editor, action) {
  const table = tableContext(editor);
  if (!table || !editor.isEditable || !actions.has(action)) return false;
  // Removing the final row/column must not unexpectedly remove the whole table.
  if ((action === 'deleteRow' && table.rows <= 1) || (action === 'deleteColumn' && table.columns <= 1)) return false;
  return editor.chain().focus()[action]().run();
}

export function appendToTable(editor, table, axis) {
  if (!editor?.isEditable || !editor.view.dom.contains(table) || !['row','column'].includes(axis)) return false;
  const row = axis === 'row' ? table.rows[table.rows.length - 1] : table.rows[0];
  const cell = row?.cells[row.cells.length - 1];
  if (!cell) return false;
  const position = editor.view.posAtDOM(cell, 0) + 1;
  const chain = editor.chain().focus().setTextSelection(position);
  // Start typing in the new row/column immediately after adding it.
  return chain[axis === 'row' ? 'addRowAfter' : 'addColumnAfter']().goToNextCell().run();
}
