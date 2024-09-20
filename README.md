[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>

# Fantasy Console

I thought I'd make a fantasy console with all the LuaJIT binding code and libraries I have laying around.

## What's unique about this one?

It's strictly LuaJIT.  No compiling required.

## Build Instructions.

Nope, none.  Just run LuaJIT.  It should ship with the binaries of that.  If you don't trust them you can rebuild and re-run your own LuaJIT.  All the code is readable and modifyable for your convenience.

There are a few libraries that NuMo9 is dependent upon (SDL2, libpng, etc).  I'm working on the definitive list.  Those should also be packaged, or you can rebuild them yourself as well.

# Hardware

### Framebuffer

Screen framebuffer is 256x256x16bpp RGB565.

This is to support blending effects, which are on the TODO list, once I figure out something close enough to SNES.

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

I'm storing these values in RAM, however there's no good way to modify them just yet.
I'm tempted to use 8.8 fixed precision just like the SNES did ...

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
0x07024c - 0x070255 = keyPressFlags
0x070255 - 0x07025e = lastKeyPressFlags
0x07025e - 0x0702ea = keyHoldCounter
0x0702ea - 0x0702ee = mousePos
0x0702ee - 0x0702f2 = lastMousePos
0x0702f2 - 0x0702f6 = lastMousePressPos
0x0702f6 - 0x0702f7 = lastMouseButtons
0x0702f7 - 0x0702f8 = mouseButtons
system dedicated 0x702f8 of RAM
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

- `run()` = run loaded cartridge
- `stop()` = stop all execution and drop into console mode

- `save([filename])` = save cartridge to virtual-filesystem and host-filesystem
- `load([filename])` = load cartridge
- `reset()` = reload cartridge to its initial state.
- `quit()` = quit the entire application outright to host OS.

- `time()` = soon to be cartridge run time, currently poor mans implementation

## memory

- `peek, peekw, peekl, poke, pokew, pokel` = read/write memory 1, 2, or 4 bytes at a time.
- `mget, mset` = read/write uint16's from/to the tilemap.  

## graphics

- `cls([color])` = clear screen.
- `clip([x, y, w, h])` = clip screen region.  `clip()` resets the clip region.
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

## mode7:

- `matident()` = set the transform matrix to identity
- `mattrans([x],[y],[z])` = translate the transform matrix by x,y,z.  Default translate is 0.
- `matrot(theta,[x,y,z])` = rotate by theta radians on axis x,y,z.  Default axis is 0,0,1 for screen rotations.
- `matscale([x],[y],[z])` = scale by x,y,z.  Default scale is 1.
- `matortho(left,right,bottom,top,[near,far])` = apply orthographic transform.
- `matfrustum(left,right,bottom,top,near,far)` = apply frustum perspective transform.
- `matlookat(eyeX,eyeY,eyeZ,camX,camY,camZ,upX,upY,upZ)` = transform view to position at camX,camY,camZ and look at eyeX,eyeY,eyeZ with the up vector upX,upY,upZ.

## input:

- `key(code) keyp(code) keyr(code)` = Returns true if the key code was pressed.
	Code is either a name or number.
	The number coincides with the console's internal scancode bit offset in internal buffer.

	Key code numbers:

|                |                |                |                |                |                |                |                |
|----------------|----------------|----------------|----------------|----------------|----------------|----------------|----------------|
|a=0             |b=1             |c=2             |d=3             |e=4             |f=5             |g=6             |h=7             |
|i=8             |j=9             |k=10            |l=11            |m=12            |n=13            |o=14            |p=15            |
|q=16            |r=17            |s=18            |t=19            |u=20            |v=21            |w=22            |x=23            |
|y=24            |z=25            |0=26            |1=27            |2=28            |3=29            |4=30            |5=31            |
|6=32            |7=33            |8=34            |9=35            |minus=36        |equals=37       |leftbracket=38  |rightbracket=39 |
|backslash=40    |semicolon=41    |quote=42        |backquote=43    |comma=44        |period=45       |slash=46        |space=47        |
|tab=48          |return=49       |backspace=50    |up=51           |down=52         |left=53         |right=54        |capslock=55     |
|lctrl=56        |rctrl=57        |lshift=58       |rshift=59       |lalt=60         |ralt=61         |lgui=62         |rgui=63         |
|delete=64       |insert=65       |pageup=66       |pagedown=67     |home=68         |end=69          |                |                |

- `btn, btnp, btnr` = same for emulated-joypad-buttons-on-keyboard
- `mouse()` = get the current mouse state.

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

# Editor

Code page. Should do what you would expect.  Ctrl(/Apple)+X=cut C=copy V=paste A=select-all.

Sprite page. Click and drag on the spritesheet to select arbitrary rectangles of sprites.
Controls for selecting sprite bitness and bitplane.
Toggle for editing the sprite sheet vs the tilemap sheet.
When you paste an image, it will quantize colors to the current palette bitness, always excluding the UI colors.  You can currently toggle whether it matches colors to the current palette or if it generates a new palette.

Tilemap page.  Click the 'T' to drop down the tilemap for selecting tiles.  Click the 'X' to toggle 8x8 vs 16x16 tiles.

Hold spacebar and move mouse to pan over any image window.

SFX page is WIP

Music page is WIP

# Cartridges

All my cartridge files are in `.png`. format.  To pack and unpack them use the `n9a.lua` script.

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

To convert a Pico8 cartridge to a local directory of unpacked n9 contents:
```
luajit n9a.lua p8 cart.p8
```

To convert a Pico8 to Numo9 cartridge and run it:
```
luajit n9a.lua p8run cart.p8
```

Pico8 Compatability is at 90%
- pget doesn't fully work, since I'm not using an indexed framebuffer.
- certain escape characters don't work
- certain machine-specific peeks and pokes don't work

# Inspiration for this:
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

# TODO
- sfx and music
- langfix needs better error-handling, line and col redirection from transpiled location to rua script location.
- Right now browser embedding is only done through luajit ffi emulation, which is currently slow.  Work on porting LuaJIT, or implementing a faster (web-compiled maybe?) FFI library in the web-compiled Lua.
