import http from 'node:http';
import {RoomPresence} from './presence.mjs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {WebSocketServer} from 'ws';
import * as Y from 'yjs';

export const MAX_STATE=4*1024*1024;
const digest=s=>createHash('sha256').update(s).digest('hex');
const fail=()=>{throw Error('Access denied');};
export function scope(m){
 if(!['github','gitlab'].includes(m.provider)||typeof m.project!=='string'||!/^[-\w.]+(?:\/[-\w.]+)+$/.test(m.project)||m.project.split('/').some(x=>x==='.'||x==='..'))fail();
 if(typeof m.branch!=='string'||!m.branch||m.branch.length>200||/[\x00-\x20]/.test(m.branch))fail();
 if(typeof m.path!=='string'||m.path.length>1000||!m.path.split('/').every(p=>p&&!p.startsWith('.')&&!p.includes('\\')&&!/[\x00-\x1f]/.test(p))||!/\.(md|markdown|txt)$/i.test(m.path))fail();
 return {provider:m.provider,project:m.project,branch:m.branch,path:m.path};
}
export async function verifyAccess(m,{allow=[],fetcher=fetch}={}){
 const s=scope(m);
 if(!allow.some(rule=>rule===s.provider+':'+s.project||(rule.endsWith('/*')&&(s.provider+':'+s.project).startsWith(rule.slice(0,-1)))))fail();
 if(typeof m.token!=='string'||!m.token||m.token.length>4096)fail();
 // Fixed provider origins, no caller-controlled API hosts or redirects. The CLI
 // credential is used only for these requests and is not retained in the room.
 const get=async(url,headers)=>{const response=await fetcher(url,{headers,redirect:'error',signal:AbortSignal.timeout(10000)});if(!response.ok)fail();return response.json();};
 let user,project;
 if(s.provider==='github'){
  const headers={Authorization:'Bearer '+m.token,Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'Omega-Relay'};
  [user,project]=await Promise.all([get('https://api.github.com/user',headers),get('https://api.github.com/repos/'+s.project,headers)]);
  if(!project.permissions?.push||project.archived||project.disabled)fail();
 }else{
  const headers={'PRIVATE-TOKEN':m.token};
  [user,project]=await Promise.all([get('https://gitlab.com/api/v4/user',headers),get('https://gitlab.com/api/v4/projects/'+encodeURIComponent(s.project),headers)]);
  const level=Math.max(project.permissions?.project_access?.access_level||0,project.permissions?.group_access?.access_level||0);
  if(level<30||project.archived)fail();
 }
 if(!user.id||!project.id)fail();
 return {key:digest(JSON.stringify([s.provider,project.id,s.branch,s.path])),name:String(user.login||user.username).slice(0,80)};
}
function decode(value){if(typeof value!=='string'||value.length>MAX_STATE*1.4||!/^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value))throw Error('Invalid update');return new Uint8Array(Buffer.from(value,'base64'));}
const encode=data=>Buffer.from(data).toString('base64');
export function createRelay({allow=[],verify=m=>verifyAccess(m,{allow}),sessionMS=300000,maxRooms=100}={}){
 const rooms=new Map(),attempts=new Map();
 const server=http.createServer((req,res)=>{res.setHeader('Cache-Control','no-store');if(req.url==='/health'&&req.method==='GET'){res.writeHead(200,{'Content-Type':'application/json'});res.end('{"service":"omega-relay","protocol":1,"ok":true}');}else{res.writeHead(404);res.end();}});
 const wss=new WebSocketServer({noServer:true,maxPayload:6*1024*1024,perMessageDeflate:false});
 server.on('upgrade',(req,socket,head)=>{
  const ip=req.socket.remoteAddress,now=Date.now(),prior=attempts.get(ip)||{at:now,n:0};if(now-prior.at>60000){prior.at=now;prior.n=0;}prior.n++;attempts.set(ip,prior);
  // Native-only transport: prevent browser origin/credential probing. All
  // clients must separately pass repository authorization before seeing data.
  if(req.url!=='/live'||req.headers.origin||prior.n>60||wss.clients.size>=100){socket.destroy();return;}
  wss.handleUpgrade(req,socket,head,ws=>wss.emit('connection',ws));
 });
 function validate(doc){const meta=doc.getMap('meta');if(meta.get('version')!==1||typeof meta.get('lineage')!=='string'||!['rich','source','tasks'].includes(meta.get('kind')))throw Error('Incompatible shared note');}
 function room(key,seed){
  if(rooms.has(key))return {room:rooms.get(key),created:false};
  if(rooms.size>=maxRooms)throw Error('Relay is full');
  const doc=new Y.Doc({gc:false});try{Y.applyUpdate(doc,decode(seed));validate(doc);if(Y.encodeStateAsUpdate(doc).length>MAX_STATE)throw Error('Too large');}catch(error){doc.destroy();throw error;}
  const value={doc,clients:new Set(),key};value.presence=new RoomPresence(doc,value.clients,send);rooms.set(key,value);return {room:value,created:true};
 }
 const send=(ws,m)=>{if(ws.readyState===1){if(ws.bufferedAmount>8*1024*1024){ws.close(1013);return;}ws.send(JSON.stringify(m));}};
 const presence=r=>{const users=[...new Set([...r.clients].map(c=>c.person))];for(const c of r.clients)send(c,{type:'peers',users});};
 wss.on('connection',ws=>{
  let active=null,authorized=false,inflight=false,count=0,windowAt=Date.now();ws.alive=true;
  const authTimer=setTimeout(()=>ws.close(4003,'Sign in required'),12000);let expiry;
  ws.on('pong',()=>ws.alive=true);
  ws.on('message',async data=>{
   try{
    if(Date.now()-windowAt>1000){count=0;windowAt=Date.now();}if(++count>80)throw Error('Too many changes');
    const m=JSON.parse(data.toString());
    if(!authorized){
     if(inflight||m.type!=='join'||m.protocol!==1)throw Error('Sign in required');inflight=true;
     const identity=await verify(m);m.token=null;if(ws.readyState!==1)return;
     const loaded=room(identity.key,m.seed);active=loaded.room;ws.person=identity.name;authorized=true;clearTimeout(authTimer);
     active.clients.add(ws);send(ws,{type:'state',state:encode(Y.encodeStateAsUpdate(active.doc)),created:loaded.created,presence:true});active.presence.join(ws);presence(active);
     expiry=setTimeout(()=>ws.close(4001,'Refresh access'),sessionMS);return;
    }
    if(m.type==='update'){
     if(m.lineage!==active.doc.getMap('meta').get('lineage'))throw Error('Different shared baseline');
     const update=decode(m.update),candidate=new Y.Doc({gc:false});
     try{Y.applyUpdate(candidate,Y.encodeStateAsUpdate(active.doc));Y.applyUpdate(candidate,update);validate(candidate);if(candidate.getMap('meta').get('lineage')!==m.lineage||candidate.getMap('meta').get('kind')!==active.doc.getMap('meta').get('kind'))throw Error('Incompatible shared note');if(Y.encodeStateAsUpdate(candidate).length>MAX_STATE)throw Error('Too large');}finally{candidate.destroy();}
     Y.applyUpdate(active.doc,update);
     for(const client of active.clients)if(client!==ws)send(client,{type:'update',update:m.update});
     send(ws,{type:'ack',sequence:m.sequence});
    }else if(m.type==='awareness'){
     if(m.lineage!==active.doc.getMap('meta').get('lineage'))throw Error('Different shared baseline');
     active.presence.receive(ws,m);
    }else if(m.type==='ping')send(ws,{type:'pong'});else throw Error('Invalid message');
   }catch{send(ws,{type:'error',message:authorized?'The relay could not forward this change. Your local copy is safe.':'Could not join. Check the allowed repository and your GitHub or GitLab write access.'});ws.close(4003,'Request rejected');}
  });
  ws.on('error',()=>{});
  ws.on('close',()=>{clearTimeout(authTimer);clearTimeout(expiry);if(active){active.clients.delete(ws);active.presence.leave(ws);presence(active);if(!active.clients.size){rooms.delete(active.key);active.presence.destroy();active.doc.destroy();}}});
 });
 const heartbeat=setInterval(()=>{for(const ws of wss.clients){if(!ws.alive){ws.terminate();continue;}ws.alive=false;ws.ping();}for(const [ip,v] of attempts)if(Date.now()-v.at>60000)attempts.delete(ip);},30000);heartbeat.unref();
 return {server,async close(){clearInterval(heartbeat);for(const ws of wss.clients)ws.terminate();await new Promise(resolve=>wss.close(resolve));await new Promise(resolve=>server.close(resolve));}};
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href){
 const allow=(process.env.OMEGA_ALLOWED_REPOS||'').split(',').map(s=>s.trim()).filter(Boolean);
 if(!allow.length)throw Error('Set OMEGA_ALLOWED_REPOS to explicitly allowed provider:owner/repository entries.');
 const relay=createRelay({allow});
 relay.server.listen(Number(process.env.PORT||8787),process.env.HOST||'127.0.0.1',()=>console.log('Omega relay ready'));
 for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{await relay.close();process.exit(0);});
}
