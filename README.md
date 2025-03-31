![splash](docpics/splash.gif)

[![NuMo9 Youtube Playlist](https://img.youtube.com/vi/R8FA24Iwo6w/0.jpg)](https://www.youtube.com/watch?v=R8FA24Iwo6w&list=PLvkQx1ZpORprcwfSuMEvSgGO7Kpxo44Ma)

[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>

# Fantasy Console

I thought I'd make a fantasy console with all the LuaJIT binding code and libraries I have laying around.

What does NuMo9 have that the competition doesn't?
- 16-bit console era.  4-button gamepads.
- 8bpp sprites, 8x8 or 16x16 tilemaps, "mode-7" transformations, blending.
- Multiplayer, 4 local players per connection, up to 64 total players, unlimited observers.
- Server can edit games in realtime.  Live game DM'ing.
- It's strictly LuaJIT.  No compiler needed.

## Build Instructions.

Nope, none.  Just run LuaJIT.  It should ship with the binaries of that.  If you don't trust them you can rebuild and re-run your own LuaJIT.  All the code is readable and modifyable for your convenience.

There are a few libraries that NuMo9 is dependent upon (SDL2, libpng, etc).  I'm working on the definitive list.  Those should also be packaged, or you can rebuild them yourself as well.

# Hardware

### Framebuffer

Mode 0:
Screen framebuffer is 256x256x16bpp RGB565.  This mode supports blending effects.

Mode 1:
This is a 8bpp-indexed option, mainly for compatability for other fantasy consoles.  Fun fact, in real life 80s/90s consoles didn't have framebuffers, so after-the-fact palette editing is indeed a fantasy.

Mode 2:
This is 8bpp RGB332.  It looks ugly. Maybe I'll add some dithering.

It's really tempting to include a hidden depth-buffer, since TIC-80 does as well.  But meh, for now nope, you have to do your own z-sorting.

### sprites / tiles

Tiles are 8x8 pixels.
Sprite BPP can be anywhere from 1bpp to 8bpp, colors indexed into a palette.
The renderer can draw the sprite bits starting at any bitplane.
This way you can store (and edit) 8 1-bpp images in the same texture region.

The sprite sheet is 256x256 pixels.  This means 32x32 instances of 8x8 sprites in a sprite sheet.  Sprites are indexed 0 through 1023.
The palette is a set of 256 colors stored in 5551 RGBA format.  Alpha is opacity, except when drawing solid rectangle/circle/line.
The font is stored in a 256x8 texture.  Each 8x8 tile holds 8 characters in 1bpp, one per bitplane.
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
`matident`, `mattrans`, `matrot`, `matscale`, `matortho`, `matfrustum`, `matlookat`.

I'm using 16.16 fixed precision to store the matrix components.  SNES used 8.8, so I am being generous.  I've tested with as close as 9.7 without getting too big of rounding errors, so maybe I could restrict this later, but meh.

### Audio

I might undercut SNES quality when it comes to audio.
Not only am I not much of a retro audio programmer, but the SNES happened to be an exceptional audio hardware console of its time.

256 Sound samples at once.
Each sample is 16bit mono.

256 different music tracks.
Music is stored in a custom format:
```
uint16_t beatsPerSecond;
struct {
	uint16_t delayUntilNextNoteInBeats;

	//Array of byte offset and value changes to the `channels` array in RAM at the current beat.
	//An offset and value of 0XFF indicates the end of the list.
	//An offset of 0xFE means that the next value will specify the music track to immediately jump to.
	struct {
		uint8_t offset;
		uint8_t value;
	}[];
}[];
```
When playing music track i, the music data starts at `musicAddrs[i].addr` and ends at `musicAddrs[i].addr + musicAddrs[i].len`.

Each mixing channel holds the following information:
- volume[2] for left and right output
- echoVolume[2] TODO
- pitch frequency scalar, where 0x1000 pitch corresponds to 1:1 playback
- sfxID 0-255 corresponding with what sfx sample to play;
- echoStartAddr TODO
- echoDelay TODO
There are 8 mixing channels.

In this sense, if you are used to other fantasy consoles, their waveforms becomes my samples and their sfx and music (tracker format audio) become my music.

### Memory Layout

```
memory layout:
- RAM -
0x000000 - 0x020000 = framebuffer
0x020000 - 0x020004 = clipRect
0x020004 - 0x020044 = mvMat
0x020044 - 0x020045 = videoMode
0x020045 - 0x020046 = blendMode
0x020046 - 0x020048 = blendColor
0x020048 - 0x020148 = fontWidth
0x020148 - 0x020149 = textFgColor
0x020149 - 0x02014a = textBgColor
0x02014a - 0x0201ca = channels
0x0201ca - 0x02026a = musicPlaying
0x02026a - 0x02026e = updateCounter
0x02026e - 0x020272 = romUpdateCounter
0x020272 - 0x0202bb = keyPressFlags
0x0202bb - 0x020304 = lastKeyPressFlags
0x020304 - 0x020794 = keyHoldCounter
0x020794 - 0x020798 = mousePos
0x020798 - 0x02079c = mouseWheel
0x02079c - 0x0207a0 = lastMousePos
0x0207a0 - 0x0207a4 = lastMousePressPos
0x0207a4 - 0x0227a4 = persistentCartridgeData
0x0227a4 - 0x030000 = userData
- ROM -
0x030000 - 0x040000 = spriteSheet
0x040000 - 0x050000 = tileSheet
0x050000 - 0x070000 = tilemap
0x070000 - 0x070200 = palette
0x070200 - 0x070a00 = font
0x070a00 - 0x080000 = extra
0x080000 - 0x080400 = sfxAddrs
0x080400 - 0x080800 = musicAddrs
0x080800 - 0x090000 = audioData
0x090000 - 0x0a0000 = code
system dedicated 0xa0000 of RAM
```

I'm tempted to just chop this up into arbitrary 64k banks and let you expand as much as you want.
- Then internally I could flag each bank for the editor to designate what to do with it.  Similar to TIC-80's chunks-within-banks, but for the whole bank and not just a portion.
- Bank types could include: spritesheet (or tilesheet) (each uses 64k atm), tilemap (uses 128k atm), audio, code, etc...
- Then in-editor the sprite-editor, tilemap-editor, audio-editor can let you add, remove, and change what the current targetted bank is.
- Not sure where to squeeze palettes or fonts into this, or how to make them modular.
	- Maybe I could end up like I'm already doing for audio and put an allocation-table somewhere for arbitrary chunks and not just audio chunks?
	- Maybe I can give audio and misc chunks ATs?  Maybe ATs shoudl come with flags of what they are carrying?
	- Maybe one giant allocation table for all of memory?  Maybe this is getting carried way ...
	- The cart could have meta-info that the editor and file saves, but cart doesn't see, like what type of resources each page uses, or the allocation-table, or idk ...
- Just having each bank have its own sprites, tilemaps, audio and only saving the present ones will be memory efficient enough, and keep things organized, and this is what TIC-80 does.

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

## Callbacks

If the following functions are defined then they will be called from the virtual-console:

- `update()` - This is called 60 times every second.  You can call draw routines here if you would like and they should be sent out to all connected clients.

- `draw(connID, connPlayer1, connPlayer2, connPlayer3, connPlayer4)` - This is called 60 times every second per-client that is connected.
	- `connID` = a unique string for this connection.
	- `connPlayer#` = the index number (0-63) of the 4 players present on this connection.

- `onconnect(connID)` - This is called when a ROM is initialized or when a new client connects to a server listening.

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

- `save([filename])` = save cartridge to virtual-filesystem and host-filesystem.
- `open([filename])` = open cartridge.
- `reset()` = reload cartridge to its initial state.
- `quit()` = quit the entire application outright to host OS.

- `time()` = soon to be cartridge run time, currently poor mans implementation

- `#include <code-to-insert>` = Ok reluctantly I'm adding an `#include` preprocessor.  It is only applied upon `n9a.lua` archiving carts, if you extract the cartridge then you will see the code already inserted. I'll replace it with multi-file storage and a proper `require` someday.

## memory

- `peek(addr)` = read 1 byte from memory.
- `peekw(addr)` = read 2 bytes from memory.
- `peekl(addr)` = read 4 bytes from memory.
- `poke(addr, value)` = write 1 byte to memory.
- `pokew(addr, value)` = write 2 bytes to memory.
- `pokel(addr, value)` = write 4 bytes to memory.
- `memcpy(dst, src, len)` = copy from `src` to `dst`, sized `len`.
- `memset(dst, val, len)` = set memory in `dst` to uint8 value `val`, size in bytes `len`.  OOB ranges will copy a value of 0.
- `mget(x, y)` = Read the uint16 from the current tilemap address at x, y.  Out of bounds coordinates return a value of 0.
- `mset(x, y, value)` = Write a uint16 to the current tilemap address at x, y.
- `pget(x, y)` = returns the color/value at this particular x, y in the framebuffer, either a 16bit or 8bit value depending on the video mode.
- `pset(x, y, c)` = sets the color/value at this particular x, y in the framebuffer , either a 16bit or 8bit value depending on the video mode.

While Pico8 has the `reload` and `cstore` functions for copying to/from RAM to ROM, and Tic80 has the `sync` function for doing similar, I am tempting myself with the idea of just using a different address range.
But how to do this in conjunction with multiple banks, a feature that Tic80 also has, especially multiple VRAM banks.  I do like the idea of having multiple VRAM banks accessible with `spr` and `map` functions.

## graphics

- `flip()` = flip the framebuffer, and wait until the next 60Hz frame to begin.
- `cls([colorIndex])` = Clears the screen to the palette index at `color`.
- `pal(i, [value])` = If value is not provided then returns the uint16 RGBA 5551 value of the palette entry at index `i`.  If value is provided then the palette entry at `i` is set to the value.
- `rect(x, y, w, h, [colorIndex])` = draw solid rectangle
- `rectb(x, y, w, h, [colorIndex])` = draw rectangle border
- `elli(x, y, w, h, [colorIndex])` = draw a solid filled ellipse.  If you want to draw a circle then you have use an ellipse.
- `ellib(x, y, w, h, [colorIndex])` = draw a ellipse border.
- `tri(x1, y1, x2, y2, x3, y3, [colorIndex])` = draw a solid triangle.
- `tri3d(x1, y1, z1, x2, y2, z2, x3, y3, z3, [colorIndex])` = draw a solid triangle.
	- x1,y1,z1,x2,y2,z2,x3,y3,z3 = triangle coordinates
- `ttri3d(x1, y1, z1, x2, y2, z2, x3, y3, z3, u1, v1, u2, v2, u3, v3, [sheetIndex=0, paletteIndex=0, transparentIndex=-1, spriteBit=0, spriteMask=0xFF])` = draw a triangle textured with a sprite/tile sheet.
	- x1,y1,z1,x2,y2,z2,x3,y3,z3 = triangle coordinates
	- u1,v1,u2,v2,u3,v3 = texture coordinates
	- sheetIndex = sheet to use, 0 = sprite sheet, 1 = tile sheet, default 0.
- `line(x1, y1, x2, y2, [colorIndex])` = draw line.
- `line3d(x1, y1, z1, x2, y2, z2, [colorIndex])` = draw line but with z / perspective.
- `spr(spriteIndex,screenX,screenY,[tilesWide,tilesHigh,paletteIndex,transparentIndex,spriteBit,spriteMask,scaleX,scaleY])` = draw sprite
	- spriteIndex = which sprite to draw.
		- Bits 0..4 = x coordinate into the 32x32 grid of 8x8 tiles in the 256x256 sprite/tile sheet.
		- Bits 5..9 = y coordinate " " "
		- Bit 10 = whether to use the sprite sheet or tile sheet.
		- Bits 11... = represent which bank to use (up to 32 addressable).
	- screenX, screenY = pixel location of upper-left corner of the sprite
	- tilesWide, tilesHigh = the size of the sprite in the spritesheet to draw, in 8x8 tile units.
	- paletteIndex = a value to offset the colors by.  this can be used for providing high nibbles and picking a separate palette when drawing lower-bpp sprites.
	- transparentIndex = an optional color to specify as transparent.  default is -1 to disable this.
	- spriteBit = which bitplane to draw.  default is start at bitplane 0.
	- spriteMask = mask of which bits to use.  default is 0xFF, in binary 1111:1111, which uses all 8 bitplanes.
		- the resulting color index drawn is `(incomingTexelIndex >> spriteBit) & spriteMask + paletteIndex`
	- scaleX, scaleY = on-screen scaling.
- `quad(screenX, screenY, w, h, tx, ty, tw, th, sheetIndex, paletteIndex, transparentIndex, spriteBit, spriteMask)` = draw arbitrary section of the spritesheet.  Cheat and pretend the PPU has no underlying sprite tile decoding constraints.  Equivalent of `sspr()` on pico8.
	- screenX, screneY = pixel location of upper-left corner of the sprite-sheet to draw
	- w, h = pixels wide and high to draw.
	- tx, ty = sprite sheet pixel upper left corner.
	- tw, th = sprite sheet width and height to use.
	- sheetIndex = sheet index. 0 for sprite sheet, 1 for tile sheet.  default 1.
	- paletteIndex = palette index offset.
	- transparentIndex = transparent index to use.
	- spriteBit, spriteMask = same as `spr()`
- `map(tileX, tileY, tilesWide, tilesHigh, screenX, screenY, mapIndexOffset, draw16x16Sprites, sheetIndex)` = draw the tilemap.
	- I am really tempted to swap out `tileX,tileY` with just tileIndex, since that's what `mget` returns and what the tilemap stores.  I know pico8 and tic80 expect you to split up the bits every time you call this, but I don't see the reason...
	- mapIndexOffset = global offset to shift all map indexes.
	- draw16x16Sprites = the tilemap draws 16x16 sprites instead of 8x8 sprites.
	- sheetIndex = the sheet to use.  0 = sprite, 1 = tile, default to 1.
- `text(str, x, y, fgColorIndex, bgColorIndex, scaleX, scaleY)` = draw text.  I should rename this to `print` for compat reasons.
- `mode(i)` = set video mode.  The current video modes are:
	- 0 = 16bpp RGB565, needed for blending
	- 1 = 8bpp Indexed, not capable of blending, but capable of modifying the framebuffer palette (like the other fantasy consoles allow)
	- 2 = 8bpp RGB332.
- `clip([x, y, w, h])` = clip screen region.  `clip()` resets the clip region.
- `blend([i])` = Set blend mode.  Default value is 0xff corresponding to no blending.  The current blend modes are:
	- 0xff = none
	- 0 = addition with framebuffer
	- 1 = average with framebuffer (addition then half)
	- 2 = subtract from background
	- 3 = subtract-then-half with background
	- 4 = addition with constant color
	- 5 = average with constant color
	- 6 = subtract from constant color
	- 7 = subtract-then-half with constant color
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
|`delete=64`       |`insert=65`       |`pageup=66`       |`pagedown=67`     |`home=68`         |`end=69`          |`mouse_left=70`   |`mouse_right=71`  |
|`jp0_up=72`       |`jp0_down=73`     |`jp0_left=74`     |`jp0_right=75`    |`jp0_a=76`        |`jp0_b=77`        |`jp0_x=78`        |`jp0_y=79`        |
|`jp1_up=80`       |`jp1_down=81`     |`jp1_left=82`     |`jp1_right=83`    |`jp1_a=84`        |`jp1_b=85`        |`jp1_x=86`        |`jp1_y=87`        |
|`jp2_up=88`       |`jp2_down=89`     |`jp2_left=90`     |`jp2_right=91`    |`jp2_a=92`        |`jp2_b=93`        |`jp2_x=94`        |`jp2_y=95`        |
|`jp3_up=96`       |`jp3_down=97`     |`jp3_left=98`     |`jp3_right=99`    |`jp3_a=100`       |`jp3_b=101`       |`jp3_x=102`       |`jp3_y=103`       |
...
etc up to `jp63`

Keyboard state is read from the local machine.  Remote connections can only send joypad input.

- `btn(buttonCode, player)`, `btnp(buttonCode, player, [hold], [period])`, `btnr(buttonCode, player)` = same for emulated-joypad-buttons-on-keyboard.
This is a compatability/convenience function that remaps the button+player codes to the corresponding `jpX_YYY` key codes.
The button codes are as follows:

|                  |                  |                  |                  |                  |                  |                  |                  |
|------------------|------------------|------------------|------------------|------------------|------------------|------------------|------------------|
|`up=0`            |`down=1`          |`left=2`          |`right=3`         |`a=4`             |`b=5`             |`x=6`             |`y=7`             |

- `mouseX, mouseY, scrollX, scrollY = mouse()` = get the current mouse state.  mouse x,y are in framebuffer coordinates.

Mouse state is read from the local machine.  Remote connections can only send joypad input.

## other globals, maybe I'll take some out eventually:

- `tostring`
- `tonumber`
- `select`
- `type`
- `error`
- `pairs`
- `ipairs`
- `getfenv`
- `setfenv`
- `tstamp` = `os.time`
- `ffi` = the luajit ffi library.  Probably going away soon.
- tables:
	- `bit` = luajit's bit library.
	- `assert` = my [lua-ext](https://github.com/thenumbernine/lua-ext) assert object.
	- `math` = my [lua-ext](https://github.com/thenumbernine/lua-ext) math library.
	- `table` = my [lua-ext](https://github.com/thenumbernine/lua-ext) table library.
	- `string` = my [lua-ext](https://github.com/thenumbernine/lua-ext) string library.
	- `coroutine` = my [lua-ext](https://github.com/thenumbernine/lua-ext) coroutine library.
	- `app` = the NuMo9 app object itself.  Probably going away soon.

# Editor

From the menu you can select "to editor" to get to the editor.  Press again to get back to gameplay.

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

To start a server from the command line:
```
luajit run.lua <cart.n9> -e "listen()"
```

To connect to a server from the command line:
```
luajit run.lua -e "connect'<address>'"
```

# CLI args:

`-e "<cmd>"` = run `<cmd>` upon initialization.

`-window <width>x<height>` = initialize window with specified width and height.

`-nosplash` = disable fantasy-console splash-screen.

`-editor` = start in editor.

`-gl <gl version>` = use GL library, options are `OpenGL`, `OpenGLES3`.

`-glsl <glsl version>` = use GLSL version.  This is your `#version` pragma that goes in your GLSL code.

`-noaudio` = don't use audio.

... any other arguments are assumed to be the input cartridge file to load.

# Cartridges

All my cartridge files are in `.png`. format.  If you want to distribute them as an image, just rename them from `.n9` to `.n9.png`.  To pack and unpack them use the `n9a.lua` script.

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

To convert a PNG-encoded cartridge to its binary ROM format:
```
luajit n9a.lua n9tobin cart.n9
```

To convert the binary ROM back to a PNG-encoded cartridge:
```
luajit n9a.lua binton9 cart.bin
```

# Pico8-Compatability

To convert a Pico8 cartridge to a local directory of unpacked n9 contents:
```
luajit n9a.lua p8 cart.p8
```

To convert a Pico8 to Numo9 cartridge and run it:
```
luajit n9a.lua p8run cart.p8
```

Pico8 compatability has most basic functions covered but still fails at some edge cases.
- certain string escape characters don't work
- certain machine-specific peeks and pokes don't work

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
- upon fantasy console startup the first few frames skip ...
- waveforms
	- BRR
	- with this comes looping-sample info being stored in the BRR ... should I also?
- music
	- needs echo effect
	- needs ADSR
	- when converting p8 to n9 music tracks that play two sfxs of different durations, I haven't finished that yet ...
	- currently the music track data is delta encoded, but it handles new values as changes come in, so if the sfxID starts at zero then it won't be delta-encoded (unless you add an extra zero to the delta data) or alternatively (BETTER) don't add the extra zero, and instead have the music ... play on sfx ID initially?  only on non-zero vol channels? (then i have to process a whole first frame first)?  or only on isPlaying channels?  idk...
- input
	- mouse wheel returned in mouse() function.
- menu
	- draw mouse / touch regions
	- transparent menu
- graphics:
	- relocatable framebuffer / sprite pages.  allow the framebuffer to write to the sprite sheet.
	- multiple sprite pages, not a separate 'spriteSheet' and 'tileSheet', but just an arbitrary # of pages.
	- sprite renderer still clips into neighboring sprites.
- editor:
	- add multi-bank support to editor.
	- copy/paste on the tilemap.
		- copy/paste tilemap entries themselves
		- paste sprites into the tilemap, then automatically quantize their sprites and palettes.. Just need to copy most of this from my `convert-to-8x8x4bpp` repo.
		- ... of text / number tables
	- flag for pen / paste / bucket fill clip-to-view-area or not
	- tilemap bucket fill, pen size, and basically all the sam edit functionality as the sprite editor
	- scroll to zoom
	- sfx tab
		- any kind of editing at all
		- paste in wave files
	- music tab
		- any kind of editing at all
		- paste in midi files ... but how to correlate instruments with your wave samples?  can midi files save wave data themselves?
	- editor+memory ... for live editing during netplay, the editor needs to see the live data.
		... but for editing live data during single-player, you will see out-of-sync data that has been since modified by the game (like when object-init tiles are spawned and cleared).
		... so to fix this I added a reset button on the rhs that you have to *always push* every time you edit single-player content ...
		... the other route to go that I don't want to do is always auto-reset when editing single-player, and don't auto-reset when editing multipalyer ...
		... another option is put the RAM and ROM both in addressible memory (to get around the reload/cstore API issue), ... but then what would the editor be editing?  the current RAM state, to-be-flushed-to-ROM-upon-save (what it's doing now), or the ROM state, or what?
- memory
	- reset, memcpy, and the pico8 functions cstore, and reload.
		Real cartridge consoles just gave separate address space to the cartridges, then you just copy between your RAM and your ROM addresses.
		Fantasy consoles seem to be keeping an extra copy of the cartridge in memory and accessing it through these functions.
		Maybe I will put the ROM in addressible space and just have load/reset perform an initial copy from ROM to RAM space. How about ROM at 0xC00000 or so?
		Maybe I'll think more on this as I think about spriteSheet vs tileSheet vs multiple sheets vs multiple arbitrary-purpose banks ...
- netplay
	- sending too much data / too big of delta cmds gets desyncs ... I can easily push cmds into the next frame and just give a client a single bad frame instead of desyncing them fully ...
	- persistent memory per cart by checksum
	- multiplayer persistent memory per client ... how to associate and how to secure
	- still have some issues where temporary / single-frame cmds like map changes aren't getting reflected ...

- Right now browser embedding is only done through luajit ffi emulation, which is currently unplayably slow.  Work on porting LuaJIT, or implementing a faster (web-compiled maybe?) FFI library in the web-compiled Lua.  Or see if WebVM.IO will support a GLES3-WebGL2 wrapper library.
- package libzip as well, and auto download updated code from github.  maybe start using versions too?  everything is alpha right now so
- Some day I should cut off cartridge access to `app`, `ffi`, etc.  I like having them around for `offsetof`'ing fields to get locations in RAM, which are subject to change while this is in alpha.  Should I introduce constant variables with the address names instead, and then hide ffi?
- Cart browser.
- Still need to make the draw message history to be per-connection, and need to send draw-specific commands to their specific connections.
- give the UI its own font-tex just like its got its own palette

# Things I'm still debating ...
- Right now netplay is just reflecting server draw commands and input buttons.  Should I support separate render screens as well, so that players in the same game can watch separate things?  Then maybe turn this into a giant MMO console?
- Right now the keypad is UP DOWN LEFT RIGHT A B X Y ... should I add L R as well, to be like SNES?  Should I add L2 R2?  Should I add start/select?
- What's a good default keyboard configuration?  I'm going with Snes9x's.
- Right now editor tilemap is 8x8 tiles by default ... maybe default to 16x16?
- How to organize the UX of the running game, the console, the menu, the editor, and netplay ...
- matortho and matfrustum have extra adjustments to pixel space baked into them. Yay or nay?
- How should audio + menu system + editor work?  i have audio keep playing, and only playing audio through the editsfx/editmusic stops it.  trying to mediate editor vs live gameplay.
- The reset button on the editor ... and editing live content vs editing cartridge content ... and editing during netplay whatsoever ... and callbacks upon editor-write for insta-spawning objects from tilemap data ... this and multicart/bank and sync() function ...
- ROM size constraints overall, especially with respect to audio and video.  Fantasy consoles usually don't do much for letting you extend past their given single spritesheet, tilesheet, tilemap, etc.  
	In reality cartridge games would come with multiple banks dedicated to audio or video and swap them in and out of memory at different times.  How extensible should I make my cartridges?
- If I'm going to continue with the SNES theme then I'm going to need a lot more than 64k for storing all audio.  
	SNES just had 64k of ARAM active at a time, but for allll samples, often it could get into the MBs ...
	What if I just had arbitrary banks, and in the editor you pick what you want to use them for ... code | sprite/tile sheets | tilemaps | audio | etc
- <8bpp interleaved instead of planar.  In fact it's tempting to get rid of the whole idea of a 2D texture and just make all textures as a giant 1D texture that the shader unravels.  
	This means redoing the tiles-wide and high of the sprite and map draw functions.
