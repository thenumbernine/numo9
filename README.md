[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>

# Fantasy Console

I thought I'd make a fantasy console with all the LuaJIT binding code and libraries I have laying around.

## What's unique about this one?

It's strictly LuaJIT.  No compiling required.

## Build Instructions.

Nope, none.  Just run LuaJIT.  It should ship with the binaries of that.  If you don't trust them you can rebuild and re-run your own LuaJIT.  All the code is readable and modifyable for your convenience.

There are a few libraries that NuMo9 is dependent upon (SDL2, libpng, libtiff, etc).  I'm working on the definitive list.  Those should also be packaged, or you can rebuild them yourself as well.

# Hardware

### Framebuffer

Mode 0:
Screen framebuffer is 256x256x16bpp RGB565.  This mode supports blending effects.

Mode 1:
This is a 8bpp-indexed option, mainly for compatability for other fantasy consoles.  Fun fact, in real life 80s/90s consoles didn't have framebuffers, so after-the-fact palette editing is indeed a fantasy.

Mode 2:
This is 8bpp RGB332.  It looks ugly. Maybe I'll add some dithering.  Once I figure out how GLSL unpacks bits from the RGBA5551REV palette textures ... that seems mysterious to me.

### sprites / tiles

Sprites are 8x8 pixels.
Sprite bpp can be anywhere from 1bpp to 8bpp, colors indexed into a palette.
The renderer can draw the sprite bits starting at any bitplane.
This way you can store (and edit) 8 1-bpp images in the same texture region.

The sprite sheet is 256x256 pixels.  This means 32x32 instances of 8x8 sprites in a sprite sheet.  Sprites are indexed 0 through 1023.
The UI and console font is stored at the bottom row of the sprite sheet.
You can edit this, however it will affect the console and editor.

The palette is a set of 256 colors stored in 5551 RGBA format.  Alpha is opacity, except when drawing solid rectangle/circle/line.
The renderer also accepts an optional color index to consider transparent in addition to the palette alpha flag.
The renderer also accepts a palette offset used for drawing low-bpp images using various palettes.
The last 16 palette colors are used by the UI and console.  You can use this, however it will affect the UI.

The tilesheet is equivalent to the sprite sheet in every way except that it is indexed by the tilemap.

### tilemap

The tilemap is 256x256x16bpp.
Tilemap bits:
- 10: lookup into the tilesheet texture
- 4: palette offset high 4 bits
- 1: hflip
- 1: vflip

Tilemaps can render 8x8 or 16x16 sprites.

### Mode7

What's a SNES-era fantasy-console without mode7?
There are a few matrix functions that you can use to manipulate the render state:

`matident`,
`mattrans`,
`matrot`,
`matscale`,
`matortho`,
`matfrustum`,
`matlookat`.

I'm using 16.16 fixed precision to store the matrix components.  SNES used 8.8, so I am splurging a bit.  I've tested with as close as 9.7 without getting too big of rounding errors.

### Audio

I might undercut SNES quality when it comes to audio.
Not only am I not much of a retro audio programmer, but the SNES happened to be an exceptional audio hardware console of its time.

256 Sound samples at once.
Each sample is 16bit mono.
They can be played back through 8 channels at a time.
Channels have the following properties:
- separate left/right volume (0-127) and flag for reverse.
- pitch / frequency as a multiplier (0-65536).  4096 = 1:1, so 2048 is one octave lower, 8192 is one octave higher.
- source sample ID.

### Memory Layout

```
0x000000 - 0x010000 = spriteSheet
0x010000 - 0x020000 = tileSheet
0x020000 - 0x040000 = tilemap
0x040000 - 0x040200 = palette
0x040200 - 0x050200 = code
0x050200 - 0x070200 = framebuffer
0x070200 - 0x070204 = clipRect
0x070204 - 0x070244 = mvMat
0x070244 - 0x070248 = updateCounter
0x070248 - 0x07024c = romUpdateCounter
0x07024c - 0x07025a = keyPressFlags
0x07025a - 0x070268 = lastKeyPressFlags
0x070268 - 0x07033e = keyHoldCounter
0x07033e - 0x070342 = mousePos
0x070342 - 0x070346 = lastMousePos
0x070346 - 0x07034a = lastMousePressPos
system dedicated 0x7034a of RAM
```

# Language

It uses Lua as the underlying script.
Cartridge code can make use of my [langfix](https://github.com/thenumbernine/langfix-lua) language modifications.
This adds to Lua(/JIT):
- bit operators: `& | << >> >>>`
- integer-division: `a // b`
- in-place operators: `..= += -= *= /= //= %= ^= &= |= ~~= <<= >>= >>>=`
- lambdas: `[args] do stmts end` for functions, `[args] expr` for single-expression functions.
- safe-navigation: `a?.b, a?['b'], a?(), a?.b(), a?:b(), a.b?(), a?.b?(), a:b?(), a?:b?()`
- ternary operator: `a ? b : c`, null-coalescence: `a ?? b`.

# API

## virtual-filesystem commands:

- `ls()` = list directory
- `dir()` = same
- `cd()` = change directory
- `mkdir()` = make directory

## system:

- `print(...)` = print to screen
- `trace(...)` = print to host OS terminal

- `run()` = run loaded cartridge.
- `stop()` = stop all execution and drop into console mode.
- `cont()` = continue execution of the cartridge.

- `save([filename])` = save cartridge to virtual-filesystem and host-filesystem
- `load([filename])` = load cartridge
- `reset()` = reload cartridge to its initial state.
- `quit()` = quit the entire application outright to host OS.

- `time()` = soon to be cartridge run time, currently poor mans implementation

## memory

- `peek, peekw, peekl, poke, pokew, pokel` = read/write memory 1, 2, or 4 bytes at a time.
- `mget, mset` = read/write uint16's from/to the tilemap.

## graphics

- `flip()` = flip the framebuffer, and wait until the next 60Hz frame to begin.
- `cls([color])` = clear screen.
- `rect(x, y, w, h, [color])` = draw solid rectangle
- `rectb(x, y, w, h, [color])` = draw rectangle border
- `elli/ellib` = draw solid/border ellipse/circle.
- `line(x1,y1,x2,y2,[color])` = draw line.
- `spr(spriteIndex,screenX,screenY,[spritesWide,spritesHigh,paletteIndex,transparentIndex,spriteBit,spriteMask,scaleX,scaleY])` = draw sprite
	- spriteIndex = which sprite to draw
	- screenX, screenY = pixel location of upper-left corner of the sprite
	- spritesWide, spritesHigh = the size of the sprite in the spritesheet to draw, in 8x8 tile units.
	- paletteIndex = a value to offset the colors by.  this can be used for providing high nibbles and picking a separate palette when drawing lower-bpp sprites.
	- transparentIndex = an optional color to specify as transparent.  default is -1 to disable this.
	- spriteBit = which bitplane to draw.  default is start at bitplane 0.
	- spriteMask = mask of which bits to use.  default is 0xFF, in binary 1111:1111, which uses all 8 bitplanes.
		- the resulting color index drawn is `(incomingTexelIndex >> spriteBit) & spriteMask + paletteIndex`
	- scaleX, scaleY = on-screen scaling.
- `quad(x,y,w,h,tx,ty,tw,th,pal,transparent,spriteBit,spriteMask)` = draw arbitrary section of the spritesheet.  Cheat and pretend the PPU has no underlying sprite tile decoding constraints.  Equivalent of `sspr()` on pico8.
- `map(tileX,tileY,tilesWide,tilesHigh,screenX,screenY,mapIndexOffset,draw16x16Sprites)` = draw the tilemap. mapIndexOffset = global offset to shift all map indexes. draw16x16Sprites = the tilemap draws 16x16 sprites instead of 8x8 sprites.
	- I am really tempted to swap out `tileX,tileY` with just tileIndex, since that's what `mget` returns and what the tilemap stores.  I know pico8 and tic80 expect you to split up the bits every time you call this, but I don't see the reason...
- `text(str,x,y)` = draw text.  I should rename this to `print` for compat reasons.
- `mode(i)` = set video mode.  The current video modes are:
	- 0 = 16bpp RGB565, needed for blending
	- 1 = 8bpp Indexed, not capable of blending, but capable of modifying the framebuffer palette (like the other fantasy consoles allow)
	- 2 = 8bpp RGB332.  This is an abomination.
- `clip([x, y, w, h])` = clip screen region.  `clip()` resets the clip region.
- `blend([i])` = Set blend mode.  Default value is 0xff corresponding to no blending.  The current blend modes are:
	- 0xff = none
	- 0 = addition with framebuffer
	- 1 = average with framebuffer (addition then half)
	- 2 = subtract from background
	- 3 = subtract-then-half with background
	- 4 = (FIXME) addition with constant color
	- 5 = (FIXME) average with constant color
	- 6 = (FIXME) subtract from constant color
	- 7 = (FIXME) subtract-then-half with constant color
Blending is only applied to opaque pixels.  Transparent pixels, i.e. those whose palette color has alpha=0, are discarded.
Constant-color blending functions use the RGB555 value stored in `blendColor` of the [memory map](#Memory Layout) as their constant color.

## mode7:

- `matident()` = set the transform matrix to identity
- `mattrans([x],[y],[z])` = translate the transform matrix by x,y,z.  Default translate is 0.
- `matrot(theta,[x,y,z])` = rotate by theta radians on axis x,y,z.  Default axis is 0,0,1 for screen rotations.
- `matscale([x],[y],[z])` = scale by x,y,z.  Default scale is 1.
- `matortho(left,right,bottom,top,[near,far])` = apply orthographic transform.
- `matfrustum(left,right,bottom,top,near,far)` = apply frustum perspective transform.
- `matlookat(eyeX,eyeY,eyeZ,camX,camY,camZ,upX,upY,upZ)` = transform view to position at camX,camY,camZ and look at eyeX,eyeY,eyeZ with the up vector upX,upY,upZ.

## input:

- `key(code)`, `keyp(code, [hold], [period])`, `keyr(code)` = Returns true if the key code was pressed.
	For `keyp()`, `hold` is how long to hold it before the first `true` is returned, and `period` is how long after that for each successive `true` to be returned.
	Code is either a name or number.
	The number coincides with the console's internal scancode bit offset in internal buffer.

	Key code numbers:

|                  |                  |                  |                  |                  |                  |                  |                  |
|------------------|------------------|------------------|------------------|------------------|------------------|------------------|------------------|
|`a=0`             |`b=1`             |`c=2`             |`d=3`             |`e=4`             |`f=5`             |`g=6`             |`h=7`             |
|`i=8`             |`j=9`             |`k=10`            |`l=11`            |`m=12`            |`n=13`            |`o=14`            |`p=15`            |
|`q=16`            |`r=17`            |`s=18`            |`t=19`            |`u=20`            |`v=21`            |`w=22`            |`x=23`            |
|`y=24`            |`z=25`            |`0=26`            |`1=27`            |`2=28`            |`3=29`            |`4=30`            |`5=31`            |
|`6=32`            |`7=33`            |`8=34`            |`9=35`            |`minus=36`        |`equals=37`       |`leftbracket=38`  |`rightbracket=39` |
|`backslash=40`    |`semicolon=41`    |`quote=42`        |`backquote=43`    |`comma=44`        |`period=45`       |`slash=46`        |`space=47`        |
|`tab=48`          |`return=49`       |`backspace=50`    |`up=51`           |`down=52`         |`left=53`         |`right=54`        |`capslock=55`     |
|`lctrl=56`        |`rctrl=57`        |`lshift=58`       |`rshift=59`       |`lalt=60`         |`ralt=61`         |`lgui=62`         |`rgui=63`         |
|`delete=64`       |`insert=65`       |`pageup=66`       |`pagedown=67`     |`home=68`         |`end=69`          |`padding0=70`     |`padding1=71`     |
|`jp0_up=72`       |`jp0_down=73`     |`jp0_left=74`     |`jp0_right=75`    |`jp0_a=76`        |`jp0_b=77`        |`jp0_x=78`        |`jp0_y=79`        |
|`jp1_up=80`       |`jp1_down=81`     |`jp1_left=82`     |`jp1_right=83`    |`jp1_a=84`        |`jp1_b=85`        |`jp1_x=86`        |`jp1_y=87`        |
|`jp2_up=88`       |`jp2_down=89`     |`jp2_left=90`     |`jp2_right=91`    |`jp2_a=92`        |`jp2_b=93`        |`jp2_x=94`        |`jp2_y=95`        |
|`jp3_up=96`       |`jp3_down=97`     |`jp3_left=98`     |`jp3_right=99`    |`jp3_a=100`       |`jp3_b=101`       |`jp3_x=102`       |`jp3_y=103`       |
|`mouse_left=104`  |`mouse_middle=105`|`mouse_right=106` |                  |                  |                  |                  |                  |

- `btn(buttonCode, player)`, `btnp(buttonCode, player, [hold], [period])`, `btnr(buttonCode, player)` = same for emulated-joypad-buttons-on-keyboard.
This is a compatability/convenience function that remaps the button+player codes to the corresponding `jpX_YYY` key codes.
The button codes are as follows:

|                  |                  |                  |                  |                  |                  |                  |                  |
|------------------|------------------|------------------|------------------|------------------|------------------|------------------|------------------|
|`up=0`            |`down=1`          |`left=2`          |`right=3`         |`a=4`             |`b=5`             |`x=6`             |`y=7`             |

- `mouseX, mouseY, scrollX, scrollY = mouse()` = get the current mouse state.  mouse x,y are in framebuffer coordinates.  scroll is zero for now.

## other globals, maybe I'll take some out eventually:

- `tostring`
- `tonumber`
- `select`
- `type`
- `error`
- `assert`
- `pairs`
- `ipairs`
- `ffi` = the luajit ffi library
- `getfenv`
- `setfenv`
- tables:
	- `bit` = luajit's bit library
	- `math` = luajit's math library
	- `table` = my lua-ext table library
	- `string` = my lua-ext string library
	- `coroutine` = my lua-ext coroutine library
	- `app` = the NuMo9 app itself.  Probably going away soon.
	- `_G` = the NuMo9 global.  Probably going away soon.

# Menu

Push Esc in gameplay to get to the menu.

# Virtual Terminal

Push Esc from the menu to get to the console.
The console accepts Lua commands directly, just like the game script does.

# Editor

Push Esc from the console to get to the editor.  Press again to get back to gameplay.

Multiplayer page will list connections.  It will let associate connected players with controllers, kick, etc.

Code page. Should do what you would expect.  Ctrl(/Apple)+X=cut C=copy V=paste A=select-all.

Sprite page. Click and drag on the spritesheet to select arbitrary rectangles of sprites.
Controls for selecting sprite bitness and bitplane.
Toggle for editing the sprite sheet vs the tilemap sheet.
When you paste an image, it will quantize colors to the current palette bitness, always excluding the UI colors.  You can currently toggle whether it matches colors to the current palette or if it generates a new palette.

Tilemap page.  Click the 'T' to drop down the tilemap for selecting tiles.  Click the 'X' to toggle 8x8 vs 16x16 tiles.

Hold spacebar and move mouse to pan over any image window.

SFX page is WIP

Music page is WIP

# Multiplayer

There are a few console commands for multiplayer:

- `listen(addr, [port])` = server starts listening on the address and port.
- `connect(addr, [port])` = client connects to address and port.
- `disconnect()` = on server: closes socket and stops listening.  on client: disconnects from server.

# Cartridges

All my cartridge files are in `.tiff`. format.  To pack and unpack them use the `n9a.lua` script.

To unpack a cartridge into a local directory with matching name:
```
luajit n9a.lua x cart.n9
```
It will overwrite files.

To pack a cartridge from a local directory of matching name:
```
luajit n9a.lua a cart.n9
```

To pack a cartridge and immediately run it:
```
luajit n9a.lua r cart.n9
```

To convert a TIFF-encoded cartridge to its binary ROM format:
```
luajit n9a.lua n9tobin cart.n9
```

To convert the binary ROM back to a TIFF-encoded cartridge:
```
luajit n9a.lua binton9 cart.bin
```

To convert a Pico8 cartridge to a local directory of unpacked n9 contents:
```
luajit n9a.lua p8 cart.p8
```

To convert a Pico8 to Numo9 cartridge and run it:
```
luajit n9a.lua p8run cart.p8
```

Pico8 Compatability is at 95%
- certain string escape characters don't work
- certain machine-specific peeks and pokes don't work
- palette functions are still buggy

# Other Fantasy Consoles / Inspiration for this:
- https://www.pico-8.com/
- https://tic80.com/
- https://pixelvision8.itch.io/
- https://github.com/emmachase/Riko4
- https://github.com/kitao/pyxel

# Some SNES hardware spec docs to guide my development:
- https://8bitworkshop.com/blog/platforms/nintendo-nes.md.html
- https://snes.nesdev.org/wiki/Tilemaps
- https://www.raphnet.net/divers/retro_challenge_2019_03/qsnesdoc.html
- https://www.coranac.com/tonc/text/hardware.htm
- https://pikensoft.com/docs.html
- https://bumbershootsoft.wordpress.com/2023/11/18/snes-digital-audio-playback/
- https://snes.nesdev.org/wiki/BRR_samples
- https://snes.nesdev.org/wiki/DSP_envelopes
- https://wiki.superfamicom.org/transparency
- https://problemkaputt.de/fullsnes.htm
- https://archive.org/details/SNESDevManual/book1/
- https://en.wikibooks.org/wiki/Super_NES_Programming/Loading_SPC700_programs

# TODO
- sfx
	- plays WAVs and generates WAVs from pico8 carts
	- still not sure how my sound 'hardware' should work ...
- music WIP
- input
	- joystick support
	- virtual buttons / touch interface ... it's in my `gameapp` repo, I just need to move it over.
	- between input and multiplayer, how about a higher max # of players than just hardcoded at 4?

... how to mix the console, the menu system, and the editor ... like tic80 does maybe ... hmm  

- editor:
	- tilemap UI for editing high-palette and horz/vert flip
	- copy/paste on the tilemap.
		- copy/paste tilemap entries themselves
		- paste sprites into the tilemap, then automatically quantize their sprites and palettes.. Just need to copy most of this from my `convert-to-8x8x4bpp` repo.
		- ... of text / number tables
	- expose palette index swap feature
	- bucket fill functionality
	- flag for pen / paste / bucket fill clip-to-view-area or not
	- blob-finding functionality ... ?  How about selection masks and click-to-select stuff?  Why not just remake Photoshop.
	- tilemap bucket fill
- graphics:
	- relocatable framebuffer / sprite pages.  allow the framebuffer to write to the sprite sheet.
	- multiple sprite pages, not a separate 'spriteSheet' and 'tileSheet', but just an arbitrary # of pages.
- langfix needs better error-handling, line and col redirection from transpiled location to rua script location.
- Right now browser embedding is only done through luajit ffi emulation, which is currently unplayably slow.  Work on porting LuaJIT, or implementing a faster (web-compiled maybe?) FFI library in the web-compiled Lua.  Or see if WebVM.IO will support a GLES3-WebGL2 wrapper library.
