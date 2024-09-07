# Fantasy Console

Screen is 256x256x8bpp. I'm a SNES fan.

Screen 8bpp is lookup into a 256 color palette.
Palettes are 16 sets of 16 colors stored in 5551 RGBA format.

Sprites are 8x8x4bpp.  When drawing a sprite, it or's the pixels with an upper 4bpp that you can specify via API.

Sprite Sheets / VRAM is 
... 256x256x4bpp for the sprite sheet (
	8x8x4bpp sprites, 
		so 5 bits for the x and 5 bits for the y sprite lookup
		so sprite lookup is 10 bits
)
	... snes used 128x128 for vram right?  how did it do that ... 4 layers or something?

... 256x256x8bpp for the map (
	implicit lookup into the sprite table?
	using (map byte value, fixed value)?
)

Not sure how I will do blending or masking just yet.

Font is from [Liko-12](https://liko-12.github.io/)
