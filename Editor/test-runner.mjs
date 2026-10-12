import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
const here=path.dirname(fileURLToPath(import.meta.url));
const runtime=process.env.FOLIO_EDITOR_RUNTIME||here;
const require=createRequire(path.join(runtime,'package.json'));
const { build }=require('esbuild');
const output=path.join(runtime,'.folio-tests.cjs');
try {
 await build({entryPoints:[path.join(here,'test.mjs')],outfile:output,bundle:true,platform:'node',format:'cjs',external:['jsdom'],nodePaths:[path.join(runtime,'node_modules')]});
 execFileSync(process.execPath,[output],{stdio:'inherit'});
} finally {fs.rmSync(output,{force:true});}
