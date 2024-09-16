# Fantasy Console

I thought I'd make a fantasy console with all the LuaJIT binding code and libraries I have laying around.

Fantasy consoles are a fantasy because of a few things:
- Framebuffer.  Old Apple 2's and terminal computers had them.  Old consoles like NES/SNES didn't.  It's a waste of resources.  Just draw your sprites directly to the screen.
	Want truecolor blending like SNES had?  Where are you going to store those RGB channels? Especially when those specs are beyond the scope of the current hardware, which only holds indexed palettes.
	Want to draw points, lines, rectangles, circles to the screen?  On a Super NES with Mario Paint?  Get ready to use all your tilemap to point to your spritesheet to store your improv framebuffer, because the system doesn't have a dedicated one.
- Spritesheets.  These are supposed to be linear in memory: Each 32 bytes is a new sprite.  But what do we have here? Sprites are stored row-by-row for the *entire spritesheet*.  Imagine all the paging. That'd be unheard of back in the old days.
	The `sspr()` function for mid-sprite/overlapping-sprite texel access would not be there.  In its place you would have to fill out the tilemap yourself, or use some other video mode to draw collections of sequential tiles.
- Memory.
	In pico8 there's functionality for reading and *writing* to the ROM.
	In the console days,  your address space was RAM and ROM - there was no need to copy the entire ROM into the RAM because you could already address it - but if you really wanted to, yes you could, and the you have duplicated memory, which is once again a luxory.
	Or maybe these are supposed to represent IO functions of reading and writing to disks.  Ever done that on a system in the 80s?  Be prepared to wait a few minutes.  So hats off to tic80 for restricting cartridge access functions to just `reset()`, which reloads the whole thing, as this would be a practical API on such a system back in the old days.  Sure you can insert disk 2 to continue your quest, but not without a loading screen.
	In the 80s terminal computers you'd have RAM and IO-filesystem, which is slow.  You need load screens.
	In the 80s consoles you'd have RAM and ROM, which is fast, but ... it's ROM, you can't write to it, no `cstore()` function.
	In pico8 you have RAM, ROM, and IO-filesystem.  This is an over-indulgance of the 80s PC/console era.

## What's unique about this one?

It's strictly LuaJIT.  No compiling required.

## Build Instructions.

Nope, none.  Just run LuaJIT.  It should ship with the binaries of that.  If you don't trust them you can rebuild and re-run your own LuaJIT.  All the code is readable and modifyable for your convenience.

There are a few libraries that NuMo9 is dependent upon (SDL2, libpng, etc).  I'm working on the definitive list.  Those should also be packaged, or you can rebuild them yourself as well.

# Hardware

### Framebuffer

Screen framebuffer is 256x256x16bpp RGB.

Originally it was an 8bpp buffer to support on-the-fly palette manipulation like NES allows.
This also lets you peek and poke pixels into the framebuffer directly.
But then I thought "I want SNES blending effects" ... and that can only be done with either a truecolor framebuffer or with a RGB framebuffer ...
... how does the SNES solve this?  Turns out it just doesn't have a framebuffer, period.   They blend content as it is being sent directly to the output.  Crazy, right?
In its defense, you can always peek and poke the tilemap and tilesheet and have the same effect.

So the NES/SNES has no framebuffer.  What does this mean?
It means that all the fantasy console commands ... `pget, pset, line, rect, circ, oval` ... all would get thrown out the window.
You can *only* draw to the screen with sprites or tiles.
The SNES could replicate this by dedicating all of the sprite and tilemap to video output, and in that way you've got your framebuffer (Mario Paint)...
But then what is left available for sprite rendering?

The other fantasy consoles do set aside memory for a framebuffer.  But their output is usually only 4bpp.
Maybe I should set aside framebuffer memory too?

### sprites / tiles

Sprites are 8x8 pixels.
Sprite bpp can be anywhere from 1bpp to 8bpp.

Palette is a set of 256 colors stored in 5551 RGBA format.

Thinking about it, if the palette is solely used for the screen blit then I don't need to use the palette alpha channel.
And if I use the palette alpha then that's the only reason I would need the palette alpha when drawing to the screen.
So for now I'll ignore palette alpha and just use transparency by specifying a color per sprite.
This means you get to use all your palettes in the final screen draw.
But it also means your sprites no longer store their own transparency info -- that will have to be provided via the draw function.

SNES:
When drawing a sprite, you can specify the bitplane and bpp that you want to use.
You can provide an arithmetic palette offset.  This allows you to access all 256 colors with sprites of <8bpp.

Sprite Sheets / VRAM.
... I'm going to do 256x256x8bpp for the sprite sheet.
Size will be
That will be 32x32 of 8x8x8bpp sprites,
so 5 bits for the x and 5 bits for the y sprite lookup.

... and then duplicate it to another separate 256x256x8bpp for the tile memory.

TODO
Let the editor edit *multiple* sprite sheets
... but only allow one to be used at a time.
That's how the old consoles worked, right?

double TODO
redo the sprite sheet renderer to store / retrieve memory sequentially.  None of this scanline-per-all-sprites-stored-together.

Right now I'm putting the font at the end of the sprite table.  Idk why.  Maybe I'll move it into non-cartridge memory somewhere.  But I don't want to bind an extra texture.  So maybe I'll leave the font in the sprite table.
Maybe I'll put it at the end.
On that logic, I could also use the end of the sprite table for the palette, and cut down just one more texture bind...
And then I could pack the font even more into 4x8 (or really I could do arbitrary rectangles) and then use the clip functionality or some nonexposed rendering functionality to draw fonts.

### tilemap

Tilemaps: 256x256x16bpp index into the tile table.
Tilemap bits:
- 10: lookup into the tilesheet texture
- 4: palette high 4 bits
- 1: hflip
- 1: vflip

### Mode7 j/k

What's a SNES-era emulator without mode7?
I'm using a 4x4 transform.
So far the API has ...

`matident`,
`mattrans`,
`matrot`,
`matscale`,
`matortho`,
`matfrustum`,
`matlookat`,

... but I will probably remove the projection stuff.
It's only there to simulate the `camera` function of Pico-8, but meh, you can inverse-transform yourself.

### Palette

Palette is stored in memory as 256 entries of rgba5551.
Sprite rendering lets you specify the bit shift and bit count, and the offset into the palette.
You can use this for 4bpp drawing with an offset into the upper 4bpp of the palette, or for any other palette effects you would like.
You can also peek/poke the palette memory directly and it should update-on-the-fly.

The last 16 colors of the palette are used by the system console and editor.  You are still free to modify these.

### Font

Font is from [Liko-12](https://liko-12.github.io/)

### Memory Layout

ROM ...
sprites = 256x256x8 = 64k
tiles = 256x256x8 = 64k
tilemap = 256x256x16bpp = 128k
	... maybe I'll cut this down to just 32x32 like SNES, i.e. two screens worth, and provide an API for saving/loading screens from mem ...
	... then it'd just be 2k instead of 128k ...
code = ???
music = ???
sound = ???

RAM ...
sprites ... same
tiles ... same
tilemap ... maybe I'll make this one only 32x32 ...
code ...
music ...
sound ...
IO
	keyboard
	mouse

# Language

Yeah it uses Lua as the underlying script.  That's the whole point of this - to do it in pure LuaJIT, no need to compile anything.
__But LuaJIT doesn't support bitwise operators?__
But with my [langfix](https://github.com/thenumbernine/langfix-lua) it does!  Built on top of my Lua parser in Lua, it modifies the grammar to incorporate lots of extra stuff.

This adds to Lua(/JIT):
- bit operators: `& | << >> >>>`
- in-place operators: `..= += -= *= /= //= %= ^= &= |= ~~= <<= >>= >>>=`
- lambdas: `[args] do stmts end` for typical multiple-statement functions, `[args] expr` for single-expression functions, but for the parser to distinguish lambdas in arg lists, now you have to wrap single-expression multiple-return-arguments in one `( )`, and that means Lua syntax dictates if you want to truncate the return to a single argument you must wrap it in `(( ))`
- safe-navigation: `a?.b, a?['b'], a?(), a?.b(), a?:b(), a.b?(), a?.b?(), a:b?(), a?:b?()`
- ternary: `a ? b : c`, null-coalescence: `a ?? b` ... but between this and single-expression-lambdas there's a few edge-cases where the grammar needs extra wrapping parenthesis, so be careful with this, or just use the traditional `a and b or c`.

# API

- `print(...)` = print to console ... not print to screen ... gotta fix that
- `write(...)` = print to console without newline

- `run()` = run loaded cartridge
- `save([filename])` = save cartridge
- `load([filename])` = save cartridge
- `quit()` = shorthand for `os.exit()`
- `time()` = soon to be cartridge run time, currently poor mans implementation

## graphics

- `cls([color])` = clear screen.
- `clip([x, y, w, h])` = clip screen region.  `clip()` resets the clip region.
- `rect(x1, y1, x2, y2, [color])` = draw solid rectangle
- `rectb(x1, y1, x2, y2, [color])` = draw rectangle border
- `spr(...)` = draw sprite
- `map(...)` = draw tilemap
- `text(...)` = draw text.  I should rename this to `print` for compat reasons.
- `sprite(...)`
- `key(code)`

## input:
- `keyp(code)` = Returns true if the key code was pressed.
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

## math
- `cos(theta)` = shorthand for `math.cos(theta)`	... maybe I won't do shorthand functions like pico-8 ... tic-80 gets by without them.
- `sin(theta)` = shorthand for `math.sin(theta)`

# Cartridge IO

All my cartridge files are in `.png`. format.  To pack and unpack them use the `n9a.lua` script.

# Compatability

- I've made a 90% functioning conversion from `.p8` to `.n9` cartridges.
	There's still some things I don't know if I want to expose support of, like an indexed framebuffer that lets you modify screen palette colors after drawing them (what kind of console hardware ever did this?).
	Soon I'll start on `.tic` support as well.

# Inspiration for this:
- https://www.pico-8.com/
- https://tic80.com/
- https://pixelvision8.itch.io/
- https://github.com/emmachase/Riko4
- https://github.com/kitao/pyxel

# Some hardware spec docs:
- https://8bitworkshop.com/blog/platforms/nintendo-nes.md.html
- https://snes.nesdev.org/wiki/Tilemaps
- https://www.raphnet.net/divers/retro_challenge_2019_03/qsnesdoc.html
- https://www.coranac.com/tonc/text/hardware.htm

# TODO
- langfix needs better error-handling, line and col redirection from transpiled location to rua script location.
- sfx and music
- image clipboard support
- in-console menu system somehow ... everyone does this different I think
- some demos to prove it is legit
- Right now browser embedding is only done through luajit ffi emulation, which is currently slow.  Work on porting LuaJIT, or implementing a faster (web-compiled maybe?) FFI library in the web-compiled Lua.
