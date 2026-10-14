const preview=document.querySelector('#preview-image'),tabs=[...document.querySelectorAll('[role="tab"][data-preview]')];
const captures={
 notes:{file:'notes.jpg',alt:'The released Omega Mac app: real notebook sidebar, notes editor, document controls, search, archive, and footer. Sample notes shown.'},
 tasks:{file:'tasks-board.jpg',alt:'The released Omega Mac app: real task board, nested subtask cards, pastel labels, linked goals, completion rings, and notebook sidebar. Sample tasks shown.'}
};
function setPreview(view){
 const capture=captures[view];if(!capture)return;
 for(const tab of tabs){const selected=tab.dataset.preview===view;tab.setAttribute('aria-selected',String(selected));tab.tabIndex=selected?0:-1;}
 document.querySelector('#preview-panel').setAttribute('aria-labelledby',view+'-tab');
 const source='/assets/screenshots/'+capture.file;
 preview.src=source;preview.alt=capture.alt;
 document.querySelector('#preview-fullsize').href=source;
 document.querySelector('#preview-fullsize').setAttribute('aria-label','View the full-size Omega '+view+' screenshot');
 document.querySelector('#preview-image-link').href=source;
}
for(const button of document.querySelectorAll('[data-preview]'))button.addEventListener('click',()=>{setPreview(button.dataset.preview);if(button.classList.contains('preview-jump'))document.querySelector('#product').scrollIntoView({block:'start'});});
for(const tab of tabs)tab.addEventListener('keydown',event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const target=event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):tabs.find(t=>t!==tab);setPreview(target.dataset.preview);target.focus();});
// The release page is a permanent fallback. Resolve the current official DMG,
// without pinning the website to a version. No visitor identifiers are sent.
fetch('https://api.github.com/repos/MHASK/Omega/releases/latest',{credentials:'omit',referrerPolicy:'no-referrer'})
 .then(response=>{if(!response.ok)throw new Error('Release unavailable');return response.json();})
 .then(release=>{const asset=release.assets?.find(asset=>/^Omega-[\d.]+\.dmg$/.test(asset.name));if(!asset)return;const url=new URL(asset.browser_download_url);if(url.origin!=='https://github.com'||!url.pathname.startsWith('/MHASK/Omega/releases/download/'))return;for(const link of document.querySelectorAll('[data-download]'))link.href=url.href;})
 .catch(()=>{});
