#!/usr/bin/env python3
"""Focused build-script tests. No Flutter, FFmpeg, or Android compilation."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent.parent


def load_properties_helper():
    spec = importlib.util.spec_from_file_location('local_properties', SCRIPTS / 'configure_local_properties.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuildHelpers(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='ffmpegpp-build helpers-')
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.env = os.environ.copy()
        self.env.update({
            'FFMPEGPP_ROOT': str(self.root),
            'FFMPEGPP_CACHE': str(self.root / 'cache'),
            'GRADLE_USER_HOME': str(self.root),
            'FFMPEGPP_RETRY_MAX_ATTEMPTS': '3',
            'FFMPEGPP_RETRY_BASE_DELAY': '0',
            'TMPDIR': str(self.root),
        })

    def fake_gradle(self, failures=0, code=37, message='HTTP 429 Too Many Requests'):
        state = self.root / 'attempts'
        arguments = self.root / 'gradle-arguments.json'
        self.env.update({'FAKE_ATTEMPTS': str(state), 'FAKE_ARGUMENTS': str(arguments)})
        script = self.root / 'fake-gradle'
        script.write_text('\n'.join([
            '#!' + sys.executable,
            'import json, os, sys',
            'from pathlib import Path',
            'state = Path(os.environ["FAKE_ATTEMPTS"])',
            'count = int(state.read_text()) + 1 if state.exists() else 1',
            'state.write_text(str(count))',
            'Path(os.environ["FAKE_ARGUMENTS"]).write_text(json.dumps(sys.argv[1:]))',
            f'if count <= {failures}:',
            f'    print({message!r}, flush=True)',
            f'    raise SystemExit({code})',
            'print("mock Gradle success")',
            '',
        ]))
        script.chmod(0o755)
        return script, state, arguments

    def retry(self, command, *args):
        return subprocess.run([
            'bash', '-c',
            'set -euo pipefail; source "$1"; shift; ffmpegpp_gradle_retry "$@"',
            '_', str(SCRIPTS / 'gradle_retry.sh'), str(command), *args,
        ], env=self.env, capture_output=True, text=True, timeout=15)

    def test_transient_failure_preserves_code_and_then_succeeds(self):
        script, state, arguments = self.fake_gradle(failures=1)
        result = self.retry(script, '--init-script', '/path with spaces/repository.gradle')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.read_text(), '2')
        self.assertIn('failed (rc=37)', result.stderr)
        self.assertNotIn('failed (rc=0)', result.stderr)
        self.assertEqual(json.loads(arguments.read_text()), ['--init-script', '/path with spaces/repository.gradle'])

    def test_nontransient_failure_is_not_retried(self):
        script, state, _ = self.fake_gradle(failures=5, code=23, message='e: Unknown Kotlin symbol')
        result = self.retry(script)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(state.read_text(), '1')
        self.assertNotIn('retrying in', result.stderr)

    def test_exhausted_retries_preserve_the_last_exit(self):
        script, state, _ = self.fake_gradle(failures=5, code=41)
        result = self.retry(script)
        self.assertEqual(result.returncode, 41)
        self.assertEqual(state.read_text(), '3')
        self.assertEqual(result.stderr.count('retrying in'), 2)
        self.assertIn('last rc=41', result.stderr)

    def test_invalid_retry_configuration_fails_before_the_command(self):
        script, state, _ = self.fake_gradle()
        self.env['FFMPEGPP_RETRY_MAX_ATTEMPTS'] = '0'
        result = self.retry(script)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(state.exists())

    def test_environment_preserves_flutter_action_cache_and_explicit_override(self):
        self.env['PUB_CACHE'] = str(self.root / 'action cache')
        command = ['bash', '-c', 'source "$1"; printf "%s" "$PUB_CACHE"', '_', str(SCRIPTS / 'env.sh')]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, self.env['PUB_CACHE'])
        self.env['FFMPEGPP_PUB_CACHE'] = str(self.root / 'explicit cache')
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, self.env['FFMPEGPP_PUB_CACHE'])

    def package_config(self, packages):
        path = self.root / 'ffmpegpp_gui/.dart_tool/package_config.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'packages': packages}))
        return path

    def test_split_picker_patches_only_the_legacy_android_implementation(self):
        facade = self.root / 'pub cache/file_picker-13.4.0'
        implementation = self.root / 'pub cache/android_file_picker-2.2.0'
        legacy = implementation / 'android/build.gradle.kts'
        legacy.parent.mkdir(parents=True)
        facade.mkdir(parents=True)
        legacy.write_text('android {\n    compileSdk = 34\n}\n')
        self.package_config([
            {'name': 'file_picker', 'rootUri': facade.as_uri()},
            {'name': 'android_file_picker', 'rootUri': implementation.as_uri()},
        ])
        command = ['bash', str(SCRIPTS / 'patch_pubcache.sh')]
        first = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertIn('compileSdk = 36', legacy.read_text())
        self.assertNotIn('WARN:', first.stderr)
        second = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertIn('needs no legacy patch', second.stdout)
        legacy.write_text('android {\n    compileSdk = 37\n}\n')
        subprocess.run(command, env=self.env, capture_output=True, check=True)
        self.assertIn('compileSdk = 37', legacy.read_text())

    def test_properties_preserve_version_and_unrelated_keys(self):
        android = self.root / 'android'
        flutter = self.root / 'Flutter SDK'
        sdk = self.root / 'Android SDK'
        android.mkdir()
        sdk.mkdir()
        (flutter / 'packages/flutter_tools/gradle').mkdir(parents=True)
        local = android / 'local.properties'
        local.write_text('sdk.dir=/old/sdk\nflutter.sdk=/old/flutter\nflutter.versionCode=42\nflutter.buildMode=release\n')
        load_properties_helper().configure(android, flutter, sdk)
        actual = local.read_text()
        self.assertIn(f'sdk.dir={sdk}', actual)
        self.assertIn(f'flutter.sdk={flutter}', actual)
        self.assertIn('flutter.versionCode=42', actual)
        self.assertEqual(actual.count('sdk.dir='), 1)
        self.assertEqual(actual.count('flutter.sdk='), 1)

    def prepare_apk_fixture(self, pub_code=0):
        app = self.root / 'ffmpegpp_gui'
        android = app / 'android'
        android.mkdir(parents=True)
        self.package_config([])
        dist = self.root / 'cache/dist'
        dist.mkdir(parents=True)
        for name in ['libffmpegpp.so', 'libffmpeg.so', 'libffprobe.so']:
            (dist / name).write_text('mock binary h264_mediacodec')
        flutter = self.root / 'Flutter SDK'
        (flutter / 'packages/flutter_tools/gradle').mkdir(parents=True)
        (flutter / 'bin').mkdir()
        executable = flutter / 'bin/flutter'
        executable.write_text(f'#!/usr/bin/env bash\nexit {pub_code}\n')
        executable.chmod(0o755)
        sdk = self.root / 'Android SDK'
        sdk.mkdir()
        self.env.update({'FLUTTER_BIN': str(flutter / 'bin'), 'ANDROID_HOME': str(sdk)})
        command, state, arguments = self.fake_gradle()
        wrapper = android / 'gradlew'
        wrapper.write_bytes(command.read_bytes())
        wrapper.chmod(0o755)
        return android, state, arguments

    def test_apk_entrypoint_generates_paths_and_passes_the_init_policy(self):
        android, state, arguments = self.prepare_apk_fixture()
        result = subprocess.run(['bash', str(SCRIPTS / 'build_apk.sh')], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state.read_text(), '1')
        args = json.loads(arguments.read_text())
        self.assertIn('-Ptarget-platform=android-arm64', args)
        self.assertEqual(args[args.index('--init-script') + 1], str(SCRIPTS / 'gradle-repositories.init.gradle'))
        self.assertIn('flutter.sdk=', (android / 'local.properties').read_text())

    def test_pub_failure_stops_before_gradle(self):
        _, state, _ = self.prepare_apk_fixture(pub_code=17)
        result = subprocess.run(['bash', str(SCRIPTS / 'build_apk.sh')], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertFalse(state.exists())


@unittest.skipUnless(os.environ.get('FFMPEGPP_TEST_GRADLE'), 'Set FFMPEGPP_TEST_GRADLE for the tiny Gradle composite fixture')
class GradleRepositories(unittest.TestCase):
    def test_mirror_first_in_root_and_included_builds(self):
        with tempfile.TemporaryDirectory(prefix='ffmpegpp-gradle-repos-') as temporary:
            root = Path(temporary)
            included = root / 'included'
            included.mkdir()
            (root / 'settings.gradle').write_text(
                "rootProject.name = 'root'\nincludeBuild('included')\ngradle.ext.fixtureSettings = settings\n")
            (included / 'settings.gradle').write_text(
                "rootProject.name = 'included'\n"
                "dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS); repositories { mavenCentral() } }\n"
                "gradle.ext.fixtureSettings = settings\n")
            build = '''
                buildscript { repositories { mavenCentral() } }
                if (gradle.ext.fixtureSettings.dependencyResolutionManagement.repositoriesMode.get() == RepositoriesMode.PREFER_PROJECT) {
                    repositories { mavenCentral() }
                }
                tasks.register('verifyRepositories') {
                    doLast {
                        def config = gradle.ext.fixtureSettings
                        def expected = 'ffmpegppMavenCentralMirror'
                        assert config.pluginManagement.repositories.first().name == expected
                        assert config.pluginManagement.repositories.any { it.name == 'Gradle Central Plugin Repository' }
                        assert config.pluginManagement.repositories.any { it.name == 'Google' }
                        assert project.buildscript.repositories.first().name == expected
                        assert config.dependencyResolutionManagement.repositories.first().name == expected
                        if (config.dependencyResolutionManagement.repositoriesMode.get() == RepositoriesMode.PREFER_PROJECT) {
                            assert project.repositories.first().name == expected
                        }
                        println('VERIFIED ' + project.name)
                    }
                }
            '''
            (root / 'build.gradle').write_text(build)
            (included / 'build.gradle').write_text(build)
            result = subprocess.run([
                os.environ['FFMPEGPP_TEST_GRADLE'], '-p', str(root), '--no-daemon', '--offline',
                '--init-script', str(SCRIPTS / 'gradle-repositories.init.gradle'),
                'verifyRepositories', ':included:verifyRepositories',
            ], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('VERIFIED root', result.stdout)
            self.assertIn('VERIFIED included', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
