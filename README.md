# Fantasy Console

I thought I'd make a fantasy console with all the LuaJIT binding code and libraries I have laying around.

## What's unique about this one?

It's strictly LuaJIT.  No compiler required.

# Hardware

### framebuffer

Screen framebuffer is 256x256x16bpp RGB.

I was tempted to do color lookup, but all that lets you do is shift palette after-the-fact with written framebuffer contents.
You can already shift the palette as you draw the sprites, so this is a bit redundant.
And then I wanted to add the SNES blending effects.
And here we are.

If I really want to simulate hardware exactly then maybe I'll store a disting 8bpp output buffer in my virtual hardware's memory ...
... and then on modern hardware / non-embedded I would draw this to *another* RGB buffer that goes on screen.

Ok I already went back once on this.
Originally it was an 8bpp buffer to support on-the-fly palette manipulation like NES allows.
This also lets you peek and poke pixels into the framebuffer directly.
But then I thought "I want SNES blending effects" ... and that can only be done with either a truecolor framebuffer or with a RGB framebuffer ...
... how does the SNES solve this?  Turns out it just doesn't have a framebuffer, period.   Crazy, right?
In its defense, you can always peek and poke the tilemap and tiles and have the same effect.
So I'm on the fence, maybe I'll go back to an 8bpp framebuffer, or maybe I'll introduce multiple 8bpp framebuffers and simulate the blend-on-output of the SNES PPU myself,
or maybe I'll do 8bpp fb and implement blending-as-dithering.
or maybe I'll use a rgb-332 fb and do truecolor blending and still be 8bpp ...
Idk.

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

### tilemap

Tilemaps: 256x256x16bpp index into the tile table.
Tilemap bits:
- 10: lookup into the tile texture
- 4: palette high 4 bits
- 1: hflip
- 1: vflip

### Mode7

What's a SNES-era emulator without mode7?  So I added some matrix math.  Really my API is just a direct copy from original OpenGL, without a matrix stack.

So far the API has ...

`mvmatident`,
`mvmattrans`,
`mvmatrot`,
`mvmatscale`,
`mvmatortho`,
`mvmatfrustum`,
`mvmatlookat`,
`projmatident`,
`projmattrans`,
`projmatrot`,
`projmatscale`,
`projmatortho`,
`projmatfrustum`,
`projmatlookat`,

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

# API

- `print(...)` = print to console ... not print to screen ... gotta fix that
- `write(...)` = print to console without newline
- `run()` = run loaded cartridge
- `save([filename])` = save cartridge
- `load([filename])` = save cartridge
- `quit()` = shorthand for `os.exit()`
- `time()` = soon to be cartridge run time, currently poor mans implementation

## graphics

- `cls([color])` = clear screen
- `rect(x1, y1, x2, y2, [color])` = draw solid rectangle
- `rectb(x1, y1, x2, y2, [color])` = draw rectangle border
- `sprite( ... )` = draw sprite
- `text( ... )` = draw text.  I should rename this to `print` for compat reasons.
- `rect(...)`
- `rectb(...)`
- `sprite(...)`
- `key(code)`

## input:
- `keyp(code)` = Returns true if the key code was pressed. 
	Code is either a name or number.
	The number coincides with the console's internal scancode bit offset in internal buffer.

	Key code numbers:
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

# Some SNES hardware spec docs:
- https://snes.nesdev.org/wiki/Tilemaps
- https://www.raphnet.net/divers/retro_challenge_2019_03/qsnesdoc.html
