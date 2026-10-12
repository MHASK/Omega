import assert from 'node:assert/strict';
import { SlashMenu, matchingCommands, installScrollIndicators } from './slash-menu.js';

export async function runSlashTests() {
 // JSDOM has no layout; geometry is covered by the live WebKit check.
 window.Range.prototype.getClientRects = () => [];
 window.Range.prototype.getBoundingClientRect = () => ({left:0,right:0,top:0,bottom:0,width:0,height:0});
 const commands=[['text','Text','paragraph'],...[1,2,3,4,5,6].map(n=>['h'+n,'Heading '+n,'heading']),['image','Image','picture']];
 const menu=document.createElement('div');menu.id='slash';document.body.append(menu);let chosen,dismissed=false;
 const slash=new SlashMenu(menu,commands,{},c=>chosen=c[0],()=>{dismissed=true;menu.hidden=true;});
 menu.hidden=false;slash.update('heading');assert.equal(menu.querySelectorAll('button').length,6);
 assert.equal(matchingCommands(commands,'heading 2')[0][0],'h2');
 const key=name=>slash.keyDown(new KeyboardEvent('keydown',{key:name,cancelable:true}));
 key('ArrowDown');assert.equal(menu.querySelector('[aria-selected=true]').id,'slash-option-h2');
 slash.update('heading');assert.equal(slash.index,1,'A redraw does not reset keyboard selection');
 key('Enter');assert.equal(chosen,'h2');
 key('ArrowUp');key('ArrowUp');assert.equal(slash.index,5,'Up wraps to the last match');
 slash.update('h3');key('Tab');assert.equal(chosen,'h3');
 slash.update('no such command');assert.equal(menu.querySelectorAll('button').length,0);assert.equal(key('Enter'),false);
 key('Escape');assert(dismissed);
 const remove=installScrollIndicators(document,10);menu.dispatchEvent(new window.Event('scroll'));assert(menu.classList.contains('is-scrolling'));
 await new Promise(r=>setTimeout(r,25));assert(!menu.classList.contains('is-scrolling'));remove();menu.remove();
 console.log('PASS: inline command filtering, all headings, keyboard navigation, wraparound, Enter/Tab, Escape, empty results, and transient scroll indicators.');

}
