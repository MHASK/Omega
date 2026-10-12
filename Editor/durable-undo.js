// Serialize repeated shortcuts while native storage commits. No keystroke can
// race an undo replacement; ordinary editing resumes immediately after it.
export function historyQueue({snapshot, lock, send, apply}) {
  let busy = false, pending = [], activeID;
  const next = () => {
    if (busy || !pending.length) return;
    const redo = pending.shift(), state = snapshot();
    activeID = state.id; busy = true; lock(true);
    send({...state, redo});
  };
  return {
    get busy() { return busy; },
    request(redo) { pending.push(redo); next(); },
    result(result) {
      if (!busy || result.id !== activeID) return;
      try { if (result.id === snapshot().id && typeof result.text === 'string') apply(result); }
      finally { busy = false; lock(false); next(); }
    },
    reset() { busy = false; pending = []; activeID = undefined; lock(false); },
  };
}
