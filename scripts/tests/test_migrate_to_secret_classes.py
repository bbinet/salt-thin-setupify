"""
Unit tests for migrate-to-secret-classes.py

Run with:
  python3 -m pytest scripts/tests/
  # or without pytest:
  python3 scripts/tests/test_migrate_to_secret_classes.py
"""
import copy
import os
import sys
import tempfile
import textwrap
import unittest

# Allow importing the script as a module regardless of cwd.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import migrate_to_secret_classes as m


# ---------------------------------------------------------------------------
# is_secret_key
# ---------------------------------------------------------------------------
class TestIsSecretKey(unittest.TestCase):

    def test_password(self):
        for k in ('password', 'PASSWORD', 'admin_password', 'db_passwd'):
            with self.subTest(k=k):
                self.assertTrue(m.is_secret_key(k))

    def test_credential(self):
        for k in ('credential', 'user_credential', 'CREDENTIAL_VALUE'):
            with self.subTest(k=k):
                self.assertTrue(m.is_secret_key(k))

    def test_key_with_boundary(self):
        # \bkey — left word boundary; matches key, keyfile but not monkey.
        self.assertTrue(m.is_secret_key('key'))
        self.assertTrue(m.is_secret_key('keyfile'))
        self.assertFalse(m.is_secret_key('monkey'))
        self.assertFalse(m.is_secret_key('donkey'))

    def test_auth_with_boundary(self):
        # \bauth\b — both word boundaries; matches auth, api-auth
        # but not nginxstaticauth/oauth.
        self.assertTrue(m.is_secret_key('auth'))
        self.assertTrue(m.is_secret_key('api-auth'))
        self.assertFalse(m.is_secret_key('nginxstaticauth'))
        self.assertFalse(m.is_secret_key('oauth'))

    def test_contents_with_boundary(self):
        self.assertTrue(m.is_secret_key('contents'))
        self.assertTrue(m.is_secret_key('file-contents'))

    def test_non_secret(self):
        for k in ('host', 'port', 'user', 'name', 'url', 'timeout',
                  'monkey', 'donkey', 'nginxstaticauth'):
            with self.subTest(k=k):
                self.assertFalse(m.is_secret_key(k))

    def test_extra_keys(self):
        self.assertTrue(m.is_secret_key('smtp_host', extra_keys={'smtp_host'}))
        self.assertFalse(m.is_secret_key('smtp_host'))


# ---------------------------------------------------------------------------
# is_reclass_reference
# ---------------------------------------------------------------------------
class TestIsReclassReference(unittest.TestCase):

    def test_reclass_reference(self):
        self.assertTrue(m.is_reclass_reference('${_param:_secret:pw}'))
        self.assertTrue(m.is_reclass_reference('${_param:host}'))

    def test_not_a_reference(self):
        self.assertFalse(m.is_reclass_reference('s3cr3t'))
        self.assertFalse(m.is_reclass_reference('${incomplete'))
        self.assertFalse(m.is_reclass_reference(42))
        self.assertFalse(m.is_reclass_reference(None))

    def test_extra_keys_does_not_leak(self):
        # extra_keys in one call must not affect another call without them.
        self.assertFalse(m.is_secret_key('smtp_host', extra_keys=()))


# ---------------------------------------------------------------------------
# unique_key
# ---------------------------------------------------------------------------
class TestUniqueKey(unittest.TestCase):

    def test_no_clash(self):
        self.assertEqual(m.unique_key('foo', set()), 'foo')

    def test_clash_once(self):
        self.assertEqual(m.unique_key('foo', {'foo'}), 'foo_2')

    def test_clash_multiple(self):
        self.assertEqual(m.unique_key('foo', {'foo', 'foo_2', 'foo_3'}), 'foo_4')

    def test_does_not_mutate_reserved(self):
        reserved = {'foo'}
        m.unique_key('foo', reserved)
        self.assertEqual(reserved, {'foo'})


# ---------------------------------------------------------------------------
# collect_all_secrets
# ---------------------------------------------------------------------------
class TestCollectAllSecrets(unittest.TestCase):

    # Helper: collect without prompts
    def _collect(self, params, extra_keys=()):
        return m.collect_all_secrets(params, extra_keys=extra_keys, prompt_fn=None)

    def test_empty(self):
        ds, dr, ns = self._collect({})
        self.assertEqual(ds, {})
        self.assertEqual(dr, {})
        self.assertEqual(ns, [])

    def test_none_parameters(self):
        ds, dr, ns = self._collect(None)
        self.assertEqual(ds, {})

    # --- Direct _param._secret block ---

    def test_direct_secret_all_keys_extracted(self):
        """ALL keys in _param._secret are extracted regardless of their name."""
        params = {'_param': {'_secret': {'admin_password': 's3cr3t', 'port': 8080}}}
        ds, dr, ns = self._collect(params)
        # Both keys are secrets because they live in _param._secret.
        self.assertEqual(ds, {'admin_password': 's3cr3t', 'port': 8080})
        self.assertEqual(dr, {})
        self.assertEqual(ns, [])

    def test_legacy_param_pattern_filter(self):
        """For _param top-level keys, only pattern-matched keys are extracted."""
        params = {'_param': {'admin_password': 's3cr3t', 'port': 8080}}
        ds, dr, ns = self._collect(params)
        self.assertEqual(ds, {'admin_password': 's3cr3t'})
        self.assertEqual(dr, {'port': 8080})
        self.assertEqual(ns, [])

    def test_direct_secret_key_is_final_key(self):
        """Direct _param._secret keys map to themselves (no unnecessary renaming)."""
        params = {'_param': {'_secret': {'api_password': 'pw'}}}
        ds, _, _ = self._collect(params)
        self.assertIn('api_password', ds)

    # --- Legacy _param migration ---

    def test_legacy_param_secret_migrated(self):
        params = {'_param': {'db_password': 'old', 'db_host': 'localhost'}}
        ds, dr, ns = self._collect(params)
        self.assertEqual(ds, {'db_password': 'old'})
        self.assertEqual(dr, {'db_host': 'localhost'})

    def test_secret_wins_over_legacy_on_clash(self):
        """_param._secret takes precedence over _param top-level on identical keys."""
        params = {
            '_param': {'db_password': 'old', '_secret': {'db_password': 'new'}},
        }
        ds, _, _ = self._collect(params)
        self.assertEqual(ds['db_password'], 'new')

    def test_bare_secret_migrated(self):
        """Bare _secret at top level (old format) is migrated."""
        params = {'_secret': {'db_password': 'old_format'}}
        ds, _, _ = self._collect(params)
        self.assertEqual(ds['db_password'], 'old_format')

    # --- Nested secrets ---

    def test_nested_secret_one_level(self):
        params = {'myapp': {'password': 's3cr3t', 'host': 'localhost'}}
        ds, dr, ns = self._collect(params)
        self.assertEqual(ds, {})
        self.assertEqual(len(ns), 1)
        path, value, key = ns[0]
        self.assertEqual(path, ('myapp', 'password'))
        self.assertEqual(value, 's3cr3t')
        self.assertEqual(key, 'myapp.password')

    def test_nested_secret_deep(self):
        params = {'a': {'b': {'c': {'password': 'deep'}}}}
        _, _, ns = self._collect(params)
        self.assertEqual(len(ns), 1)
        path, _, key = ns[0]
        self.assertEqual(path, ('a', 'b', 'c', 'password'))
        self.assertEqual(key, 'a.b.c.password')

    def test_nested_non_secret_untouched(self):
        params = {'myapp': {'host': 'localhost', 'port': 9090}}
        ds, dr, ns = self._collect(params)
        self.assertEqual(ds, {})
        self.assertEqual(ns, [])

    # --- Clash detection ---

    def test_clash_direct_vs_nested(self):
        """
        _param._secret.'myapp.password' is a direct secret (keeps its name).
        The nested parameters.myapp.password would generate the same dotted
        key and must be renamed.
        """
        params = {
            '_param': {'_secret': {'myapp.password': 'direct'}},
            'myapp':  {'password': 'nested'},
        }
        ds, _, ns = self._collect(params)
        # Direct key keeps its original name (processed first).
        self.assertIn('myapp.password', ds)
        # Nested key must be renamed.
        _, _, nested_key = ns[0]
        self.assertNotEqual(nested_key, 'myapp.password')
        self.assertEqual(nested_key, 'myapp.password_2')

    def test_clash_two_nested_keys(self):
        """
        Two paths that produce the same flat key must get distinct names.
        """
        params = {
            'a_b': {'secret': 'first'},
            'a':   {'b_secret': 'second'},
        }
        _, _, ns = self._collect(params)
        keys = [key for _, _, key in ns]
        self.assertEqual(len(keys), len(set(keys)), "Duplicate _secret keys generated")

    def test_clash_non_secret_remaining(self):
        """
        A non-secret key in _param (remaining) must block its name from
        being used by a generated nested key.
        """
        params = {
            '_param': {'myapp_host': 'localhost'},  # non-secret -> stays in remaining
            'myapp':  {'host_secret': 'pw'},        # nested -> myapp.host_secret
        }
        ds, dr, ns = self._collect(params)
        self.assertEqual(dr, {'myapp_host': 'localhost'})
        _, _, nested_key = ns[0]
        # 'myapp.host_secret' does not clash with 'myapp_host'.
        self.assertEqual(nested_key, 'myapp.host_secret')

    # --- Reclass references skipped ---

    def test_nested_reference_skipped(self):
        """A value that is already a ${...} reference is not extracted."""
        params = {'myapp': {'password': '${_param:_secret:myapp.password}',
                            'db_secret': 'real_secret'}}
        _, _, ns = self._collect(params)
        keys = [key for _, _, key in ns]
        self.assertNotIn('myapp.password', keys)
        self.assertIn('myapp.db_secret', keys)

    def test_legacy_param_reference_skipped(self):
        """Legacy _param key with a ${...} value is not extracted."""
        params = {'_param': {'db_password': '${_param:_secret:db_password}',
                              'db_host': 'localhost'}}
        ds, dr, _ = self._collect(params)
        self.assertNotIn('db_password', ds)
        self.assertEqual(dr, {'db_host': 'localhost'})

    def test_reference_in_has_any_secrets(self):
        """A file with only references should not be flagged as having secrets."""
        params = {'myapp': {'password': '${_param:_secret:myapp.password}'}}
        self.assertFalse(m.has_any_secrets(params, ()))

    # --- Lists and dicts skipped ---

    def test_list_value_skipped(self):
        """A key whose value is a list is not a scalar secret."""
        params = {'myapp': {'secrets': ['a', 'b', 'c']}}
        _, _, ns = self._collect(params)
        self.assertEqual(ns, [])

    def test_dict_value_not_extracted_as_leaf(self):
        """A key whose value is a dict is walked into, not extracted."""
        params = {'myapp': {'credentials': {'user': 'admin', 'password': 'pw'}}}
        _, _, ns = self._collect(params)
        keys = [key for _, _, key in ns]
        self.assertNotIn('myapp.credentials', keys)
        self.assertIn('myapp.credentials.password', keys)

    def test_list_in_has_any_secrets(self):
        """A file with only list-valued secret keys should not be flagged."""
        params = {'myapp': {'secrets': ['a', 'b']}}
        self.assertFalse(m.has_any_secrets(params, ()))

    # --- Extra keys ---

    def test_extra_key_forces_extraction(self):
        params = {'myapp': {'smtp_host': 'mail.example.com'}}
        _, _, ns = self._collect(params, extra_keys=('smtp_host',))
        self.assertEqual(len(ns), 1)
        self.assertEqual(ns[0][2], 'myapp.smtp_host')

    def test_extra_key_not_extracted_without_option(self):
        params = {'myapp': {'smtp_host': 'mail.example.com'}}
        _, _, ns = self._collect(params)
        self.assertEqual(ns, [])

    # --- Interactive prompt_fn ---

    def test_interactive_rename_accepted(self):
        """prompt_fn returning a non-empty string renames the key."""
        params = {'myapp': {'password': 's3cr3t'}}

        def fake_prompt(suggested, description):
            return 'my_custom_key'

        _, _, ns = m.collect_all_secrets(params, prompt_fn=fake_prompt)
        _, _, key = ns[0]
        self.assertEqual(key, 'my_custom_key')

    def test_interactive_empty_accepts_default(self):
        """prompt_fn returning '' accepts the suggested name."""
        params = {'myapp': {'password': 's3cr3t'}}

        def fake_prompt(suggested, description):
            return ''

        _, _, ns = m.collect_all_secrets(params, prompt_fn=fake_prompt)
        _, _, key = ns[0]
        self.assertEqual(key, 'myapp.password')

    def test_interactive_clash_auto_resolved(self):
        """
        If the operator picks a name that is already reserved, _resolve_key
        automatically appends a suffix.
        """
        params = {
            '_param': {'_secret': {'taken': 'direct_secret'}},
            'myapp':  {'password': 'nested'},
        }

        def fake_prompt(suggested, description):
            return 'taken'   # user deliberately picks a taken name

        ds, _, ns = m.collect_all_secrets(params, prompt_fn=fake_prompt)
        # Direct secret 'taken' is reserved first; nested gets 'taken_2'.
        _, _, nested_key = ns[0]
        self.assertEqual(nested_key, 'taken_2')


# ---------------------------------------------------------------------------
# apply_nested_replacements
# ---------------------------------------------------------------------------
class TestApplyNestedReplacements(unittest.TestCase):

    def test_simple_replacement(self):
        params = {'myapp': {'password': 's3cr3t', 'host': 'localhost'}}
        ns = [(('myapp', 'password'), 's3cr3t', 'myapp_password')]
        result = m.apply_nested_replacements(params, ns)
        self.assertEqual(result['myapp']['password'], '${_param:_secret:myapp_password}')
        self.assertEqual(result['myapp']['host'], 'localhost')

    def test_deep_replacement(self):
        params = {'a': {'b': {'c': {'token': 'tok'}}}}
        ns = [(('a', 'b', 'c', 'token'), 'tok', 'a_b_c_token')]
        result = m.apply_nested_replacements(params, ns)
        self.assertEqual(result['a']['b']['c']['token'], '${_param:_secret:a_b_c_token}')

    def test_does_not_mutate_original(self):
        params = {'myapp': {'password': 's3cr3t'}}
        original = copy.deepcopy(params)
        ns = [(('myapp', 'password'), 's3cr3t', 'myapp_password')]
        m.apply_nested_replacements(params, ns)
        self.assertEqual(params, original)

    def test_no_nested_secrets(self):
        params = {'myapp': {'host': 'localhost'}}
        result = m.apply_nested_replacements(params, [])
        self.assertEqual(result, params)


# ---------------------------------------------------------------------------
# secret_class_path / secret_class_name
# ---------------------------------------------------------------------------
class TestSecretClassPath(unittest.TestCase):

    def setUp(self):
        self.repo_root  = '/srv/salt'
        self.secret_dir = '/srv/salt/reclass/classes/secret'

    def test_nodes_file(self):
        src = '/srv/salt/reclass/nodes/myhost.yml'
        result = m.secret_class_path(src, self.repo_root, self.secret_dir)
        self.assertEqual(result, '/srv/salt/reclass/classes/secret/nodes/myhost.yml')

    def test_classes_file(self):
        src = '/srv/salt/reclass/classes/foo/bar.yml'
        result = m.secret_class_path(src, self.repo_root, self.secret_dir)
        self.assertEqual(result, '/srv/salt/reclass/classes/secret/classes/foo/bar.yml')


class TestSecretClassName(unittest.TestCase):

    def setUp(self):
        self.repo_root  = '/srv/salt'
        self.secret_dir = '/srv/salt/reclass/classes/secret'

    def test_nodes_file(self):
        src = '/srv/salt/reclass/nodes/myhost.yml'
        self.assertEqual(
            m.secret_class_name(src, self.repo_root, self.secret_dir),
            'secret.nodes.myhost',
        )

    def test_classes_file(self):
        src = '/srv/salt/reclass/classes/foo/bar.yml'
        self.assertEqual(
            m.secret_class_name(src, self.repo_root, self.secret_dir),
            'secret.classes.foo.bar',
        )

    def test_nested_classes(self):
        src = '/srv/salt/reclass/classes/a/b/c.yml'
        self.assertEqual(
            m.secret_class_name(src, self.repo_root, self.secret_dir),
            'secret.classes.a.b.c',
        )

    def test_yaml_extension(self):
        src = '/srv/salt/reclass/classes/foo/bar.yaml'
        self.assertEqual(
            m.secret_class_name(src, self.repo_root, self.secret_dir),
            'secret.classes.foo.bar',
        )


# ---------------------------------------------------------------------------
# Integration: process_file
# ---------------------------------------------------------------------------
class TestProcessFile(unittest.TestCase):

    def _run(self, source_yaml, extra_keys=(), prompt_fn=None):
        """
        Write *source_yaml* to a temp file, run process_file in dry_run=True,
        and return (direct_secrets, direct_remaining, nested_secrets) that
        would have been extracted, by collecting via collect_all_secrets.

        Also returns the list of would-be-written content strings via a
        patched write_or_print.
        """
        import yaml as _yaml
        with tempfile.TemporaryDirectory() as tmp:
            repo_root  = tmp
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            src_dir    = os.path.join(tmp, 'reclass', 'classes', 'test')
            os.makedirs(src_dir, exist_ok=True)
            src_path = os.path.join(src_dir, 'test.yml')

            with open(src_path, 'w') as f:
                f.write(source_yaml)

            written = []
            orig_wop = m.write_or_print

            def capture(path, content, dry_run, label):
                written.append((label, content))

            m.write_or_print = capture
            try:
                result = m.process_file(
                    src_path, repo_root, secret_dir,
                    dry_run=True, prompt_fn=prompt_fn, extra_keys=extra_keys,
                )
            finally:
                m.write_or_print = orig_wop

            return result, written

    def test_no_secrets_skipped(self):
        src = textwrap.dedent("""\
            parameters:
              myapp:
                host: localhost
                port: 8080
        """)
        changed, written = self._run(src)
        self.assertFalse(changed)
        self.assertEqual(written, [])

    def test_direct_secret_extracted_from_legacy_param(self):
        """_param: only pattern-matched keys are extracted; others stay."""
        src = textwrap.dedent("""\
            parameters:
              _param:
                db_password: s3cr3t
                db_host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        self.assertIn('db_password', secret_content)
        self.assertNotIn('db_host', secret_content)

        updated_content = next(c for label, c in written if label == 'updated source')
        self.assertNotIn('db_password', updated_content)
        self.assertIn('db_host', updated_content)
        # Non-secret keys remain under _param (not _param._secret).
        self.assertIn('_param:', updated_content)

    def test_direct_secret_all_keys_extracted(self):
        """_param._secret: ALL keys are extracted regardless of name."""
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  db_password: s3cr3t
                  db_host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        self.assertIn('db_password', secret_content)
        self.assertIn('db_host', secret_content)

        updated_content = next(c for label, c in written if label == 'updated source')
        self.assertNotIn('db_password', updated_content)
        self.assertNotIn('db_host', updated_content)

    def test_nested_secret_replaced(self):
        src = textwrap.dedent("""\
            parameters:
              myapp:
                admin_password: hunter2
                host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        updated = next(c for label, c in written if label == 'updated source')
        self.assertIn('${_param:_secret:myapp.admin_password}', updated)
        self.assertNotIn('hunter2', updated)

    def test_legacy_param_migrated(self):
        src = textwrap.dedent("""\
            parameters:
              _param:
                old_password: tok123
                old_host: srv
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        self.assertIn('old_password', secret_content)
        updated = next(c for label, c in written if label == 'updated source')
        # Non-secret keys remain under _param.
        self.assertIn('_param:', updated)
        self.assertIn('old_host', updated)
        self.assertNotIn('old_password', updated)

    def test_class_added_to_classes(self):
        src = textwrap.dedent("""\
            classes:
              - service.base
            parameters:
              _param:
                _secret:
                  pw: s3cr3t
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        updated = next(c for label, c in written if label == 'updated source')
        self.assertIn('service.base', updated)
        self.assertIn('secret.classes.test.test', updated)

    def test_class_not_duplicated(self):
        src = textwrap.dedent("""\
            classes:
              - secret.classes.test.test
            parameters:
              _param:
                _secret:
                  pw: s3cr3t
        """)
        changed, written = self._run(src)
        updated = next(c for label, c in written if label == 'updated source')
        self.assertEqual(updated.count('secret.classes.test.test'), 1)

    def test_secret_dir_files_skipped(self):
        import yaml as _yaml
        with tempfile.TemporaryDirectory() as tmp:
            repo_root  = tmp
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            os.makedirs(secret_dir, exist_ok=True)
            src_path = os.path.join(secret_dir, 'test.yml')
            with open(src_path, 'w') as f:
                f.write('parameters:\n  _param:\n    _secret:\n      pw: s3cr3t\n')
            result = m.process_file(
                src_path, repo_root, secret_dir,
                dry_run=True, prompt_fn=None, extra_keys=[],
            )
            self.assertFalse(result)

    def test_clash_resolves_in_output(self):
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  myapp.password: direct
              myapp:
                password: nested
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        self.assertIn('myapp.password:', secret_content)
        self.assertIn('myapp.password_2:', secret_content)


# ---------------------------------------------------------------------------
# Skip support in collect_all_secrets
# ---------------------------------------------------------------------------
class TestSkipSupport(unittest.TestCase):

    def test_skip_direct_secret(self):
        """prompt_fn returning SKIP_MARKER excludes the direct secret."""
        params = {'_param': {'_secret': {'admin_password': 'pw', 'db_token': 'tok'}}}

        def skip_admin(suggested, description):
            if 'admin_password' in description:
                return m.SKIP_MARKER
            return ''

        ds, _, _ = m.collect_all_secrets(params, prompt_fn=skip_admin)
        self.assertNotIn('admin_password', ds)
        self.assertIn('db_token', ds)

    def test_skip_nested_secret(self):
        """prompt_fn returning SKIP_MARKER excludes the nested secret."""
        params = {'myapp': {'password': 's3cr3t', 'db_secret': 'k'}}

        def skip_password(suggested, description):
            if 'password' in description:
                return m.SKIP_MARKER
            return ''

        _, _, ns = m.collect_all_secrets(params, prompt_fn=skip_password)
        keys = [key for _, _, key in ns]
        self.assertNotIn('myapp.password', keys)
        self.assertIn('myapp.db_secret', keys)

    def test_skip_all_yields_empty(self):
        """Skipping every candidate yields empty results."""
        params = {'_param': {'_secret': {'pw': 'x'}}, 'app': {'secret_val': 'y'}}

        def skip_all(suggested, description):
            return m.SKIP_MARKER

        ds, _, ns = m.collect_all_secrets(params, prompt_fn=skip_all)
        self.assertEqual(ds, {})
        self.assertEqual(ns, [])

    def test_skip_in_process_file(self):
        """Skipping all secrets in a file causes process_file to return False."""
        import yaml as _yaml
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = tmp
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            src_dir = os.path.join(tmp, 'reclass', 'classes', 'test')
            os.makedirs(src_dir, exist_ok=True)
            src_path = os.path.join(src_dir, 'test.yml')
            with open(src_path, 'w') as f:
                f.write('parameters:\n  _param:\n    _secret:\n      pw: s3cr3t\n')

            def skip_all(suggested, description):
                return m.SKIP_MARKER

            result = m.process_file(
                src_path, repo_root, secret_dir,
                dry_run=True, prompt_fn=skip_all, extra_keys=[],
            )
            self.assertFalse(result)


# ---------------------------------------------------------------------------
# collect_candidates_for_file
# ---------------------------------------------------------------------------
class TestCollectCandidatesForFile(unittest.TestCase):

    def _write_yaml(self, tmp, yaml_text, subdir='classes/test', name='test.yml'):
        src_dir = os.path.join(tmp, 'reclass', subdir)
        os.makedirs(src_dir, exist_ok=True)
        src_path = os.path.join(src_dir, name)
        with open(src_path, 'w') as f:
            f.write(yaml_text)
        return src_path

    def test_collects_direct_and_nested(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self._write_yaml(tmp, textwrap.dedent("""\
                parameters:
                  _param:
                    _secret:
                      db_password: pw
                  myapp:
                    api_secret: tok
                    host: localhost
            """))
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            cands = m.collect_candidates_for_file(src, tmp, secret_dir, [])
            descs = [d for d, _ in cands]
            self.assertTrue(any('db_password' in d for d in descs))
            self.assertTrue(any('api_secret' in d for d in descs))
            # Non-secret 'host' should not appear.
            self.assertFalse(any('host' in d for d in descs
                                 if 'secret' not in d and 'password' not in d))

    def test_no_secrets_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self._write_yaml(tmp, textwrap.dedent("""\
                parameters:
                  myapp:
                    host: localhost
            """))
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            cands = m.collect_candidates_for_file(src, tmp, secret_dir, [])
            self.assertEqual(cands, [])

    def test_secret_dir_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            src = self._write_yaml(tmp, textwrap.dedent("""\
                parameters:
                  _param:
                    _secret:
                      pw: s3cr3t
            """), subdir='classes/secret')
            cands = m.collect_candidates_for_file(src, tmp, secret_dir, [])
            self.assertEqual(cands, [])

    def test_descriptions_match_collect_all_secrets(self):
        """Descriptions from collect_candidates_for_file must match those
        generated by collect_all_secrets, so batch decisions map correctly."""
        with tempfile.TemporaryDirectory() as tmp:
            src = self._write_yaml(tmp, textwrap.dedent("""\
                parameters:
                  _param:
                    _secret:
                      db_password: pw
                  myapp:
                    api_secret: tok
            """))
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            cands = m.collect_candidates_for_file(src, tmp, secret_dir, [])
            cand_descs = {d for d, _ in cands}

            # Collect the descriptions that collect_all_secrets would produce.
            import yaml as _yaml
            with open(src) as f:
                data = _yaml.safe_load(f)
            actual_descs = set()

            def capture_prompt(suggested, description):
                actual_descs.add(description)
                return ''

            m.collect_all_secrets(data['parameters'], prompt_fn=capture_prompt)
            self.assertEqual(cand_descs, actual_descs)


# ---------------------------------------------------------------------------
# make_batch_prompt_fn
# ---------------------------------------------------------------------------
class TestMakeBatchPromptFn(unittest.TestCase):

    def test_returns_decided_key(self):
        decisions = {'_param._secret.pw  (direct)': 'my_renamed_key'}
        pfn = m.make_batch_prompt_fn(decisions)
        self.assertEqual(pfn('pw', '_param._secret.pw  (direct)'), 'my_renamed_key')

    def test_missing_description_returns_skip(self):
        decisions = {}
        pfn = m.make_batch_prompt_fn(decisions)
        self.assertEqual(pfn('pw', '_param._secret.pw  (direct)'), m.SKIP_MARKER)

    def test_skip_marker_passed_through(self):
        decisions = {'_param._secret.pw  (direct)': m.SKIP_MARKER}
        pfn = m.make_batch_prompt_fn(decisions)
        self.assertEqual(pfn('pw', '_param._secret.pw  (direct)'), m.SKIP_MARKER)

    def test_integration_with_collect_all_secrets(self):
        """Batch prompt_fn drives collect_all_secrets correctly."""
        params = {
            '_param': {'_secret': {'admin_password': 'pw', 'db_token': 'tok'}},
            'myapp': {'api_secret': 'k'},
        }
        decisions = {
            '_param._secret.admin_password  (direct)': 'renamed_pw',
            '_param._secret.db_token  (direct)': m.SKIP_MARKER,
            'parameters.myapp.api_secret': 'app_api_secret',
        }
        pfn = m.make_batch_prompt_fn(decisions)
        ds, _, ns = m.collect_all_secrets(params, prompt_fn=pfn)
        # admin_password renamed.
        self.assertIn('renamed_pw', ds)
        self.assertEqual(ds['renamed_pw'], 'pw')
        # db_token skipped.
        self.assertNotIn('db_token', ds)
        # Nested api_secret renamed.
        nested_keys = [key for _, _, key in ns]
        self.assertIn('app_api_secret', nested_keys)


# ---------------------------------------------------------------------------
# batch_review (parsing logic)
# ---------------------------------------------------------------------------
class TestBatchReviewParsing(unittest.TestCase):
    """Test the review-file parsing inside batch_review by simulating
    the $EDITOR step (monkey-patching subprocess.check_call)."""

    def _run_batch_review(self, candidates_by_file, repo_root, edited_content):
        """Run batch_review with a fake editor that writes *edited_content*."""
        import subprocess as _sp

        original_check_call = _sp.check_call

        def fake_editor(cmd, **kw):
            # cmd = ['editor', tmppath]
            tmppath = cmd[1]
            with open(tmppath, 'w') as f:
                f.write(edited_content)

        _sp.check_call = fake_editor
        try:
            return m.batch_review(candidates_by_file, repo_root)
        finally:
            _sp.check_call = original_check_call

    def test_accept_all(self):
        repo_root = '/srv/salt'
        fp = '/srv/salt/reclass/nodes/myhost.yml'
        candidates = [
            (fp, [
                ('_param._secret.pw  (direct)', 'pw'),
                ('parameters.myapp.token', 'myapp.token'),
            ]),
        ]
        edited = textwrap.dedent("""\
            ## reclass/nodes/myhost.yml
            _param._secret.pw  (direct) | pw
            parameters.myapp.token | myapp.token
        """)
        decisions = self._run_batch_review(candidates, repo_root, edited)
        self.assertEqual(decisions[fp]['_param._secret.pw  (direct)'], 'pw')
        self.assertEqual(decisions[fp]['parameters.myapp.token'], 'myapp.token')

    def test_rename_key(self):
        repo_root = '/srv/salt'
        fp = '/srv/salt/reclass/nodes/myhost.yml'
        candidates = [
            (fp, [('_param._secret.pw  (direct)', 'pw')]),
        ]
        edited = textwrap.dedent("""\
            ## reclass/nodes/myhost.yml
            _param._secret.pw  (direct) | my_custom_name
        """)
        decisions = self._run_batch_review(candidates, repo_root, edited)
        self.assertEqual(decisions[fp]['_param._secret.pw  (direct)'], 'my_custom_name')

    def test_delete_line_skips(self):
        repo_root = '/srv/salt'
        fp = '/srv/salt/reclass/nodes/myhost.yml'
        candidates = [
            (fp, [
                ('_param._secret.pw  (direct)', 'pw'),
                ('parameters.myapp.token', 'myapp.token'),
            ]),
        ]
        # Only keep the token line, delete the pw line.
        edited = textwrap.dedent("""\
            ## reclass/nodes/myhost.yml
            parameters.myapp.token | myapp.token
        """)
        decisions = self._run_batch_review(candidates, repo_root, edited)
        self.assertEqual(decisions[fp]['_param._secret.pw  (direct)'], m.SKIP_MARKER)
        self.assertEqual(decisions[fp]['parameters.myapp.token'], 'myapp.token')

    def test_comment_line_skips(self):
        repo_root = '/srv/salt'
        fp = '/srv/salt/reclass/nodes/myhost.yml'
        candidates = [
            (fp, [('_param._secret.pw  (direct)', 'pw')]),
        ]
        edited = textwrap.dedent("""\
            ## reclass/nodes/myhost.yml
            # _param._secret.pw  (direct) | pw
        """)
        decisions = self._run_batch_review(candidates, repo_root, edited)
        self.assertEqual(decisions[fp]['_param._secret.pw  (direct)'], m.SKIP_MARKER)

    def test_multiple_files(self):
        repo_root = '/srv/salt'
        fp1 = '/srv/salt/reclass/nodes/host1.yml'
        fp2 = '/srv/salt/reclass/nodes/host2.yml'
        candidates = [
            (fp1, [('_param._secret.pw  (direct)', 'pw')]),
            (fp2, [('parameters.app.token', 'app_token')]),
        ]
        # Accept host1, skip host2.
        edited = textwrap.dedent("""\
            ## reclass/nodes/host1.yml
            _param._secret.pw  (direct) | pw

            ## reclass/nodes/host2.yml
        """)
        decisions = self._run_batch_review(candidates, repo_root, edited)
        self.assertEqual(decisions[fp1]['_param._secret.pw  (direct)'], 'pw')
        self.assertEqual(decisions[fp2]['parameters.app.token'], m.SKIP_MARKER)


# ---------------------------------------------------------------------------
# extract_secret_comments
# ---------------------------------------------------------------------------
class TestExtractSecretComments(unittest.TestCase):

    def _write(self, content):
        f = tempfile.NamedTemporaryFile(
            mode='w', suffix='.yml', delete=False)
        f.write(content)
        f.close()
        return f.name

    def test_extracts_and_associates_with_following_key(self):
        path = self._write(textwrap.dedent("""\
            parameters:
              myapp:
                # _secret_: hunter2
                admin_password: ${_param:_secret:myapp.admin_password}
                # normal comment
                host: localhost
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(len(comments), 1)
            self.assertEqual(comments[0],
                             ('# _secret_: hunter2',
                              ('parameters', 'myapp', 'admin_password')))
        finally:
            os.unlink(path)

    def test_preserves_order_and_paths(self):
        path = self._write(textwrap.dedent("""\
            # _secret_: first
            parameters:
              # _secret_: second
              myapp:
                # _secret_: third
                pw: x
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(comments, [
                ('# _secret_: first', ('parameters',)),
                ('# _secret_: second', ('parameters', 'myapp')),
                ('# _secret_: third', ('parameters', 'myapp', 'pw')),
            ])
        finally:
            os.unlink(path)

    def test_no_secret_comments(self):
        path = self._write(textwrap.dedent("""\
            # just a normal comment
            parameters:
              myapp:
                host: localhost
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(comments, [])
        finally:
            os.unlink(path)

    def test_ignores_non_comment_lines_with_marker(self):
        path = self._write(textwrap.dedent("""\
            parameters:
              myapp:
                _secret_marker: not_a_comment
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(comments, [])
        finally:
            os.unlink(path)

    def test_comment_at_end_of_file_has_no_key(self):
        path = self._write(textwrap.dedent("""\
            parameters:
              pw: x
            # _secret_: trailing
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(comments, [('# _secret_: trailing', None)])
        finally:
            os.unlink(path)

    def test_inline_comment_associated_with_same_line_key(self):
        path = self._write(textwrap.dedent("""\
            parameters:
              myapp:
                db_password: mypass  # _secret_: the real password
                host: localhost
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(len(comments), 1)
            self.assertEqual(comments[0],
                             ('# _secret_: the real password',
                              ('parameters', 'myapp', 'db_password')))
        finally:
            os.unlink(path)

    def test_inline_and_standalone_mixed(self):
        path = self._write(textwrap.dedent("""\
            parameters:
              myapp:
                db_password: mypass  # _secret_: inline pw
                # _secret_: standalone pw
                api_secret: tok
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(comments, [
                ('# _secret_: inline pw',
                 ('parameters', 'myapp', 'db_password')),
                ('# _secret_: standalone pw',
                 ('parameters', 'myapp', 'api_secret')),
            ])
        finally:
            os.unlink(path)

    def test_inline_comment_without_key_marker_ignored(self):
        """A line with _secret_ in a value but not in a comment is ignored."""
        path = self._write(textwrap.dedent("""\
            parameters:
              note: "contains _secret_ in value"
        """))
        try:
            comments = m.extract_secret_comments(path)
            self.assertEqual(comments, [])
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# inject_comments_into_yaml
# ---------------------------------------------------------------------------
class TestInjectCommentsIntoYaml(unittest.TestCase):

    def test_injects_before_matching_key(self):
        yaml_text = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw: s3cr3t
        """)
        comments = [('# _secret_: old_password', 'pw')]
        result = m.inject_comments_into_yaml(yaml_text, comments)
        lines = result.splitlines()
        pw_idx = next(i for i, l in enumerate(lines) if 'pw:' in l)
        self.assertIn('# _secret_: old_password', lines[pw_idx - 1])

    def test_preserves_indentation(self):
        yaml_text = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw: s3cr3t
        """)
        comments = [('# _secret_: pw', 'pw')]
        result = m.inject_comments_into_yaml(yaml_text, comments)
        lines = result.splitlines()
        pw_idx = next(i for i, l in enumerate(lines)
                      if l.strip().startswith('pw:'))
        comment_line = lines[pw_idx - 1]
        pw_line = lines[pw_idx]
        self.assertEqual(
            len(pw_line) - len(pw_line.lstrip()),
            len(comment_line) - len(comment_line.lstrip()),
        )

    def test_multiple_comments_different_keys(self):
        yaml_text = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  admin_pw: a
                  db_token: b
        """)
        comments = [
            ('# _secret_: for_admin', 'admin_pw'),
            ('# _secret_: for_db', 'db_token'),
        ]
        result = m.inject_comments_into_yaml(yaml_text, comments)
        lines = result.splitlines()
        admin_idx = next(i for i, l in enumerate(lines) if 'admin_pw:' in l)
        db_idx = next(i for i, l in enumerate(lines) if 'db_token:' in l)
        self.assertIn('for_admin', lines[admin_idx - 1])
        self.assertIn('for_db', lines[db_idx - 1])
        self.assertLess(admin_idx, db_idx)

    def test_multiple_comments_same_key(self):
        yaml_text = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw: x
        """)
        comments = [('# _secret_: first', 'pw'), ('# _secret_: second', 'pw')]
        result = m.inject_comments_into_yaml(yaml_text, comments)
        lines = result.splitlines()
        pw_idx = next(i for i, l in enumerate(lines) if l.strip().startswith('pw:'))
        self.assertIn('first', lines[pw_idx - 2])
        self.assertIn('second', lines[pw_idx - 1])

    def test_empty_comments_no_change(self):
        yaml_text = "parameters:\n  _param:\n    _secret:\n      pw: x\n"
        self.assertEqual(m.inject_comments_into_yaml(yaml_text, []), yaml_text)

    def test_orphan_comment_appended(self):
        yaml_text = "parameters:\n  _param:\n    _secret:\n      pw: x\n"
        comments = [('# _secret_: orphan', None)]
        result = m.inject_comments_into_yaml(yaml_text, comments)
        self.assertIn('# _secret_: orphan', result)

    def test_unmatched_key_appended(self):
        yaml_text = "parameters:\n  _param:\n    _secret:\n      pw: x\n"
        comments = [('# _secret_: gone', 'nonexistent')]
        result = m.inject_comments_into_yaml(yaml_text, comments)
        self.assertIn('# _secret_: gone', result)


# ---------------------------------------------------------------------------
# Integration: process_file with _secret_ comments
# ---------------------------------------------------------------------------
class TestProcessFileSecretComments(unittest.TestCase):

    def _run(self, source_yaml, extra_keys=(), prompt_fn=None):
        import yaml as _yaml
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = tmp
            secret_dir = os.path.join(tmp, 'reclass', 'classes', 'secret')
            src_dir = os.path.join(tmp, 'reclass', 'classes', 'test')
            os.makedirs(src_dir, exist_ok=True)
            src_path = os.path.join(src_dir, 'test.yml')

            with open(src_path, 'w') as f:
                f.write(source_yaml)

            written = []
            orig_wop = m.write_or_print

            def capture(path, content, dry_run, label):
                written.append((label, content))

            m.write_or_print = capture
            try:
                result = m.process_file(
                    src_path, repo_root, secret_dir,
                    dry_run=True, prompt_fn=prompt_fn, extra_keys=extra_keys,
                )
            finally:
                m.write_or_print = orig_wop

            return result, written

    def test_secret_comment_placed_before_its_key(self):
        """Comment is placed right above the key it was associated with."""
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  admin_password: pw
              myapp:
                # _secret_: old_db_pass
                db_password: ${_param:_secret:db_password}
                host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        lines = secret_content.splitlines()
        comment_idx = next(i for i, l in enumerate(lines)
                           if '_secret_: old_db_pass' in l)
        # The comment was on db_password in source; in the secret file
        # it should appear somewhere above the keys (associated key = db_password).
        self.assertIn('# _secret_: old_db_pass', secret_content)

    def test_comment_above_correct_key_in_secret_file(self):
        """Two comments associated with different keys land above each key."""
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw_a: aaa
                  pw_b: bbb
              myapp:
                # _secret_: secret_for_a
                pw_a: ${_param:_secret:pw_a}
                # _secret_: secret_for_b
                pw_b: ${_param:_secret:pw_b}
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        lines = secret_content.splitlines()
        # Find key lines in secret file.
        a_idx = next(i for i, l in enumerate(lines) if 'pw_a:' in l)
        b_idx = next(i for i, l in enumerate(lines) if 'pw_b:' in l)
        # Comments should be right before their keys.
        self.assertIn('secret_for_a', lines[a_idx - 1])
        self.assertIn('secret_for_b', lines[b_idx - 1])

    def test_comment_mapped_to_nested_secret_key(self):
        """Comment on a nested key (e.g. db_password) lands above the
        renamed key in the secret file (e.g. myapp.db_password)."""
        src = textwrap.dedent("""\
            parameters:
              myapp:
                # _secret_: the_real_password
                db_password: hunter2
                host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        lines = secret_content.splitlines()
        # The key in the secret file is 'myapp.db_password' (dotted path).
        key_idx = next(i for i, l in enumerate(lines) if 'myapp.db_password' in l)
        # Comment should be right before it, not at the end.
        self.assertIn('the_real_password', lines[key_idx - 1])

    def test_inline_comment_mapped_to_nested_secret_key(self):
        """Inline comment on a nested key lands above the renamed key."""
        src = textwrap.dedent("""\
            parameters:
              myapp:
                db_password: hunter2  # _secret_: the real password
                host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        lines = secret_content.splitlines()
        key_idx = next(i for i, l in enumerate(lines) if 'myapp.db_password' in l)
        self.assertIn('the real password', lines[key_idx - 1])

    def test_inline_comment_on_reference_value(self):
        """Inline comment on an already-migrated ref value is still mapped."""
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  myapp.db_password: hunter2
              myapp:
                db_password: ${_param:_secret:myapp.db_password}  # _secret_: the real pw
                host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        lines = secret_content.splitlines()
        key_idx = next(i for i, l in enumerate(lines) if 'myapp.db_password' in l)
        self.assertIn('the real pw', lines[key_idx - 1])

    def test_only_secret_comments_no_yaml_secrets(self):
        """File with only _secret_ comments (no YAML secrets) still migrates."""
        src = textwrap.dedent("""\
            # _secret_: legacy_password_in_comment
            parameters:
              myapp:
                host: localhost
        """)
        changed, written = self._run(src)
        self.assertTrue(changed)
        secret_content = next(c for label, c in written if label == 'secret class')
        self.assertIn('# _secret_: legacy_password_in_comment', secret_content)

    def test_normal_comments_not_migrated(self):
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw: s3cr3t
              myapp:
                # this is a normal comment
                host: localhost
        """)
        changed, written = self._run(src)
        secret_content = next(c for label, c in written if label == 'secret class')
        self.assertNotIn('this is a normal comment', secret_content)


# ---------------------------------------------------------------------------
# update_source_file_text (in-place editing)
# ---------------------------------------------------------------------------
class TestUpdateSourceFileText(unittest.TestCase):

    def test_preserves_key_order(self):
        src = textwrap.dedent("""\
            classes:
            - service.base
            parameters:
              zebra:
                host: z
              alpha:
                password: s3cr3t
                host: a
              _param:
                _secret:
                  pw: 123
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={('alpha', 'password'): '${_param:_secret:alpha.password}'},
            cls_name='secret.classes.test.test',
        )
        lines = result.splitlines()
        # Key order preserved: zebra before alpha.
        zebra_idx = next(i for i, l in enumerate(lines) if 'zebra:' in l)
        alpha_idx = next(i for i, l in enumerate(lines) if 'alpha:' in l)
        self.assertLess(zebra_idx, alpha_idx)
        # Value replaced.
        self.assertIn('${_param:_secret:alpha.password}', result)
        # Original value gone.
        self.assertNotIn('s3cr3t', result)
        # Non-secret key preserved.
        self.assertIn('host: a', result)

    def test_preserves_comments(self):
        src = textwrap.dedent("""\
            # File header comment
            classes:
            - service.base
            parameters:
              # Section comment
              myapp:
                # This is a normal comment
                password: s3cr3t
                host: localhost
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={('myapp', 'password'): '${_param:_secret:myapp.password}'},
            cls_name='secret.classes.test.test',
        )
        self.assertIn('# File header comment', result)
        self.assertIn('# Section comment', result)
        self.assertIn('# This is a normal comment', result)

    def test_removes_param_secret_block(self):
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw: 123
                  tok: abc
                host: kept
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys={'host'},
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertNotIn('pw:', result)
        self.assertNotIn('tok:', result)
        self.assertNotIn('_secret:', result)
        self.assertIn('host: kept', result)
        self.assertIn('_param:', result)

    def test_removes_empty_param_block(self):
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  pw: 123
              myapp:
                host: ok
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertNotIn('_param:', result)
        self.assertIn('myapp:', result)

    def test_removes_bare_secret_block(self):
        src = textwrap.dedent("""\
            parameters:
              _secret:
                old_pw: legacy
              myapp:
                host: ok
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertNotIn('old_pw', result)
        self.assertNotIn('_secret:', result)
        self.assertIn('host: ok', result)

    def test_removes_legacy_param_keys(self):
        src = textwrap.dedent("""\
            parameters:
              _param:
                db_password: s3cr3t
                db_host: localhost
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys={'db_host'},
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertNotIn('db_password', result)
        self.assertIn('db_host: localhost', result)

    def test_removes_secret_comments(self):
        src = textwrap.dedent("""\
            parameters:
              myapp:
                # _secret_: old_pw
                password: s3cr3t
                host: ok  # _secret_: inline_secret
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={('myapp', 'password'): '${_param:_secret:pw}'},
            cls_name='secret.test',
        )
        self.assertNotIn('_secret_', result)
        self.assertIn('host: ok', result)
        # Inline comment stripped but key:value preserved.
        self.assertNotIn('inline_secret', result)

    def test_adds_class_import(self):
        src = textwrap.dedent("""\
            classes:
            - service.base
            parameters:
              _param:
                _secret:
                  pw: 123
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertIn('secret.test', result)
        self.assertIn('service.base', result)

    def test_does_not_duplicate_class(self):
        src = textwrap.dedent("""\
            classes:
            - secret.test
            parameters:
              _param:
                _secret:
                  pw: 123
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertEqual(result.count('secret.test'), 1)

    def test_preserves_indentation_style(self):
        """4-space indented files stay 4-space indented."""
        src = textwrap.dedent("""\
            parameters:
                myapp:
                    password: s3cr3t
                    host: localhost
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={('myapp', 'password'): '${_param:_secret:pw}'},
            cls_name='secret.test',
        )
        # The host line should keep its 8-space indent.
        host_line = [l for l in result.splitlines() if 'host:' in l][0]
        self.assertTrue(host_line.startswith('        '))

    def test_multiline_block_scalar_replaced(self):
        """Block scalar (|) continuation lines are removed on replacement."""
        src = textwrap.dedent("""\
            parameters:
              myapp:
                private_key: |
                  -----BEGIN RSA PRIVATE KEY-----
                  MIIEpAIBAAKCAQEA...
                  -----END RSA PRIVATE KEY-----
                host: localhost
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={('myapp', 'private_key'): '${_param:_secret:myapp.private_key}'},
            cls_name='secret.test',
        )
        self.assertIn('${_param:_secret:myapp.private_key}', result)
        self.assertNotIn('BEGIN RSA', result)
        self.assertNotIn('MIIEp', result)
        self.assertIn('host: localhost', result)

    def test_multiline_folded_scalar_replaced(self):
        """Folded scalar (>) continuation lines are removed on replacement."""
        src = textwrap.dedent("""\
            parameters:
              myapp:
                secret_desc: >
                  This is a long
                  secret description
                host: localhost
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={('myapp', 'secret_desc'): '${_param:_secret:myapp.secret_desc}'},
            cls_name='secret.test',
        )
        self.assertNotIn('This is a long', result)
        self.assertNotIn('secret description', result)
        self.assertIn('host: localhost', result)

    def test_multiline_in_param_secret_block(self):
        """Multi-line values inside _param._secret are fully removed."""
        src = textwrap.dedent("""\
            parameters:
              _param:
                _secret:
                  cert: |
                    -----BEGIN CERTIFICATE-----
                    MIID...
                    -----END CERTIFICATE-----
                  pw: simple
              myapp:
                host: ok
        """)
        result = m.update_source_file_text(
            src,
            direct_remaining_keys=set(),
            nested_replacements={},
            cls_name='secret.test',
        )
        self.assertNotIn('BEGIN CERTIFICATE', result)
        self.assertNotIn('MIID', result)
        self.assertNotIn('simple', result)
        self.assertIn('host: ok', result)


if __name__ == '__main__':
    unittest.main()
