"""nso_syms.py sdk_exports: the SDK surface is read from sdk and every subsdk<N> module, never main or rtld, so a game without an sdk module (30XX ships only subsdk0-2) is surveyed too."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('nso_syms', REPO / 'dm/tools/nso_syms.py')
ns = importlib.util.module_from_spec(spec); spec.loader.exec_module(ns)


class SdkExports(unittest.TestCase):
    def exefs(self, *names):
        d = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, d)
        for n in names: (d / n).write_bytes(b'')
        return d

    def test_modules_read(self):
        for names, want in [(('main', 'main.npdm', 'rtld', 'subsdk0', 'subsdk1', 'subsdk2'), ['subsdk0', 'subsdk1', 'subsdk2']),
                            (('main', 'rtld', 'sdk', 'subsdk9'), ['sdk', 'subsdk9'])]:
            seen = []
            with mock.patch.object(ns, 'exports', lambda e, m: (seen.append(m), {m + '_sym'})[1]):
                got = ns.sdk_exports(str(self.exefs(*names)))
            self.assertEqual(seen, want); self.assertEqual(got, {m + '_sym' for m in want})


if __name__ == '__main__':
    unittest.main()
