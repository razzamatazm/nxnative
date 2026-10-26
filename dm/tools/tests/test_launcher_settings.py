"""The launcher offers frame buffering only for the graphics API selected by the packer."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('launcher_settings', ROOT / 'dm/games/settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class LauncherSettingsTests(unittest.TestCase):
    def test_frame_buffering_by_graphics_api(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']):
            for api, gid in [('nvn', '01007EF00011E000'), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000'), ('', '01007EF00011E000')]:
                with self.subTest(api=api), patch.dict(os.environ, {'GFXAPI': api}):
                    rows = settings.build(gid, tmp, Path(tmp) / 'control.nacp')['settings']
                    found = [s for s in rows if s['env'] == 'DM_PRESENT_SNAP']
                    self.assertEqual(len(found), int(api == 'nvn'))
                    if found:
                        self.assertEqual(found[0]['kind'], 'toggle')
                        self.assertEqual(found[0]['default'], '0')
                        self.assertIn('latency', found[0]['note'])

    def test_platform(self):   # the touch gamepad's feedback is the iPhone's only; the Mac app (DM_PACK_PLATFORM=mac) leaves it out
        with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']):
            for platform, shown in [('', True), ('ios', True), ('mac', False)]:
                with self.subTest(platform=platform), patch.dict(os.environ, {'DM_PACK_PLATFORM': platform, 'GFXAPI': 'nvn'}):
                    rows = settings.build('01007EF00011E000', tmp, Path(tmp) / 'control.nacp')['settings']
                    self.assertEqual(any(s['env'] == 'DM_TOUCH_HAPTICS' for s in rows), shown)
                    self.assertTrue(any(s['env'] == 'DM_OPMODE' for s in rows))


if __name__ == '__main__':
    unittest.main()
