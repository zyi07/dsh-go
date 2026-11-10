#!/usr/bin/env python3
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('distribution', ROOT / 'tooling/ohos/hap-distribution.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DistributionTests(unittest.TestCase):
    def fixture(self):
        return {'module': {'requestPermissions': [{'name': 'ohos.permission.INTERNET'}],
                           'abilities': [{'name': 'EntryAbility', 'backgroundModes': ['audioPlayback']}],
                           'skills': [{'unrelated': True}]}}

    def test_debug_and_device_enable_actual_acl_and_mode(self):
        for distribution in ('debug', 'device'):
            result = module.permissions(self.fixture(), distribution)['module']
            names = [x['name'] for x in result['requestPermissions']]
            self.assertEqual(len(names), len(set(names)))
            self.assertTrue(set(module.RESTRICTED).issubset(names))
            self.assertIn('ohos.permission.KEEP_BACKGROUND_RUNNING', names)
            self.assertEqual(result['abilities'][0]['backgroundModes'], ['audioPlayback', 'taskKeeping'])
            paste = next(x for x in result['requestPermissions'] if x['name'] == module.RESTRICTED[1])
            self.assertEqual(paste['usedScene'], {'abilities': ['EntryAbility'], 'when': 'inuse'})

    def test_store_removes_restricted_permissions_and_only_task_keeping(self):
        result = module.permissions(module.permissions(self.fixture(), 'debug'), 'store')['module']
        self.assertFalse(set(module.RESTRICTED) & {x['name'] for x in result['requestPermissions']})
        self.assertEqual(result['abilities'][0]['backgroundModes'], ['audioPlayback'])
        self.assertEqual(result['skills'], [{'unrelated': True}])

    def test_overlay_is_idempotent(self):
        for distribution in ('debug', 'device', 'store'):
            original = module.permissions(self.fixture(), distribution)
            self.assertEqual(module.permissions(copy.deepcopy(original), distribution), original)

    def test_private_signing_arguments_never_enter_process_argv_and_cleanup(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for name in ('keystore', 'profile', 'cert', 'tool.jar', 'unsigned.hap', 'java'):
                (root / name).touch()
            env = {'DSH_OHOS_SIGN_KEYSTORE': str(root / 'keystore'), 'DSH_OHOS_SIGN_PROFILE': str(root / 'profile'),
                   'DSH_OHOS_SIGN_CERTIFICATE': str(root / 'cert'), 'DSH_OHOS_SIGN_KEY_ALIAS': 'test-alias',
                   'DSH_OHOS_SIGN_KEY_PASSWORD': 'fake-Password-雪\\"', 'DSH_OHOS_SIGN_STORE_PASSWORD': 'fake-store',
                   'DSH_OHOS_SIGN_TOOL': str(root / 'tool.jar')}
            calls = []
            def run(argv, **kwargs):
                self.assertNotIn(env['DSH_OHOS_SIGN_KEY_PASSWORD'], str(argv))
                self.assertEqual(kwargs['stdout'], subprocess.DEVNULL)
                self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
                calls.append((argv, kwargs))
                if len(calls) == 1:
                    argfile = Path(argv[1][1:])
                    self.assertEqual(argfile.stat().st_mode & 0o777, 0o600)
                    self.assertIn(module.quote_java(env['DSH_OHOS_SIGN_KEY_PASSWORD']), argfile.read_text())
                    (Path(kwargs['cwd']) / 'signed.hap').write_bytes(b'fixture-signed')
                return subprocess.CompletedProcess(argv, 0)
            with patch.dict(os.environ, env, clear=True), patch.object(module.shutil, 'which', return_value=str(root / 'java')), patch.object(module.subprocess, 'run', side_effect=run):
                module.sign(root / 'unsigned.hap', root / 'output.hap')
            self.assertEqual((root / 'output.hap').read_bytes(), b'fixture-signed')
            self.assertEqual(len(calls), 2)
            self.assertFalse(Path(calls[0][1]['cwd']).exists())

    def test_build_failure_restores_module_and_keeps_secrets_from_build_children(self):
        import shutil
        import zipfile
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            app = root / 'app'; helpers = root / 'tooling/ohos'
            (app / 'ohos/entry/src/main').mkdir(parents=True); helpers.mkdir(parents=True)
            (app / 'pubspec.lock').write_text('original lock\n')
            document = self.fixture(); document['module']['requestPermissions'].append({'name': module.RESTRICTED[1]})
            original = json.dumps(document).encode()
            manifest = app / 'ohos/entry/src/main/module.json5'; manifest.write_bytes(original)
            (app / 'ohos/build-profile.json5').write_text('{"app":{"signingConfigs":[]}}')
            for name in ('build-hap.sh', 'hap-distribution.py'):
                shutil.copy2(ROOT / 'tooling/ohos' / name, helpers / name)
            asset_helpers = root / 'runtime/ohos/package'; asset_helpers.mkdir(parents=True)
            shutil.copy2(ROOT / 'runtime/ohos/package/linux-assets.py', asset_helpers / 'linux-assets.py')
            observed = root / 'observed.json'
            (helpers / 'patch_framework.py').write_text('import json,os,pathlib\npathlib.Path(' + repr(str(observed)) + ').write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith("DSH_OHOS_SIGN_")}))\nraise SystemExit(3)\n')
            libs = root / 'libs'; libs.mkdir()
            for name in ('libnode.so', 'libdsh_flock.so', 'libdsh_require_builtin.so'):(libs / name).touch()
            flutter = root / 'flutter/bin/flutter'; flutter.parent.mkdir(parents=True); flutter.write_text('#!/bin/sh\nexit 0\n'); flutter.chmod(0o755)
            archive = root / 'runtime.zip'
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, 'w') as z:z.writestr('manifest.json', b'{}')
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as z:z.writestr('dsh-runtime/runtime.zip', inner.getvalue())
            env = dict(os.environ, FLUTTER_OHOS=str(flutter), DSH_OHOS_NATIVE_LIBS=str(libs), DSH_NODE_HEADERS=str(root), DSH_OHOS_RUNTIME=str(archive), DSH_OHOS_SIGN_KEY_PASSWORD='fake-secret-trace')
            result = subprocess.run(['bash', '-x', str(helpers / 'build-hap.sh')],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(manifest.read_bytes(), original)
            self.assertEqual((app / 'pubspec.lock').read_text(), 'original lock\n')
            self.assertEqual(json.loads(observed.read_text()), {})
            self.assertNotIn('fake-secret-trace', result.stdout + result.stderr)

    def test_missing_material_is_explicit_failure_without_secret_output(self):
        tool = ROOT / 'tooling/ohos/hap-distribution.py'
        env = dict(os.environ, DSH_OHOS_SIGN_KEY_PASSWORD='fake-secret-never-log')
        for name in list(env):
            if name.startswith('DSH_OHOS_SIGN_') and name != 'DSH_OHOS_SIGN_KEY_PASSWORD': del env[name]
        result = subprocess.run(['python3', str(tool), 'check-signing'], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('fake-secret-never-log', result.stdout + result.stderr)
        self.assertIn('DSH_OHOS_SIGN_', result.stderr)


if __name__ == '__main__':
    unittest.main()
