// Loopback-only synthetic identities for the real-WebKit integration test.
import {createRelay,scope} from '../Relay/server.mjs';
const names=['Alice','Bob','Cara'];
const relay=createRelay({verify:async m=>{scope(m);const index=names.indexOf(m.token);if(index<0)throw Error('Not a test identity');return {key:m.path,name:names[index]};}});
relay.server.listen(0,'127.0.0.1',()=>console.log(relay.server.address().port));
process.on('SIGTERM',async()=>{await relay.close();process.exit(0);});
