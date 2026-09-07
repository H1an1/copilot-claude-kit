"""Offline regression tests; never write to the developer's real HOME."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import tomllib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'install.sh').read_text()
LIB = SOURCE.split('# CLI dispatch')[0]

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.lib = self.home / 'functions.sh'
        self.lib.write_text(LIB)
        self.env = dict(os.environ, HOME=str(self.home), CODEX_HOME=str(self.home / '.codex'))

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, code, ok=True):
        result = subprocess.run(['bash', '-c', 'source "$1"\n' + code, '_', str(self.lib)],
                                env=self.env, text=True, capture_output=True, timeout=75)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_catalog_merge_rerun_restore(self):
        d = self.home / '.codex'; d.mkdir()
        original = '''model = "original"
model_provider = "other"
approval_policy = "never"
approvals_reviewer = "auto_review"
sandbox_mode = "read-only"
[model_providers.copilot]
base_url = "http://old.invalid"
[apps.example]
enabled = false
'''
        (d / 'config.toml').write_text(original)
        (d / 'copilot-models.json').write_text('{"original": true}')
        self.run_shell('CODEX_VERIFIED_MODELS=(gpt-6-astra gpt-5.6-sol gpt-5.5)\nwrite_codex_catalog\nmerge_codex_desktop_config\nmerge_codex_desktop_config')
        cfg = tomllib.loads((d / 'config.toml').read_text())
        self.assertEqual(cfg['model'], 'gpt-6-astra')
        self.assertEqual(cfg['approvals_reviewer'], 'user')
        self.assertEqual(cfg['approval_policy'], 'on-request')
        self.assertEqual(cfg['sandbox_mode'], 'workspace-write')
        self.assertFalse(cfg['apps']['example']['enabled'])
        self.assertEqual(cfg['model_providers']['copilot']['base_url'], 'http://127.0.0.1:4142/v1')
        catalog = json.loads((d / 'copilot-models.json').read_text())
        self.assertEqual([m['slug'] for m in catalog['models']], ['gpt-6-astra','gpt-5.6-sol','gpt-5.5'])
        self.run_shell('restore_codex_desktop_config')
        self.assertEqual(tomllib.loads((d / 'config.toml').read_text()), tomllib.loads(original))
        self.assertEqual(json.loads((d / 'copilot-models.json').read_text()), {'original': True})

    def test_granular_policy_merge_and_restore(self):
        d=self.home/'.codex'; d.mkdir()
        original='[approval_policy.granular]\nsandbox_approval = false\n[apps.example]\nenabled = true\n'
        (d/'config.toml').write_text(original)
        self.run_shell('merge_codex_desktop_config; merge_codex_desktop_config')
        cfg=tomllib.loads((d/'config.toml').read_text())
        self.assertEqual(cfg['approval_policy'],'on-request')
        self.run_shell('restore_codex_desktop_config')
        self.assertEqual(tomllib.loads((d/'config.toml').read_text()),tomllib.loads(original))

    def test_failed_model_leaves_config_untouched(self):
        d = self.home / '.codex'; d.mkdir()
        config = d / 'config.toml'; config.write_text('model = "original"\n')
        result = self.run_shell('codex_smoke_test() { return 1; }; select_codex_models; merge_codex_desktop_config', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), 'model = "original"\n')

    def test_only_successful_models_in_catalog(self):
        self.run_shell('codex_smoke_test() { [ "$1" != gpt-5.6-sol ]; }; select_codex_models; write_codex_catalog')
        models = json.loads((self.home / '.codex/copilot-models.json').read_text())['models']
        self.assertEqual([m['slug'] for m in models], ['gpt-6-astra', 'gpt-5.5'])

    def test_smoke_rejects_failed_empty_and_malformed_responses(self):
        for payload, expected in [({'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'pong'}]}]},0),
                                  ({'status':'failed','output':[]},1), ({'status':'incomplete','output':[]},1),
                                  ({'status':'completed','output':[]},1), ('not json',1)]:
            (self.home / 'response').write_text(json.dumps(payload) if isinstance(payload, dict) else payload)
            r=self.run_shell('curl() { cat "$HOME/response"; }; codex_smoke_test',ok=False)
            self.assertEqual(r.returncode,expected,r.stdout+r.stderr)

    def test_cli_validation_precedes_install(self):
        for args in [['--with-codex-desktop','--codex-model'], ['--with-codex-desktop','--codex-model','codex-auto-review'], ['--verify','--codex-model','gpt-6-astra']]:
            r=subprocess.run(['bash',str(ROOT/'install.sh'),*args],env=self.env,capture_output=True)
            self.assertNotEqual(r.returncode,0)
            self.assertFalse((self.home/'.copilot-api').exists())

    def test_cli_profile(self):
        self.run_shell('CODEX_DESKTOP_MODEL=gpt-5.6-sol; write_codex_profile')
        cfg=tomllib.loads((self.home/'.codex/copilot.config.toml').read_text())
        self.assertEqual(cfg['model'],'gpt-5.6-sol')
        self.assertEqual(self.run_shell('read_codex_model "$CODEX_PROFILE"').stdout.strip(),'gpt-5.6-sol')
        self.assertEqual(cfg['approvals_reviewer'],'user')
        self.assertFalse((self.home/'.codex/config.toml').exists())

    def test_approval_rpc_requires_real_callback(self):
        # A fake app-server exercises the same subprocess/RPC test as installation.
        fake=self.home/'codex-fake'
        fake.write_text('''#!/usr/bin/env node
const rl=require('readline').createInterface({input:process.stdin});
const mode=process.env.CCK_TEST_MODE;
const send=o=>console.log(JSON.stringify(o));
rl.on('line',l=>{const m=JSON.parse(l); if(!m.method)return;
let result={};
if(m.method==='config/read') result={config:{model_provider:'copilot',approval_policy:'on-request',approvals_reviewer:mode==='auto'?'auto_review':'user'}};
if(m.method==='thread/start')result={thread:{id:'test'},approvalPolicy:'on-request',approvalsReviewer:'user'};
if(m.id!==undefined)send({id:m.id,result});
if(m.method==='turn/start') {
 if(mode==='approval')send({id:999,method:'item/commandExecution/requestApproval',params:{threadId:'test'}});
 else send({method:'turn/completed',params:{}});
}
});
''');fake.chmod(0o755)
        for mode,expected in [('approval',0),('no_callback',1),('auto',1)]:
            self.env['CCK_TEST_MODE']=mode
            r=self.run_shell('find_codex_binary() { printf "%s" "$HOME/codex-fake"; }; codex_approval_test',ok=False)
            self.assertEqual(r.returncode,expected,r.stdout+r.stderr)

if __name__ == '__main__': unittest.main()
