# Fantasy Console

Screen is 256x256x8bpp. I'm a SNES fan.

Screen 8bpp color index is lookup into a 256 color palette.
Palettes are 16 sets of 16 colors stored in 5551 RGBA format.

Thinking about it, if the palette is solely used for the screen blit then I don't need to use the palette alpha channel.
And if I use the palette alpha then that's the only reason I would need the palette alpha when drawing to the screen.
So for now I'll ignore palette alpha and just use transparency by specifying a color per sprite.
This means you get to use all your palettes in the final screen draw.
But it also means your sprites no longer store their own transparency info -- that will have to be provided via the draw function.
Not sure how I will do blending or masking just yet.

Sprites are 8x8.
Sprites can be anywhere from 1bpp to 8bpp.
When drawing a sprite, it shifts the texel color index with a palette offset that you can specify via API.
This allows you to access all 256 colors with sprites of <8bpp.

Sprite Sheets / VRAM is 
... 256x256x8bpp for the sprite sheet (
	8x8x8bpp sprites, 
	so 5 bits for the x and 5 bits for the y sprite lookup
	... should I also provide a tilemap shift like I do a palette shift?
)
... snes used 128x128 for vram right?  how did it do that ... 4 layers or something?

... 256x256x8bpp for the tilemap (
	implicit lookup into the sprite table?
	4bits per x and 4 bits per y?
	then use the tilemap shift to access dif parts?
)


Font is from [Liko-12](https://liko-12.github.io/)

Total raw memory ...
sprites = 256x256x8 = 64k
tilemap = 256x256x8 = 64k
code = ???
music = ???
sound = ???
