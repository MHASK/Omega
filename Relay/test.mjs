import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {WebSocket} from 'ws';
import * as Y from 'yjs';
import {createRelay,verifyAccess,scope} from './server.mjs';
const encode=doc=>Buffer.from(Y.encodeStateAsUpdate(doc)).toString('base64');
const apply=(doc,data)=>Y.applyUpdate(doc,Buffer.from(data,'base64'));
const seed=()=>{const d=new Y.Doc({gc:false});d.getMap('meta').set('version',1);d.getMap('meta').set('lineage',crypto.randomUUID());d.getMap('meta').set('kind','source');d.getText('source').insert(0,'Hello world');return d;};
async function start(dir){const r=createRelay({directory:dir,verify:async m=>{scope(m);if(m.token!=='test-token')throw Error();return {key:m.path==='other.md'?'other':'test',name:'writer'};}});await new Promise(done=>r.server.listen(0,'127.0.0.1',done));return r;}
async function client(relay,doc,extra={}){
 const ws=new WebSocket('ws://127.0.0.1:'+relay.server.address().port+'/live');const queue=[],waiters=[];
 ws.on('message',data=>{const m=JSON.parse(data);if(m.type==='peers')return;const next=waiters.shift();next?next(m):queue.push(m);});
 const next=()=>queue.length?Promise.resolve(queue.shift()):new Promise(resolve=>waiters.push(resolve));
 await new Promise(resolve=>ws.on('open',resolve));ws.send(JSON.stringify({type:'join',protocol:1,provider:'github',project:'owner/notes',branch:'main',path:'note.md',token:'test-token',seed:encode(doc),...extra}));
 return {ws,next,send:update=>ws.send(JSON.stringify({type:'update',update:encode(update),sequence:1,lineage:update.getMap('meta').get('lineage')}))};
}
test('provider write permission, allowlist, fixed origins, no redirects and traversal',async()=>{
 const message={provider:'github',project:'owner/notes',branch:'main',path:'a.md',token:'secret'};
 const calls=[];const fetcher=async(url,options)=>{calls.push([url,options]);return {ok:true,json:async()=>url.endsWith('/user')?{id:1,login:'person'}:{id:2,permissions:{push:true}}};};
 const result=await verifyAccess(message,{allow:['github:owner/*'],fetcher});assert.equal(result.name,'person');assert.equal(calls.length,2);assert.ok(calls.every(([,o])=>o.redirect==='error'));
 await assert.rejects(verifyAccess(message,{allow:[],fetcher}));await assert.rejects(verifyAccess({...message,path:'../secret.md'},{allow:['github:owner/*'],fetcher}));
 await assert.rejects(verifyAccess(message,{allow:['github:owner/*'],fetcher:async()=>({ok:true,json:async()=>({id:1,permissions:{push:false}})})}));
 const gitlab={...message,provider:'gitlab',project:'group/sub/project'};
 const gl=level=>async(url)=>({ok:true,json:async()=>url.endsWith('/user')?{id:1,username:'gitlab-user'}:{id:99,permissions:{group_access:{access_level:level}}}});
 assert.equal((await verifyAccess(gitlab,{allow:['gitlab:group/*'],fetcher:gl(30)})).name,'gitlab-user');await assert.rejects(verifyAccess(gitlab,{allow:['gitlab:group/*'],fetcher:gl(20)}));
});
test('concurrent edits, cold join, rejected token, isolated rooms, empty relay restart and recovery from clients',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'omega-relay-'));let relay=await start(dir);const sockets=[];
 try{
  const initial=seed(),a=await client(relay,initial);sockets.push(a.ws);const first=await a.next();assert.equal(first.created,true);
  const b=await client(relay,seed());sockets.push(b.ws);const second=await b.next();assert.equal(second.created,false);
  const da=new Y.Doc({gc:false}),db=new Y.Doc({gc:false});apply(da,first.state);apply(db,second.state);
  da.getText('source').insert(0,'Alice: ');db.getText('source').insert(db.getText('source').length,' — Bob');a.send(da);b.send(db);
  for(let i=0;i<2;i++){const m=await a.next();if(m.type==='update')apply(da,m.update);}for(let i=0;i<2;i++){const m=await b.next();if(m.type==='update')apply(db,m.update);}
  assert.equal(da.getText('source').toString(),db.getText('source').toString());assert.equal(da.getText('source').toString(),'Alice: Hello world — Bob');
  const bad=await client(relay,seed(),{token:'wrong'});sockets.push(bad.ws);assert.equal((await bad.next()).type,'error');
  const mismatch=await client(relay,seed());sockets.push(mismatch.ws);await mismatch.next();mismatch.send(seed());assert.equal((await mismatch.next()).type,'error');
  const other=await client(relay,seed(),{path:'other.md'});sockets.push(other.ws);const isolated=await other.next(),di=new Y.Doc();apply(di,isolated.state);assert.equal(di.getText('source').toString(),'Hello world');
  await relay.close();da.getText('source').insert(0,'Offline ');relay=await start(dir);
  const resumed=await client(relay,da);sockets.push(resumed.ws);const restarted=await resumed.next();assert.equal(restarted.created,true);apply(da,restarted.state);resumed.send(da);assert.equal((await resumed.next()).type,'ack');
  await relay.close();relay=await start(dir);const final=await client(relay,da);sockets.push(final.ws);const finalDoc=new Y.Doc();apply(finalDoc,(await final.next()).state);assert.equal(finalDoc.getText('source').toString(),'Offline Alice: Hello world — Bob');
  assert.deepEqual(fs.readdirSync(dir),[],'relay never writes note contents or credentials to disk');
 }finally{for(const ws of sockets)ws.terminate();await relay.close();fs.rmSync(dir,{recursive:true,force:true});}
});

test('last participant leaving erases the room without a server restart',async()=>{
 const relay=await start();
 try{
  const a=await client(relay,seed());assert.equal((await a.next()).created,true);
  a.ws.close();await new Promise(resolve=>a.ws.once('close',resolve));
  const fresh=seed();fresh.getText('source').insert(0,'New session: ');
  const b=await client(relay,fresh);const state=await b.next();assert.equal(state.created,true);
  const doc=new Y.Doc();apply(doc,state.state);assert.equal(doc.getText('source').toString(),'New session: Hello world');
  b.ws.close();await new Promise(resolve=>b.ws.once('close',resolve));
 }finally{await relay.close();}
});
