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
        self.run_shell('codex_smoke_test() { echo "$1" >> "$HOME/probed"; [ "$1" != gpt-5.6-sol ]; }; select_codex_models; write_codex_catalog')
        models = json.loads((self.home / '.codex/copilot-models.json').read_text())['models']
        self.assertEqual([m['slug'] for m in models],
                         ['gpt-6-astra','gpt-6.1-sol','gpt-6-sol','gpt-6-luna','gpt-5.6-sol-fast','gpt-5.6-luna','gpt-5.5','gpt-5.3-codex'])
        # Retiring models (gpt-5.6-terra, deprecated 2026-11-16) are not probed for the picker.
        self.assertNotIn('gpt-5.6-terra',(self.home/'probed').read_text().split())

    def test_retiring_codex_model_is_accepted_explicitly_with_a_warning(self):
        choices=self.run_shell('printf "%s\\n" "${CODEX_MODEL_CHOICES[@]}"').stdout.split()
        self.assertNotIn('gpt-5.6-terra',choices)
        script=SOURCE.replace('case "$COMMAND" in\n  ""|install)','echo "parsed:$CODEX_DESKTOP_MODEL"; exit 0\ncase "$COMMAND" in\n  ""|install)')
        r=subprocess.run(['bash','-c',script,'install.sh','--with-codex-desktop','--codex-model','gpt-5.6-terra'],
                         env=self.env,capture_output=True,text=True,timeout=30)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('deprecated by GitHub Copilot on 2026-11-16',r.stdout)
        self.assertIn('gpt-6.1-sol',r.stdout)
        self.assertEqual(r.stdout.strip().splitlines()[-1],'parsed:gpt-5.6-terra')
        # An explicit selection is still verified first and kept at the top of the picker.
        self.run_shell('CODEX_DESKTOP_MODEL=gpt-5.6-terra; codex_smoke_test() { echo "$1" >> "$HOME/probed"; }; select_codex_models; write_codex_catalog')
        self.assertEqual((self.home/'probed').read_text().split().count('gpt-5.6-terra'),1)
        models=json.loads((self.home/'.codex/copilot-models.json').read_text())['models']
        self.assertEqual(models[0]['slug'],'gpt-5.6-terra')
        self.assertEqual(models[0]['display_name'],'GPT-5.6 Terra (Copilot)')
        # Other mode validation still applies.
        r=subprocess.run(['bash',str(ROOT/'install.sh'),'--verify','--codex-model','gpt-5.6-terra'],env=self.env,capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.home/'.copilot-api').exists())

    def test_catalog_names_and_reasoning_levels_per_model(self):
        self.run_shell('CODEX_VERIFIED_MODELS=(gpt-6.1-sol gpt-6-astra gpt-5.5 gpt-5.3-codex); write_codex_catalog')
        models={m['slug']:m for m in json.loads((self.home/'.codex/copilot-models.json').read_text())['models']}
        self.assertEqual(models['gpt-6.1-sol']['display_name'],'GPT-6.1 Sol (Copilot)')
        self.assertEqual(models['gpt-5.3-codex']['display_name'],'GPT-5.3-Codex (Copilot)')
        levels=lambda slug:[l['effort'] for l in models[slug]['supported_reasoning_levels']]
        self.assertEqual(levels('gpt-6.1-sol'),['low','medium','high','xhigh','max'])
        self.assertEqual(levels('gpt-6-astra'),['low','medium','high','xhigh','max'])
        self.assertEqual(levels('gpt-5.5'),['low','medium','high','xhigh'])
        self.assertEqual(levels('gpt-5.3-codex'),['low','medium','high','xhigh'])
        self.assertEqual([m['priority'] for m in models.values()],[1,2,3,4])

    def test_cli_accepts_every_listed_codex_model_and_rejects_others(self):
        choices=self.run_shell('printf "%s\\n" "${CODEX_MODEL_CHOICES[@]}"').stdout.split()
        self.assertEqual(choices[0],'gpt-6.1-sol')
        for model in ['gpt-6.1-sol','gpt-6-luna','gpt-5.3-codex','gpt-5.5','gpt-5.6-luna','gpt-5.6-sol-fast']:
            self.assertIn(model,choices)
            # Stop right after argument parsing: never reach an install step.
            script=SOURCE.replace('case "$COMMAND" in\n  ""|install)','echo "parsed:$CODEX_DESKTOP_MODEL"; exit 0\ncase "$COMMAND" in\n  ""|install)')
            self.assertNotEqual(script,SOURCE)
            r=subprocess.run(['bash','-c',script,'install.sh','--with-codex','--codex-model',model],
                             env=self.env,capture_output=True,text=True,timeout=30)
            self.assertEqual(r.stdout.strip(),f'parsed:{model}',r.stderr)
        r=subprocess.run(['bash',str(ROOT/'install.sh'),'--with-codex','--codex-model','gpt-4o'],
                         env=self.env,capture_output=True,text=True,timeout=30)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('gpt-6.1-sol',r.stderr)
        self.assertFalse((self.home/'.copilot-api').exists())

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

    def test_claude_settings_defaults_preserve_picker_and_saved_model(self):
        d=self.home/'.claude'; d.mkdir()
        path=d/'settings.json'
        path.write_text(json.dumps({'model':'sonnet','env':{'ANTHROPIC_MODEL':'old','OTHER':'keep'}}))
        self.run_shell('NODE_BIN="$(command -v node)"; merge_settings; merge_settings')
        settings=json.loads(path.read_text())
        self.assertEqual(settings['model'],'sonnet')
        self.assertEqual(settings['env']['ANTHROPIC_DEFAULT_OPUS_MODEL'],'claude-opus-5-5')
        self.assertEqual(settings['env']['ANTHROPIC_DEFAULT_SONNET_MODEL'],'claude-sonnet-5-5')
        self.assertEqual(settings['env']['ANTHROPIC_DEFAULT_HAIKU_MODEL'],'claude-haiku-5-5')
        self.assertEqual(settings['env']['ANTHROPIC_SMALL_FAST_MODEL'],'claude-haiku-5-5')
        self.assertEqual(settings['env']['ANTHROPIC_DEFAULT_MODEL'],'opus')
        self.assertNotIn('ANTHROPIC_MODEL',settings['env'])
        self.assertEqual(settings['env']['OTHER'],'keep')

    def test_uninstall_removes_every_settings_key_it_writes(self):
        self.run_shell('NODE_BIN="$(command -v node)"; merge_settings')
        path=self.home/'.claude/settings.json'
        ours=set(json.loads(path.read_text())['env'])
        data=json.loads(path.read_text()); data['env']['OTHER']='keep'; path.write_text(json.dumps(data))
        # Run only uninstall's settings cleaner (never the launchctl/rm steps).
        cleaner=SOURCE.split('do_uninstall() {')[1].split("<<'NODE_EOF'")[1].split('\n',1)[1].split('\nNODE_EOF')[0]
        subprocess.run(['node','-',str(path)],input=cleaner,text=True,check=True,env=self.env,capture_output=True)
        self.assertEqual(json.loads(path.read_text())['env'],{'OTHER':'keep'})
        self.assertTrue(ours)

    def test_claude_smoke_checks_new_model_and_actual_text(self):
        for payload,expected in [({'type':'message','content':[{'type':'text','text':'pong'}]},0),
                                 ({'type':'message','content':[]},1),({'type':'error','error':{'message':'unsupported'}},1)]:
            (self.home/'response').write_text(json.dumps(payload))
            r=self.run_shell('curl() { printf "%s\\n" "$@" > "$HOME/curl-args"; cat "$HOME/response"; }; smoke_test',ok=False)
            self.assertEqual(r.returncode,expected,r.stdout+r.stderr)
            self.assertIn('claude-opus-5-5',(self.home/'curl-args').read_text())
            self.assertIn('x-cck-exact-model: 1',(self.home/'curl-args').read_text())

    def combined_stubs(self, claude_rc=0, approval_rc=0):
        return f'''
for fn in need_macos write_plist load_service wait_for_port is_authed_retry write_watchdog_plist; do
  eval "$fn() {{ return 0; }}"
done
ensure_node() {{ NODE_BIN="$(command -v node)"; }}
ensure_copilot_api() {{ COPILOT_API_BIN=true; }}
smoke_test() {{ return {claude_rc}; }}
select_codex_models() {{ CODEX_VERIFIED_MODELS=(gpt-6-astra); }}
codex_desktop_tool_test() {{ return 0; }}
codex_approval_test() {{ return {approval_rc}; }}
'''

    def test_combined_install_writes_both_and_restore_keeps_claude(self):
        self.run_shell(self.combined_stubs() + 'do_with_codex_desktop')
        settings=self.home/'.claude/settings.json'
        before=settings.read_text()
        self.assertEqual(json.loads(before)['env']['ANTHROPIC_DEFAULT_OPUS_MODEL'],'claude-opus-5-5')
        config=tomllib.loads((self.home/'.codex/config.toml').read_text())
        self.assertEqual(config['model_provider'],'copilot')
        mode=self.home/'.copilot-api/watchdog-mode'
        self.assertEqual(mode.read_text().strip(),'combined')
        self.run_shell('need_macos() { :; }; do_restore_codex_desktop')
        self.assertEqual(settings.read_text(),before)
        self.assertEqual(mode.read_text().strip(),'claude')

    def test_combined_claude_failure_still_configures_codex_and_fails(self):
        # A missing Codex binary (2) must not mask an earlier Claude failure.
        result=self.run_shell(self.combined_stubs(claude_rc=1,approval_rc=2)+'do_with_codex_desktop',ok=False)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertTrue((self.home/'.codex/config.toml').exists())
        self.assertTrue((self.home/'.claude/settings.json').exists())

    def test_combined_codex_failure_keeps_claude(self):
        result=self.run_shell(self.combined_stubs()+'''select_codex_models() { die "unavailable"; }
do_with_codex_desktop''',ok=False)
        self.assertEqual(result.returncode,1)
        self.assertTrue((self.home/'.claude/settings.json').exists())
        self.assertFalse((self.home/'.codex/config.toml').exists())

    def test_combined_doctor_checks_both_and_reports_partial_failure(self):
        self.run_shell(self.combined_stubs()+'do_with_codex_desktop')
        for claude_rc,codex_rc in [(0,0),(1,0),(0,1)]:
            result=self.run_shell(f'''need_macos() {{ :; }}
service_loaded() {{ return 0; }}
plist_binds_loopback() {{ return 0; }}
curl() {{ return 0; }}
is_authed_retry() {{ return 0; }}
smoke_test() {{ echo checked-claude; return {claude_rc}; }}
codex_smoke_test() {{ echo checked-codex; return {codex_rc}; }}
codex_approval_test() {{ return 0; }}
do_verify''',ok=False)
            self.assertEqual(result.returncode,int(bool(claude_rc or codex_rc)))
            self.assertIn('checked-claude',result.stdout)
            self.assertIn('checked-codex',result.stdout)

    def test_single_client_install_modes_remain_separate(self):
        self.run_shell(self.combined_stubs()+'''codex_smoke_test() { return 0; }
do_with_codex''')
        self.assertFalse((self.home/'.claude/settings.json').exists())
        self.assertTrue((self.home/'.codex/copilot.config.toml').exists())
        self.assertFalse((self.home/'.codex/config.toml').exists())
        self.assertFalse((self.home/'.codex/copilot-models.json').exists())
        profile_catalog=json.loads((self.home/'.codex/copilot-profile-models.json').read_text())
        self.assertEqual([m['slug'] for m in profile_catalog['models']],['gpt-6-astra'])
        self.run_shell(self.combined_stubs()+'do_install')
        self.assertTrue((self.home/'.claude/settings.json').exists())
        self.assertFalse((self.home/'.codex/config.toml').exists())
        self.assertEqual((self.home/'.copilot-api/watchdog-mode').read_text().strip(),'claude')

    def test_combined_watchdog_probes_both_even_if_first_fails(self):
        source=SOURCE.split("<<'WATCHDOG_EOF'\n")[1].split('\nWATCHDOG_EOF')[0]
        # Source definitions only: never run launchctl or the background loop.
        lib=self.home/'watchdog-functions.sh'
        lib.write_text(source.split('\ntrim_log\n')[0])
        mode=self.home/'mode'; mode.write_text('combined')
        for claude_rc,codex_rc in [(0,0),(1,0),(0,1),(1,1)]:
            script=f'''source "$HOME/watchdog-functions.sh"
MODE_FILE="$HOME/mode"
log() {{ :; }}
works_claude() {{ echo claude >> "$HOME/probes"; return {claude_rc}; }}
works_codex() {{ echo codex >> "$HOME/probes"; return {codex_rc}; }}
works'''
            (self.home/'probes').write_text('')
            result=self.run_shell(script,ok=False)
            self.assertEqual(result.returncode,int(bool(claude_rc or codex_rc)))
            self.assertEqual((self.home/'probes').read_text().splitlines(),['claude','codex'])

    def thinking_bundle(self):
        bundle=self.home/'npm/copilot-api/dist/main.js'
        bundle.parent.mkdir(parents=True,exist_ok=True)
        bundle.write_text('''const request = {
    tool_choice: translateAnthropicToolChoiceToOpenAI(payload.tool_choice)
\t};
const responseMessage = {
    content: [...allTextBlocks, ...allToolUseBlocks],
};
''')
        return bundle

    def apply_thinking_patch(self):
        return self.run_shell('npm() { printf "%s" "$HOME/npm"; }; patch_copilot_api')

    def test_thinking_patch_is_verified_and_idempotent(self):
        bundle=self.thinking_bundle()
        first=self.apply_thinking_patch()
        patched=bundle.read_text()
        self.assertIn('patch applied and verified',first.stdout)
        self.assertIn('reasoning_effort: payload.thinking',patched)
        self.assertIn('message.reasoning_text',patched)
        second=self.apply_thinking_patch()
        self.assertIn('already verified',second.stdout)
        self.assertEqual(bundle.read_text(),patched)

    def test_thinking_patch_repairs_partial_install(self):
        bundle=self.thinking_bundle();original=bundle.read_text()
        self.apply_thinking_patch();patched=bundle.read_text()
        # Retain only the earlier request-side change, as in an interrupted patch.
        bundle.write_text(patched.split('const responseMessage')[0]+original[original.index('const responseMessage'):])
        self.apply_thinking_patch()
        self.assertEqual(bundle.read_text(),patched)

    def test_thinking_patch_reports_unknown_or_ambiguous_bundle_without_writing(self):
        bundle=self.thinking_bundle();original=bundle.read_text()
        for content in ['// new upstream with no anchors',
                        original.replace('content: [...allTextBlocks, ...allToolUseBlocks],','content: newFormat,'),
                        original+original]:
            bundle.write_text(content)
            result=self.apply_thinking_patch()
            self.assertIn('compatibility NOT verified',result.stdout)
            self.assertNotIn('✓ copilot-api',result.stdout)
            self.assertEqual(bundle.read_text(),content)

    def test_missing_thinking_bundle_is_reported(self):
        result=self.apply_thinking_patch()
        self.assertIn('bundle not found',result.stdout)
        self.assertIn('NOT verified',result.stdout)

    def test_thinking_patch_write_failure_is_a_clean_warning(self):
        bundle=self.thinking_bundle();original=bundle.read_text()
        bundle.parent.chmod(0o555)   # rename into the dir fails
        try:
            result=self.apply_thinking_patch()
        finally:
            bundle.parent.chmod(0o755)
        if os.geteuid()==0: self.skipTest('root ignores directory permissions')
        self.assertIn('could not write',result.stdout+result.stderr)
        self.assertNotIn('    at ',result.stdout+result.stderr)   # no Node stack trace
        self.assertIn('NOT verified',result.stdout)
        self.assertEqual(bundle.read_text(),original)
        self.assertEqual(sorted(p.name for p in bundle.parent.iterdir()),['main.js'])

    REFRESH_BUNDLE="""async function setupCopilotToken() {
	setInterval(async () => {
		try {
			const { token: token$1 } = await getCopilotToken();
			state.copilotToken = token$1;
		} catch (error) {
			consola.error("Failed to refresh Copilot token:", error);
			throw error;
		}
	}, refreshInterval);
}
"""

    def apply_refresh_patch(self):
        return self.run_shell('npm() { printf "%s" "$HOME/npm"; }; patch_token_refresh')

    def test_token_refresh_patch_missing_applied_idempotent_unknown(self):
        missing=self.apply_refresh_patch()
        self.assertIn('bundle not found',missing.stdout)
        self.assertIn('NOT verified',missing.stdout)
        bundle=self.home/'npm/copilot-api/dist/main.js'
        bundle.parent.mkdir(parents=True)
        bundle.write_text(self.REFRESH_BUNDLE)
        first=self.apply_refresh_patch()
        patched=bundle.read_text()
        self.assertIn('token-refresh patch verified',first.stdout)
        self.assertNotIn('throw error',patched)
        self.assertIn('__cck_refresh_retry',patched)
        subprocess.run(['node','--check',str(bundle)],check=True)
        second=self.apply_refresh_patch()
        self.assertIn('already verified',second.stdout)
        self.assertEqual(bundle.read_text(),patched)
        for content in ['// unknown upstream', self.REFRESH_BUNDLE*2]:
            bundle.write_text(content)
            r=self.apply_refresh_patch()
            self.assertIn('NOT verified',r.stdout)
            self.assertEqual(bundle.read_text(),content)

    def test_token_refresh_patch_uses_resolved_node_and_no_temp_file(self):
        body=SOURCE.split('patch_token_refresh() {')[1].split('\n}\n')[0]
        self.assertNotIn('$(mktemp',body)
        self.assertIn('"${NODE_BIN:-node}" - "$m"',body)
        bundle=self.home/'npm/copilot-api/dist/main.js'
        bundle.parent.mkdir(parents=True); bundle.write_text(self.REFRESH_BUNDLE)
        shim=self.home/'node-shim'
        shim.write_text('#!/bin/sh\necho shim-used >> "$HOME/shim.log"\nexec node "$@"\n'); shim.chmod(0o755)
        self.run_shell(f'NODE_BIN="{shim}"; npm() {{ printf "%s" "$HOME/npm"; }}; patch_token_refresh')
        self.assertIn('shim-used',(self.home/'shim.log').read_text())

    def test_plists_bind_loopback_and_rerun_rewrites_old_plist(self):
        import plistlib
        la=self.home/'Library/LaunchAgents'; la.mkdir(parents=True)
        api=la/'com.copilot-api.plist'
        # An install from before the fix: no HOST in the environment.
        api.write_text(SOURCE.split('write_plist() {')[1].split("<<EOF\n")[1].split('\nEOF\n')[0]
                       .replace('    <key>HOST</key>\n    <string>${BIND_HOST}</string>\n',''))
        self.assertFalse(self.run_shell(f'plist_binds_loopback "{api}"',ok=False).returncode==0)
        stubs='''for fn in need_macos load_service wait_for_port is_authed_retry write_watchdog_plist write_normalizer smoke_test; do
  eval "$fn() { return 0; }"
done
ensure_node() { NODE_BIN="$(command -v node)"; NODE_DIR="$(dirname "$NODE_BIN")"; }
ensure_copilot_api() { COPILOT_API_BIN=/opt/fake/copilot-api; }
'''
        self.run_shell(stubs+'do_install')
        for name,program in [('com.copilot-api.plist',['/opt/fake/copilot-api','start']),
                             ('com.copilot-api-normalize.plist',None)]:
            data=plistlib.loads((la/name).read_bytes())
            self.assertEqual(data['EnvironmentVariables']['HOST'],'127.0.0.1',name)
            if program: self.assertEqual(data['ProgramArguments'],program)
        self.assertEqual(self.run_shell(f'plist_binds_loopback "{api}"',ok=False).returncode,0)
        # The normalizer listens on loopback in code, independent of HOST.
        norm=SOURCE.split("<<'NORMALIZER_EOF'\n")[1].split('\nNORMALIZER_EOF')[0]
        self.assertIn('const LISTEN_HOST = "127.0.0.1";',norm)
        self.assertIn('server.listen(LISTEN_PORT, LISTEN_HOST,',norm)
        self.assertNotIn('copilot-api start',SOURCE.split('# CLI dispatch')[0].replace('`copilot-api start`',''))

    def test_verify_flags_a_plist_without_loopback_binding(self):
        la=self.home/'Library/LaunchAgents'; la.mkdir(parents=True)
        (la/'com.copilot-api.plist').write_text('<plist><dict></dict></plist>')
        r=self.run_shell('''need_macos() { :; }; service_loaded() { return 0; }; curl() { return 0; }
is_authed_retry() { return 0; }; smoke_test() { return 0; }; do_verify''',ok=False)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('listens on all interfaces',r.stdout+r.stderr)

    LIVE_NO_CLAUDE=json.dumps({'object':'list','data':[{'id':i} for i in ['gpt-5.5','gpt-6-astra','grok-4.7','text-embedding-3-small']]})

    def test_claude_models_available_states(self):
        for body,expected in [(self.LIVE_NO_CLAUDE,1),
                              (json.dumps({'data':[{'id':'gpt-6-astra'},{'id':'claude-opus-5.5'}]}),0),
                              (json.dumps({'data':[]}),2),('not json',2)]:
            (self.home/'models').write_text(body)
            r=self.run_shell('NODE_BIN="$(command -v node)"; curl() { cat "$HOME/models"; }; claude_models_available',ok=False)
            self.assertEqual(r.returncode,expected,body)

    def test_install_and_verify_explain_missing_claude_models(self):
        (self.home/'models').write_text(self.LIVE_NO_CLAUDE)
        stubs='''for fn in need_macos load_service wait_for_port is_authed_retry write_watchdog_plist write_normalizer write_plist; do
  eval "$fn() { return 0; }"
done
ensure_node() { NODE_BIN="$(command -v node)"; NODE_DIR="$(dirname "$NODE_BIN")"; }
ensure_copilot_api() { COPILOT_API_BIN=true; }
curl() { cat "$HOME/models"; }
smoke_test() { echo SMOKE-CALLED; return 1; }
'''
        r=self.run_shell(stubs+'do_install',ok=False)
        out=r.stdout+r.stderr
        self.assertNotEqual(r.returncode,0)
        self.assertIn('no Claude models enabled; ask your org admin to enable them in Copilot policy',out)
        self.assertNotIn('SMOKE-CALLED',out)
        self.assertTrue((self.home/'.claude/settings.json').exists())
        r=self.run_shell(stubs+'service_loaded() { return 0; }; plist_binds_loopback() { return 0; }; do_verify',ok=False)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('no Claude models enabled',r.stdout+r.stderr)

    def test_watchdog_treats_missing_claude_models_as_healthy(self):
        source=SOURCE.split("<<'WATCHDOG_EOF'\n")[1].split('\nWATCHDOG_EOF')[0]
        lib=self.home/'watchdog-functions.sh'
        lib.write_text(source.split('\ntrim_log\n')[0])
        for body,expected in [('{"type":"error","error":{"code":"copilot_no_claude_models"}}',0),
                              ('{"type":"error","error":{"message":"model_not_supported"}}',1),
                              ('{"type":"message","content":[]}',0)]:
            (self.home/'probe').write_text(body)
            r=self.run_shell('''source "$HOME/watchdog-functions.sh"
log() { echo "LOG: $*"; }
curl() { cat "$HOME/probe"; }
works_claude''',ok=False)
            self.assertEqual(r.returncode,expected,body)

    def watchdog_script(self):
        # The whole watchdog with its fixed /tmp paths moved under the temp HOME.
        source=SOURCE.split("<<'WATCHDOG_EOF'\n")[1].split('\nWATCHDOG_EOF')[0]
        source=source.replace('/tmp/com.copilot-api-watchdog',str(self.home/'wd'))
        self.assertNotIn('/tmp/com.',source)
        script=self.home/'watchdog.sh'; script.write_text(source)
        bin_=self.home/'bin'; bin_.mkdir(exist_ok=True)
        # curl: network and sockets are fine; a completion fails for models listed in $HOME/gone.
        (bin_/'curl').write_text('''#!/usr/bin/env bash
args="$*"; echo "$args" >> "$HOME/curl-calls"
case "$args" in *api.github.com*|*/v1/models*) exit 0 ;; esac
for m in $(cat "$HOME/gone" 2>/dev/null); do
  case "$args" in *"\\"model\\":\\"$m\\""*) echo '{"error":{"code":"model_not_supported"}}'; exit 22 ;; esac
done
case "$args" in *responses*) echo '{"status":"completed","output":[]}' ;; *) echo '{"type":"message"}' ;; esac
''')
        for name,body in [('launchctl','echo "$*" >> "$HOME/kicks"'),('osascript','echo "$*" >> "$HOME/notes"'),('sleep',':')]:
            (bin_/name).write_text('#!/usr/bin/env bash\n'+body+'\n')
        for f in bin_.iterdir(): f.chmod(0o755)
        (self.home/'.copilot-api').mkdir(exist_ok=True)
        return script

    def run_watchdog(self, script, mode, pinned, gone):
        (self.home/'.copilot-api/watchdog-mode').write_text(mode)
        (self.home/'.copilot-api/codex-model').write_text(pinned+'\n')
        (self.home/'gone').write_text(' '.join(gone))
        for f in ['kicks','notes','curl-calls']: (self.home/f).unlink(missing_ok=True)
        env=dict(self.env,PATH=f"{self.home/'bin'}:{os.environ['PATH']}")
        r=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True,timeout=60)
        self.assertEqual(r.returncode,0,r.stderr)
        read=lambda f:(self.home/f).read_text() if (self.home/f).exists() else ''
        return read('kicks'),read('notes'),read('wd.log')

    def test_watchdog_does_not_restart_storm_on_a_retired_pinned_codex_model(self):
        script=self.watchdog_script()
        for mode in ['codex','combined']:
            (self.home/'wd.model-notified').unlink(missing_ok=True)
            (self.home/'wd.log').unlink(missing_ok=True)
            kicks,notes,log=self.run_watchdog(script,mode,'gpt-5.6-terra',['gpt-5.6-terra'])
            self.assertEqual(kicks,'',mode)
            self.assertIn('gpt-5.6-terra fails but gpt-6-astra works',log)
            self.assertNotIn('token likely expired',log)
            self.assertIn('Codex model gpt-5.6-terra is no longer served',notes)
            self.assertNotIn('re-auth',notes)
            # The next 90s run stays quiet: no restart and no repeated notification.
            kicks,notes,log2=self.run_watchdog(script,mode,'gpt-5.6-terra',['gpt-5.6-terra'])
            self.assertEqual((kicks,notes,log2),('','',log),mode)
        # A pinned default that is gone is checked against the next fallback.
        (self.home/'wd.model-notified').unlink()
        kicks,notes,log=self.run_watchdog(script,'codex','gpt-6-astra',['gpt-6-astra'])
        self.assertEqual(kicks,'')
        self.assertIn('gpt-6-astra fails but gpt-6.1-sol works',log)
        # A healthy pinned model costs exactly one probe.
        self.run_watchdog(script,'codex','gpt-5.6-terra',[])
        self.assertEqual(len((self.home/'curl-calls').read_text().splitlines()),1)

    def test_watchdog_still_restarts_when_every_codex_model_fails(self):
        script=self.watchdog_script()
        kicks,notes,log=self.run_watchdog(script,'codex','gpt-5.6-terra',['gpt-5.6-terra','gpt-6-astra','gpt-6.1-sol'])
        self.assertIn('kickstart -k',kicks)
        self.assertIn('token likely expired',log)
        self.assertIn('re-auth',notes)

    def test_cli_profile(self):
        self.run_shell('CODEX_DESKTOP_MODEL=gpt-5.6-sol; write_codex_profile')
        cfg=tomllib.loads((self.home/'.codex/copilot.config.toml').read_text())
        self.assertEqual(cfg['model'],'gpt-5.6-sol')
        self.assertEqual(cfg['model_catalog_json'],str(self.home/'.codex/copilot-profile-models.json'))
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
