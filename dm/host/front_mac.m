// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard and controllers → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// The window is fullscreen-capable (the green button and ⌃⌘F); DM_FULLSCREEN starts it that way. ⌘Q quits; the left mouse button is the touchscreen.
// Key map (Nintendo layout, changed in Settings, ⌘,): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−,
// Space=shake the controller; the right stick has no keys until some are given.
// Controllers: buttons by position as on the iPhone (right A, bottom B, top X, left Y; Settings or the Controllers menu switches to by label), shoulders L R, triggers ZL ZR, Menu + Options −,
// both sticks and their presses.
// Each controller is a player of its own (local co-op): the first one connected is player 1, together with the keyboard, the next player 2, and so on up to 8 (pad_slots.h); the Controllers
// menu moves a controller or the keyboard to another player. DM_PAD_MERGE=1 merges every controller into player 1 instead, DM_KBD_PLAYER=own makes the keyboard player 1 on its own, with the
// controllers from player 2 on.
// Menus: File (the save folder, save backups, the log, screenshots), Game (pause, console mode), Audio (mute), View (fullscreen, window size, Apple's performance HUD), Controllers.
// In a Mac app (dm/mac/pack_app.py, which packs dm/launcher.json) the Settings window also shows the game's player settings, the iOS launcher's (dm/games/settings.tsv), and the host
// starts with the choices saved there (settings_env).
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "pad_slots.h"
#include "haptics_apple.h"
#include <signal.h>
#include <math.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/stat.h>

static CAMetalLayer *g_layer;
static int g_input_on = 1;   // main thread: the game window is key, so its keyboard, mouse and controllers reach the game (input_release / input_resume)

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
// The screen's refresh rate matched to the game's frame rate in fullscreen (front_screen_match, from PR #79; DM_SCREEN_MATCH=0 turns it off). 60 fps on a 144 Hz screen cannot be paced
// evenly: the display link counts a tick on the refresh nearest each 1/60 s slot (nvn_mtl.m link_range), so frames stay up 2 and 3 refreshes in turn (13.9 / 20.8 ms) and Apple's HUD shows
// the frame interval jumping between them. In fullscreen, a screen whose rate is not a multiple of the game's switches to the mode of the same size with the highest rate that is (144 → 120 Hz
// for 60 and 30 fps), for this app only: macOS switches it back when the host quits, crashes included, and leaving fullscreen or that screen switches it back at once. A window keeps the
// screen's rate, because the switch changes the whole screen for every app and most external screens go black for a second or more. A screen with no such mode keeps the virtual ticks
static NSWindow *g_win; static _Atomic int g_match_want;   // the game's window; the frame rate to match (0 = not known yet), written by the present thread only
static CGDirectDisplayID g_match_id; static CGDisplayModeRef g_match_orig;   // main thread: the screen this host switched and its own mode (NULL = none switched)
static double mode_hz(CGDisplayModeRef m) { double hz = CGDisplayModeGetRefreshRate(m); return hz > 0 ? hz : 0; }   // 0 = not known (older built-in screens report none)
static int hz_multiple(double hz, int fps) { double k = round(hz / fps); return k >= 1 && fabs(hz / fps - k) < 0.01; }   // 59.94 Hz counts as 60
static CGError screen_set_mode(CGDirectDisplayID id, CGDisplayModeRef m) {   // for this app only (kCGConfigureForAppOnly)
    CGDisplayConfigRef cfg; CGError r = CGBeginDisplayConfiguration(&cfg);
    if (r != kCGErrorSuccess) return r;
    r = CGConfigureDisplayWithDisplayMode(cfg, id, m, NULL);
    if (r != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return r; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}
static void screen_match_restore(int on_it) {   // main thread: the screen this host switched gets its own mode again; on_it: the window is on that screen
    double hz = mode_hz(g_match_orig); CGError r = screen_set_mode(g_match_id, g_match_orig);
    LOG("front end: screen %s %.0f Hz", r == kCGErrorSuccess ? "back at" : "could not be switched back to", hz);
    if (r == kCGErrorSuccess && on_it && hz > 0) g_screen_fps = (int)round(hz);
    CGDisplayModeRelease(g_match_orig); g_match_orig = NULL;
}
static void screen_match_apply(void) {   // main thread: on a new frame rate, on entering and leaving fullscreen and on a move to another screen
    static int off = -1; if (off < 0) { const char *e = getenv("DM_SCREEN_MATCH"); off = e && !strcmp(e, "0"); if (off) LOG("front end: the screen keeps its refresh rate in fullscreen too (DM_SCREEN_MATCH=0)"); }
    NSScreen *scr = g_win.screen; int want = g_match_want, full = (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    CGDirectDisplayID id = scr ? [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
    if (g_match_orig && (!full || id != g_match_id)) screen_match_restore(id == g_match_id);
    if (off || !full || want <= 0 || !scr) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(id);
    if (!cur) return;
    double hz = mode_hz(cur);
    if (hz <= 0 || hz_multiple(hz, want)) {   // already a multiple, or not known
        if (g_match_orig && hz > 0) g_screen_fps = (int)round(hz);   // the screen this host switched: its rate from the mode, which maximumFramesPerSecond (the screen observer) may not show yet
        CGDisplayModeRelease(cur); return;
    }
    size_t w = CGDisplayModeGetWidth(cur), h = CGDisplayModeGetHeight(cur), pw = CGDisplayModeGetPixelWidth(cur), ph = CGDisplayModeGetPixelHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    CGDisplayModeRef pick = NULL; double pick_hz = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i); double r = mode_hz(m);
        if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h || CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        if (hz_multiple(r, want) && r > pick_hz) { pick = m; pick_hz = r; }
    }
    if (!pick) LOG("front end: screen at %.0f Hz has no mode of this size at a multiple of %d Hz: frames are paced on the nearest refreshes", hz, want);
    else {
        CGError r = screen_set_mode(id, pick);
        LOG("front end: screen at %.0f Hz %s %.0f Hz for %d fps in fullscreen (DM_SCREEN_MATCH=0 keeps it)", hz, r == kCGErrorSuccess ? "switched to" : "could not be switched to", pick_hz, want);
        if (r == kCGErrorSuccess) { if (!g_match_orig) { g_match_orig = CGDisplayModeRetain(cur); g_match_id = id; } g_screen_fps = (int)round(pick_hz); }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(cur);
}
void front_screen_match(int fps) {
    if (!g_layer || g_match_want == fps) return;   // no window (a windowless run's main thread runs the guest), or the rate as before
    g_match_want = fps; dispatch_async(dispatch_get_main_queue(), ^{ screen_match_apply(); });
}

// Settings. The player's choices persist in NSUserDefaults: the game's own (launcher.json's rows) as launcher.<VAR>, the iOS launcher's keys (Launcher.swift), under org.nxnative.mac.<title ID>;
// the keyboard map and the controller options, shared by every game, under org.nxnative.mac
static NSUserDefaults *game_defaults(void) {
    static NSUserDefaults *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:@"org.nxnative.mac." DM_GAME_ID]; });
    return d;
}
static NSUserDefaults *input_defaults(void) {
    static NSUserDefaults *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:@"org.nxnative.mac"]; });
    return d;
}
static NSArray<NSDictionary *> *g_settings;   // launcher.json's rows (env, kind, label, note, default, options or min / max / step); nil outside a Mac app
static NSSet<NSString *> *g_locked;           // the variables an env file set (DM_ENV_FILE_KEYS, dm/mac/launcher.c): shown, not changed
static NSString *setting_valid(NSDictionary *s, NSString *v) {   // v when the row takes it, else nil (a saved choice the game no longer offers)
    if (![v isKindOfClass:NSString.class] || !v.length) return nil;
    NSString *kind = s[@"kind"];
    if ([kind isEqual:@"choice"]) { for (NSArray *o in s[@"options"]) if ([o[0] isEqual:v]) return v; return nil; }
    if ([kind isEqual:@"toggle"]) return [v isEqual:@"0"] || [v isEqual:@"1"] ? v : nil;
    if ([kind isEqual:@"range"]) { double x = v.doubleValue; return x >= [s[@"min"] doubleValue] - 1e-6 && x <= [s[@"max"] doubleValue] + 1e-6 ? v : nil; }
    return nil;
}
static NSString *setting_value(NSDictionary *s) {   // the value in force: the environment's (an env file's or a saved choice), else the row's default
    const char *e = getenv([s[@"env"] UTF8String]);
    return setting_valid(s, e ? @(e) : nil) ?: s[@"default"];
}
// Before main: the saved choices go into the environment, where the host reads them when it starts (hle_oe.c DM_OPMODE, loader.c DM_FPS_TARGET / DM_RENDER_SCALE, ...). Only in a Mac app,
// whose Resources/dm holds launcher.json beside the rewritten modules; a host run from a build folder keeps its environment as it is
static void settings_env(void) {
    char exe[PATH_MAX], real[PATH_MAX]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) || !realpath(exe, real)) return;
    NSString *path = [@(real).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Resources/dm/launcher.json"];   // Contents/MacOS/dmhost → Contents
    NSData *data = [NSData dataWithContentsOfFile:path]; if (!data) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class] || ![j[@"settings"] isKindOfClass:NSArray.class]) { fprintf(stderr, "[RED] front end: %s cannot be read; the game's settings are not shown\n", path.UTF8String); return; }
    g_settings = j[@"settings"];
    const char *fk = getenv("DM_ENV_FILE_KEYS");
    g_locked = [NSSet setWithArray:fk && *fk ? [@(fk) componentsSeparatedByString:@" "] : @[]];
    for (NSDictionary *s in g_settings) {
        NSString *env = s[@"env"];
        if ([g_locked containsObject:env]) { fprintf(stderr, "front end: %s kept at %s (env file)\n", env.UTF8String, getenv(env.UTF8String) ?: "?"); continue; }
        NSString *v = setting_valid(s, [game_defaults() stringForKey:[@"launcher." stringByAppendingString:env]]);
        if (v) { setenv(env.UTF8String, v.UTF8String, 1); fprintf(stderr, "front end: %s=%s (saved setting)\n", env.UTF8String, v.UTF8String); }
    }
}
// Metal reads MTL_HUD_ENABLED when the process makes its first device, which can be before the window: set from DM_METAL_HUD before main (set in front_run, the HUD did not show)
__attribute__((constructor)) static void front_env(void) {
    @autoreleasepool { settings_env(); }
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) setenv("MTL_HUD_ENABLED", "1", 0);
}

// Keyboard: each action has one key, a macOS virtual key code (KEY_NONE: none), saved by the action's name (input.key.<name>), so an action added later leaves the others' keys alone.
// A key may serve one action only: giving it to another takes it from the first
enum { KEY_NONE = 0xffff };
typedef struct { const char *name; uint64_t bit; int axis; unsigned short key; } key_action;   // axis 1..8: left stick up, down, left, right, right stick up, down, left, right; 0: a button
static const key_action g_actions[] = {
    {"Left stick up", 0, 1, 13}, {"Left stick down", 0, 2, 1}, {"Left stick left", 0, 3, 0}, {"Left stick right", 0, 4, 2},
    {"Right stick up", 0, 5, KEY_NONE}, {"Right stick down", 0, 6, KEY_NONE}, {"Right stick left", 0, 7, KEY_NONE}, {"Right stick right", 0, 8, KEY_NONE},
    {"A", DM_BTN_A, 0, 38}, {"B", DM_BTN_B, 0, 40}, {"X", DM_BTN_X, 0, 32}, {"Y", DM_BTN_Y, 0, 34},
    {"L", DM_BTN_L, 0, 12}, {"R", DM_BTN_R, 0, 14}, {"ZL", DM_BTN_ZL, 0, 6}, {"ZR", DM_BTN_ZR, 0, 8},
    {"Left stick press", DM_BTN_LS, 0, 3}, {"Right stick press", DM_BTN_RS, 0, 5},
    {"Plus (+)", DM_BTN_PLUS, 0, 36}, {"Minus (-)", DM_BTN_MINUS, 0, 48},
    {"D-pad up", DM_BTN_UP, 0, 126}, {"D-pad down", DM_BTN_DOWN, 0, 125}, {"D-pad left", DM_BTN_LEFT, 0, 123}, {"D-pad right", DM_BTN_RIGHT, 0, 124},
    {"Shake", DM_BTN_SHAKE, 0, 49},
};
enum { NACT = sizeof g_actions / sizeof g_actions[0] };
static unsigned short g_key[NACT];   // main thread: the key of each action
static char g_down[NACT];            // main thread: the action's key is held
static NSString *key_default(int i) { return [@"input.key." stringByAppendingString:@(g_actions[i].name)]; }
static void keymap_load(void) {
    for (int i = 0; i < NACT; i++) { id v = [input_defaults() objectForKey:key_default(i)]; g_key[i] = [v isKindOfClass:NSNumber.class] ? [v unsignedShortValue] : g_actions[i].key; }
}
static void keymap_save(void) { for (int i = 0; i < NACT; i++) [input_defaults() setInteger:g_key[i] forKey:key_default(i)]; }
static NSString *key_name(unsigned short k) {
    static const char *names[128] = {
        [0] = "A", [1] = "S", [2] = "D", [3] = "F", [4] = "H", [5] = "G", [6] = "Z", [7] = "X", [8] = "C", [9] = "V", [11] = "B", [12] = "Q", [13] = "W", [14] = "E", [15] = "R",
        [16] = "Y", [17] = "T", [18] = "1", [19] = "2", [20] = "3", [21] = "4", [22] = "6", [23] = "5", [24] = "=", [25] = "9", [26] = "7", [27] = "-", [28] = "8", [29] = "0", [30] = "]",
        [31] = "O", [32] = "U", [33] = "[", [34] = "I", [35] = "P", [36] = "Return", [37] = "L", [38] = "J", [39] = "'", [40] = "K", [41] = ";", [42] = "\\", [43] = ",", [44] = "/",
        [45] = "N", [46] = "M", [47] = ".", [48] = "Tab", [49] = "Space", [50] = "`", [51] = "Delete", [53] = "Escape", [65] = "Keypad .", [67] = "Keypad *", [69] = "Keypad +",
        [75] = "Keypad /", [76] = "Keypad Enter", [78] = "Keypad -", [82] = "Keypad 0", [83] = "Keypad 1", [84] = "Keypad 2", [85] = "Keypad 3", [86] = "Keypad 4", [87] = "Keypad 5",
        [88] = "Keypad 6", [89] = "Keypad 7", [91] = "Keypad 8", [92] = "Keypad 9", [96] = "F5", [97] = "F6", [98] = "F7", [99] = "F3", [100] = "F8", [101] = "F9", [103] = "F11",
        [109] = "F10", [111] = "F12", [114] = "Help", [115] = "Home", [116] = "Page Up", [117] = "Forward Delete", [118] = "F4", [119] = "End", [120] = "F2", [121] = "Page Down",
        [122] = "F1", [123] = "Left Arrow", [124] = "Right Arrow", [125] = "Down Arrow", [126] = "Up Arrow",
    };
    if (k == KEY_NONE) return @"None";
    return k < 128 && names[k] ? @(names[k]) : [NSString stringWithFormat:@"Key %u", k];
}

// Physical controllers (GameController) go to dm_pad_set_player, mapped as the iPhone's (DmGamepad.m read_pad, same layout); player 1's is ORed with the keyboard, a stick takes
// whichever is deflected more (hle_hid.c). DM_KEYS uses player 1's path, so player 1's controller touched during a script takes it over.
// Players: every controller with an extended gamepad profile holds a slot (pad_slots.h: player 1 first, a reconnected controller gets its player back), and hle_hid.c reports
// player n on its own npad while the slot is held (dm_pad_players). A one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c).
// The Controllers menu moves a controller or the keyboard to another player (pad_slot_put); a controller taken off its player there is benched until it reconnects.
// With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins; when the last one goes away its buttons and sticks are released)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static NSMutableSet<GCController *> *g_benched;   // controllers taken off their player by hand: given none again until they reconnect
static int g_merge, g_kbd_own;
static int g_kbd_slot = -1;   // the player the keyboard holds on its own (DM_KBD_PLAYER=own: player 1; another by hand); -1: it plays with player 1, beside player 1's controller
static const char g_kbd_owner = 0;   // the keyboard's owner in the slot table
static int g_by_label;        // buttons by label (A bottom, B right, X left, Y top, as an Xbox controller prints them) instead of by position
static float g_deadzone;      // the sticks' dead zone, a fraction of full tilt (0: none, as before)

static void kbd_send(uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {   // player 1's own path when the keyboard plays player 1, shared or on its own
    if (g_kbd_slot > 0) dm_pad_set_player(g_kbd_slot, b, lx, ly, rx, ry); else dm_input_set(b, lx, ly, rx, ry);
}
static void push(void) {
    uint64_t b = 0; int ax[9] = {0};
    for (int i = 0; i < NACT; i++) if (g_down[i]) { b |= g_actions[i].bit; ax[g_actions[i].axis] = 1; }
    kbd_send(b, (ax[4] - ax[3]) * 32767, (ax[1] - ax[2]) * 32767, (ax[8] - ax[7]) * 32767, (ax[5] - ax[6]) * 32767);
}
static void keys_release(void) { memset(g_down, 0, sizeof g_down); push(); }
static void on_key(NSEvent *e, int down) {
    if (!g_input_on) return;
    for (int i = 0; i < NACT; i++) if (g_key[i] == e.keyCode) g_down[i] = (char)down;
    push();
}

static int32_t pad_axis(float v) {
    float a = fabsf(v); if (a <= g_deadzone) return 0;
    return (int32_t)(copysignf(fminf(1.f, (a - g_deadzone) / (1.f - g_deadzone)), v) * DM_STICK_MAX);
}
static void pad_read(GCExtendedGamepad *g) {
    if (!g_input_on) return;
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= bit
    if (g_by_label) { K(g.buttonA, DM_BTN_A); K(g.buttonB, DM_BTN_B); K(g.buttonX, DM_BTN_X); K(g.buttonY, DM_BTN_Y); }
    else { K(g.buttonB, DM_BTN_A); K(g.buttonA, DM_BTN_B); K(g.buttonY, DM_BTN_X); K(g.buttonX, DM_BTN_Y); }   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); K(g.buttonOptions, DM_BTN_MINUS); K(g.leftThumbstickButton, DM_BTN_LS); K(g.rightThumbstickButton, DM_BTN_RS);   // nil on pads without them: not pressed
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    dm_pad_set_player(p, m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value), pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
}
static void pads_reread(void) {   // every controller read as it is now (after a layout or dead zone change, or a change of players)
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) pad_read(c.extendedGamepad); }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p].extendedGamepad) pad_read(g_held[p].extendedGamepad);
}
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pad_listen(GCController *c) { c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); }; }
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil on a connect)
static void pads_changed(GCController *gone) {
    if (g_merge) {
        int any = 0;
        for (GCController *c in GCController.controllers) if (c.extendedGamepad && c != gone) { any = 1; pad_listen(c); pad_read(c.extendedGamepad); }
        if (!any) { dm_pad_set(0, 0, 0, 0, 0); dm_haptics_apple_controller(0, nil); }
        return;
    }
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (GCController *c in g_benched.allObjects) if (c == gone || ![now containsObject:c]) [g_benched removeObject:c];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && ![g_benched containsObject:c] && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_listen(c);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)", pad_name(c), p + 1, nb);
        pad_read(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
}
// After a change by hand: g_held and the keyboard's player from the slot table. A player that changes hands starts with nothing pressed, and so does the keyboard's old route
static GCController *controller_of(const void *owner) {
    for (GCController *c in GCController.controllers) if ((__bridge const void *)c == owner) return c;
    return nil;
}
static void slots_sync(void) {
    int kbd = -1;
    for (int p = 0; p < DM_PLAYERS; p++) {
        const void *o = g_slots.owner[p];
        if (o == &g_kbd_owner) kbd = p;
        GCController *c = o && o != &g_kbd_owner ? controller_of(o) : nil;
        if (c == g_held[p]) continue;
        g_held[p] = c; dm_pad_set_player(p, 0, 0, 0, 0, 0); dm_haptics_apple_controller(p, c);
    }
    if (kbd != g_kbd_slot) { kbd_send(0, 0, 0, 0, 0); if (g_kbd_slot > 0) dm_pad_set_player(g_kbd_slot, 0, 0, 0, 0, 0); g_kbd_slot = kbd; }
    dm_pad_players(pad_slot_mask(&g_slots));
    pads_reread(); push();
}
static void bench(const void *owner) {   // a controller left without a player by a change by hand
    GCController *c = owner && owner != &g_kbd_owner ? controller_of(owner) : nil;
    if (c) { [g_benched addObject:c]; LOG("controller '%s' has no player now (Controllers menu)", pad_name(c)); }
}
static void pick_controller(GCController *c, int p) {
    if (!c.extendedGamepad || p < 0 || p >= DM_PLAYERS) return;
    [g_benched removeObject:c]; pad_listen(c);
    bench(pad_slot_put(&g_slots, (__bridge const void *)c, p, pad_name(c)));
    slots_sync(); LOG("controller '%s' is player %d (Controllers menu)", pad_name(c), p + 1);
}
static void pick_keyboard(int p) {   // player 1: the keyboard plays with player 1, beside its controller; another: the keyboard holds that player
    if (p <= 0) pad_slot_free(&g_slots, &g_kbd_owner);
    else bench(pad_slot_put(&g_slots, &g_kbd_owner, p, "keyboard"));
    slots_sync(); LOG("the keyboard is player %d%s (Controllers menu)", p <= 0 ? 1 : p + 1, p <= 0 ? ", with player 1's controller" : "");
}
static void pick_none(int p) {   // player p loses its controller (benched) or the keyboard (back to player 1)
    const void *o = g_slots.owner[p]; if (!o) return;
    pad_slot_free(&g_slots, o); bench(o);
    slots_sync();
}
// Focus: a window that is no longer key sees no key-up, mouse-up or controller release, so whatever is held when it loses focus (another app, the text box, minimized) would
// stay pressed in the game. The front end releases only what it pressed itself: player 1's pad and the touch are also DM_KEYS / DM_CTL's (hle_hid.c), and a scripted hold goes on.
// Out of focus a controller's changes are ignored, so back in focus each controller is read as it is now (a button still held, a stick still deflected)
static int g_mouse_down;   // the mouse holds the touch (DmGameView)
static void input_release(void) {
    g_input_on = 0;
    keys_release();
    if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); }
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) { dm_pad_set(0, 0, 0, 0, 0); break; } }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
static void input_resume(void) { g_input_on = 1; pads_reread(); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_KBD_PLAYER"); g_kbd_own = !g_merge && e && !strcmp(e, "own");
    g_benched = [NSMutableSet new];
    g_by_label = [input_defaults() boolForKey:@"input.pad.by_label"];
    g_deadzone = fminf(fmaxf([input_defaults() floatForKey:@"input.pad.deadzone"], 0.f), 0.3f);
    if (g_kbd_own) { pad_slot_take(&g_slots, &g_kbd_owner, "keyboard"); g_kbd_slot = 0; }   // holds player 1 for good
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : g_kbd_own ? "the keyboard is player 1, each controller a player of its own from player 2 on (DM_KBD_PLAYER=own)"
                                                                           : "each controller is a player of its own, the keyboard plays with player 1");
    if (g_by_label || g_deadzone > 0) LOG("front end: controller buttons %s, stick dead zone %.0f%% (Settings)", g_by_label ? "by label" : "by position", g_deadzone * 100);
    pads_changed(nil);
}

// Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized or paused (Game menu) → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1).
// Muted (Audio menu), and out of focus with Mute in Background, the audio is paused too. Main thread
static int g_key_win = 1, g_mini, g_paused, g_muted, g_mute_bg;
static int g_gfx_off, g_audio_off;   // what this front end has suspended
static void lifecycle_apply(void) {
    int bg = g_mini || g_paused, f = bg ? 3 : g_key_win ? 1 : 2;
    int aoff = bg || g_muted || (g_mute_bg && !g_key_win);
    if (bg) dm_focus_set(f);   // going to the background: the game hears it first, then its sound and graphics stop
    if (aoff && !g_audio_off) { g_audio_off = 1; dm_audio_suspend(1); }
    if (bg != g_gfx_off) { g_gfx_off = bg; dm_gfx_suspend(bg); }
    if (!aoff && g_audio_off) { g_audio_off = 0; dm_audio_suspend(0); }
    dm_focus_set(f);
}

// Mouse as a single-point touchscreen (front.h dm_touch_set): left button down / drag = finger 0, release = lifted. The content view takes the clicks,
// not a window-wide event monitor, so clicks on the title bar, the window buttons and the resize edges still reach AppKit.
@interface DmGameView : NSView @end
@implementation DmGameView
- (void)mouseDown:(NSEvent *)e { [self mouseDragged:e]; }
- (void)mouseDragged:(NSEvent *)e {
    if (!g_input_on) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize b = self.bounds.size;
    double w = b.width, h = b.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;   // the centered 16:9 picture the present fits into the view, as on the iPhone (DmGamepad.m)
    double x0 = (b.width - w) / 2, y0 = (b.height - h) / 2;
    dm_touch t = {0, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax(1 - (p.y - y0) / h, 0), 0.999)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
    dm_touch_set(&t, 1); g_mouse_down = 1;
}
- (void)mouseUp:(NSEvent *)e { (void)e; if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); } }
// The drawable follows the view in pixels: a layer assigned to a layer-backed view kept the drawable at the first window's 1280x720 in fullscreen too, so the game picture was
// scaled down to it and up again by the compositor
- (void)fitDrawable {
    CAMetalLayer *l = (CAMetalLayer *)self.layer; if (![l isKindOfClass:CAMetalLayer.class] || !self.window) return;
    l.contentsScale = self.window.backingScaleFactor;
    NSSize px = [self convertSizeToBacking:self.bounds.size]; if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(l.drawableSize, px)) return;
    l.drawableSize = px; LOG("front end: drawable %.0fx%.0f", px.width, px.height);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self fitDrawable]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fitDrawable]; }
@end

// Files the menus reach. The save is DM_SAVE (a Mac app: ~/Library/Application Support/nxnative/<title ID>/save, dm/mac/launcher.c), with the device save beside it when the game has one
// (<save>_device, hle_fs.c); a backup is a zip of both committed folders (a commit in progress is the .work / .new beside them, which the next mount discards). The log is wherever stderr
// goes (a Mac app: ~/Library/Logs/nxnative/<title ID>.log); screenshots go to ~/Pictures/nxnative/<game name>/
static NSString *save_dir(void) { const char *s = getenv("DM_SAVE"); return s && *s ? [@(s) stringByStandardizingPath] : nil; }
static NSArray<NSString *> *save_parts(NSString *save) { return @[save.lastPathComponent, [save.lastPathComponent stringByAppendingString:@"_device"]]; }
static NSString *log_path(void) {
    struct stat st; char p[MAXPATHLEN];
    if (fstat(STDERR_FILENO, &st) || !S_ISREG(st.st_mode) || fcntl(STDERR_FILENO, F_GETPATH, p) < 0) return nil;
    return @(p);
}
static NSString *game_file_name(void) {   // the game name with what Finder shows otherwise (':' and '/') as ' - ', as the NSP script names the app (mac_app_name)
    NSString *name = @DM_GAME_NAME;
    NSString *n = [[NSRegularExpression regularExpressionWithPattern:@"\\s*[:/]\\s*" options:0 error:nil] stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@" - "];
    return n.length ? n : @"nxnative";
}
static NSString *stamp(void) { NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss"; return [f stringFromDate:NSDate.date]; }
static int run_tool(NSString *tool, NSArray<NSString *> *args, NSString *cwd) {   // the exit status, -1 when it could not start
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:tool]; t.arguments = args;
    if (cwd) t.currentDirectoryURL = [NSURL fileURLWithPath:cwd isDirectory:YES];
    if (![t launchAndReturnError:nil]) return -1;
    [t waitUntilExit]; return t.terminationStatus;
}
static void alert(NSString *title, NSString *text) { NSAlert *a = [NSAlert new]; a.messageText = title; a.informativeText = text ?: @""; [a runModal]; }

// Apple's performance HUD over the game (frame rate, frame and GPU time, memory): DM_METAL_HUD at start, the View menu or Settings later
static int hud_on(void) { return [g_layer.developerHUDProperties[@"mode"] isEqual:@"default"]; }
static void hud_set(int on) { g_layer.developerHUDProperties = on ? @{@"mode": @"default"} : @{}; LOG("front end: Metal performance HUD %s", on ? "on" : "off"); }

static NSInteger g_rebind = -1;   // main thread: the key map row waiting for its new key (Settings), -1: none

@interface DmApp : NSObject <NSMenuDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (strong) NSWindow *settings;
@property (strong) NSTableView *keys;
@property (strong) NSMutableDictionary<NSString *, NSControl *> *controls;   // Settings: the control of each game setting, by variable
@property (strong) NSMutableDictionary<NSString *, NSTextField *> *percent;   // and the percentage beside each range
@property (strong) NSPopUpButton *layout;
@end
static DmApp *g_app;

@implementation DmApp
- (void)about:(id)sender { (void)sender; [NSApp orderFrontStandardAboutPanelWithOptions:@{NSAboutPanelOptionApplicationName: @DM_GAME_NAME}]; }

// File menu
- (void)screenshot:(id)sender {
    (void)sender;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSPicturesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:[@"nxnative" stringByAppendingPathComponent:game_file_name()]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %@.png", game_file_name(), stamp()]];
    dm_gfx_shot_at(1, path.fileSystemRepresentation);   // the next frame presented (nvn_mtl.m)
    LOG("front end: screenshot of the next frame → %s", path.fileSystemRepresentation);
}
- (void)showScreenshots:(id)sender {
    (void)sender;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSPicturesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:[@"nxnative" stringByAppendingPathComponent:game_file_name()]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
}
- (void)showSave:(id)sender {
    (void)sender; NSString *s = save_dir(); if (!s) return;
    if ([NSFileManager.defaultManager fileExistsAtPath:s]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:s]]];
    else [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:s.stringByDeletingLastPathComponent isDirectory:YES]];
}
- (void)exportSave:(id)sender {
    (void)sender; NSString *s = save_dir(); if (!s) return;
    NSString *parent = s.stringByDeletingLastPathComponent; NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in save_parts(s)) if ([NSFileManager.defaultManager fileExistsAtPath:[parent stringByAppendingPathComponent:p]]) [parts addObject:p];
    if (!parts.count) { alert(@"There is no save yet", @"The game has not saved anything."); return; }
    NSSavePanel *pn = [NSSavePanel savePanel];
    pn.nameFieldStringValue = [NSString stringWithFormat:@"%@ save %@.zip", game_file_name(), stamp()];
    pn.allowedContentTypes = @[UTTypeZIP];
    if ([pn runModal] != NSModalResponseOK || !pn.URL) return;
    [NSFileManager.defaultManager removeItemAtURL:pn.URL error:nil];   // zip adds to an existing archive
    int rc = run_tool(@"/usr/bin/zip", [@[@"-r", @"-q", @"-y", pn.URL.path] arrayByAddingObjectsFromArray:parts], parent);
    LOG("front end: save backup %s → %s%s", s.fileSystemRepresentation, pn.URL.fileSystemRepresentation, rc ? " FAILED" : "");
    if (rc) alert(@"The save could not be exported", [NSString stringWithFormat:@"zip stopped with status %d.", rc]);
}
- (void)restoreSave:(id)sender {
    (void)sender; NSString *s = save_dir(); if (!s) return;
    NSOpenPanel *pn = [NSOpenPanel openPanel]; pn.allowedContentTypes = @[UTTypeZIP]; pn.message = @"Choose a save backup (a .zip from File > Export Save Backup)";
    if ([pn runModal] != NSModalResponseOK || !pn.URL) return;
    NSAlert *a = [NSAlert new]; a.messageText = @"Restore this save?";
    a.informativeText = @"The game quits to restore it; open it again to play from the restored save. The current save is kept in a folder beside it.";
    [a addButtonWithTitle:@"Restore and Quit"]; [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSFileManager *fm = NSFileManager.defaultManager; NSString *parent = s.stringByDeletingLastPathComponent;
    NSString *tmp = [parent stringByAppendingPathComponent:@".restore"]; [fm removeItemAtPath:tmp error:nil];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    if (run_tool(@"/usr/bin/ditto", @[@"-x", @"-k", pn.URL.path, tmp], nil)) { [fm removeItemAtPath:tmp error:nil]; alert(@"The backup could not be read", pn.URL.path); return; }
    // A backup holds save/ (and save_device/) at its top, as Export writes it; one with neither is taken as the contents of save/ itself
    NSMutableDictionary<NSString *, NSString *> *from = [NSMutableDictionary dictionary]; BOOL dir;
    for (NSString *p in save_parts(s)) if ([fm fileExistsAtPath:[tmp stringByAppendingPathComponent:p] isDirectory:&dir] && dir) from[p] = [tmp stringByAppendingPathComponent:p];
    if (!from.count) from[s.lastPathComponent] = tmp;
    g_paused = 1; input_release(); lifecycle_apply();   // the game stops before its save changes under it
    NSString *keep = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ before restore %@", s.lastPathComponent, stamp()]];
    [fm createDirectoryAtPath:keep withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    for (NSString *p in save_parts(s)) {
        NSString *cur = [parent stringByAppendingPathComponent:p];
        for (NSString *x in @[cur, [cur stringByAppendingString:@".work"], [cur stringByAppendingString:@".new"]])
            if ([fm fileExistsAtPath:x] && ![fm moveItemAtPath:x toPath:[keep stringByAppendingPathComponent:x.lastPathComponent] error:&err]) break;
        if (err) break;
        if (from[p] && ![fm moveItemAtPath:from[p] toPath:cur error:&err]) break;
    }
    [fm removeItemAtPath:tmp error:nil];
    if (err) LOG("[RED] front end: save restore stopped: %s (the previous save is in %s)", err.localizedDescription.UTF8String, keep.fileSystemRepresentation);
    else LOG("front end: save restored from %s (the previous one is in %s)", pn.URL.fileSystemRepresentation, keep.fileSystemRepresentation);
    if (err) alert(@"The save could not be restored", [NSString stringWithFormat:@"%@\nThe previous save is in %@.", err.localizedDescription, keep]);
    dm_host_shutdown("save restored");
}
- (void)showLog:(id)sender { (void)sender; NSString *l = log_path(); if (l) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:l]]; }

// Game, Audio and View menus
- (void)togglePause:(id)sender {
    (void)sender; g_paused = !g_paused;
    if (g_paused) input_release(); else if (g_key_win) input_resume();
    LOG("front end: game %s", g_paused ? "paused" : "resumed");
    lifecycle_apply();
}
- (void)opmode:(NSMenuItem *)m { [self setOpmode:(int)m.tag]; }
- (void)setOpmode:(int)m {
    dm_set_opmode(m);   // the game hears the change (hle_oe.c notifications 30 / 31)
    char v[4]; snprintf(v, sizeof v, "%d", m); setenv("DM_OPMODE", v, 1);
    if (![g_locked containsObject:@"DM_OPMODE"]) [game_defaults() setObject:@(v) forKey:@"launcher.DM_OPMODE"];
    NSPopUpButton *b = (NSPopUpButton *)self.controls[@"DM_OPMODE"];
    for (NSMenuItem *i in b.itemArray) if ([i.representedObject isEqual:@(v)]) [b selectItem:i];
}
- (void)toggleMute:(id)sender { (void)sender; g_muted = !g_muted; lifecycle_apply(); }
- (void)toggleMuteBg:(id)sender { (void)sender; g_mute_bg = !g_mute_bg; [input_defaults() setBool:g_mute_bg forKey:@"audio.mute_background"]; lifecycle_apply(); }
- (void)toggleHud:(id)sender {
    (void)sender; int on = !hud_on(); hud_set(on);
    if (![g_locked containsObject:@"DM_METAL_HUD"]) [game_defaults() setObject:on ? @"1" : @"0" forKey:@"launcher.DM_METAL_HUD"];
    ((NSButton *)self.controls[@"DM_METAL_HUD"]).state = on ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)windowSize:(NSMenuItem *)m {   // the content at a width of tag points, 16:9, centered where the window was and kept on its screen
    if (g_win.styleMask & NSWindowStyleMaskFullScreen) return;
    NSRect f = g_win.frame, c = [g_win contentRectForFrameRect:f];
    c.size = NSMakeSize(m.tag, round(m.tag * 9.0 / 16.0));
    NSRect n = [g_win frameRectForContentRect:c];
    n.origin = NSMakePoint(NSMidX(f) - n.size.width / 2, NSMidY(f) - n.size.height / 2);
    [g_win setFrame:[g_win constrainFrameRect:n toScreen:g_win.screen] display:YES animate:YES];
}

// Controllers menu, rebuilt each time it opens
- (void)layoutPick:(NSMenuItem *)m { [self applyLayout:(int)m.tag]; }
- (void)applyLayout:(int)by_label {
    g_by_label = by_label; [input_defaults() setBool:by_label forKey:@"input.pad.by_label"]; [self.layout selectItemAtIndex:by_label];
    LOG("front end: controller buttons %s", by_label ? "by label (A bottom, B right, X left, Y top)" : "by position (A right, B bottom, X top, Y left)");
    pads_reread();
}
- (void)pickController:(NSMenuItem *)m { NSArray *r = m.representedObject; pick_controller(r[1], [r[0] intValue]); }
- (void)pickKeyboard:(NSMenuItem *)m { pick_keyboard((int)m.tag); }
- (void)pickNone:(NSMenuItem *)m { pick_none((int)m.tag); }
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSMutableArray<GCController *> *pads = [NSMutableArray array];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) [pads addObject:c];
    NSString *(^title)(GCController *) = ^NSString *(GCController *c) {
        float b = c.battery ? c.battery.batteryLevel : 0;
        return b > 0 ? [NSString stringWithFormat:@"%s (battery %d%%)", pad_name(c), (int)lroundf(b * 100)] : @(pad_name(c));
    };
    if (g_merge) {
        [menu addItemWithTitle:@"Every controller is player 1 (DM_PAD_MERGE)" action:nil keyEquivalent:@""].enabled = NO;
        for (GCController *c in pads) [menu addItemWithTitle:[@"    " stringByAppendingString:title(c)] action:nil keyEquivalent:@""].enabled = NO;
    } else {
        int last = 3; for (int p = 0; p < DM_PLAYERS; p++) if (g_slots.owner[p]) last = MAX(last, p);
        for (int p = 0; p <= last; p++) {
            NSMutableArray<NSString *> *who = [NSMutableArray array];
            if (g_held[p]) [who addObject:@(pad_name(g_held[p]))];
            if (g_kbd_slot == p || (p == 0 && g_kbd_slot < 0)) [who addObject:@"Keyboard"];
            NSMenu *sub = [[NSMenu alloc] initWithTitle:@""];
            for (GCController *c in pads) {
                NSMenuItem *i = [sub addItemWithTitle:title(c) action:@selector(pickController:) keyEquivalent:@""];
                i.target = self; i.representedObject = @[@(p), c]; i.state = g_held[p] == c ? NSControlStateValueOn : NSControlStateValueOff;
            }
            if (pads.count) [sub addItem:NSMenuItem.separatorItem];
            NSMenuItem *k = [sub addItemWithTitle:p ? @"Keyboard" : @"Keyboard (with player 1's controller)" action:@selector(pickKeyboard:) keyEquivalent:@""];
            k.target = self; k.tag = p; k.state = g_kbd_slot == p || (p == 0 && g_kbd_slot < 0) ? NSControlStateValueOn : NSControlStateValueOff;
            if (p) { NSMenuItem *n = [sub addItemWithTitle:@"None" action:@selector(pickNone:) keyEquivalent:@""]; n.target = self; n.tag = p; n.state = g_slots.owner[p] ? NSControlStateValueOff : NSControlStateValueOn; }
            NSString *t = [NSString stringWithFormat:@"Player %d: %@", p + 1, who.count ? [who componentsJoinedByString:@" + "] : @"None"];
            [[menu addItemWithTitle:t action:nil keyEquivalent:@""] setSubmenu:sub];
        }
        NSMutableArray<NSString *> *idle = [NSMutableArray array];
        for (GCController *c in pads) if (pad_slot_of(&g_slots, (__bridge const void *)c) < 0) [idle addObject:@(pad_name(c))];
        if (idle.count) [menu addItemWithTitle:[@"Not playing: " stringByAppendingString:[idle componentsJoinedByString:@", "]] action:nil keyEquivalent:@""].enabled = NO;
        if (!pads.count) [menu addItemWithTitle:@"No controller connected" action:nil keyEquivalent:@""].enabled = NO;
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *pos = [menu addItemWithTitle:@"Buttons by Position (Nintendo)" action:@selector(layoutPick:) keyEquivalent:@""]; pos.target = self; pos.tag = 0;
    NSMenuItem *lab = [menu addItemWithTitle:@"Buttons by Label (Xbox)" action:@selector(layoutPick:) keyEquivalent:@""]; lab.target = self; lab.tag = 1;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Keyboard and Controller Settings…" action:@selector(showSettings:) keyEquivalent:@""].target = self;
}
- (BOOL)validateMenuItem:(NSMenuItem *)m {
    SEL a = m.action;
    if (a == @selector(opmode:)) m.state = dm_opmode() == m.tag ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(togglePause:)) m.title = g_paused ? @"Resume" : @"Pause";
    else if (a == @selector(toggleMute:)) m.state = g_muted ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(toggleMuteBg:)) m.state = g_mute_bg ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(toggleHud:)) m.state = hud_on() ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(layoutPick:)) m.state = g_by_label == m.tag ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(showSave:) || a == @selector(exportSave:) || a == @selector(restoreSave:)) return save_dir() != nil;
    else if (a == @selector(showLog:)) return log_path() != nil;
    else if (a == @selector(windowSize:)) return !(g_win.styleMask & NSWindowStyleMaskFullScreen);
    else if (a == @selector(screenshot:)) return !g_paused && !g_mini;
    return YES;
}

// Settings window (⌘,): the game's settings (launcher.json), the controls (controller buttons, dead zone, the key map) and the save
static NSTextField *heading(NSString *s) { NSTextField *t = [NSTextField labelWithString:s]; t.font = [NSFont boldSystemFontOfSize:13]; return t; }
static NSTextField *small(NSString *s) {
    NSTextField *t = [NSTextField wrappingLabelWithString:s]; t.font = [NSFont systemFontOfSize:11]; t.textColor = NSColor.secondaryLabelColor;
    t.preferredMaxLayoutWidth = 460; return t;
}
- (NSView *)controlFor:(NSDictionary *)s {
    NSString *env = s[@"env"], *kind = s[@"kind"], *v = setting_value(s); NSControl *c; NSView *view;
    if ([kind isEqual:@"choice"]) {
        NSPopUpButton *b = [NSPopUpButton new];
        for (NSArray *o in s[@"options"]) { [b addItemWithTitle:o[1]]; b.lastItem.representedObject = o[0]; if ([o[0] isEqual:v]) [b selectItem:b.lastItem]; }
        c = b; view = b;
    } else if ([kind isEqual:@"toggle"]) {
        NSButton *b = [NSButton checkboxWithTitle:@"" target:nil action:nil]; b.state = [v isEqual:@"1"] ? NSControlStateValueOn : NSControlStateValueOff;
        c = b; view = b;
    } else {
        double lo = [s[@"min"] doubleValue], hi = [s[@"max"] doubleValue], st = [s[@"step"] doubleValue];
        NSSlider *sl = [NSSlider sliderWithValue:v.doubleValue minValue:lo maxValue:hi target:nil action:nil];
        if (st > 0) { sl.numberOfTickMarks = (NSInteger)llround((hi - lo) / st) + 1; sl.allowsTickMarkValuesOnly = YES; }
        [sl.widthAnchor constraintEqualToConstant:200].active = YES;
        NSTextField *pc = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld %%", lround(v.doubleValue * 100)]];
        self.percent[env] = pc; c = sl; view = [NSStackView stackViewWithViews:@[sl, pc]];
    }
    c.identifier = env; c.target = self; c.action = @selector(settingChanged:);
    c.enabled = ![g_locked containsObject:env];
    self.controls[env] = c;
    return view;
}
- (void)settingChanged:(NSControl *)c {
    NSString *env = c.identifier, *v; NSDictionary *s = nil;
    for (NSDictionary *r in g_settings) if ([r[@"env"] isEqual:env]) s = r;
    if (!s) return;
    if ([c isKindOfClass:NSPopUpButton.class]) v = ((NSPopUpButton *)c).selectedItem.representedObject;
    else if ([c isKindOfClass:NSSlider.class]) {
        double st = [s[@"step"] doubleValue], x = c.doubleValue; if (st > 0) x = [s[@"min"] doubleValue] + round((x - [s[@"min"] doubleValue]) / st) * st;
        v = [NSString stringWithFormat:@"%.2f", x]; self.percent[env].stringValue = [NSString stringWithFormat:@"%ld %%", lround(x * 100)];
    } else v = ((NSButton *)c).state == NSControlStateValueOn ? @"1" : @"0";
    if (!setting_valid(s, v)) return;
    [game_defaults() setObject:v forKey:[@"launcher." stringByAppendingString:env]];
    int now = [env isEqual:@"DM_OPMODE"] || [env isEqual:@"DM_METAL_HUD"];
    if ([env isEqual:@"DM_OPMODE"]) [self setOpmode:v.intValue];
    else if ([env isEqual:@"DM_METAL_HUD"]) hud_set(v.intValue);
    setenv(env.UTF8String, v.UTF8String, 1);
    LOG("front end: setting %s=%s%s", env.UTF8String, v.UTF8String, now ? "" : " (from the next start)");
}
- (void)showSettings:(id)sender {
    (void)sender;
    if (!self.settings) [self buildSettings];
    [self.settings makeKeyAndOrderFront:nil];
}
- (void)buildSettings {
    self.controls = [NSMutableDictionary dictionary]; self.percent = [NSMutableDictionary dictionary];
    NSStackView *st = [NSStackView new]; st.orientation = NSUserInterfaceLayoutOrientationVertical; st.alignment = NSLayoutAttributeLeading; st.spacing = 10;
    st.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    NSGridView *(^grid)(void) = ^NSGridView *(void) { NSGridView *g = [NSGridView gridViewWithViews:@[]]; g.rowSpacing = 8; g.columnSpacing = 10; return g; };
    if (g_settings.count) {
        [st addArrangedSubview:heading(@"Game")];
        NSGridView *g = grid();
        for (NSDictionary *s in g_settings) {
            [g addRowWithViews:@[[NSTextField labelWithString:[s[@"label"] stringByAppendingString:@":"]], [self controlFor:s]]];
            NSString *note = [s[@"note"] length] ? s[@"note"] : nil;
            if ([g_locked containsObject:s[@"env"]]) note = note ? [note stringByAppendingString:@" Set by an env file."] : @"Set by an env file.";
            if (note) [g addRowWithViews:@[[NSGridCell emptyContentView], small(note)]];
        }
        [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        [st addArrangedSubview:g];
        [st addArrangedSubview:small(@"Console mode and the performance HUD change at once; the other settings take effect the next time the game starts.")];
    }
    [st addArrangedSubview:heading(@"Controls")];
    NSGridView *g = grid();
    self.layout = [NSPopUpButton new]; [self.layout addItemsWithTitles:@[@"By position (Nintendo)", @"By label (Xbox)"]]; [self.layout selectItemAtIndex:g_by_label];
    self.layout.target = self; self.layout.action = @selector(layoutChanged:);
    NSSlider *dz = [NSSlider sliderWithValue:g_deadzone minValue:0 maxValue:0.3 target:self action:@selector(deadzoneChanged:)];
    dz.numberOfTickMarks = 7; [dz.widthAnchor constraintEqualToConstant:200].active = YES;
    NSTextField *dzl = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld %%", lroundf(g_deadzone * 100)]]; self.percent[@"deadzone"] = dzl;
    [g addRowWithViews:@[[NSTextField labelWithString:@"Controller buttons:"], self.layout]];
    [g addRowWithViews:@[[NSTextField labelWithString:@"Stick dead zone:"], [NSStackView stackViewWithViews:@[dz, dzl]]]];
    [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [st addArrangedSubview:g];
    NSTableView *tv = [NSTableView new];
    NSTableColumn *ca = [[NSTableColumn alloc] initWithIdentifier:@"action"]; ca.title = @"Action"; ca.width = 240;
    NSTableColumn *ck = [[NSTableColumn alloc] initWithIdentifier:@"key"]; ck.title = @"Key"; ck.width = 190;
    [tv addTableColumn:ca]; [tv addTableColumn:ck]; tv.dataSource = self; tv.delegate = self; tv.target = self; tv.doubleAction = @selector(rebind:);
    tv.usesAlternatingRowBackgroundColors = YES; self.keys = tv;
    NSScrollView *sv = [NSScrollView new]; sv.documentView = tv; sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    [sv.widthAnchor constraintEqualToConstant:460].active = YES; [sv.heightAnchor constraintEqualToConstant:220].active = YES;
    [st addArrangedSubview:sv];
    [st addArrangedSubview:small(@"Double-click an action, then press its key: Delete leaves it without one, Escape keeps the old one. The keyboard plays player 1 unless the Controllers menu gives it another.")];
    NSButton *reset = [NSButton buttonWithTitle:@"Restore Default Keys" target:self action:@selector(resetKeys:)];
    [st addArrangedSubview:reset];
    [st addArrangedSubview:heading(@"Save")];
    NSString *s = save_dir();
    NSTextField *where = small(s ?: @"No save folder (DM_SAVE is not set)."); where.selectable = YES; [st addArrangedSubview:where];
    NSStackView *bs = [NSStackView stackViewWithViews:@[[NSButton buttonWithTitle:@"Show in Finder" target:self action:@selector(showSave:)],
                                                         [NSButton buttonWithTitle:@"Export Backup…" target:self action:@selector(exportSave:)],
                                                         [NSButton buttonWithTitle:@"Restore Backup…" target:self action:@selector(restoreSave:)]]];
    for (NSButton *b in bs.arrangedSubviews) b.enabled = s != nil;
    [st addArrangedSubview:bs];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 600) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Settings"; w.releasedWhenClosed = NO; w.delegate = self; w.contentView = st;
    [w setContentSize:st.fittingSize]; [w center];
    self.settings = w;
}
- (void)windowWillClose:(NSNotification *)n { (void)n; g_rebind = -1; [self.keys reloadData]; }
- (void)layoutChanged:(NSPopUpButton *)b { [self applyLayout:(int)b.indexOfSelectedItem]; }
- (void)deadzoneChanged:(NSSlider *)s {
    g_deadzone = (float)(round(s.doubleValue * 100) / 100); [input_defaults() setFloat:g_deadzone forKey:@"input.pad.deadzone"];
    self.percent[@"deadzone"].stringValue = [NSString stringWithFormat:@"%ld %%", lroundf(g_deadzone * 100)];
    pads_reread();
}
- (void)resetKeys:(id)sender { (void)sender; for (int i = 0; i < NACT; i++) g_key[i] = g_actions[i].key; keymap_save(); g_rebind = -1; [self.keys reloadData]; }
- (void)rebind:(NSTableView *)tv { if (tv.clickedRow < 0) return; g_rebind = tv.clickedRow; [tv reloadData]; }
- (void)rebound:(unsigned short)code {   // the key pressed while a row waits: Escape keeps the old key, Delete / Forward Delete leaves none
    NSInteger r = g_rebind; g_rebind = -1; if (r < 0 || r >= NACT) return;
    if (code != 53) {
        unsigned short k = code == 51 || code == 117 ? KEY_NONE : code;
        if (k != KEY_NONE) for (int i = 0; i < NACT; i++) if (g_key[i] == k) g_key[i] = KEY_NONE;
        g_key[r] = k; keymap_save();
        LOG("front end: key %s → %s", key_name(k).UTF8String, g_actions[r].name);
    }
    [self.keys reloadData];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { (void)tv; return NACT; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    (void)tv;
    NSString *s = [col.identifier isEqual:@"action"] ? @(g_actions[row].name) : row == g_rebind ? @"Press a key…" : key_name(g_key[row]);
    NSTextField *t = [NSTextField labelWithString:s]; t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}
@end

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

static NSMenuItem *item(NSMenu *m, NSString *title, SEL a, NSString *key, NSEventModifierFlags mods, NSInteger tag) {
    NSMenuItem *i = [m addItemWithTitle:title action:a keyEquivalent:key ?: @""];
    if (mods) i.keyEquivalentModifierMask = mods;
    i.tag = tag;
    if (a && [g_app respondsToSelector:a]) i.target = g_app;
    return i;
}
static NSMenu *menu(NSMenu *bar, NSString *title) { NSMenu *m = [[NSMenu alloc] initWithTitle:title]; [[bar addItemWithTitle:title action:nil keyEquivalent:@""] setSubmenu:m]; return m; }
// Main menu: AppKit runs ⌘ shortcuts only through menu items, so ⌘Q quits and ⌃⌘F toggles fullscreen from here (AppKit shows the item as Globe-F and keeps ⌃⌘F as a hidden twin)
static void menus(void) {
    NSMenu *bar = [NSMenu new], *app = [NSMenu new];
    [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:app];
    item(app, @"About " DM_GAME_NAME, @selector(about:), nil, 0, 0);
    [app addItem:NSMenuItem.separatorItem];
    item(app, @"Settings…", @selector(showSettings:), @",", 0, 0);
    [app addItem:NSMenuItem.separatorItem];
    item(app, @"Hide " DM_GAME_NAME, @selector(hide:), @"h", 0, 0);
    item(app, @"Hide Others", @selector(hideOtherApplications:), @"h", NSEventModifierFlagOption | NSEventModifierFlagCommand, 0);
    item(app, @"Show All", @selector(unhideAllApplications:), nil, 0, 0);
    [app addItem:NSMenuItem.separatorItem];
    item(app, @"Quit " DM_GAME_NAME, @selector(terminate:), @"q", 0, 0);
    NSMenu *file = menu(bar, @"File");
    item(file, @"Take Screenshot", @selector(screenshot:), @"s", 0, 0);
    item(file, @"Show Screenshots", @selector(showScreenshots:), nil, 0, 0);
    [file addItem:NSMenuItem.separatorItem];
    item(file, @"Show Save in Finder", @selector(showSave:), nil, 0, 0);
    item(file, @"Export Save Backup…", @selector(exportSave:), nil, 0, 0);
    item(file, @"Restore Save Backup…", @selector(restoreSave:), nil, 0, 0);
    [file addItem:NSMenuItem.separatorItem];
    item(file, @"Show Log", @selector(showLog:), nil, 0, 0);
    NSMenu *game = menu(bar, @"Game");
    item(game, @"Pause", @selector(togglePause:), @"p", 0, 0);
    [game addItem:NSMenuItem.separatorItem];
    item(game, @"Docked", @selector(opmode:), nil, 0, 1);
    item(game, @"Handheld", @selector(opmode:), nil, 0, 0);
    NSMenu *audio = menu(bar, @"Audio");
    item(audio, @"Mute", @selector(toggleMute:), @"m", NSEventModifierFlagShift | NSEventModifierFlagCommand, 0);
    item(audio, @"Mute in Background", @selector(toggleMuteBg:), nil, 0, 0);
    NSMenu *view = menu(bar, @"View");
    item(view, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", NSEventModifierFlagControl | NSEventModifierFlagCommand, 0);
    NSMenu *size = [[NSMenu alloc] initWithTitle:@"Window Size"];
    const int widths[] = {960, 1280, 1600, 1920};
    for (int i = 0; i < 4; i++) item(size, [NSString stringWithFormat:@"%d × %d", widths[i], widths[i] * 9 / 16], @selector(windowSize:), [NSString stringWithFormat:@"%d", i + 1], 0, widths[i]);
    [[view addItemWithTitle:@"Window Size" action:nil keyEquivalent:@""] setSubmenu:size];
    [view addItem:NSMenuItem.separatorItem];
    item(view, @"Performance HUD", @selector(toggleHud:), nil, 0, 0);
    NSMenu *ctl = menu(bar, @"Controllers"); ctl.delegate = g_app;
    NSMenu *wm = menu(bar, @"Window");
    item(wm, @"Minimize", @selector(performMiniaturize:), @"m", 0, 0);
    item(wm, @"Zoom", @selector(performZoom:), nil, 0, 0);
    [wm addItem:NSMenuItem.separatorItem];
    item(wm, @"Bring All to Front", @selector(arrangeInFront:), nil, 0, 0);
    NSApp.mainMenu = bar; NSApp.windowsMenu = wm;
}

void front_run(void (*guest)(void)) {
    // A game: tell macOS its work is latency-critical, so the system does not trade its frame time for power while the frame rate is capped
    static id activity; activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"game"];
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow.allowsAutomaticWindowTabbing = NO;   // no tab bar items in the View menu: the game has one window
        g_app = [DmApp new];
        keymap_load();
        g_mute_bg = [input_defaults() boolForKey:@"audio.mute_background"];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        // Fullscreen: without FullScreenPrimary the green button only zooms the window. The present path already scales
        // the game picture to fit the drawable with black bars around it, so fullscreen keeps the game's aspect ratio.
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        NSView *v = win.contentView = [[DmGameView alloc] initWithFrame:r];
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }
        v.layer = g_layer; [(DmGameView *)v fitDrawable];
        [win center];
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        g_win = win;
        [NSApp activateIgnoringOtherApps:YES];
        menus();
        if (getenv("DM_FULLSCREEN")) dispatch_async(dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; });   // start in fullscreen
        for (NSNotificationName nm in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                GCController *c = n.object; int conn = n.name == GCControllerDidConnectNotification;
                if (!c.extendedGamepad || g_merge) LOG("controller %s: %s%s", conn ? "connected" : "disconnected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
                pads_changed(conn ? nil : c); }];
        dm_haptics_apple_init();
        pads_start();
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (g_rebind >= 0 && e.window == g_app.settings) {   // Settings waits for a key: it goes to the key map, not to the game or the table
                if (e.type == NSEventTypeKeyDown && !(e.modifierFlags & NSEventModifierFlagCommand)) { if (!e.isARepeat) [g_app rebound:e.keyCode]; return nil; }
                return e.type == NSEventTypeKeyUp ? nil : e;
            }
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand)) return e;   // ⌘ shortcuts go to the menu; a key released while ⌘ is held still reaches the game, or it would stay pressed
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Input is released when the window stops being key (and when it is minimized) and taken up again when it is key again (lifecycle_apply for the rest)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) { g_screen_fps = (int)win.screen.maximumFramesPerSecond; g_layer.contentsScale = win.backingScaleFactor; } screen_match_apply(); }];
        // Entering and leaving fullscreen: the layer is layer-backed, so its frame (and with it the drawable) follows the
        // content view by itself; only the scale factor has to be carried over to the screen the window ended up on. The screen's rate is matched in fullscreen only (screen_match_apply)
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidExitFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); g_key_win = 0; lifecycle_apply(); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (!g_paused) input_resume(); g_key_win = 1; lifecycle_apply(); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); g_mini = 1; lifecycle_apply(); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_mini = 0; lifecycle_apply(); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
extern int g_swkbd_min_chars;   // hle_swkbd.c: this input's minimum length from ShowKeyboardArg; the applet keeps OK disabled until the text is long enough
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // The box takes the keyboard and the mouse, so the game window never sees the key-up of the button or the touch-up of the click that opened it: nothing may stay pressed
        // while it is up, or the game reads the stuck button / touch the moment the box closes (Stardew Valley's character creation re-opened the keyboard endlessly)
        keys_release();
        dm_touch_set(NULL, 0);
        int min_chars = g_swkbd_min_chars > 0 ? g_swkbd_min_chars : 0;
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        for (;;) {
            NSAlert *a = [NSAlert new];
            a.messageText = title && *title ? @(title) : @"Input";
            a.informativeText = info;
            [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
            NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            f.stringValue = text ?: (initial ? @(initial) : @"");
            if (guide && *guide) f.placeholderString = @(guide);
            a.accessoryView = f; a.window.initialFirstResponder = f;
            r = [a runModal] == NSAlertFirstButtonReturn;
            text = f.stringValue;
            if (!r || (int)text.length >= min_chars) break;
            // On hardware the applet would not have accepted the shorter text (OK stayed disabled); a game that rejects it re-opens the keyboard for ever, so the box comes back with the rule instead
            info = [info stringByAppendingFormat:@"\nAt least %d characters are needed here.", min_chars];
        }
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
