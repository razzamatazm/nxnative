# 30XX (`010059B017F9E000`)

Update 1.3.6 (v851968), SDK 13.3.5. Batterystaple Games' own engine, with FMOD for sound and Pia / NEX for online play. It renders with **OpenGL**, not NVN: NVIDIA's desktop GL 4.5 through EGL, which the host implements on Metal (`dm/gfx/gl/hle_gl.m`). Modules `main` and `subsdk0`, which holds Nintendo's SDK: the game ships no `sdk` module. `subsdk1` (NVIDIA's OpenGL driver) and `subsdk2` (GLSLC) are never loaded. One DLC (Dally's Feline Fury). IPA about 928 MB.

On the Mac: the title and the first level with scripted input (`DM_KEYS`), headless, at 60 fps; about 2.5 GB resident and 1.8 GB of Metal allocations in the level. Not yet tested on the iPhone, nor with a window and a controller.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `modules main subsdk0` | [`game.tsv`](game.tsv) | `subsdk0` is the SDK (no `sdk` module); `subsdk1` / `subsdk2` are NVIDIA's GL driver and GLSLC, never loaded |
| [`gl_capture.tsv`](gl_capture.tsv) | profile | the 55 shaders the engine puts together at run time, which no game file holds whole; the NSP script captures them on the Mac; see [Shaders](#shaders) |
| `sys_resource 0x0`; `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | no system resource, so no virtual address memory: `main` sets a heap of at most the pool − 64 MB (a 3,328 MB heap region), as the provisional profile guessed |
| No NVN shader tables | `game.tsv` `shader_note` | no NVN shaders: `gl_shaders.py` writes the GL library and its table, not the profile |

No rewriter cut, profile key or build gate is specific to it: everything it needed was a general change.

## Bring-up

The NSP script's first run stopped in the survey, then in the capture boot; each step below is a general change ([Found on this game](#found-on-this-game)).

- **Resolved: no `sdk` module.** The survey's `nso_syms.py` stopped on `ExeFS/sdk`, then the host on `FATAL StandardAllocator::Allocate not found in the SDK` in `main`'s init array. The SDK (`nnSdk-13_3_5`, `StandardAllocator::Allocate`) is in `subsdk0`, which the survey had labelled `NintendoSDK_NVN` after the first component tag it found there.
- **Resolved: OpenGL ES probed first.** `eglBindAPI(OPENGL_ES)`, then `eglGetConfigs`, which the layer did not have; the game then binds desktop OpenGL and makes a 4.5 context, and asks the window surface's size with `eglQuerySurface`.
- **Resolved: direct state access.** Its buffers are made and filled by name (`glCreateBuffers`, `glNamedBufferStorage`, `glMapNamedBufferRange`); a null mapping crashed at `main+0x1e97c0`. With those in, `DM_GL_STUBS=1` named the rest it calls: `glFlush`, `glDepthRangef`, `glGetBooleanv(DEPTH_WRITEMASK)`, `glIsSync`, `glCompressedTexSubImage2D` (DXT1 / DXT5 levels into `glTexStorage2D` textures) and a pixel unpack buffer.
- **Resolved: the title over black, then the level black.** Only the menu text showed. A trace of one frame (passes, draws, units) found the scene drawn into framebuffer 2 (texture 32) and composited at the end, with alpha but no colour in texture 32 although its tile textures held the art and `fadeColor` was 1 before each draw: every shader declares the same 14 samplers and samples one to three, and all 14 had slot 0 in the table.
- **Resolved: colours swapped and the player in pieces.** In a window the player showed as a few scattered pixels and the scene's reds and blues were exchanged (the earlier gallery shot had both). Its atlases and palettes are `RGBA8` storage filled with `GL_BGRA` sub-images, copied unswapped; the palette shader (`PS_Palette`: `c.r * 256` into a 256x32 palette at row `_PaletteIndex`) then read blue as the colour index.

## Rendering (OpenGL)

- A frame on the title: the scene into a 1280x720 target (13 draws of 640-pixel-wide background strips), four blur passes, then the composite and the interface on the window; 11 passes and about 32 draws. In the level about 74 draws a frame.
- Depth is a 24-bit renderbuffer (Depth32Float here) on every target; the frames traced never enable the depth test.
- Textures: 1,300 to 1,600 alive, RGBA8 and DXT1 / DXT5 (98 compressed at the title), uploaded by `glTexStorage2D` + `glTexSubImage2D` / `glCompressedTexSubImage2D`.

## Shaders

- **Current:** 55 sources (10 vertex), all `#version 120` (`attribute` / `varying`, `gl_FragColor`, `texture2D`, precision statements). Each is one shared header (every uniform and sampler of the engine, its constants and helper functions) and a body. All are compiled before the title shows; the first level used none other. No game file holds them whole, so the NSP script captures them on the Mac (`DM_GL_CAPTURE` until every file in `gl_capture.tsv` is there) and `gl_shaders.py` translates them; the host finds each by the hash of its text.
- **Resolved:** glslang takes desktop GLSL only from 1.40 on; `gl_shaders.py` now raises older shaders to 3.30. The header defines `trunc` (a built-in from 1.30 on) and `bias` (Metal's `metal::bias`), both renamed.
- **Open:** later levels and bosses may compile shaders the title does not; a capture run that stops at the title would leave them out of the library (the host then skips their draws with a red line naming the shader).

## Mac routes

- `DM_KEYS=12:A*20/4` (A every 4 s from 12 s): Play at the title, through the selection screens into the first level by about frame 1,500.

## Open

- iPhone: not tested (the IPA builds; 2.5 GB resident on the Mac).
- Gameplay past the first screens of the first level, a window with a controller, sound by ear, the DLC, and online play (Pia / NEX) are not checked.

## Found on this game

General host changes first needed here; each applies to every game:

- **The SDK in `subsdk` modules** (`dm_sdk_modules`: the allocator hook, the SDK version, the survey's exports): [The SDK in subsdk modules, with no `sdk`](../../../docs/reference/memory.md#the-sdk-in-subsdk-modules-with-no-sdk).
- **OpenGL ES bound before a desktop context** (`eglBindAPI`, `eglGetConfigs`, `eglQuerySurface`): [OpenGL ES configurations probed before a desktop context](../../../docs/reference/rendering.md#opengl-es-configurations-probed-before-a-desktop-context).
- **Direct state access buffers, pixel unpack buffers, the depth range and the other calls above**: [GL 4.5 direct state access buffers](../../../docs/reference/rendering.md#gl-45-direct-state-access-buffers).
- **GLSL 1.20 raised to 3.30, and names that clash with newer built-ins or Metal's types**: [Desktop GLSL older than 1.40](../../../docs/reference/rendering.md#desktop-glsl-older-than-140).
- **Only the samplers a shader uses in the table**: [Every declared sampler bound to slot 0](../../../docs/reference/rendering.md#every-declared-sampler-bound-to-slot-0).
- **BGRA sub-images swapped into RGBA textures**: [BGRA sub-images into an RGBA texture](../../../docs/reference/rendering.md#bgra-sub-images-into-an-rgba-texture).
