# Fantasy Console

Screen framebuffer is 256x256x24bpp RGB.

Screen framebuffer 8bpp color index is lookup into a 256 color palette.

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
... and then duplicate it to another separate 256x256x8bpp for the tiles.

Tilemaps:
- [SNES hardware](https://snes.nesdev.org/wiki/Tilemaps): 32x32 tiles, each entry 16bpp specifying the spritesheet index (10 bits), palette (3 bits), priority (1 bit), hflip (1 bit), vflip (1 bit)
- I could do the same and merge the priority and palette to give it 4 bits and therefore provide the upper 4 bits on the spritesheet...
- What all can we cram into a tilemap?
	- h flip (1 bit)
	- v flip (1 bit)
	- integer rotation (2 bits)
	- palette high bits / offset (up to 8 bits for 8bpp)
	- spritesheet index (2N bits for 2^N x 2^N spritesheet)
Mine ...
... 256x256x8bpp for the tilemap (
	then use the tilemap shift to access dif parts?

	... or should I use 16bpp so I can access all 10bpp of 32x32 indexes into 256x256 of 8x8 sprites?
	... or should I resize the sprite tex to accomodate to all bits?  256x8 = 2048, so I could make the sprite sheet 2048x2048x8bpp , with 8x8 sprites, so that a 16bpp tilemap can index into it ...
)

Font is from [Liko-12](https://liko-12.github.io/)

Total raw memory ...
sprites = 256x256x8 = 64k
tilemap = 256x256x8 = 64k
code = ???
music = ???
sound = ???


# API so far ...

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
