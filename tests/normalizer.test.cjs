const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const source = fs.readFileSync(require('node:path').join(__dirname, '../install.sh'), 'utf8')
  .split("<<'NORMALIZER_EOF'\n")[1].split('\nNORMALIZER_EOF')[0];
function harness(models=[{id:"gpt-6-astra"}], mode='ok') {
  let handler; const upstream=[];
  const state={mode,lookups:0,listening:false,destroyed:0};
  const http = {
    createServer(fn) { handler=fn; return { listen() { state.listening=true; } }; },
    request(options, fn) {
      const req=new EventEmitter();
      req.destroy=()=>{state.destroyed++;req.emit('error',new Error('destroyed'));};
      req.setTimeout=()=>req;
      req.end=(body)=>{
        const r=new EventEmitter(); r.statusCode=200; r.headers={};
        r.pipe=res=>res.end('{}');
        if(options.method==='POST') upstream.push({params:{body,headers:options.headers},url:options.path});
        if(options.method==='POST'&&state.reply){
          const {status,data}=state.reply(JSON.parse(body.toString()));
          r.statusCode=status;r.pipe=res=>res.end(data);fn(r);r.emit('data',Buffer.from(data));r.emit('end');return;
        }
        if(options.path==='/v1/models') {
          state.lookups++;
          if(state.mode==='stall')return;
          if(state.mode==='error'){req.emit('error',new Error('offline'));return;}
          if(state.mode==='abort'){fn(r);r.emit('aborted');return;}
          if(state.mode==='invalid'){fn(r);r.emit('data','{invalid');r.emit('end');return;}
        }
        fn(r); r.emit('data',Buffer.from(JSON.stringify({data:models}))); r.emit('end');
      };
      return req;
    }
  };
  const context={require(name) { if(name==='http')return http; if(name==='fs')return {readFileSync(){return 'fake-token';}}; return require(name); },
    setTimeout: (fn,ms)=>setTimeout(fn,Math.min(ms,25)), clearTimeout,
    process:{env:{HOME:'/test'}}, Buffer, console:{error(){}}, AbortController, fetch:async(url,params)=>{
      upstream.push({url,params});
      if(url.includes('copilot_internal')) return {ok:true,json:async()=>({token:'test',expires_at:9999999999,endpoints:{api:'https://copilot.test'}})};
      if(state.fetchMode==='stall') return new Promise((_,reject)=>params.signal.addEventListener('abort',()=>reject(params.signal.reason)));
      if(state.fetchMode==='stream-error') return {status:200,headers:new Map([['content-type','text/event-stream']]),
        body:new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('data: {}\n\n'));c.error(new Error('upstream reset'));}})};
      return {status:200,headers:new Map(),body:null,text:async()=>'{"status":"completed"}'};
    }};
  vm.runInNewContext(source,context);
  return { upstream, state, eval(code) { return vm.runInNewContext(code,context); }, async post(model, url='/v1/responses', extra={}, headers={}) {
    const req=new EventEmitter();Object.assign(req,{method:'POST',url,headers});
    return new Promise(resolve=>{const res=new EventEmitter();Object.assign(res,{headersSent:false,writableEnded:false,destroyed:false,chunks:[],
      writeHead(status){this.status=status;this.headersSent=true;},
      write(c){this.chunks.push(c);return true;},
      end(body){if(body!==undefined)this.chunks.push(body);this.writableEnded=true;resolve({status:this.status,body:this.chunks.join('')});},
      destroy(){this.destroyed=true;resolve({status:this.status,destroyed:true,body:this.chunks.join('')});}});
      handler(req,res);req.emit('data',Buffer.from(JSON.stringify({model,...extra})));req.emit('end');});
  }, async get(url) {
    const req=new EventEmitter();Object.assign(req,{method:'GET',url,headers:{}});
    return new Promise(resolve=>{const res=new EventEmitter();Object.assign(res,{headersSent:false,writableEnded:false,destroyed:false,
      writeHead(status){this.status=status;this.headersSent=true;},
      end(body){this.writableEnded=true;resolve({status:this.status,body:String(body)});},destroy(){resolve({destroyed:true});}});
      handler(req,res);req.emit('end');});
  }};
}
test('dedicated reviewer fails locally with manual approval instructions, without token exchange', async()=>{
  for(const url of ['/responses','/v1/responses']){
    const h=harness();const r=await h.post('codex-auto-review',url);
    assert.equal(r.status,400);assert.equal(JSON.parse(r.body).error.code,'copilot_auto_review_unsupported');
    assert.match(r.body,/Ask for approval/);assert.equal(h.upstream.length,0);
  }
});
test('GPT selections keep their exact id and coding tools',async()=>{
  for(const model of ['gpt-6.1-sol','gpt-6-astra','gpt-6-sol','gpt-6-luna','gpt-5.6-sol','gpt-5.6-terra','gpt-5.5','gpt-5.3-codex']){
    const h=harness();await h.post(model,'/v1/responses',{tools:[{type:'function',name:'shell'},{type:'web_search'}],service_tier:'priority'});
    const request=JSON.parse(h.upstream.at(-1).params.body.toString());
    assert.equal(request.model,model);assert.equal(request.tools.length,1);assert.equal(request.tools[0].name,'shell');assert.equal(request.service_tier,undefined);
  }
});

test('Opus 5.5 resolves both live upstream spellings and picker suffixes',()=>{
  for(const id of ['claude-opus-5.5','claude-opus-5-5']){
    const h=harness([{id},{id:'claude-opus-4.8'}]);
    for(const input of ['claude-opus-5.5','claude-opus-5-5','claude-opus-5-5[1m]','claude-opus-5-5-20260301','opus','claude-opus'])
      assert.equal(h.eval(`normalize(${JSON.stringify(input)})`),id);
    const picker=h.eval(`forwardId(${JSON.stringify(id)})`);
    assert.equal(h.eval(`normalize(${JSON.stringify(picker)})`),id);
  }
});
test('Opus 5.5 is kept on a cold start and when exact is requested',()=>{
  for(const models of [[],[{id:'claude-opus-4.8'}]]){
    const h=harness(models);
    assert.equal(h.eval('normalize("claude-opus-5-5", true)'),'claude-opus-5.5');
    assert.equal(h.eval('normalize("claude-opus-5.5", true)'),'claude-opus-5.5');
    assert.equal(h.eval('normalize("claude-opus-4-8")'),'claude-opus-4.8');
    assert.equal(h.eval('normalize("gpt-6-astra")'),'gpt-6-astra');
  }
  assert.equal(harness([]).eval('normalize("claude-opus-5-5")'),'claude-opus-5.5');
});
test('an unserved Claude id falls back to the newest served id of its family (no 400)',async()=>{
  const h=harness([{id:'claude-opus-4.8'},{id:'claude-sonnet-4.6'},{id:'claude-haiku-4.5'}]);
  await h.eval('refreshModels()');
  assert.equal(h.eval('normalize("claude-opus-5-5")'),'claude-opus-4.8');
  assert.equal(h.eval('normalize("claude-sonnet-5-5")'),'claude-sonnet-4.6');
  assert.equal(h.eval('normalize("claude-haiku-5-5")'),'claude-haiku-4.5');
  assert.equal(h.eval('normalize("claude-fable-5-1")'),'claude-opus-4.8');
  assert.equal(h.eval('normalize("claude-haiku-5-5", true)'),'claude-haiku-5.5');
});
test('sonnet/haiku aliases and old ids map to served ids, newest first',async()=>{
  const ids=['claude-opus-5.5','claude-opus-4.8','claude-sonnet-5.5','claude-sonnet-4.6','claude-haiku-5.5','claude-haiku-4.5','claude-fable-5.1','claude-fable-5'];
  const h=harness(ids.map(id=>({id})));
  await h.eval('refreshModels()');
  const cases={sonnet:'claude-sonnet-5.5',haiku:'claude-haiku-5.5',opus:'claude-opus-5.5',fable:'claude-fable-5.1',
    'claude-sonnet-5-5':'claude-sonnet-5.5','claude-haiku-5-5':'claude-haiku-5.5','claude-haiku-5-5-20261001':'claude-haiku-5.5',
    'claude-sonnet-4-6':'claude-sonnet-4.6','claude-haiku-4-5':'claude-haiku-4.5','claude-haiku-4-5-20251001':'claude-haiku-4.5',
    'claude-opus-4-8[1m]':'claude-opus-4.8','claude-fable-5':'claude-fable-5','claude-fable-5-1':'claude-fable-5.1',
    'claude-3-5-haiku-20241022':'claude-haiku-5.5','claude-3-7-sonnet-latest':'claude-sonnet-5.5','gpt-6.1-sol':'gpt-6.1-sol'};
  for(const [input,expected] of Object.entries(cases)) assert.equal(h.eval(`normalize(${JSON.stringify(input)})`),expected,input);
  // Variant ids (e.g. fast/1m) never become the family default.
  const v=harness([{id:'claude-opus-4.8'},{id:'claude-opus-4.8-fast'}]);await v.eval('refreshModels()');
  assert.equal(v.eval('normalize("opus")'),'claude-opus-4.8');
});
test('cold start (no catalog) uses the dotted id or a built-in family default',()=>{
  const h=harness([]);
  for(const [input,expected] of [['sonnet','claude-sonnet-5.5'],['haiku','claude-haiku-5.5'],['claude-haiku-5-5','claude-haiku-5.5'],['claude-sonnet-4-6','claude-sonnet-4.6']])
    assert.equal(h.eval(`normalize(${JSON.stringify(input)})`),expected,input);
});
test('Messages honours x-cck-exact-model and does not forward the header',async()=>{
  const h=harness([{id:'claude-opus-4.8'}]);await h.eval('refreshModels()');
  await h.post('claude-opus-5-5','/v1/messages',{messages:[{role:'user',content:'hi'}]},{'x-cck-exact-model':'1'});
  let sent=h.upstream.at(-1);
  assert.equal(JSON.parse(sent.params.body.toString()).model,'claude-opus-5.5');
  assert.equal(sent.params.headers['x-cck-exact-model'],undefined);
  await h.post('claude-opus-5-5','/v1/messages',{messages:[{role:'user',content:'hi'}]});
  assert.equal(JSON.parse(h.upstream.at(-1).params.body.toString()).model,'claude-opus-4.8');
});
test('haiku requests drop thinking/effort after alias mapping',async()=>{
  const h=harness([{id:'claude-haiku-5.5'}]);await h.eval('refreshModels()');
  await h.post('haiku','/v1/messages',{thinking:{type:'enabled',budget_tokens:1024},reasoning_effort:'high',messages:[{role:'user',content:'hi'}]});
  const body=JSON.parse(h.upstream.at(-1).params.body.toString());
  assert.equal(body.model,'claude-haiku-5.5');assert.equal(body.thinking,undefined);assert.equal(body.reasoning_effort,undefined);
});
test('output budget uses the built-in table when upstream has no limit',async()=>{
  for(const [id,stream,expected] of [['claude-sonnet-4.6',true,32000],['claude-haiku-4.5',true,64000],['claude-haiku-5.5',true,64000],
      ['claude-opus-5.5',true,64000],['claude-fable-5.1',true,64000],['claude-opus-4.5',true,32000],['claude-sonnet-4.6',false,16000]]){
    const h=harness([{id}]);await h.eval('refreshModels()');
    await h.post(id,'/v1/messages',{stream,max_tokens:1024,messages:[{role:'user',content:'ping'}]});
    assert.equal(JSON.parse(h.upstream.at(-1).params.body.toString()).max_tokens,expected,id);
  }
  const h=harness([]);
  assert.equal(h.eval('outputCeiling("claude-sonnet-4-6")'),32000);
  assert.equal(h.eval('outputCeiling("gpt-6-astra")'),32000);
});
test('Messages forwards Opus 5.5 tools, thinking and upstream output limit',async()=>{
  const h=harness([{id:'claude-opus-5.5',capabilities:{limits:{max_output_tokens:128000}}}]);
  const extra={stream:true,thinking:{type:'adaptive'},tools:[{name:'read_file',input_schema:{type:'object'}}],
    tool_choice:{type:'auto'},messages:[{role:'user',content:'hello'}]};
  await h.post('claude-opus-5-5','/v1/messages',extra);
  const body=JSON.parse(h.upstream.at(-1).params.body.toString());
  assert.equal(body.model,'claude-opus-5.5'); assert.equal(body.max_tokens,128000);
  for(const k of ['thinking','tools','tool_choice','messages']) assert.deepEqual(body[k],extra[k]);
});

test('non-streaming budgets respect live ceilings, including invalid metadata',async()=>{
  for(const [limit,expected] of [[8192,8192],[128000,16000],[0,16000],[-1,16000],['8192',16000]]){
    const h=harness([{id:'claude-opus-5.5',capabilities:{limits:{max_output_tokens:limit}}}]);
    await h.post('claude-opus-5-5','/v1/messages',{stream:false,max_tokens:1024,messages:[{role:'user',content:'ping'}]});
    assert.equal(JSON.parse(h.upstream.at(-1).params.body.toString()).max_tokens,expected);
  }
});
test('stalled discovery is bounded, shared, and does not block startup',async()=>{
  const h=harness([], 'stall');
  const first=h.eval('refreshModels()');
  assert.equal(first,h.eval('refreshModels()'));
  await first;
  assert.equal(h.state.lookups,1);assert.equal(h.state.destroyed,1);
  assert.equal(h.state.listening,true);
  // With no model list yet, every request retries discovery (like main did).
  await h.post('gpt-6-astra');
  assert.equal(h.state.lookups,2);
  h.state.mode='ok';
  await h.post('gpt-6-astra');
  assert.equal(h.state.lookups,3);
  await h.post('gpt-6-astra');
  assert.equal(h.state.lookups,3);
});
test('with a valid model list, a failed refresh backs off for 30s',async()=>{
  const h=harness([{id:'claude-opus-5.5'}]);
  await h.eval('refreshModels()');
  assert.equal(h.state.lookups,1);
  h.state.mode='error';
  h.eval('lastFetch = 0');
  await h.post('gpt-6-astra');
  assert.equal(h.state.lookups,2);
  await h.post('gpt-6-astra');
  assert.equal(h.state.lookups,2);
  assert.equal(h.eval('normalize("opus")'),'claude-opus-5.5');
});
test('/responses: idle upstream is aborted with a 502, stream errors end the response',async()=>{
  const h=harness();
  h.state.fetchMode='stall';
  const stalled=await h.post('gpt-6-astra');
  assert.equal(stalled.status,502);assert.match(stalled.body,/no upstream activity/);
  h.state.fetchMode='stream-error';
  const broken=await h.post('gpt-6-astra');
  assert.equal(broken.status,200);assert.equal(broken.destroyed,true);
});
test('failed refreshes preserve cached model ids and recover on a later refresh',async()=>{
  const h=harness([{id:'claude-opus-5-5'}]);
  await h.eval('refreshModels()');
  for(const mode of ['stall','abort','error','invalid']){
    h.state.mode=mode;
    await h.eval('refreshModels()');
    assert.equal(h.eval('normalize("claude-opus-5.5")'),'claude-opus-5-5');
  }
  h.state.mode='ok';
  await h.eval('refreshModels()');
  assert.equal(h.state.lookups,6);
});

test('real stalled HTTP discovery still lets the normalizer start', {timeout:8000}, async()=>{
  const http=require('node:http');
  const {spawn}=require('node:child_process');
  const upstream=http.createServer((_req,_res)=>{});
  await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
  const script=source.replace('const UPSTREAM_PORT = 4141;',`const UPSTREAM_PORT = ${upstream.address().port};`)
    .replace('const LISTEN_PORT = 4142;','const LISTEN_PORT = 0;');
  const child=spawn(process.execPath,['-e',script],{stdio:['ignore','ignore','pipe']});
  let deadline;
  try {
    await new Promise((resolve,reject)=>{
      let log='';
      deadline=setTimeout(()=>reject(new Error('normalizer never started')),7000);
      child.on('error',reject);
      child.on('exit',code=>reject(new Error(`normalizer exited early: ${code}`)));
      child.stderr.on('data',chunk=>{log+=chunk;if(log.includes('model-normalizer listening'))resolve();});
    });
  } finally {
    clearTimeout(deadline);
    const exited=new Promise(resolve=>child.once('close',resolve));
    child.kill();await exited;
    upstream.closeAllConnections();await new Promise(resolve=>upstream.close(resolve));
  }
});

// --- real HTTP: idle timeout vs. long streams, upstream resets ------------
async function freePort(){const http=require('node:http');const s=http.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
async function withNormalizer(onMessages, fn){
  const http=require('node:http');const os=require('node:os');const path=require('node:path');
  const {spawn}=require('node:child_process');
  const upstream=http.createServer((req,res)=>{
    if(req.url.startsWith('/v1/models')){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{id:'claude-opus-5.5'}]}));return;}
    req.resume();req.on('end',()=>onMessages(req,res));
  });
  await new Promise(r=>upstream.listen(0,'127.0.0.1',r));
  const port=await freePort();
  const script=source.replace('const UPSTREAM_PORT = 4141;',`const UPSTREAM_PORT = ${upstream.address().port};`)
    .replace('const LISTEN_PORT = 4142;',`const LISTEN_PORT = ${port};`)
    .replace('const UPSTREAM_IDLE_MS = 300000;','const UPSTREAM_IDLE_MS = 400;');
  assert.notEqual(script,source);
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'cck-norm-'));
  const child=spawn(process.execPath,['-e',script],{stdio:['ignore','ignore','pipe'],env:{...process.env,HOME:home}});
  let log='';child.stderr.on('data',c=>log+=c);
  try{
    await new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(new Error('no start')),5000);
      child.stderr.on('data',()=>{if(log.includes('listening')){clearTimeout(t);resolve();}});child.on('exit',c=>reject(new Error('exit '+c)));});
    await fn(port,()=>log);
  } finally {
    const exited=new Promise(r=>child.once('close',r));child.kill();await exited;
    upstream.closeAllConnections();await new Promise(r=>upstream.close(r));fs.rmSync(home,{recursive:true,force:true});
  }
}
function postMessages(port){
  const http=require('node:http');
  return new Promise((resolve)=>{
    const started=Date.now();let data='';
    const req=http.request({host:'127.0.0.1',port,path:'/v1/messages',method:'POST',headers:{'content-type':'application/json'}},(res)=>{
      res.on('data',c=>data+=c);
      res.on('end',()=>resolve({status:res.statusCode,data,complete:true,ms:Date.now()-started}));
      res.on('error',()=>resolve({status:res.statusCode,data,complete:false,ms:Date.now()-started}));
      res.on('aborted',()=>{});
    });
    req.on('error',(e)=>resolve({error:e.message,data,complete:false,ms:Date.now()-started}));
    req.end(JSON.stringify({model:'claude-opus-5-5',stream:true,messages:[{role:'user',content:'hi'}]}));
  });
}
test('a long stream that keeps sending survives the idle timeout',{timeout:10000},async()=>{
  await withNormalizer((req,res)=>{
    res.writeHead(200,{'content-type':'text/event-stream'});let n=0;
    const t=setInterval(()=>{res.write(`data: ${n}\n\n`);if(++n===8){clearInterval(t);res.end('data: [DONE]\n\n');}},150);
  },async(port)=>{
    const r=await postMessages(port);
    assert.equal(r.complete,true);assert.ok(r.ms>=1000,`stream lasted ${r.ms}ms`);
    assert.match(r.data,/data: 7/);assert.match(r.data,/\[DONE\]/);
  });
});
test('a stalled upstream is cut after the idle timeout; a reset does not crash the proxy',{timeout:10000},async()=>{
  let mode='stall';
  await withNormalizer((req,res)=>{
    if(mode==='stall'){res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: first\n\n');return;}
    if(mode==='reset'){res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: x\n\n');setTimeout(()=>res.socket.destroy(),50);return;}
    res.writeHead(200,{'content-type':'application/json'});res.end('{"ok":true}');
  },async(port,log)=>{
    const stalled=await postMessages(port);
    assert.equal(stalled.complete,false);assert.match(stalled.data,/first/);
    assert.ok(stalled.ms>=350&&stalled.ms<3000,`cut after ${stalled.ms}ms`);
    mode='reset';
    const reset=await postMessages(port);
    assert.equal(reset.complete,false);
    mode='ok';
    const ok=await postMessages(port);
    assert.equal(ok.status,200);assert.equal(ok.data,'{"ok":true}');
    assert.match(log(),/no upstream activity/);
  });
});

// Live /v1/models of a Copilot account with no Claude models (VPS run 2026-10-08).
const LIVE_NO_CLAUDE=['gpt-3.5-turbo','gpt-3.5-turbo-0613','gpt-4','gpt-4-0125-preview','gpt-4-0613','gpt-4.1','gpt-4.1-2025-04-14',
  'gpt-41-copilot','gpt-4o','gpt-4o-2024-05-13','gpt-4o-2024-08-06','gpt-4o-2024-11-20','gpt-4o-mini','gpt-4o-mini-2024-07-18',
  'gpt-4-o-preview','gpt-5.3-codex','gpt-5.4','gpt-5.4-mini','gpt-5.5','gpt-5.6-luna','gpt-5.6-sol','gpt-5.6-sol-fast','gpt-5.6-terra',
  'gpt-5-mini','gpt-6.1-sol','gpt-6-astra','gpt-6-luna','gpt-6-sol','grok-4.5','grok-4.6','grok-4.7','mai-code-1.1-flash',
  'text-embedding-3-small','text-embedding-3-small-inference','text-embedding-ada-002','trajectory-compaction'];
test('picker view (GET /v1/models via :4142) keeps every non-Claude id from a live list',async()=>{
  const h=harness(LIVE_NO_CLAUDE.map(id=>({id,object:'model'})));
  const r=await h.get('/v1/models');
  assert.equal(r.status,200);
  assert.deepEqual(JSON.parse(r.body).data.map(m=>m.id),LIVE_NO_CLAUDE);
  // Claude ids are still re-spelled and variants hidden when present.
  const c=harness([{id:'gpt-6-astra'},{id:'claude-opus-5.5'},{id:'claude-opus-5.5-high'}]);
  assert.deepEqual(JSON.parse((await c.get('/v1/models')).body).data.map(m=>m.id),['gpt-6-astra','claude-opus-5-5-20260301']);
});
test('no Claude models on the account: clear error instead of a raw 400, nothing forwarded',async()=>{
  const h=harness(LIVE_NO_CLAUDE.map(id=>({id})));await h.eval('refreshModels()');
  for(const [model,headers] of [['sonnet',{}],['haiku',{}],['opus',{}],['claude-opus-5-5',{'x-cck-exact-model':'1'}],['claude-haiku-4-5[1m]',{}]]){
    const before=h.upstream.length;
    const r=await h.post(model,'/v1/messages',{messages:[{role:'user',content:'hi'}]},headers);
    assert.equal(r.status,400,model);
    const e=JSON.parse(r.body);
    assert.equal(e.type,'error');assert.equal(e.error.code,'copilot_no_claude_models');
    assert.match(e.error.message,/no Claude models enabled; ask your org admin to enable them in Copilot policy/);
    assert.equal(h.upstream.length,before,model);
  }
  // GPT over Responses and non-Claude Messages requests are unaffected.
  await h.post('gpt-6-astra','/v1/responses');
  assert.equal(JSON.parse(h.upstream.at(-1).params.body.toString()).model,'gpt-6-astra');
  const before=h.upstream.length;
  await h.post('gpt-4.1','/v1/messages',{messages:[{role:'user',content:'hi'}]});
  assert.equal(h.upstream.length,before+1);
});
test('no false "no Claude" error on a cold start or when Claude is served',async()=>{
  for(const models of [[],[{id:'gpt-6-astra'},{id:'claude-haiku-4.5'}]]){
    const h=harness(models);await h.eval('refreshModels()');
    if(!models.length) h.state.mode='error';
    const before=h.upstream.length;
    await h.post('haiku','/v1/messages',{messages:[{role:'user',content:'hi'}]});
    assert.equal(h.upstream.length,before+1);
  }
});

// GitHub changelog 2026-10-15: Claude Opus 4.8 (except individual annual plans)
// and Claude Opus 5 are deprecated 2026-11-16; suggested alternative Opus 5.5.
test('retired Opus ids fall back to the newest served Opus once the catalog drops them',async()=>{
  const h=harness([{id:'claude-opus-5.5'},{id:'claude-sonnet-5.5'},{id:'claude-haiku-5.5'}]);await h.eval('refreshModels()');
  for(const id of ['claude-opus-4-8','claude-opus-4.8','claude-opus-4-8[1m]','claude-opus-4-8-20260301','claude-opus-5','claude-opus-5-20260301','claude-opus-5[1m]'])
    assert.equal(h.eval(`normalize(${JSON.stringify(id)})`),'claude-opus-5.5',id);
  // Annual-plan seats that keep Opus 4.8 still get exactly what they asked for.
  const annual=harness([{id:'claude-opus-4.8'},{id:'claude-opus-5.5'}]);await annual.eval('refreshModels()');
  assert.equal(annual.eval('normalize("claude-opus-4-8")'),'claude-opus-4.8');
});
const NOT_SUPPORTED=JSON.stringify({error:{message:JSON.stringify({error:{message:'The requested model is not supported.',code:'model_not_supported',param:'model',type:'invalid_request_error'}}),type:'error'}});
function retiringUpstream(h,gone){
  h.state.reply=(j)=>gone.includes(j.model)?{status:400,data:NOT_SUPPORTED}:{status:200,data:JSON.stringify({type:'message',model:j.model})};
}
test('stale catalog: a retired Opus that Copilot rejects is retried once on the newest served Opus',async()=>{
  // copilot-api caches /models at startup, so after 2026-11-16 it can still list the retired ids.
  const h=harness([{id:'claude-opus-4.8'},{id:'claude-opus-5'},{id:'claude-opus-5.5'}]);await h.eval('refreshModels()');
  retiringUpstream(h,['claude-opus-4.8','claude-opus-5']);
  for(const [input,failed] of [['claude-opus-4-8','claude-opus-4.8'],['claude-opus-5','claude-opus-5']]){
    const before=h.upstream.length;
    const r=await h.post(input,'/v1/messages',{stream:true,messages:[{role:'user',content:'hi'}]});
    assert.equal(r.status,200,input);
    const sent=h.upstream.slice(before).map(u=>JSON.parse(u.params.body.toString()));
    assert.deepEqual(sent.map(b=>b.model),[failed,'claude-opus-5.5'],input);
    assert.equal(sent[1].max_tokens,64000);
    // Now known to be gone: the next request goes straight to Opus 5.5 and the picker hides it.
    const again=h.upstream.length;
    await h.post(input,'/v1/messages',{messages:[{role:'user',content:'hi'}]});
    assert.deepEqual(h.upstream.slice(again).map(u=>JSON.parse(u.params.body.toString()).model),['claude-opus-5.5']);
  }
  const picker=JSON.parse((await h.get('/v1/models')).body).data.map(m=>m.id);
  assert.deepEqual(picker,['claude-opus-5-5-20260301']);
  // The rejection expires, so an id Copilot serves again is used again.
  h.eval('rejected.set("claude-opus-4.8", Date.now() - REJECTED_TTL_MS - 1)');
  assert.equal(h.eval('normalize("claude-opus-4-8")'),'claude-opus-4.8');
});
test('model_not_supported retry never happens in exact mode, for other 400s, or without a served alternative',async()=>{
  const h=harness([{id:'claude-opus-4.8'},{id:'claude-opus-5.5'}]);await h.eval('refreshModels()');
  retiringUpstream(h,['claude-opus-4.8']);
  let before=h.upstream.length;
  let r=await h.post('claude-opus-4-8','/v1/messages',{messages:[{role:'user',content:'hi'}]},{'x-cck-exact-model':'1'});
  assert.equal(r.status,400);assert.match(r.body,/model_not_supported/);assert.equal(h.upstream.length,before+1);
  h.state.reply=()=>({status:400,data:'{"error":{"message":"prompt is too long","type":"error"}}'});
  before=h.upstream.length;
  r=await h.post('claude-opus-5-5','/v1/messages',{messages:[{role:'user',content:'hi'}]});
  assert.equal(r.status,400);assert.match(r.body,/prompt is too long/);assert.equal(h.upstream.length,before+1);
  // Only the retired id is served (stale): nothing to retry on, the real error is returned.
  const only=harness([{id:'claude-opus-4.8'}]);await only.eval('refreshModels()');
  retiringUpstream(only,['claude-opus-4.8']);
  r=await only.post('opus','/v1/messages',{messages:[{role:'user',content:'hi'}]});
  assert.equal(r.status,400);assert.match(r.body,/model_not_supported/);assert.equal(only.upstream.length,1);
});
test('GPT-5.6 Terra is never silently substituted over Responses',async()=>{
  const h=harness([{id:'gpt-6.1-sol'},{id:'gpt-6-astra'}]);await h.eval('refreshModels()');
  await h.post('gpt-5.6-terra','/v1/responses');
  assert.equal(JSON.parse(h.upstream.at(-1).params.body.toString()).model,'gpt-5.6-terra');
});
