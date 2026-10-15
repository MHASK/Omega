import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
const here = path.dirname(fileURLToPath(import.meta.url));
const runtime = process.env.FOLIO_EDITOR_RUNTIME || here;
const require = createRequire(path.join(runtime, 'package.json'));
const { build } = require('esbuild');
const result = await build({ metafile:true, entryPoints:[path.join(here,'editor.js')], outfile:path.join(here,'../Resources/editor.js'),bundle:true,minify:true,format:'iife',target:['safari16.4'],nodePaths:[path.join(runtime,'node_modules')],loader:{'.woff2':'file','.woff':'file','.ttf':'file'},assetNames:'fonts/[name]-[hash]',legalComments:'linked' });
const diagrams = await build({metafile:true,entryPoints:[path.join(here,'diagram-renderer.js')],outfile:path.join(here,'../Resources/diagrams.js'),bundle:true,minify:true,format:'iife',target:['safari16.4'],nodePaths:[path.join(runtime,'node_modules')],legalComments:'linked'});
fs.copyFileSync(path.join(here,'index.html'),path.join(here,'../Resources/index.html'));
await build({entryPoints:[path.join(here,'folder-tasks.js')],outfile:path.join(here,'../Resources/folder-tasks.js'),bundle:true,minify:true,format:'iife',target:['safari16.4'],nodePaths:[path.join(runtime,'node_modules')],legalComments:'linked'});
fs.copyFileSync(path.join(here,'folder-tasks.html'),path.join(here,'../Resources/folder-tasks.html'));
console.log('Bundled the local editor.');

const packages=new Map();
for(const input of new Set([...Object.keys(result.metafile.inputs),...Object.keys(diagrams.metafile.inputs)])) {
  if(!input.includes('node_modules/'))continue;
  let directory=path.dirname(path.resolve(input));
  while(directory!==path.dirname(directory)) {
    const manifest=path.join(directory,'package.json');
    if(fs.existsSync(manifest)) {
      const pkg=JSON.parse(fs.readFileSync(manifest,'utf8'));
      if(pkg.name){packages.set(pkg.name,{pkg,directory});break;}
    }
    directory=path.dirname(directory);
  }
}
let notices='Omega includes the following open-source editor packages.\n\n';
for(const [name,{pkg,directory}] of [...packages.entries()].sort()) {
  notices+=name+' '+pkg.version+'\nLicense: '+(pkg.license||'See notice below')+'\n';
  for(const file of fs.readdirSync(directory).filter(name=>/^licen[sc]e(?:[.-]|$)/i.test(name))) {
    const full=path.join(directory,file);if(fs.statSync(full).isFile())notices+=fs.readFileSync(full,'utf8')+'\n';
  }
  notices+='\n----------------------------------------\n\n';
}
fs.writeFileSync(path.join(here,'../Resources/Third-Party-Notices.txt'),notices);
