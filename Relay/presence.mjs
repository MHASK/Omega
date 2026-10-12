import * as decoding from 'lib0/decoding';
import {Awareness,applyAwarenessUpdate,encodeAwarenessUpdate,modifyAwarenessUpdate,removeAwarenessStates} from 'y-protocols/awareness';

const palette=['#BDA9DC','#8FBCC4','#D3AD8D','#9ABB9D','#D0A2B5','#B7B989'];
const integer=n=>Number.isSafeInteger(n)&&n>=0;
const id=p=>p&&integer(p.client)&&p.client<=0xffffffff&&integer(p.clock)?{client:p.client,clock:p.clock}:null;
function position(p){
 if(!p||typeof p!=='object'||Array.isArray(p))throw Error('Invalid cursor');
 const out={assoc:p.assoc??0};if(![-1,0,1].includes(out.assoc))throw Error('Invalid affinity');
 if(p.type!=null){out.type=id(p.type);if(!out.type)throw Error('Invalid type');}
 if(p.item!=null){out.item=id(p.item);if(!out.item)throw Error('Invalid item');}
 if(p.tname!=null){if(typeof p.tname!=='string'||p.tname.length>80)throw Error('Invalid field');out.tname=p.tname;}
 if(!out.type&&!out.item&&!out.tname)throw Error('Missing position');
 return out;
}
const encode=bytes=>Buffer.from(bytes).toString('base64');
export class RoomPresence {
 constructor(doc,clients,send){
  this.clients=clients;this.send=send;this.awareness=new Awareness(doc);this.awareness.setLocalState(null);
  this.awareness.on('update',({added,updated,removed},origin)=>{
   const update=encode(encodeAwarenessUpdate(this.awareness,[...added,...updated,...removed]));
   for(const client of clients)if(client!==origin)send(client,{type:'awareness',update});
  });
 }
 join(ws){
  const used=new Set([...this.clients].filter(c=>c!==ws).map(c=>c.cursorColor));let hash=0;for(const c of ws.person)hash=(hash*31+c.charCodeAt(0))>>>0;
  const preferred=palette[hash%palette.length];ws.cursorColor=used.has(preferred)?palette.find(c=>!used.has(c))||preferred:preferred;
  const ids=[...this.awareness.getStates().keys()];if(ids.length)this.send(ws,{type:'awareness',update:encode(encodeAwarenessUpdate(this.awareness,ids))});
 }
 receive(ws,message){
  if(typeof message.update!=='string'||message.update.length>8192||!/^[A-Za-z0-9+/]*={0,2}$/.test(message.update))throw Error('Invalid presence');
  const bytes=new Uint8Array(Buffer.from(message.update,'base64')),decoder=decoding.createDecoder(bytes);
  if(decoding.readVarUint(decoder)!==1)throw Error('One cursor per connection');
  const client=decoding.readVarUint(decoder),clock=decoding.readVarUint(decoder);
  if(!integer(client)||client>0xffffffff||!integer(clock)||client===this.awareness.clientID)throw Error('Invalid client');
  const raw=JSON.parse(decoding.readVarString(decoder));if(decoding.hasContent(decoder))throw Error('Invalid presence payload');
  if(ws.awarenessID!==undefined&&ws.awarenessID!==client)throw Error('Cursor identity changed');
  if([...this.clients].some(c=>c!==ws&&c.awarenessID===client))throw Error('Cursor belongs to another connection');
  let state=null;
  if(raw!==null){
   if(typeof raw!=='object'||Array.isArray(raw))throw Error('Invalid presence state');
   state={user:{name:ws.person,color:ws.cursorColor},cursor:raw.cursor?{anchor:position(raw.cursor.anchor),head:position(raw.cursor.head)}:null};
   if(raw.field!=null){if(typeof raw.field!=='string'||raw.field.length>160||/[\x00-\x1f]/.test(raw.field))throw Error('Invalid field');state.field=raw.field;}
  }
  ws.awarenessID=client;
  applyAwarenessUpdate(this.awareness,modifyAwarenessUpdate(bytes,()=>state),ws);
 }
 leave(ws){if(ws.awarenessID!==undefined)removeAwarenessStates(this.awareness,[ws.awarenessID],ws);}
 destroy(){this.awareness.destroy();}
}
