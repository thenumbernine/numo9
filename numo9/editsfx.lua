local Editor = require 'numo9.editor'

local EditSFX = Editor:subclass()

function EditSFX:update()
	EditSFX.super.update(self)

--[[
TODO to be like other fantasy console editors
waveforms: pico8 uses 8, 

https://skyelynwaddell.github.io/tic80-manual-cheatsheet/
tic80 has 16 waveforms
- each is 32 x 4-bit values. 

64 sound effects:
- speed
- left vs right speaker flags
- per each time interval
	- which sfx is being played
	- what volume to use
	- what pitch to adjust
	- arpegio

TODO to be like SNES ...
--]]
end

return EditSFX 
