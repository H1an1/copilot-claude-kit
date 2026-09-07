"""Opt-in: real installed Codex + a local Responses fixture, no account/API calls.
Run: CCK_CODEX_INTEGRATION=1 python3 -m unittest discover -s tests -v
"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.environ.get('CCK_CODEX_INTEGRATION')=='1','opt-in real Codex protocol test')
class CodexIntegration(unittest.TestCase):
    def test_actual_codex_requests_manual_approval(self):
        requests=[]
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(body)
                tools=body.get('tools',[])
                names=[t.get('name') for t in tools]
                name=next((n for n in ['shell_command','exec_command','shell'] if n in names),None)
                if not name:
                    self.send_error(500,'No shell tool: '+str(names)); return
                command='printf cck-approval-probe'
                args={'command':command,'sandbox_permissions':'require_escalated','justification':'Test the approval dialog'}
                if name=='exec_command': args['cmd']=args.pop('command')
                if name=='shell': args['command']=['/bin/sh','-c',command]
                item={'type':'function_call','id':'fc_test','call_id':'call_test','name':name,'arguments':json.dumps(args)}
                events=[{'type':'response.created','response':{'id':'resp_test','status':'in_progress','output':[]}},
                        {'type':'response.output_item.added','output_index':0,'item':dict(item,arguments='')},
                        {'type':'response.function_call_arguments.delta','item_id':'fc_test','output_index':0,'delta':item['arguments']},
                        {'type':'response.output_item.done','output_index':0,'item':item},
                        {'type':'response.completed','response':{'id':'resp_test','status':'completed','output':[item],'usage':{'input_tokens':10,'output_tokens':10,'total_tokens':20}}}]
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
                for e in events: self.wfile.write(('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n').encode())
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                lib=Path(tmp)/'functions.sh';lib.write_text((ROOT/'install.sh').read_text().split('# CLI dispatch')[0])
                env=dict(os.environ,HOME=tmp,CODEX_HOME=str(Path(tmp)/'.codex'))
                code='source "$1"\nNORM_PORT="$2"\nCODEX_VERIFIED_MODELS=(gpt-6-astra)\nwrite_codex_catalog\nmerge_codex_desktop_config\ncodex_approval_test'
                r=subprocess.run(['bash','-c',code,'_',str(lib),str(server.server_port)],env=env,text=True,capture_output=True,timeout=70)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                self.assertTrue(requests)
                self.assertEqual({r['model'] for r in requests},{'gpt-6-astra'})
        finally:
            server.shutdown();server.server_close()
