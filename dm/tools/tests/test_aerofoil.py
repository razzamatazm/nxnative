"""Aerofoil downloader (scripts/aerofoil.py): logs in as the web UI does, searches /api/titles, takes the base game, the newest update and each DLC's newest version from
/api/title-details, downloads them into <library>/<name> [<title ID>]/ resuming a .part file, and refuses a library inside the repository. A small stand-in server plays Aerofoil."""
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from unittest import mock
import urllib.parse

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('aerofoil', REPO / 'scripts/aerofoil.py')
af = importlib.util.module_from_spec(spec); spec.loader.exec_module(af)

TID = '0100AAAA00000000'
BLOBS = {1: b'B' * 3000, 2: b'u1' * 100, 3: b'U' * 2500, 4: b'd0' * 50, 5: b'D' * 700, 6: b'X' * 10}
NAMES = {1: f'Game [{TID}][v0].nsp', 2: f'Game [0100AAAA00000800][v65536].nsp', 3: f'Game [0100AAAA00000800][v131072].nsp',
         4: 'Game DLC [0100AAAA00001001][v0].nsp', 5: 'Game DLC [0100AAAA00001001][v65536].nsp', 6: f'Game [{TID}][v0].xci'}


def entry(i): return {'id': i, 'filename': NAMES[i], 'size': len(BLOBS[i]), 'url': f'/api/get_game/{i}?download=1'}


GAME = {'name': 'Game: The Test', 'title_id_name': 'Game: The Test', 'title_id': TID, 'app_id': TID, 'app_type': 'BASE', 'files': [entry(6), entry(1)],
        'version': [{'version': 65536, 'files': [entry(2)]}, {'version': 131072, 'files': [entry(3)]}, {'version': 196608, 'files': []}],
        'dlc_list': [{'app_id': '0100AAAA00001001', 'files': [entry(4), entry(5)]}, {'app_id': '0100AAAA00001002', 'files': []}]}


class Fake(http.server.BaseHTTPRequestHandler):
    ranges = []

    def log_message(self, *a): pass

    def authed(self): return 'session=ok' in (self.headers.get('Cookie') or '')

    def send(self, code, body=b'', headers=()):
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        if form.get('user') == ['me'] and form.get('password') == ['pw']:
            self.send(302, headers=[('Location', '/'), ('Set-Cookie', 'session=ok; Path=/')])
        else:
            self.send(302, headers=[('Location', '/login')])

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        if not self.authed(): return self.send(302, headers=[('Location', '/login?next=' + u.path)])
        if u.path == '/api/titles':
            games = [g for g in [GAME, {**GAME, 'title_id': '0100BBBB00000000', 'app_id': '0100BBBB00000000', 'title_id_name': 'Other Game'}]
                     if q['search'].lower() in g['title_id_name'].lower() or q['search'].upper() == g['title_id']]
            return self.send(200, json.dumps({'total': len(games), 'page': 1, 'games': games}).encode())
        if u.path == '/api/title-details':
            return self.send(200, json.dumps({'success': q['app_id'] == TID, 'game': GAME if q['app_id'] == TID else None}).encode())
        if u.path.startswith('/api/get_game/'):
            blob = BLOBS[int(u.path.rsplit('/', 1)[1])]; rng = self.headers.get('Range'); Fake.ranges.append(rng)
            if rng:
                start = int(rng.split('=')[1].rstrip('-'))
                return self.send(206, blob[start:], [('Content-Range', f'bytes {start}-{len(blob) - 1}/{len(blob)}')])
            return self.send(200, blob)
        self.send(404)


class Aerofoil(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, self.tmp)
        self.srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fake)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.shutdown)
        self.url = f'http://127.0.0.1:{self.srv.server_address[1]}'
        env = {'AEROFOIL_PASSWORD': 'pw'}
        p = mock.patch.dict(os.environ, env); p.start(); self.addCleanup(p.stop)
        p = mock.patch.object(af, 'CONFIG', self.tmp / 'cfg.json'); p.start(); self.addCleanup(p.stop)
        p = mock.patch.object(af, 'interactive', lambda: False); p.start(); self.addCleanup(p.stop)
        Fake.ranges = []

    def run_main(self, *args):
        out = io.StringIO()
        with redirect_stdout(out): rc = af.main(['--server', self.url, '--user', 'me', '--library', str(self.tmp / 'lib'), *args])
        return rc, out.getvalue()

    def test_plan_takes_base_newest_update_newest_dlc(self):
        kinds = [(k, f['id']) for k, f in af.plan(GAME)]
        self.assertEqual(kinds, [('base', 1), ('update v131072', 3), ('DLC 0100AAAA00001001', 5)])
        self.assertEqual([f['id'] for _, f in af.plan(GAME, update=False, dlc=False)], [1])

    def test_download_into_game_folder(self):
        rc, out = self.run_main(TID, '-y')
        self.assertEqual(rc, 0)
        d = self.tmp / 'lib' / f'Game The Test [{TID}]'
        self.assertEqual(sorted(p.name for p in d.iterdir()), sorted(NAMES[i] for i in (1, 3, 5)))
        for i in (1, 3, 5): self.assertEqual((d / NAMES[i]).read_bytes(), BLOBS[i])
        self.assertIn('build_ipa_from_nsp.py', out)
        self.assertEqual(json.loads((self.tmp / 'cfg.json').read_text())['server'], self.url)
        self.assertNotIn('pw', json.loads((self.tmp / 'cfg.json').read_text()).values())   # the password stays out of the config

    def test_resume_and_skip(self):
        d = self.tmp / 'lib' / f'Game The Test [{TID}]'; d.mkdir(parents=True)
        (d / (NAMES[1] + '.part')).write_bytes(BLOBS[1][:1000])
        (d / NAMES[3]).write_bytes(BLOBS[3])
        self.assertEqual(self.run_main(TID, '-y')[0], 0)
        self.assertEqual((d / NAMES[1]).read_bytes(), BLOBS[1])
        self.assertFalse((d / (NAMES[1] + '.part')).exists())
        self.assertEqual(Fake.ranges, ['bytes=1000-', None])   # the base resumed, the update skipped, the DLC fetched whole

    def test_several_matches_need_a_pick(self):
        with self.assertRaisesRegex(af.Error, '2 matches; choose one with --pick'): self.run_main('game')
        self.assertEqual(self.run_main('game', '--pick', '1', '-y')[0], 0)
        rc, out = self.run_main('game', '--list')
        self.assertIn('Other Game', out)

    def test_list_sizes_and_free_space(self):
        row = {**GAME, 'size': 4 << 30, 'version': [{'version': 65536, 'owned': True, 'size': 1 << 30}, {'version': 131072, 'owned': True, 'size': 2 << 30},
                                                   {'version': 196608, 'owned': False, 'size': 3 << 30}]}
        self.assertEqual(af.list_size(row), 6 << 30)   # the base and the newest update the server has
        self.assertEqual(af.build_need(6 << 30), 22 << 30)
        out = io.StringIO()
        with redirect_stdout(out), mock.patch.object(af, 'free_space', lambda p: 20 << 30): af.show([row], self.tmp / 'lib')
        self.assertIn('20.0 GB free', out.getvalue()); self.assertIn('6.0 GB', out.getvalue()); self.assertIn('22.0 GB !', out.getvalue())
        af.game_dir(self.tmp / 'lib', GAME['title_id_name'], TID).mkdir(parents=True)
        (af.game_dir(self.tmp / 'lib', GAME['title_id_name'], TID) / NAMES[1]).write_bytes(b'x')
        out = io.StringIO()
        with redirect_stdout(out), mock.patch.object(af, 'free_space', lambda p: 20 << 30): af.show([row], self.tmp / 'lib')
        self.assertIn('(downloaded)', out.getvalue()); self.assertNotIn('22.0 GB !', out.getvalue())

    def test_confirmation(self):
        with self.assertRaisesRegex(af.Error, 'pass -y'): self.run_main(TID)
        self.assertFalse((self.tmp / 'lib').exists())   # nothing made before the answer
        with mock.patch.object(af, 'interactive', lambda: True), mock.patch('builtins.input', lambda *_: 'n'):
            rc, out = self.run_main(TID)
        self.assertEqual(rc, 0); self.assertIn('1 match: Game: The Test', out); self.assertIn('Cancelled.', out); self.assertFalse((self.tmp / 'lib').exists())
        with mock.patch.object(af, 'interactive', lambda: True), mock.patch('builtins.input', lambda *_: ''):
            rc, out = self.run_main(TID)
        self.assertIn('[3/3] DLC', out); self.assertIn('Done: 3 file(s)', out)
        rc, out = self.run_main(TID)   # all files here: nothing to confirm, even without a terminal
        self.assertEqual(rc, 0); self.assertIn('Done: 3 file(s)', out)

    def test_bad_password(self):
        with mock.patch.dict(os.environ, {'AEROFOIL_PASSWORD': 'nope'}), self.assertRaisesRegex(af.Error, 'login refused'): self.run_main(TID, '-y')

    def test_build_options_go_to_the_build(self):   # build_ipa_from_nsp.py's options anywhere on the line, with their values; --keys and -h stay this script's
        ours = {'--keys': 1, '-h': 1, '--build': 1}
        self.assertEqual(af.split_build_options(['mario', 'wonder', '--build', '--platform', 'mac-app'], ours), (['mario', 'wonder', '--build'], ['--platform', 'mac-app']))
        self.assertEqual(af.split_build_options(['--build', '--platform', 'mac-app', 'mario', '--no-show-fps', '-o=/x.app', '--keys', 'k'], ours),
                         (['--build', 'mario', '--keys', 'k'], ['--platform', 'mac-app', '--no-show-fps', '-o=/x.app']))
        self.assertEqual(af.split_build_options(['mario', '--bogus'], ours), (['mario', '--bogus'], []))   # neither script's: argparse rejects it
        with redirect_stdout(io.StringIO()), mock.patch('sys.stderr', io.StringIO()), self.assertRaises(SystemExit): af.main(['mario', '--platform', 'mac-app'])   # without --build

    def test_library_outside_repo(self):
        self.assertEqual(af.check_library(Path.home() / 'Games'), (Path.home() / 'Games').resolve())
        with self.assertRaisesRegex(af.Error, 'inside the repository'): af.check_library(REPO / 'x')


if __name__ == '__main__':
    unittest.main()
