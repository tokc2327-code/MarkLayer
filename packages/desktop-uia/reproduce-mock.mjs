import { WebSocketServer } from 'ws';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
const dir = await mkdtemp(join(tmpdir(), 'desktop-annotation-'));
const server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
await new Promise((resolve) => server.once('listening', resolve));
const target = { kind:'windows-uia', app:'test', windowTitle:'Test', controlType:'ControlType.Button', name:'OK', automationId:'ok', ancestry:[], relativeRect:{left:0,top:0,width:30,height:20}, captured:{left:10,top:20,width:30,height:20,dpr:1}, screen:{width:1920,height:1080,scale:1} };
try {
 const path=join(dir,'target.json'); await writeFile(path, JSON.stringify(target));
 let received;
 server.on('connection', ws => { ws.send(JSON.stringify({type:'init',ops:[],canEdit:true})); ws.on('message', raw => { received=JSON.parse(raw); ws.send(JSON.stringify({type:'ack',opId:received.clientOpId,status:'applied',seq:1,rev:1})); }); });
 const child=spawn(process.execPath,['packages/desktop-uia/cli.mjs','annotate','-Target',path,'--text','test','--room',`http://127.0.0.1:${server.address().port}/s/test`]);
 let out='',err=''; child.stdout.on('data',x=>out+=x); child.stderr.on('data',x=>err+=x);
 const code=await new Promise(resolve=>child.on('close',resolve));
 assert.equal(code,0,err); assert.deepEqual(received.op.desktopTarget,target); assert.equal(JSON.parse(out).opId,received.op.id);
 console.log(JSON.stringify({test:'cli-protocol-mock',ok:true,opId:received.op.id, note:'mock server only; not room persistence'}));
} finally { server.close(); await rm(dir,{recursive:true,force:true}); }
