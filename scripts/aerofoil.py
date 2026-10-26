#!/usr/bin/env python3
# Search an Aerofoil server (a self-hosted Switch library: github.com/luketanti/aerofoil) and download one game's files into an NSP folder that build_ipa_from_nsp.py takes as it is.
#   python3 scripts/aerofoil.py zelda                 search, pick a number, download the base game, its newest update and every DLC into <library>/<name> [<title ID>]/
#   python3 scripts/aerofoil.py 0100F2C0115B6000      a title ID (or a search with one match) is picked without asking
#   python3 scripts/aerofoil.py zelda --list          only list the matches
#   python3 scripts/aerofoil.py zelda --build         download, then run build_ipa_from_nsp.py on the folder (with the saved prod.keys; options after -- go to it: --build -- --platform mac)
# The first run asks for the server URL, the user and the library folder (or give --server, --user, --library, --keys); they are saved in ~/.config/nxnative/aerofoil.json, the password in the
#   macOS Keychain (service nxnative-aerofoil; AEROFOIL_PASSWORD overrides it). The library folder must be outside this repository.
# Aerofoil's Tinfoil shop index is encrypted for Tinfoil by default, so this logs in as the web UI does (POST /login, then /api/titles, /api/title-details, /api/get_game/<id>?download=1).
#   Downloads go to <file>.part and resume from it; a finished file of the server's size is skipped. Exit code 0 on success, 1 on error, 130 when interrupted.
import argparse, getpass, http.cookiejar, json, os, re, shlex, shutil, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CONFIG = Path(os.environ.get('AEROFOIL_CONFIG') or Path.home() / '.config/nxnative/aerofoil.json')
KEYCHAIN = 'nxnative-aerofoil'
EXT_RANK = {'.nsp': 0, '.nsz': 1, '.xci': 2, '.xcz': 3}   # one file per item when the server has several forms of it


class Error(Exception):
    pass


def size_text(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB': return f'{n:.0f} {unit}' if unit == 'B' else f'{n:.1f} {unit}'
        n /= 1024


def interactive():
    return sys.stdin.isatty()


def ask(prompt, what):
    if not interactive(): raise Error(f'{what} is not set (no terminal to ask on); pass it as an option')
    v = input(prompt).strip()
    if not v: raise Error(f'{what} is required')
    return v


def load_config():
    try: return json.loads(CONFIG.read_text())
    except FileNotFoundError: return {}
    except ValueError as e: raise Error(f'{CONFIG} is not valid JSON: {e}')


def save_config(cfg):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(cfg, indent=2) + '\n')


def keychain_get(user):
    if sys.platform != 'darwin': return None
    r = subprocess.run(['security', 'find-generic-password', '-s', KEYCHAIN, '-a', user, '-w'], capture_output=True, text=True)
    return r.stdout.rstrip('\n') if r.returncode == 0 else None


def keychain_set(user, pw):
    if sys.platform != 'darwin': return False
    return subprocess.run(['security', 'add-generic-password', '-U', '-s', KEYCHAIN, '-a', user, '-w', pw], capture_output=True).returncode == 0


def keychain_delete(user):
    if sys.platform == 'darwin': subprocess.run(['security', 'delete-generic-password', '-s', KEYCHAIN, '-a', user], capture_output=True)


def check_library(p):   # game files stay out of the repository
    p = p.expanduser().resolve()
    if p == REPO or REPO in p.parents: raise Error(f'library folder {p} is inside the repository')
    return p


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


class Client:
    def __init__(self, server, user, password):
        self.base = server.rstrip('/')
        if not re.match(r'https?://', self.base): self.base = 'http://' + self.base
        self.user, self.password = user, password
        self.jar = http.cookiejar.CookieJar()
        cookies = urllib.request.HTTPCookieProcessor(self.jar)
        self.open = urllib.request.build_opener(cookies).open
        self.open_once = urllib.request.build_opener(cookies, NoRedirect).open   # login and API calls: a redirect to /login means not logged in

    def url(self, path, **q):
        return self.base + path + ('?' + urllib.parse.urlencode(q) if q else '')

    def login(self):
        body = urllib.parse.urlencode({'user': self.user, 'password': self.password, 'remember': ''}).encode()
        req = urllib.request.Request(self.url('/login'), data=body, headers={'Content-Type': 'application/x-www-form-urlencoded'})
        try:
            r = self.open_once(req, timeout=30); r.read(); where = r.headers.get('Location', '')
        except urllib.error.HTTPError as e:
            if e.code not in (301, 302, 303, 307, 308): raise Error(f'login failed: HTTP {e.code} from {self.base}/login')
            where = e.headers.get('Location', '')
        except urllib.error.URLError as e:
            raise Error(f'cannot reach {self.base}: {e.reason}')
        if '/login' in urllib.parse.urlparse(where).path:   # Aerofoil sends a failed login (bad user or password, frozen account, locked-out IP) back to the login page
            raise Error(f'login refused for user "{self.user}" (wrong password, frozen account, or this IP is locked out after failed attempts)')

    def api(self, path, **q):
        try:
            r = self.open_once(urllib.request.Request(self.url(path, **q), headers={'Accept': 'application/json'}), timeout=60)
            data = r.read()
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 401): raise Error(f'{path}: not logged in (HTTP {e.code})')
            if e.code == 403: raise Error(f'{path}: user "{self.user}" has no shop access (HTTP 403)')
            raise Error(f'{path}: HTTP {e.code}')
        except urllib.error.URLError as e:
            raise Error(f'cannot reach {self.base}: {e.reason}')
        try: return json.loads(data)
        except ValueError: raise Error(f'{path}: the server did not answer with JSON (is {self.base} an Aerofoil server?)')

    def search(self, query, limit=200):
        games, page = [], 1
        while True:
            d = self.api('/api/titles', search=query, types='BASE', sort='title_asc', page=page, per_page=200)
            got = d.get('games') or []
            games += got
            if not got or len(games) >= min(int(d.get('total') or 0), limit): break
            page += 1
        return games[:limit]

    def details(self, app_id):
        d = self.api('/api/title-details', app_id=app_id, app_type='BASE')
        if not d.get('success') or not d.get('game'): raise Error(f'the server has no details for {app_id}')
        return d['game']

    def download(self, f, dest):
        """f: a file entry of /api/title-details ({id, filename, size, url}). Resumes from dest.part."""
        size = int(f.get('size') or 0)
        if dest.exists() and dest.stat().st_size == size:
            print(f'  have {dest.name} ({size_text(size)})'); return
        part = dest.with_name(dest.name + '.part')
        have = part.stat().st_size if part.exists() else 0
        if size and have > size: part.unlink(); have = 0
        req = urllib.request.Request(self.base + f['url'])
        if have: req.add_header('Range', f'bytes={have}-')
        try:
            r = self.open(req, timeout=60)
        except urllib.error.HTTPError as e:
            if e.code == 416 and size and have == size: r = None
            elif e.code == 403: raise Error(f'{f["filename"]}: download refused (HTTP 403: the user\'s rating limit, or no shop access)')
            else: raise Error(f'{f["filename"]}: HTTP {e.code}')
        except urllib.error.URLError as e:
            raise Error(f'cannot reach {self.base}: {e.reason}')
        if r is not None:
            if have and r.status != 206: have = 0   # the server ignored the range: start again
            total = size or (have + int(r.headers.get('Content-Length') or 0))
            done, t0, last = have, time.time(), 0.0
            with open(part, 'ab' if have else 'wb') as out:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk: break
                    out.write(chunk); done += len(chunk)
                    now = time.time()
                    if now - last >= 0.5 or done == total:
                        last = now; rate = (done - have) / max(now - t0, 1e-6)
                        pct = f'{done * 100 // total:3d}%' if total else ''
                        eta = f' ETA {int((total - done) / rate) // 60}:{int((total - done) / rate) % 60:02d}' if total and rate > 0 else ''
                        print(f'\r  {dest.name[:60]:60} {pct} {size_text(done)}/{size_text(total)} {size_text(rate)}/s{eta}   ', end='', flush=True)
            print()
        got = part.stat().st_size
        if size and got != size: raise Error(f'{f["filename"]}: got {got} bytes, the server lists {size}; run again to resume')
        part.replace(dest)


def pick_file(files):   # the preferred form of one item (NSP over NSZ over XCI)
    files = [f for f in files or [] if f.get('url')]
    return min(files, key=lambda f: EXT_RANK.get(Path(f['filename']).suffix.lower(), 9)) if files else None


def tag_version(name):
    m = re.search(r'\[v(\d+)\]', name)
    return int(m.group(1)) if m else -1


def plan(game, update=True, dlc=True):
    """[(kind, file entry)] to download: the base, the newest update with files, each DLC's newest version."""
    out = []
    base = pick_file(game.get('files'))
    if base is None: raise Error(f'{game.get("name")}: the server has no base game file for it')
    out.append(('base', base))
    if update:
        for v in sorted(game.get('version') or [], key=lambda v: int(v.get('version') or 0), reverse=True):
            f = pick_file(v.get('files'))
            if f: out.append((f'update v{v.get("version")}', f)); break
    if dlc:
        for d in game.get('dlc_list') or []:
            files = [f for f in d.get('files') or [] if f.get('url')]
            if not files: continue
            newest = max(tag_version(f['filename']) for f in files)
            f = pick_file([f for f in files if tag_version(f['filename']) == newest])
            out.append((f'DLC {d.get("app_id", "")}', f))
    return out


def safe_name(s):
    s = re.sub(r'[\x00-\x1f/\\:*?"<>|]+', ' ', s or '').strip(' .')
    return re.sub(r'\s+', ' ', s)[:100] or 'game'


def has_profile(tid):
    return bool(tid) and (REPO / 'dm/games' / tid.upper() / 'game.tsv').exists()


BUILD_EXTRA = 10 << 30   # the NSP script's working space beyond the NSPs: about twice their size plus 10 GB in all (README, Pack an IPA)


def build_need(download):   # disk for the NSPs and a build of them
    return 2 * download + BUILD_EXTRA


def list_size(g):   # what a search row shows: the base and its newest update on the server (search rows carry no DLC sizes)
    upd = [v for v in g.get('version') or [] if v.get('owned') and int(v.get('size') or 0)]
    newest = max(upd, key=lambda v: int(v.get('version') or 0), default=None)
    return int(g.get('size') or 0) + (int(newest['size']) if newest else 0)


def free_space(p):   # free bytes on the volume p is (or will be) on
    p = Path(p)
    while not p.exists() and p != p.parent: p = p.parent
    return shutil.disk_usage(p).free


def game_dir(lib, name, tid):
    return Path(lib) / f'{safe_name(name)} [{tid}]'


def show(games, lib=None):
    free = free_space(lib) if lib else None
    if lib: print(f'Library {lib}: {size_text(free)} free')
    w = len(str(len(games)))
    print(f'{"":>{w}}    {"":60} {"title ID":16}  {"download":>9}  {"to build":>9}')
    tight = False
    for i, g in enumerate(games, 1):
        tid = (g.get('title_id') or g.get('app_id') or '').upper()
        mark = '*' if has_profile(tid) else ' '
        name = g.get('title_id_name') or g.get('name') or tid
        dl = list_size(g); need = build_need(dl)
        here = lib and game_dir(lib, name, tid).is_dir() and any(game_dir(lib, name, tid).glob('*.ns[pz]'))
        flag = ' (downloaded)' if here else ''
        if free is not None and need > free and not here: flag = ' !'; tight = True
        print(f'{i:>{w}}. {mark} {name[:60]:60} {tid}  {size_text(dl):>9}  {size_text(need):>9}{flag}')
    if any(has_profile((g.get('title_id') or '').upper()) for g in games): print('  * has a game profile in this repository')
    print('  download: base game + newest update (DLC is added after you pick); to build: about 2x the download + 10 GB')
    if tight: print('  ! more than the free space on the library drive')


def choose(games, query, pick, lib=None):
    if not games: raise Error(f'nothing on the server matches "{query}"')
    if pick:
        if not 1 <= pick <= len(games): raise Error(f'--pick {pick}: there are {len(games)} matches')
        return games[pick - 1]
    exact = [g for g in games if (g.get('title_id') or '').upper() == query.upper()]
    one = exact[0] if len(exact) == 1 else games[0] if len(games) == 1 else None
    if one:
        print(f'1 match: {one.get("title_id_name") or one.get("name")} [{(one.get("title_id") or "").upper()}]')
        return one
    show(games, lib)
    if not interactive(): raise Error(f'{len(games)} matches; choose one with --pick N')
    while True:
        s = input(f'Pick 1-{len(games)} (empty to quit): ').strip()
        if not s: raise KeyboardInterrupt
        if s.isdigit() and 1 <= int(s) <= len(games): return games[int(s) - 1]


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    passthru = []
    if '--' in argv: i = argv.index('--'); argv, passthru = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(description='Search an Aerofoil server and download one game into an NSP folder for build_ipa_from_nsp.py.')
    ap.add_argument('query', nargs='*', help='words of the game name, or a title ID')
    ap.add_argument('--list', action='store_true', help='only list the matches')
    ap.add_argument('--pick', type=int, help='the match to take (its number in the list), without asking')
    ap.add_argument('-y', '--yes', action='store_true', help='download without asking to confirm')
    ap.add_argument('--no-update', action='store_true', help='leave out the update')
    ap.add_argument('--no-dlc', action='store_true', help='leave out the DLC')
    ap.add_argument('--dest', help='the folder for this game (default <library>/<name> [<title ID>])')
    ap.add_argument('--build', action='store_true', help='run build_ipa_from_nsp.py on the folder afterwards (options after -- go to it)')
    ap.add_argument('--server', help='Aerofoil URL, e.g. http://nas.local:8465 (saved)')
    ap.add_argument('--user', help='Aerofoil user (saved)')
    ap.add_argument('--library', help='folder the game folders go in (saved)')
    ap.add_argument('--keys', help='prod.keys for --build (its path is saved, never its contents)')
    ap.add_argument('--forget-password', action='store_true', help='remove the saved password from the Keychain and ask again')
    a = ap.parse_args(argv)

    cfg = load_config(); changed = False
    for k in ('server', 'user', 'library', 'keys'):
        v = getattr(a, k)
        if v:
            if k in ('library', 'keys'): v = str(Path(v).expanduser().resolve())
            if cfg.get(k) != v: cfg[k] = v; changed = True
    if not cfg.get('server'): cfg['server'] = ask('Aerofoil server URL (e.g. http://nas.local:8465): ', 'the server (--server)'); changed = True
    if not cfg.get('user'): cfg['user'] = ask('Aerofoil user: ', 'the user (--user)'); changed = True
    if changed: save_config(cfg)

    if a.forget_password: keychain_delete(cfg['user'])
    pw = os.environ.get('AEROFOIL_PASSWORD') or keychain_get(cfg['user'])
    from_prompt = not pw
    if from_prompt:
        if not interactive(): raise Error('no password: set AEROFOIL_PASSWORD, or run once in a terminal to save it in the Keychain')
        pw = getpass.getpass(f'Password for {cfg["user"]} on {cfg["server"]}: ')
    c = Client(cfg['server'], cfg['user'], pw)
    print(f'Logging in to {c.base} as {cfg["user"]}...', flush=True)
    c.login()
    if from_prompt and keychain_set(cfg['user'], pw): print(f'Saved the password in the Keychain ({KEYCHAIN}).')

    query = ' '.join(a.query).strip()
    if not query:
        if a.list or not interactive(): raise Error('give a search: words of the game name, or a title ID')
        query = ask('Search: ', 'a search')
    print(f'Searching for "{query}"...', flush=True)
    games = c.search(query)
    if len(games) > 1: print(f'{len(games)} matches')
    if a.list:
        if not games: raise Error(f'nothing on the server matches "{query}"')
        show(games, cfg.get('library')); return 0
    g = choose(games, query, a.pick, cfg.get('library'))
    tid = (g.get('title_id') or g.get('app_id') or '').upper()
    print('Getting its files...', flush=True)
    game = c.details(g.get('app_id') or tid)
    name = game.get('title_id_name') or game.get('name') or tid
    items = plan(game, update=not a.no_update, dlc=not a.no_dlc)

    if a.dest: dest = check_library(Path(a.dest))
    else:
        if not cfg.get('library'):
            cfg['library'] = str(Path(ask('Library folder for game folders: ', 'the library (--library)')).expanduser().resolve())
        lib = check_library(Path(cfg['library'])); cfg['library'] = str(lib); save_config(cfg)
        dest = game_dir(lib, name, tid)
    total = sum(int(f.get('size') or 0) for _, f in items)
    print(f'{name} [{tid}]: {len(items)} file(s), {size_text(total)} -> {dest}')
    for kind, f in items: print(f'  {kind:24} {f["filename"]}  {size_text(int(f.get("size") or 0))}')
    need = sum(int(f.get('size') or 0) for _, f in items if not ((dest / safe_file(f)).exists() and (dest / safe_file(f)).stat().st_size == int(f.get('size') or 0)))
    free = free_space(dest)
    print(f'  to download {size_text(need)}, to build about {size_text(build_need(total) - (total - need))}, free {size_text(free)}')
    if need > free: raise Error(f'{size_text(need)} to download, {size_text(free)} free on {dest}')
    if build_need(total) - (total - need) > free: print('  warning: enough space to download, likely not enough to build')
    if not a.yes and need:   # nothing to download: no question (a --build of files already here)
        if not interactive(): raise Error('not downloading without confirmation; pass -y')
        if input('Download? [Y/n] ').strip().lower() not in ('', 'y', 'yes'): print('Cancelled.'); return 0
    dest.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    for k, (kind, f) in enumerate(items, 1):
        print(f'[{k}/{len(items)}] {kind}', flush=True)
        c.download(f, dest / safe_file(f))
    secs = int(time.time() - t0)
    print(f'Done: {len(items)} file(s) in {dest} ({secs // 60}:{secs % 60:02d})')

    cmd = [sys.executable, str(REPO / 'scripts/build_ipa_from_nsp.py'), str(dest)]
    keys = cfg.get('keys')
    if a.build:
        if not keys:
            keys = str(Path(ask('prod.keys path: ', 'prod.keys (--keys)')).expanduser().resolve()); cfg['keys'] = keys; save_config(cfg)
        if not Path(keys).is_file(): raise Error(f'prod.keys not found: {keys}')
        cmd += ['-k', keys, *passthru]
        print('Building:', ' '.join(map(shlex.quote, cmd)), flush=True)
        return subprocess.call(cmd)
    print('Build it with:', ' '.join(map(shlex.quote, cmd + ['-k', keys or '<prod.keys>'])))
    return 0


def safe_file(f):
    return safe_name(Path(f['filename']).stem) + Path(f['filename']).suffix.lower()


if __name__ == '__main__':
    try: sys.exit(main())
    except Error as e: print(f'error: {e}', file=sys.stderr); sys.exit(1)
    except KeyboardInterrupt: print(file=sys.stderr); sys.exit(130)
