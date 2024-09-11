# Fantasy Console

I thought I'd make a fantasy console with all the LuaJIT binding code and libraries I have laying around.

## What's unique about this one?

It's strictly LuaJIT.  No compiler required.

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
let the editor edit *multiple* sprite sheets
... but only allow one to be used at a time.
that's how the old consoles worked, right?

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


# Inspiration for this:
- https://www.pico-8.com/
- https://tic80.com/
- https://pixelvision8.itch.io/
- https://github.com/emmachase/Riko4

# Some hardware spec docs:
- https://8bitworkshop.com/blog/platforms/nintendo-nes.md.html
- https://snes.nesdev.org/wiki/Tilemaps
- https://www.raphnet.net/divers/retro_challenge_2019_03/qsnesdoc.html
- https://www.coranac.com/tonc/text/hardware.htm
