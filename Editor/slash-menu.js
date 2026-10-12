const normalize = text => text.toLowerCase().trim().replace(/\s+/g, ' ');

export function matchingCommands(commands, query) {
  const words = normalize(query).split(' ').filter(Boolean);
  return commands.filter(command => words.every(word =>
    normalize(`${command[0]} ${command[1]} ${command[2]}`).includes(word)));
}

// The caret stays in the note. Typing filters this list directly; navigation
// only changes the active option, never the document or its selection.
export class SlashMenu {
  constructor(element, commands, icons, onSelect, onDismiss) {
    Object.assign(this, {element, commands, icons, onSelect, onDismiss});
    this.query = null; this.items = []; this.index = 0;
  }
  update(query) {
    if (query === this.query && !this.element.hidden) return;
    this.query = query; this.items = matchingCommands(this.commands, query); this.index = 0;
    this.render(); this.element.scrollTop = 0;
  }
  render() {
    this.element.replaceChildren();
    if (!this.items.length) {
      const empty = document.createElement('div'); empty.className = 'empty';
      empty.textContent = 'No matching commands'; this.element.append(empty); return;
    }
    this.items.forEach((command, index) => {
      const button = document.createElement('button'); button.type = 'button'; button.tabIndex = -1;
      button.id = `slash-option-${command[0]}`; button.setAttribute('role', 'option');
      const icon = document.createElement('span');
      icon.className = 'command-icon ' + (!/^(h\d|equation)$/.test(command[0]) ? 'icon' : '');
      icon.textContent = this.icons[command[0]]; icon.setAttribute('aria-hidden', 'true');
      const title = document.createElement('span'); title.className = 'command-title'; title.textContent = command[1];
      const enter = document.createElement('span'); enter.className = 'command-enter'; enter.textContent = '↵'; enter.setAttribute('aria-hidden', 'true');
      button.append(icon, title, enter);
      button.onmousedown = event => { event.preventDefault(); this.onSelect(command); };
      // Moving DOM under a stationary pointer must not steal keyboard selection.
      button.onpointermove = event => { if (event.movementX || event.movementY) this.select(index); };
      this.element.append(button);
    });
    this.select(this.index);
  }
  select(index, scroll = false) {
    this.index = index;
    [...this.element.querySelectorAll('button')].forEach((button, i) => {
      button.classList.toggle('selected', i === index); button.setAttribute('aria-selected', String(i === index));
      if (i === index) this.element.setAttribute('aria-activedescendant', button.id);
    });
    const active = this.element.children[index];
    if (scroll && active) {
      if (active.offsetTop < this.element.scrollTop) this.element.scrollTop = active.offsetTop;
      else if (active.offsetTop + active.offsetHeight > this.element.scrollTop + this.element.clientHeight)
        this.element.scrollTop = active.offsetTop + active.offsetHeight - this.element.clientHeight;
    }
  }
  keyDown(event) {
    if (this.element.hidden || event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return false;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (this.items.length) this.select((this.index + (event.key === 'ArrowDown' ? 1 : -1) + this.items.length) % this.items.length, true);
      return true;
    }
    if ((event.key === 'Enter' || event.key === 'Tab') && this.items.length) {
      event.preventDefault(); this.onSelect(this.items[this.index]); return true;
    }
    if (event.key === 'Escape') { event.preventDefault(); this.onDismiss(); return true; }
    return false;
  }
}

export function installScrollIndicators(root = document, delay = 750) {
  const timers = new Map();
  const onScroll = event => {
    const element = event.target;
    if (!(element instanceof Element)) return;
    clearTimeout(timers.get(element)); element.classList.add('is-scrolling');
    timers.set(element, setTimeout(() => { element.classList.remove('is-scrolling'); timers.delete(element); }, delay));
  };
  root.addEventListener('scroll', onScroll, {capture: true, passive: true});
  return () => { root.removeEventListener('scroll', onScroll, true); for (const [el, timer] of timers) { clearTimeout(timer); el.classList.remove('is-scrolling'); } };
}
