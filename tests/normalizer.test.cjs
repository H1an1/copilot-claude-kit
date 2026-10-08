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
      req.end=(body)=>{
        const r=new EventEmitter(); r.statusCode=200; r.headers={};
        r.pipe=res=>res.end('{}');
        if(options.method==='POST') upstream.push({params:{body},url:options.path});
        if(options.path==='/v1/models') {
          state.lookups++;
          if(state.mode==='stall')return;
          if(state.mode==='error'){req.emit('error',new Error('offline'));return;}
          if(state.mode==='abort'){fn(r);r.emit('aborted');return;}
          if(state.mode==='invalid'){fn(r);r.emit('data','{invalid');r.emit('end');return;}
        }
        fn(r); r.emit('data',JSON.stringify({data:models})); r.emit('end');
      };
      return req;
    }
  };
  const context={require(name) { if(name==='http')return http; if(name==='fs')return {readFileSync(){return 'fake-token';}}; return require(name); },
    setTimeout: (fn,ms)=>setTimeout(fn,Math.min(ms,25)), clearTimeout,
    process:{env:{HOME:'/test'}}, Buffer, console:{error(){}}, fetch:async(url,params)=>{
      upstream.push({url,params});
      if(url.includes('copilot_internal')) return {ok:true,json:async()=>({token:'test',expires_at:9999999999,endpoints:{api:'https://copilot.test'}})};
      return {status:200,headers:new Map(),body:null,text:async()=>'{"status":"completed"}'};
    }};
  vm.runInNewContext(source,context);
  return { upstream, state, eval(code) { return vm.runInNewContext(code,context); }, async post(model, url='/v1/responses', extra={}) {
    const req=new EventEmitter();Object.assign(req,{method:'POST',url,headers:{}});
    return new Promise(resolve=>{const res={writeHead(status){this.status=status;},end(body){resolve({status:this.status,body});}};
      handler(req,res);req.emit('data',Buffer.from(JSON.stringify({model,...extra})));req.emit('end');});
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
  for(const model of ['gpt-6-astra','gpt-5.6-sol','gpt-5.5']){
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
test('explicit Opus 5.5 never downgrades on cold or older catalogs',()=>{
  for(const models of [[],[{id:'claude-opus-4.8'}]]){
    const h=harness(models);
    assert.equal(h.eval('normalize("claude-opus-5-5")'),'claude-opus-5.5');
    assert.equal(h.eval('normalize("claude-opus-5.5")'),'claude-opus-5.5');
    assert.equal(h.eval('normalize("claude-opus-4-8")'),'claude-opus-4.8');
    assert.equal(h.eval('normalize("gpt-6-astra")'),'gpt-6-astra');
  }
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
  // Failed lookup backs off instead of holding each incoming request again.
  await h.post('gpt-6-astra');
  assert.equal(h.state.lookups,1);
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
