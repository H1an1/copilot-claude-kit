const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const source = fs.readFileSync(require('node:path').join(__dirname, '../install.sh'), 'utf8')
  .split("<<'NORMALIZER_EOF'\n")[1].split('\nNORMALIZER_EOF')[0];
function harness() {
  let handler; const upstream=[];
  const http = {
    createServer(fn) { handler=fn; return { listen() {} }; },
    request(options, fn) {
      const req=new EventEmitter();
      req.end=()=>{ const r=new EventEmitter(); fn(r); r.emit('data',JSON.stringify({data:[{id:'gpt-6-astra'}]})); r.emit('end'); };
      return req;
    }
  };
  const context={require(name) { if(name==='http')return http; if(name==='fs')return {readFileSync(){return 'fake-token';}}; return require(name); },
    process:{env:{HOME:'/test'}}, Buffer, console:{error(){}}, fetch:async(url,params)=>{
      upstream.push({url,params});
      if(url.includes('copilot_internal')) return {ok:true,json:async()=>({token:'test',expires_at:9999999999,endpoints:{api:'https://copilot.test'}})};
      return {status:200,headers:new Map(),body:null,text:async()=>'{"status":"completed"}'};
    }};
  vm.runInNewContext(source,context);
  return { upstream, async post(model, url='/v1/responses', extra={}) {
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
