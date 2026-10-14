const preview=document.querySelector('iframe'),tabs=[...document.querySelectorAll('[role="tab"][data-preview]')];
let current='notes';
function setPreview(view){
 current=view;
 for(const tab of tabs){const selected=tab.dataset.preview===view;tab.setAttribute('aria-selected',String(selected));tab.tabIndex=selected?0:-1;}
 document.querySelectorAll('.sample-page').forEach(button=>button.classList.toggle('selected',button.dataset.preview===view));
 document.querySelector('#preview-panel').setAttribute('aria-labelledby',view+'-tab');
 document.querySelector('#preview-breadcrumb').textContent='Projects / '+(view==='notes'?'A little room to think':'The next chapter');
 preview.contentWindow?.postMessage({type:'omega-preview',view},location.origin);
}
for(const button of document.querySelectorAll('[data-preview]'))button.addEventListener('click',()=>{setPreview(button.dataset.preview);if(button.classList.contains('preview-jump'))document.querySelector('#product').scrollIntoView({block:'start'});});
for(const tab of tabs)tab.addEventListener('keydown',event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const target=event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):tabs.find(t=>t!==tab);setPreview(target.dataset.preview);target.focus();});
window.addEventListener('message',event=>{if(event.origin===location.origin&&event.source===preview.contentWindow&&event.data?.type==='omega-preview-ready')setPreview(current);});
// The release page is a permanent fallback. Resolve the current official DMG,
// without pinning the website to a version. No visitor identifiers are sent.
fetch('https://api.github.com/repos/MHASK/Omega/releases/latest',{credentials:'omit',referrerPolicy:'no-referrer'})
 .then(response=>{if(!response.ok)throw new Error('Release unavailable');return response.json();})
 .then(release=>{const asset=release.assets?.find(asset=>/^Omega-[\d.]+\.dmg$/.test(asset.name));if(!asset)return;const url=new URL(asset.browser_download_url);if(url.origin!=='https://github.com'||!url.pathname.startsWith('/MHASK/Omega/releases/download/'))return;for(const link of document.querySelectorAll('[data-download]'))link.href=url.href;})
 .catch(()=>{});
