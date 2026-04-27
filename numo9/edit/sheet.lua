--[[
This will be the code editor
--]]
local ffi = require 'ffi'
local gl = require 'gl'
local assert = require 'ext.assert'
local math = require 'ext.math'
local table = require 'ext.table'
local string = require 'ext.string'
local vec2d = require 'vec-ffi.vec2d'
local vec2i = require 'vec-ffi.vec2i'
require 'ffi.req' 'c.string'	-- memcmp
local Image = require 'image'
local Quantize = require 'image.quantize_mediancut'

local clip = require 'numo9.clipboard'

local UIWidget = require 'numo9.ui.widget'
local UIButton = require 'numo9.ui.button'
local UISpinner = require 'numo9.ui.spinner'
local UILabel = require 'numo9.ui.label'
local UITextField = require 'numo9.ui.textfield'
local UIRadio = require 'numo9.ui.radio'
local UIBlobSelect = require 'numo9.ui.blobselect'
local Undo = require 'numo9.ui.undo'

local numo9_video = require 'numo9.video'
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551	-- TODO move this
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize
local spriteSize = numo9_rom.spriteSize
local spriteSheetSizeInTiles = numo9_rom.spriteSheetSizeInTiles
local clipMax = numo9_rom.clipMax
local palettePtrType = numo9_rom.palettePtrType


local uint8_t = ffi.typeof'uint8_t'

-- used by fill
local dirs = {
	{1,0},
	{0,1},
	{-1,0},
	{0,-1},
}



local SpriteSheetPicker = UIWidget:subclass()

function SpriteSheetPicker:init(args)
	SpriteSheetPicker.super.init(self, args)
end

function SpriteSheetPicker:draw(args)
	SpriteSheetPicker.super.draw(self, args)
end

function SpriteSheetPicker:update(args)
	SpriteSheetPicker.super.update(self, args)
end


local EditSheet = require 'numo9.ui':subclass()

function EditSheet:init(args)
	EditSheet.super.init(self, args)

	self.undo = Undo{
		get = function()
			-- for now I'll just have one undo buffer for the current sheet
			-- TODO palette too
			local app = self.app
			local sheetRAM = app.blobs.sheet[self.sheetBlobIndex+1].ramgpu
			local paletteRAM = app.blobs.palette[self.paletteBlobIndex+1].ramgpu
			return {
				sheet = sheetRAM.image:clone(),
				palette = paletteRAM.image:clone(),
			}
		end,
		changed = function(entry)
			local app = self.app
			local sheetRAM = app.blobs.sheet[self.sheetBlobIndex+1].ramgpu
			local paletteRAM = app.blobs.palette[self.paletteBlobIndex+1].ramgpu
			return 0 ~= ffi.C.memcmp(entry.sheet.buffer, sheetRAM.image.buffer, sheetRAM.image:getBufferSize())
			or 0 ~= ffi.C.memcmp(entry.palette.buffer, paletteRAM.image.buffer, paletteRAM.image:getBufferSize())
		end,
	}

	self:setupNewUISceneGraph()

	-- hflip, vflip, hrot, vrot
	self:addChild(UIButton{
		owner = self,
		text = 'H',
		pos = vec2d(0, 96),
		tooltip = 'hflip',
		events = {
			click = function()
				local selx = spriteSize.x * (math.min(self.spriteSelDown.x, self.spriteSelUp.x))
				local sely = spriteSize.y * (math.min(self.spriteSelDown.y, self.spriteSelUp.y))
				local selw = spriteSize.x * (math.max(self.spriteSelDown.x, self.spriteSelUp.x) + 1) - selx
				local selh = spriteSize.y * (math.max(self.spriteSelDown.y, self.spriteSelUp.y) + 1) - sely
				for j=0,selh-1 do
					local y = j + sely
					for i=0,math.floor(selw/2)-1 do
						local x1 = selx + i
						local x2 = selx + (selw - 1 - i)
						local p1 = self:getpixel(x1, y)
						local p2 = self:getpixel(x2, y)
						self:putpixel(x1, y, p2)
						self:putpixel(x2, y, p1)
					end
				end
			end,
		},
	})
	self:addChild(UIButton{
		owner = self,
		text = 'V',
		pos = vec2d(6, 96),
		tooltip = 'vflip',
		events = {
			click = function()
				local selx = spriteSize.x * (math.min(self.spriteSelDown.x, self.spriteSelUp.x))
				local sely = spriteSize.y * (math.min(self.spriteSelDown.y, self.spriteSelUp.y))
				local selw = spriteSize.x * (math.max(self.spriteSelDown.x, self.spriteSelUp.x) + 1) - selx
				local selh = spriteSize.y * (math.max(self.spriteSelDown.y, self.spriteSelUp.y) + 1) - sely
				for j=0,math.floor(selh/2)-1 do
					local y1 = sely + j
					local y2 = sely + (selh - 1 - j)
					for i=0,selw-1 do
						local x = selx + i
						local p1 = self:getpixel(x, y1)
						local p2 = self:getpixel(x, y2)
						self:putpixel(x, y1, p2)
						self:putpixel(x, y2, p1)
					end
				end
			end,
		},
	})
	self:addChild(UIButton{
		owner = self,
		text = 'L',
		pos = vec2d(0, 104),
		tooltip = 'rot-L',
		events = {
			click = function()
				local selx = spriteSize.x * (math.min(self.spriteSelDown.x, self.spriteSelUp.x))
				local sely = spriteSize.y * (math.min(self.spriteSelDown.y, self.spriteSelUp.y))
				local selw = spriteSize.x * (math.max(self.spriteSelDown.x, self.spriteSelUp.x) + 1) - selx
				local selh = spriteSize.y * (math.max(self.spriteSelDown.y, self.spriteSelUp.y) + 1) - sely
				-- this is only guaranteed to work for a square ...
				selw = math.min(selw, selh)
				selh = selw
				for j=0,math.floor(selh/2)-1 do
					for i=0,math.floor(selw/2)-1 do
						local x1, y1 = selx + i, sely + j
						local x2, y2 = selx + (selw-1-j), sely + i
						local x3, y3 = selx + (selw-1-i), sely + (selw-1-j)
						local x4, y4 = selx + j, sely + (selw-1-i)
						local p1 = self:getpixel(x1, y1)
						local p2 = self:getpixel(x2, y2)
						local p3 = self:getpixel(x3, y3)
						local p4 = self:getpixel(x4, y4)
						self:putpixel(x1, y1, p2)
						self:putpixel(x2, y2, p3)
						self:putpixel(x3, y3, p4)
						self:putpixel(x4, y4, p1)
					end
				end
			end,
		},
	})
	self:addChild(UIButton{
		owner = self,
		text = 'R',
		pos = vec2d(6, 104),
		tooltip = 'rot-R',
		events = {
			click = function()
				local selx = spriteSize.x * (math.min(self.spriteSelDown.x, self.spriteSelUp.x))
				local sely = spriteSize.y * (math.min(self.spriteSelDown.y, self.spriteSelUp.y))
				local selw = spriteSize.x * (math.max(self.spriteSelDown.x, self.spriteSelUp.x) + 1) - selx
				local selh = spriteSize.y * (math.max(self.spriteSelDown.y, self.spriteSelUp.y) + 1) - sely
				-- this is only guaranteed to work for a square ...
				selw = math.min(selw, selh)
				selh = selw
				for j=0,math.floor(selh/2)-1 do
					local y1 = sely + j
					local y2 = sely + (selh - 1 - j)
					for i=0,math.floor(selw/2)-1 do
						local x1, y1 = selx + i, sely + j
						local x2, y2 = selx + (selw-1-j), sely + i
						local x3, y3 = selx + (selw-1-i), sely + (selw-1-j)
						local x4, y4 = selx + j, sely + (selw-1-i)
						local p1 = self:getpixel(x1, y1)
						local p2 = self:getpixel(x2, y2)
						local p3 = self:getpixel(x3, y3)
						local p4 = self:getpixel(x4, y4)
						self:putpixel(x1, y1, p4)
						self:putpixel(x2, y2, p1)
						self:putpixel(x3, y3, p2)
						self:putpixel(x4, y4, p3)
					end
				end
			end,
		},
	})
	self:addChild(UIButton{
		owner = self,
		text = 'X',
		pos = vec2d(16, 128),
		tooltip = 'pal swap',
		events = {
			isset = function()
				return self.isPaletteSwapping
			end,
			click = function()
				self.isPaletteSwapping = not self.isPaletteSwapping
			end,
		},
	})
	-- adjust palette size
	self:addChild(UISpinner{
		owner = self,
		pos = vec2d(16, 200),
		tooltip = function()
			return 'pal bpp='..bit.lshift(1, self.log2PalBits)
		end,
		setValue = function(dx)
			self.log2PalBits = math.clamp(self.log2PalBits + dx, 0, 3)
		end,
	})
	-- adjust palette offset
	self:addChild(UISpinner{
		owner = self,
		pos = vec2d(16+24, 200),
		tooltip = function()
			return 'pal ofs='..self.paletteOffset
		end,
		setValue = function(dx)
			self.paletteOffset = bit.band(0xff, self.paletteOffset + dx)
		end,
	})
	-- adjust pen size
	self:addChild(UISpinner{
		owner = self,
		pos = vec2d(16+48, 200),
		tooltip = function()
			return 'pen size='..self.penSize
		end,
		setValue = function(dx)
			self.penSize = math.clamp(self.penSize + dx, 1, 5)
		end,
	})

	-- choose spriteBit
	self:addChild(UILabel{
		owner = self,
		text = '#',
		pos = vec2d(128+16+24, 12),
		fgColorIndex = 13,
		bgColorIndex = -1,
	})
	self.spriteBitTextField = UITextField{
		owner = self,
		pos = vec2d(128+16+24+5, 12),
		width = 10,
		events = {
			change = function(target, e)
				self.spriteBit = target.value
			end,
		},
	}
	self:addChild(self.spriteBitTextField)
	self.spriteBitSpinner = UISpinner{
		owner = self,
		pos = vec2d(128+16+24, 20),
		setValue = function(dx)
			self.spriteBit = self.spriteBit + dx
		end,
	}
	self:addChild(self.spriteBitSpinner)

	-- choose spriteMask
	self:addChild(UILabel{
		owner = self,
		text = '#',
		pos = vec2d(128+16+24+32, 12),
		fgColorIndex = 13,
		bgColorIndex = -1,
	})
	self.spriteBitDepthTextField = UITextField{
		owner = self,
		pos = vec2d(128+16+24+32+5, 12),
		width = 10,
		events = {
			change = function(target, e)
				self.spriteBitDepth = target.value
			end,
		},
	}
	self:addChild(self.spriteBitDepthTextField)
	self:addChild(UISpinner{
		owner = self,
		pos = vec2d(128+16+24+32, 20),
		tooltip = function()
			return 'bpp='..self.spriteBitDepth
		end,
		setValue = function(dx)
			-- should I not let this exceed 8 - spriteBit ?
			-- or should I wrap around bits and be really unnecessarily clever?
			self.spriteBitDepth = self.spriteBitDepth + dx
		end,
	})

	-- spritesheet pan vs select
	self:addChild(UIRadio{
		owner = self,
		pos = vec2d(224, 12),
		options = {'select', 'pan'},
		getSelected = function()
			return self.spritesheetEditMode
		end,
		setSelected = function(result)
			self.spritesheetEditMode = result
		end,
	})
	
	-- sprite edit area
	local x = 2
	local y = 12
	self:addChild(UILabel{
		owner = self,
		text = '#',
		pos = vec2d(x + 32, y),
		fgColorIndex = 0xfd,
		bgColorIndex = -1,
	})
	
	self.spriteSelIndexTextField = UITextField{
		owner = self,
		pos = vec2d(x + 32 + 5, y),
		width = 20,
		events = {
			change = function(target, e)
				local index = tonumber(target.value)
				if not index then return end
				
				-- hmm might be more cohesive to store a single index
				self:setSpriteSelDown(
					index % spriteSheetSizeInTiles.x,
					(index - self.spriteSelDown.x) / spriteSheetSizeInTiles.x
				)
			end,
		},
	}
	self:addChild(self.spriteSelIndexTextField)

	-- sprite edit method
	local x = 32
	local y = 96
	self:addChild(UIRadio{
		owner = self,
		pos = vec2d(x, y),
		options = {'draw', 'dropper', 'fill', 'pan'},
		getSelected = function()
			return self.spriteDrawMode
		end,
		setSelected = function(result)
			self.spriteDrawMode = result
		end,
	})
	
	-- select palette color to draw
	self:addChild(UILabel{
		owner = self,
		text = '#',
		pos = vec2d(16, 112),
		fgColorIndex = 13,
		bgColorIndex = -1,
	})
	self.paletteSelIndexTextField = UITextField{
		owner = self,
		pos = vec2d(16+5, 112),
		width = 15,
		events = {
			change = function(target, e)
				self.paletteSelIndex = target.value
			end,
		},
	}
	self:addChild(self.paletteSelIndexTextField)
	
	-- edit palette entries
	self:addChild(UILabel{
		owner = self,
		text = 'C=',
		pos = vec2d(16, 216),
		fgColorIndex = 13,
		bgColorIndex = -1,
	})

	-- update its value on self.paletteSelIndex change
	-- or on that palette index's value's change
	self.selColorValueTextField = UITextField{
		owner = self,
		pos = vec2d(16+10, 216),
		width = 20,
		events = {
			change = function(target, e)
				local result = target.value
				result = tonumber(result, 16)
				if not result then return end

				self.undo:pushContinuous()

				self:setPaletteSelIndexColor(result)
			end,
		},
	}
	self:addChild(self.selColorValueTextField)

	for _,info in ipairs{
		{
			letter = 'R',
			y = 224,
			textfield = 'selColorRedValueTextField',
			shift = 0,
		},
		{
			letter = 'G',
			y = 224+8,
			textfield = 'selColorGreenValueTextField',
			shift = 5,
		},
		{
			letter = 'B',
			y = 224+16,
			textfield = 'selColorBlueValueTextField',
			shift = 10,
		},
	} do
		self:addChild(UILabel{
			owner = self,
			text = info.letter..'=',
			pos = vec2d(16, info.y),
			fgColorIndex = 13,
			bgColorIndex = -1,
		})		
		self[info.textfield] = UITextField{
			owner = self,
			pos = vec2d(16+10, info.y),
			width = 20,
			events = {
				change = function(target, e)
					local result = target.value
					result = tonumber(result, 16)
					if not result then return end

					self.undo:pushContinuous()

					local selColorValue = self:getPaletteSelIndexColor()
					local mask = bit.lshift(0x1f, info.shift)
					selColorValue = bit.bor(
						bit.band(
							bit.lshift(result, info.shift),
							mask
						),
						bit.band(
							selColorValue,
							bit.bnot(mask)
						)
					)
					self:setPaletteSelIndexColor(selColorValue)
				end,
			},
		}
		self:addChild(self[info.textfield])
		self:addChild(UISpinner{
			owner = self,
			pos = vec2d(16+32, info.y),
			setValue = function(dx)
				self.undo:pushContinuous()
				local selColorValue = self:getPaletteSelIndexColor()
				local mask = bit.lshift(0x1f, info.shift)
				selColorValue = bit.bor(
					bit.band(
						selColorValue + bit.lshift(dx, info.shift),
						mask
					),
					bit.band(
						selColorValue,
						bit.bnot(mask)
					)
				)
				self:setPaletteSelIndexColor(selColorValue)
			end,
		})
	end
	
	self:addChild(UIButton{
		owner = self,
		pos = vec2d(16, 224+24),
		text = 'A',
		isset = function()
			local selColorValue = self:getPaletteSelIndexColor()
			local alpha = 0 ~= bit.band(selColorValue, 0x8000)
			return alpha
		end,
		events = {
			click = function()
				local selColorValue = self:getPaletteSelIndexColor()
				local alpha = 0 ~= bit.band(selColorValue, 0x8000)
				self.undo:pushContinuous()
				if alpha then	-- if it was set then clear it
					selColorValue = bit.band(selColorValue, 0x7fff)
				else	-- otherwise set it
					selColorValue = bit.bor(selColorValue, 0x8000)
				end				
				self:setPaletteSelIndexColor(selColorValue)
			end,
		},
	})

	self.alphaLabel = UILabel{
		owner = self,
		pos = vec2d(16+16, 224+24),
		fgColorIndex = 13,
		bgColorIndex = -1,
	}
	self:addChild(self.alphaLabel)

	self:addChild(UIButton{
		owner = self,
		pos = vec2d(112, 32),
		text = 'P',
		tooltip = function()
			return 'Paste Keeps Pal='..tostring(self.pasteKeepsPalette)
		end,
		isset = function()
			return self.pasteKeepsPalette
		end,
		events = {
			click = function()
				self.pasteKeepsPalette = not self.pasteKeepsPalette
			end,
		},
	})
	self:addChild(UIButton{
		owner = self,
		pos = vec2d(112, 42),
		text = 'A',
		tooltip = function()
			return 'Paste Transparent='..tostring(self.pasteTransparent)
		end,
		isset = function()
			return self.pasteTransparent
		end,
		events = {
			click = function()
				self.pasteTransparent = not self.pasteTransparent
			end,
		},
	})

	--[[
	self:guiSpinner(96, 52, function(dx)
		self.pasteTargetNumColors = bit.band(self.pasteTargetNumColors + dx)
	end, 'paste target # colors='..tostring(self.pasteTargetNumColors))
	--]]
	-- [[
	self:addChild(UITextField{
		owner = self,
		pos = vec2d(80, 32),
		width = 4*8,
		tooltip = function()
			return 'paste target # colors='..self.pasteTargetNumColors
		end,
		events = {
			focus = function(target, e)
				target.value = tostring(self.pasteTargetNumColors)
			end,
			change = function(target, e)
				self.pasteTargetNumColors = tonumber(target.value) or 0
			end,
		},
	})
	--]]

	-- TODO button for cut copy and paste as well?

	-- flags ... ???

	self.sheetBlobSelect = UIBlobSelect{
		owner = self,
		pos = vec2d(80, 0),
		blobName = 'sheet',
		valueTable = self,
		valueKey = 'sheetBlobIndex',
		setValue = function(value)
			-- for now only one undo per sheet/palette at a time
			self.undo:clear()
		end,
	}
	self:addChild(self.sheetBlobSelect)
	
	self.paletteBlobSelect = UIBlobSelect{
		owner = self,
		pos = vec2d(96, 0),
		blobName = 'palette',
		valueTable = self,
		valueKey = 'paletteBlobIndex',
		setValue = function()
			-- for now only one undo per sheet/palette at a time
			self.undo:clear()
		end,
	}
	self:addChild(self.paletteBlobSelect)

	self.spriteSheetPicker = SpriteSheetPicker{
		owner = self,
		pos = vec2d(0,0),
	}
	self:addChild(self.spriteSheetPicker)

	local private = {}
	local getset = {
		paletteBlobIndex = {
			get = function(self, k)
				return private[k]
			end,
			set = function(self, k, v)
				private[k] = v

				-- on self.paletteBlobIndex change...
				self.paletteBlobSelect.textfield.value = tostring(v)
			end,
		},
		sheetBlobIndex = {
			get = function(self, k)
				return private[k]
			end,
			set = function(self, k, v)
				private[k] = v

				-- on self.sheetBlobIndex change...
				self.sheetBlobSelect.textfield.value = tostring(v)
			end,
		},
		paletteSelIndex = {
			get = function(self, k)
				return private[k]
			end,
			set = function(self, k, v)
				local oldvalue = private[k]

				private[k] = bit.band(0xff, tonumber(v) or private[k])

				if private[k] ~= oldvalue then
					self.paletteSelIndexTextField.value = tostring(private[k])
					self:updatePaletteSelIndexColor()
				end		
			end,
		},
		spriteBit = {
			get = function(self, k)
				return private[k]
			end,
			set = function(self, k, v)
				local oldvalue = private[k]

				private[k] = math.clamp(tonumber(v) or private[k], 0, 7)

				-- only update if different
				if private[k] ~= oldvalue then
					self.spriteBitSpinner.tooltip = 'bit='..private[k]
					self.spriteBitTextField.value = tostring(private[k])
				end
			end,
		},
		spriteBitDepth = {
			get = function(self, k)
				return private[k]
			end,
			set = function(self, k, v)
				local oldvalue = private[k]

				-- should I not let this exceed 8 - spriteBit ?
				-- or should I wrap around bits and be really unnecessarily clever?
				private[k] = math.clamp(tonumber(v) or private[k], 1, 8)

				if private[k] ~= oldvalue then
					self.spriteBitDepthTextField.value = tostring(private[k])
				end
			end,
		},
	}
	local mt = getmetatable(self)
	setmetatable(self, table.union({}, mt, {
		__index = function(self, k)
			local gs = getset[k]
			if gs then 
				local get = gs.get
				if get then
					return get(self, k)
				end
			end

			local index = mt.__index
			if index then
				if type(index) == 'function' then
					return index(self, k, v)
				elseif type(index) == 'table' then
					local v = index[k]
					if v ~= nil then return v end
				elseif type(index) == 'nil' then
					-- fall through to return nil
				else
					error("unknown index type "..type(index))
				end
			end

			return nil
		end,
		__newindex = function(self, k, v)
			local gs = getset[k]
			if gs then
				local set = gs.set
				if set then
					return set(self, k, v)
				end
			end

			local newindex = mt.__newindex
			if newindex  then
				if type(newindex) == 'function' then
					return newindex(self, k, v)
				elseif type(newindex) == 'table' then
					-- still fall through to rawset, right?
				elseif type(newindex) == 'nil' then
					-- fall through
				else
					error("unknown newindex type "..type(newindex))
				end
			end

			rawset(self, k, v)
		end
	}))

	self:onCartLoad()
end

function EditSheet:onCartLoad()
	self.sheetBlobIndex = 0

	self.paletteBlobIndex = 0

--[[ nah metainfo isnt defined, and this doesnt remember palettes per sheet, so nah not right now
	local app = self.app
	local paletteForSheet = app.metainfo['archive.paletteForSheet']
	if paletteForSheet then
		-- TODO hmm, way to do this for each sheet?
		-- I could save the paletteForSheet in this editor ... so when you change sheets it remembers the palette ...
		-- maybe
		self.paletteBlobIndex = paletteForSheet[1+self.sheetBlobIndex] or 0
	end
--]]

	-- sprite edit mode
	self.spriteSelDown = vec2i(-1, -1)	-- differ from 0,0 so it'll trigger the onchange
	self.spriteSelUp = vec2i()
	self:setSpriteSelDown(self.spriteSelDown:unpack())

	self.spritesheetPanOffset = vec2d()
	self.spritesheetPanDownPos = vec2d()
	self.spritesheetScale = 1
	self.spritesheetPanPressed = false

	self.spritePanOffset = vec2d()	-- holds the panning offset from the sprite location
	self.spritePanDownPos = vec2d()	-- where the mouse was when you pressed down to pan
	self.spritePanPressed = false

	self.spriteBit = 0	-- which bitplane to start at: 0-7
	self.spriteBitDepth = 8	-- how many bits to edit at once: 1-8
	self.spritesheetEditMode = 'select'

	self.spriteDrawMode = 'draw'
	self.paletteSelIndex = 0	-- which color we are painting
	self.log2PalBits = 3	-- showing an 1<<3 == 8bpp image: 0-3
	self.paletteOffset = 0	-- allow selecting this in another full-palette pic?

	self.pasteKeepsPalette = true
	self.pasteTargetNumColors = 256
	self.penSize = 1 		-- size 1 thru 5 or so
	-- TODO pen dropper cut copy paste pan fill circle flipHorz flipVert rotate clear

	-- whether to paste transparent pixels from the clipboard image
	self.pasteTransparent = false

	self.undo:clear()
end

-- read-only ... const-ness ... i don't want a getter, i want a write component function ... so i'll keep this. 
function EditSheet:setSpriteSelDown(x, y)
	local oldx = self.spriteSelDown.x
	local oldy = self.spriteSelDown.y

	self.spriteSelDown.x = math.clamp(x, 0, spriteSheetSizeInTiles.x-1)
	self.spriteSelDown.y = math.clamp(y, 0, spriteSheetSizeInTiles.x-1)

	if self.spriteSelDown.x ~= oldx
	or self.spriteSelDown.y ~= oldy
	then
		self.spriteSelIndexTextField.value = tostring(self.spriteSelDown.x + spriteSheetSizeInTiles.x * self.spriteSelDown.y)
	end

	self.spriteSelUp:set(self.spriteSelDown:unpack())
end

-- on changing C, R, G, B, A, call this to update all fields
function EditSheet:updatePaletteSelIndexColor()
	local selColorValue = self:getPaletteSelIndexColor()

	self.selColorValueTextField.value = ('%04X'):format(selColorValue)
	self.selColorRedValueTextField.value = ('%02X'):format(
		bit.band(selColorValue, 0x1f)
	)
	self.selColorGreenValueTextField.value = ('%02X'):format(
		bit.band(bit.rshift(selColorValue, 5), 0x1f)
	)
	self.selColorBlueValueTextField.value = ('%02X'):format(
		bit.band(bit.rshift(selColorValue, 10), 0x1f)
	)

	local alpha = bit.band(selColorValue,0x8000)~=0
	self.alphaLabel.text = 'opaque' or 'clear'
end

function EditSheet:getPaletteSelIndexColor()
	local app = self.app
	local paletteBlob = app.blobs.palette[self.paletteBlobIndex+1]
	local paletteRAM = paletteBlob.ramgpu
	local selPaletteAddr = paletteRAM.addr + bit.lshift(self.paletteSelIndex, 1)
	local selColorValue = app:peekw(selPaletteAddr)
	return selColorValue 
end

function EditSheet:setPaletteSelIndexColor(selColorValue)
	local app = self.app
	local paletteBlob = app.blobs.palette[self.paletteBlobIndex+1]
	local paletteRAM = paletteBlob.ramgpu
	local selPaletteAddr = paletteRAM.addr + bit.lshift(self.paletteSelIndex, 1)
	self:edit_pokew(selPaletteAddr, selColorValue)

	-- change all C R G B A fields:
	self:updatePaletteSelIndexColor()
end

local selBorderColors = {0xfd, 0xfc}

function EditSheet:getpixel(tx, ty)
	if not (0 <= tx and tx < spriteSheetSize.x
	and 0 <= ty and ty < spriteSheetSize.y)
	then return end

	-- TODO HERE draw a pixel to the sprite sheet ...
	-- TODO TODO I'm gonna write to the spriteSheet.image then re-upload it
	-- I hope nobody has modified the GPU buffer and invalidated the sync between them ...
	local mask = bit.lshift(
		bit.lshift(1, self.spriteBitDepth) - 1,
		self.spriteBit
	)


	-- TODO since shift is shift, should I be subtracing it here?
	-- or should I just be AND'ing it?
	-- let's subtract it
	local texelIndex = tx + spriteSheetSize.x * ty
	assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())

	local app = self.app
	local sheetBlob = app.blobs.sheet[self.sheetBlobIndex+1]
	local sheetRAM = sheetBlob.ramgpu
	local currentSheetAddr = sheetBlob.addr

	local addr = currentSheetAddr + texelIndex
	return bit.band(
		0xff,
		self.paletteOffset
		+ bit.rshift(
			bit.band(mask, app:peek(addr)),
			self.spriteBit
		)
	)
end

function EditSheet:putpixel(tx,ty, putValue)
	if not (0 <= tx and tx < spriteSheetSize.x
	and 0 <= ty and ty < spriteSheetSize.y)
	then return end

	putValue = putValue or self.paletteSelIndex

	-- TODO HERE draw a pixel to the sprite sheet ...
	-- TODO TODO I'm gonna write to the spriteSheet.image then re-upload it
	-- I hope nobody has modified the GPU buffer and invalidated the sync between them ...
	local mask = bit.lshift(
		bit.lshift(1, self.spriteBitDepth) - 1,
		self.spriteBit
	)


	local texelIndex = tx + spriteSheetSize.x * ty
	assert(0 <= texelIndex and texelIndex < spriteSheetSize:volume())

	local app = self.app
	local sheetBlob = app.blobs.sheet[self.sheetBlobIndex+1]
	local sheetRAM = sheetBlob.ramgpu
	local currentSheetAddr = sheetBlob.addr

	local addr = currentSheetAddr + texelIndex
	local value = bit.bor(
		bit.band(
			bit.bnot(mask),
			app:peek(addr)
		),
		bit.band(
			mask,
			bit.lshift(
				putValue - self.paletteOffset,
				self.spriteBit
			)
		)
	)
	self:edit_poke(addr, value)
	self.hist = nil	-- invalidate histogram

	-- TODO wait does edit_poke write to the blob?
	-- it has to right?
	-- if not then pushing the undo content wont matter
	self.undo:pushContinuous()
end



function EditSheet:update()
	local app = self.app

	-- TODO gotta do this to align children to the the immediate-mode radio-buttons for switching blob type
	-- until I switch those immediate-mode radio-buttons
	-- but to do that I have to switch all editor tabs to the new sytsem.
	for _,ch in ipairs(self.uiRoot.children) do
		if not ch.origPosX then ch.origPosX = ch.pos.x end
		ch.pos.x = ch.origPosX - self.uiRoot.pos.x
	end



	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())
	local lastMousePressX, lastMousePressY = app:invTransform(app.ram.lastMousePressPos:unpack())

	-- hmm without this the panning starts to drift
	-- TODO fix all this coordinate conversion stuff someday
	mouseX = math.floor(mouseX)
	mouseY = math.floor(mouseY)

	local shift = app:key'lshift' or app:key'rshift'

	EditSheet.super.update(self)

	local sheetBlob = app.blobs.sheet[self.sheetBlobIndex+1]
	local sheetRAM = sheetBlob.ramgpu
	-- use the ramgpu's addr which can be relocated?  or use the blob's addr?
	-- I'm using the blob addr at the moment, since it is related to the permanent state of the cart/blob.
	local currentSheetAddr = sheetBlob.addr
	--local currentSheetAddr = sheetRAM.addr	-- use this to see whatever the "fantasy hardware" is seeing at present

	local paletteBlob = app.blobs.palette[self.paletteBlobIndex+1]
	local paletteRAM = paletteBlob.ramgpu

	local x = 126
	local y = 32
	local sw = spriteSheetSizeInTiles.x / 2	-- only draw a quarter worth since it's the same size as the screen
	local sh = spriteSheetSizeInTiles.y / 2
	local w = sw * spriteSize.x
	local h = sh * spriteSize.y

	-- draw some pattern under the spritesheet so you can tell what's transparent
	self:guiSetClipRect(x, y, w-1, h-1)

	app:matMenuReset()
	app:mattrans(x, y)
	app:matscale(self.spritesheetScale, self.spritesheetScale)
	app:mattrans(-self.spritesheetPanOffset.x, -self.spritesheetPanOffset.y)

	app:drawQuadTex(
		app.paletteMenuTex,
		app.checkerTex,
		0, 0, 256, 256,	-- x y w h
		0, 0, w/2, h/2)			-- tx ty tw th
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = self.paletteBlobIndex

	app:drawQuad(
		0,		-- x
		0,		-- y
		256,	-- w
		256,	-- h
		0,		-- tx
		0,		-- ty
		256,	-- tw
		256,	-- th
		0,		-- orientation2D
		self.sheetBlobIndex,
		0,		-- paletteShift
		-1,		-- transparentIndex
		0,		-- spriteBit ... TODO show the current spriteBit here?
		0xFF	-- spriteMask ... TODO same?
	)

	app.ram.paletteBlobIndex = pushPalBlobIndex

	-- sprite sel rect (1x1 ... 8x8)
	-- ... also show the offset ... is that a good idea?
	do
		local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
		local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
		local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
		local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
		app:drawBorderRect(
			selx * spriteSize.x + self.spritePanOffset.x,
			sely * spriteSize.y + self.spritePanOffset.y,
			selw * spriteSize.x,
			selh * spriteSize.y,
			0xd,
			nil,
			app.paletteMenuTex
		)
	end

	app:matMenuReset()

	-- since when is clipMax having problems?
	--self:guiSetClipRect(0, 0, clipMax, clipMax)
	self:guiSetClipRect(0, 0, 256, 256)

	app:drawBorderRect(x-1, y-1, w+2, h+2, 0xd, nil, app.paletteMenuTex)

	local function fbToSheetCoord(fbX, fbY)
		return
			((fbX - x) / self.spritesheetScale + self.spritesheetPanOffset.x) / spriteSize.x,
			((fbY - y) / self.spritesheetScale + self.spritesheetPanOffset.y) / spriteSize.y
	end

	local function panSheet(dx, dy)
		self.spritesheetPanOffset.x = self.spritesheetPanOffset.x + dx
		self.spritesheetPanOffset.y = self.spritesheetPanOffset.y + dy
	end

	local spritesheetPanHandled
	local function spritesheetPan(press)
		spritesheetPanHandled = true
		if press then
			if mouseX >= x and mouseX < x + w
			and mouseY >= y and mouseY < y + h
			then
				self.spritesheetPanDownPos:set(mouseX, mouseY)
				self.spritesheetPanPressed = true
			end
		else
			if self.spritesheetPanPressed then
				local tx1, ty1 = fbToSheetCoord(mouseX, mouseY)
				local tx0, ty0 = fbToSheetCoord(self.spritesheetPanDownPos:unpack())
				local tx = tx1 - tx0
				local ty = ty1 - ty0
				if tx ~= 0 or ty ~= 0 then
					panSheet(-tx * tonumber(spriteSize.x), -ty * tonumber(spriteSize.y))
					self.spritesheetPanDownPos:set(mouseX, mouseY)
				end
			end
		end
	end

	if x <= mouseX and mouseX < x+w
	and y <= mouseY and mouseY <= y+h
	then
		if shift then
			local dy = app.ram.mouseWheel.y
			if dy ~= 0 then
				panSheet((w/2) / self.spritesheetScale, (h/2) / self.spritesheetScale)
				self.spritesheetScale = self.spritesheetScale * math.exp(.1 * dy)
				panSheet(-(w/2) / self.spritesheetScale, -(h/2) / self.spritesheetScale)
			end
		else
			self.spritesheetPanOffset.x = self.spritesheetPanOffset.x - app.ram.mouseWheel.x
			self.spritesheetPanOffset.y = self.spritesheetPanOffset.y - app.ram.mouseWheel.y
		end

		if app:key'space' then
			spritesheetPan(app:keyp'space')
		end
		if self.spritesheetEditMode == 'select' then
			if leftButtonPress then
				self:setSpriteSelDown(fbToSheetCoord(mouseX, mouseY))

				self.spritePanOffset:set(0,0)
			elseif leftButtonDown then
				self.spriteSelUp:set(fbToSheetCoord(mouseX, mouseY))
				self.spriteSelUp.x = math.clamp(self.spriteSelUp.x, 0, spriteSheetSizeInTiles.x-1)
				self.spriteSelUp.y = math.clamp(self.spriteSelUp.y, 0, spriteSheetSizeInTiles.x-1)
			end
		elseif self.spritesheetEditMode == 'pan'  then
			if leftButtonDown then
				spritesheetPan(leftButtonPress)
			end
		end
	end

	if not spritesheetPanHandled then
		self.spritesheetPanPressed = false
	end

	-- sprite edit area
	local x = 2
	local y = 24
	local w = 64
	local h = 64
	-- draw some pattern under the sprite so you can tell what's transparent
	self:guiSetClipRect(x, y, w-1, h-1)
	local function spriteCoordToFb(sX, sY)
		local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
		local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
		local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
		local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
		return
			(sX - selx * spriteSize.x - self.spritePanOffset.x) / tonumber(selw * spriteSize.x) * w + x,
			(sY - sely * spriteSize.y - self.spritePanOffset.y) / tonumber(selh * spriteSize.y) * h + y
	end
	do
		local x1, y1 = spriteCoordToFb(0, 0)
		local x2, y2 = spriteCoordToFb(spriteSheetSize:unpack())
		app:drawQuadTex(
			app.paletteMenuTex,
			app.checkerTex,
			x1, y1, x2-x1, y2-y1,	-- x y w h
			0, 0, w*8, h*8)			-- tx ty tw th
	end
	local pushPalBlobIndex = app.ram.paletteBlobIndex
	app.ram.paletteBlobIndex = self.paletteBlobIndex
	do
		local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
		local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
		local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
		local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
		app:drawQuad(
			x, y, w, h,
			selx * spriteSize.x + self.spritePanOffset.x,
			sely * spriteSize.y + self.spritePanOffset.y,
			selw * spriteSize.x,
			selh * spriteSize.y,
			0,		-- orientation2D
			self.sheetBlobIndex,
			0,										-- paletteIndex
			-1,										-- transparentIndex
			self.spriteBit,							-- spriteBit
			bit.lshift(1, self.spriteBitDepth)-1	-- spriteMask
		)
	end
	app.ram.paletteBlobIndex = pushPalBlobIndex

	-- since when is clipMax having problems?
	--self:guiSetClipRect(0, 0, clipMax, clipMax)
	self:guiSetClipRect(0, 0, 256, 256)

	app:drawBorderRect(x-1, y-1, w+2, h+2, 0xd, nil, app.paletteMenuTex)

	-- convert x y in framebuffer space to x y in sprite window space
	local function fbToSpriteCoord(fbX, fbY)
		local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
		local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
		local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
		local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
		return
			(fbX - x) / w * tonumber(selw * spriteSize.x) + selx * spriteSize.x + self.spritePanOffset.x,
			(fbY - y) / h * tonumber(selh * spriteSize.y) + sely * spriteSize.y + self.spritePanOffset.y
	end

	local spritePanHandled
	local function spritePan(press)
		spritePanHandled = true
		if press then
			if mouseX >= x and mouseX < x + w
			and mouseY >= y and mouseY < y + h
			then
				self.spritePanDownPos:set(mouseX, mouseY)
				self.spritePanPressed = true
			end
		else
			if self.spritePanPressed then
				local tx1, ty1 = fbToSpriteCoord(mouseX, mouseY)
				local tx0, ty0 = fbToSpriteCoord(self.spritePanDownPos:unpack())
				-- convert mouse framebuffer pixel movement to sprite texel movement
				local tx = math.round(tx1 - tx0)
				local ty = math.round(ty1 - ty0)
				if tx ~= 0 or ty ~= 0 then
					self.spritePanOffset.x = self.spritePanOffset.x - tx
					self.spritePanOffset.y = self.spritePanOffset.y - ty
					self.spritePanDownPos:set(mouseX, mouseY)
				end
			end
		end
	end

	if self.spriteDrawMode == 'draw'
	or self.spriteDrawMode == 'dropper'
	or self.spriteDrawMode == 'fill'
	then
		if leftButtonDown
		and mouseX >= x and mouseX < x + w
		and mouseY >= y and mouseY < y + h
		then
			local tx, ty = fbToSpriteCoord(mouseX, mouseY)
			tx = math.floor(tx)
			ty = math.floor(ty)

			if self.spriteDrawMode == 'dropper'
			or (self.spriteDrawMode == 'draw' and shift)
			or (self.spriteDrawMode == 'fill' and shift)
			then
				local c = self:getpixel(tx, ty)
				if c then
					self.paletteSelIndex = c + self.paletteOffset
				end
			elseif self.spriteDrawMode == 'draw' then
				local tx0 = tx - math.floor(self.penSize / 2)
				local ty0 = ty - math.floor(self.penSize / 2)
				assert.eq(sheetRAM.image.buffer, sheetRAM.tex.data)
				sheetRAM.tex:bind()
				for dy=0,self.penSize-1 do
					for dx=0,self.penSize-1 do
						local tx = tx0 + dx
						local ty = ty0 + dy
						--[[ constrain to entire sheet (TODO flag for this option)
						if tx >= 0 and tx < spriteSheetSize.x
						and ty >= 0 and ty < spriteSheetSize.y
						--]]
						-- [[ constrain to current selection
						local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
						local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
						local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
						local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
						if tx >= selx * spriteSize.x
						and ty >= sely * spriteSize.y
						and tx < (selx + selw) * spriteSize.x
						and ty < (sely + selh) * spriteSize.y
						--]]
						then
							self:putpixel(tx,ty)
						end
					end
				end
				sheetRAM.tex:unbind()
			elseif self.spriteDrawMode == 'fill' then
				local srcColor = self:getpixel(tx, ty)
				if srcColor ~= self.paletteSelIndex then
					local fillstack = table()
					self:putpixel(tx, ty)
					fillstack:insert{tx, ty}
					while #fillstack > 0 do
						local tx0, ty0 = table.unpack(fillstack:remove())
						for _,dir in ipairs(dirs) do
							local tx1, ty1 = tx0 + dir[1], ty0 + dir[2]
							--[[ constrain to entire sheet (TODO flag for this option)
							if tx1 >= 0 and tx1 < spriteSheetSize.x
							and ty1 >= 0 and ty1 < spriteSheetSize.y
							--]]
							-- [[ constrain to current selection
							local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
							local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
							local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
							local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
							if tx1 >= selx * spriteSize.x
							and ty1 >= sely * spriteSize.y
							and tx1 < (selx + selw) * spriteSize.x
							and ty1 < (sely + selh) * spriteSize.y
							--]]
							and self:getpixel(tx1, ty1) == srcColor
							then
								self:putpixel(tx1, ty1)
								fillstack:insert{tx1, ty1}
							end
						end
					end
				end
			end
		end
	end

	if mouseX >= x and mouseX < x + w
	and mouseY >= y and mouseY < y + h
	then
		if app:key'space' then
			spritePan(app:keyp'space')
		end
		if self.spriteDrawMode == 'pan' then
			if leftButtonDown then
				spritePan(leftButtonPress)
			end
		end
	end

	if not spritePanHandled then
		self.spritePanPressed = false
	end

	-- sprite edit method

	-- TODO how to draw all colors
	-- or how many to draw ...
	local x = 32
	local y = 128
	app:drawBorderRect(
		x-1,
		y-1,
		w+2,
		h+2,
		0xd,
		nil,
		app.paletteMenuTex
	)

	-- log2PalBits == 3 <=> palBits == 8 <=> showing 1<<8 = 256 colors <=> showing 16 x 16 colors
	-- log2PalBits == 2 <=> palBits == 4 <=> showing 1<<4 = 16 colors <=> showing 4 x 4 colors
	-- log2PalBits == 1 <=> palBits == 2 <=> showing 1<<2 = 4 colors <=> showing 2 x 2 colors
	-- log2PalBits == 0 <=> palBits == 1 <=> showing 1<<1 = 2 colors <=> showing 2 x 1 colors
	-- means showing 1 << 8 = 256 palettes, means showing 1 << 4 = 16 per width and height
	local palCount = bit.lshift(1, bit.lshift(1, self.log2PalBits))
	local palBlockWidth = math.sqrt(palCount)
	local palBlockHeight = math.ceil(palCount / palBlockWidth)
	local bw = w / palBlockWidth
	local bh = h / palBlockHeight
	for j=0,palBlockHeight-1 do
		for i=0,palBlockWidth-1 do
			local paletteIndex = bit.band(0xff, self.paletteOffset + i + palBlockWidth * j)
			local rx = x + bw * i
			local ry = y + bh * j

			app:drawSolidRect(
				rx,
				ry,
				bw,
				bh,
				paletteIndex,
				nil,			-- borderOnly
				nil,			-- round
				paletteRAM.tex	-- paletteTex
			)

			if mouseX >= rx and mouseX < rx + bw
			and mouseY >= ry and mouseY < ry + bh
			then
				if leftButtonPress then
					if self.isPaletteSwapping then
						self.undo:pushContinuous()
						-- TODO button for only swap in this screen
						app:colorSwap(
							self.paletteSelIndex, 	-- from
							paletteIndex, 			-- to
							0, 0, 					-- x, y
							spriteSheetSize.x,		-- w
							spriteSheetSize.y-8,	-- h ... cheap trick to avoid the font row
							self.paletteBlobIndex
						)
						self.isPaletteSwapping = false
					end
					self.paletteSelIndex = paletteIndex
					self.paletteSelDown = paletteIndex
				elseif leftButtonDown then
					if self.paletteSelDown then
						local move = paletteIndex - self.paletteSelDown
						self.paletteOffset = bit.band(0xff, self.paletteOffset - move)
						self.paletteSelDown = bit.band(0xff, paletteIndex - move)
					end
				else
					self.paletteSelDown = nil

					-- histogram info ... TODO when to recalculate it ...
					if not self.hist then
						self.hist = Quantize.buildHistogram(sheetRAM.image)
					end
					self:setTooltip(
						tostring(self.hist[string.char(paletteIndex)] or 0),
						mouseX - 12,
						mouseY - 12,
						12,
						6
					)
				end
			end
		end
	end
	for j=0,palBlockHeight-1 do
		for i=0,palBlockWidth-1 do
			local paletteIndex = bit.band(0xff, self.paletteOffset + i + palBlockWidth * j)
			local rx = x + bw * i
			local ry = y + bh * j
			if self.paletteSelIndex == paletteIndex then
				for k,selBorderColor in ipairs(selBorderColors) do
					app:drawBorderRect(
						rx-k,
						ry-k,
						bw+2*k,
						bh+2*k,
						selBorderColor,
						nil,
						app.paletteMenuTex
					)
				end
			end
		end
	end

	-- handle input

	local uikey
	if ffi.os == 'OSX' then
		uikey = app:key'lgui' or app:key'rgui'
	else
		uikey = app:key'lctrl' or app:key'rctrl'
	end
	if uikey then
		local selx = math.min(self.spriteSelDown.x, self.spriteSelUp.x)
		local sely = math.min(self.spriteSelDown.y, self.spriteSelUp.y)
		local selw = math.max(self.spriteSelDown.x, self.spriteSelUp.x) - selx + 1
		local selh = math.max(self.spriteSelDown.y, self.spriteSelUp.y) - sely + 1
		local x = spriteSize.x * selx
		local y = spriteSize.y * sely
		local width = spriteSize.x * selw
		local height = spriteSize.y * selh
		if app:keyp'x' or app:keyp'c' then
			-- copy the selected region in the sprite/tile sheet
			-- TODO copy the current-edit region? wait it's the same region ...
			-- TODO if there is such a spriteSheetRAM.dirtyGPU then flush GPU changes here ... but there's not cuz I never write to it with the GPU ...
			assert(not sheetRAM.dirtyGPU)
			assert(x >= 0 and y >= 0 and x + width <= sheetRAM.image.width and y + height <= sheetRAM.image.height)
			local image = sheetRAM.image:copy{x=x, y=y, width=width, height=height}
			if image.channels == 1 then
--DEBUG:print'BAKING PALETTE'
				-- TODO move palette functionality inot Image
				-- TODO offset palette by current bits / shift?
				local rgba = Image(image.width, image.height, 4, uint8_t)
				local srcp = image.buffer
				local dstp = rgba.buffer
				for i=0,image.width*image.height-1 do
					dstp[0],dstp[1],dstp[2],dstp[3] = rgba5551_to_rgba8888_4ch(
						ffi.cast(palettePtrType, paletteBlob.ramptr)[srcp[0]]
					)
--DEBUG:print(i, dstp[0],dstp[1],dstp[2],dstp[3])
					dstp = dstp + 4
					srcp = srcp + 1
				end
				image = rgba	-- current clipboard restrictions ... only 32bpp
			end
			clip.image(image)
			if app:keyp'x' then
				self.undo:push()
				-- image-cut ... how about setting the region to the current-palette-offset (whatever appears as zero) ?
				sheetRAM.dirtyCPU = true
				assert.eq(sheetRAM.image.channels, 1)
				for j=y,y+height-1 do
					for i=x,x+width-1 do
						self:edit_poke(currentSheetAddr + i + sheetRAM.image.width * j, self.paletteOffset)
					end
				end
				self.hist = nil	-- invalidate histogram
			end
		elseif app:keyp'v' then
			-- how about allowing over-paste?  same with over-draw., how about a flag to allow it or not?
			assert(not sheetRAM.dirtyGPU)
			local image = clip.image()
			if image then
				self.undo:push()
				--[[
				image paste options:
				- constrain to selection vs spill over (same with drawing pen)
				- blit to selection vs keeping 1:1 with original
				- quantize palette ...
					- use current palette
						- option to preserve pasted image original indexes vs remap them
					- or create new palette from pasted image
						- option to preserve spritesheet original indexes vs remap them
					- or create new palette from current and pasted image
					- target bitness?  just use spriteFlags?
					- target palette offset?  just use paletteOffset?
				- quantize tiles? only relevant for whatever the tilemap is pointing into ...
					- use 'convert-to-8x8x4pp's trick there ...
				--]]
				if image.channels ~= 1 then
print('quantizing image to '..tostring(self.pasteTargetNumColors)..' colors')
					assert.ge(image.channels, 3)	-- NOTICE it's only RGB right now ... not even alpha
					image = image:rgba()
					assert.eq(image.channels, 4, "image channels")

					-- TODO move this into image next to toIndexed, or Quantize
					if self.pasteKeepsPalette then
						local image1ch = Image(image.width, image.height, 1, uint8_t)
						local srcp = image.buffer
						local dstp = image1ch.buffer
						for i=0,image.width*image.height-1 do
							-- slow way - just test every color against every color
							-- TODO build a mapping and then use 'applyColorMap' to go quicker
							local r,g,b,a = srcp[0], srcp[1], srcp[2], srcp[3]
							--local r,g,b = srcp[0], srcp[1], srcp[2]
							local bestIndex = bit.band(0xff, self.paletteOffset)
							local palR, palG, palB, palA = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteBlob.ramptr)[bestIndex])
							local bestDistSq
							if palA == 0 then
								bestDistSq = (palA-a)^2
							else
								bestDistSq = (palR-r)^2 + (palG-g)^2 + (palB-b)^2	-- + (palA-a)^2
							end
							for j=1,self.pasteTargetNumColors-1 do
								local colorIndex = bit.band(0xff, j + self.paletteOffset)
								local palR, palG, palB, palA = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteBlob.ramptr)[colorIndex])
								local distSq
								if palA == 0 then
									distSq = (palA-a)^2
								else
									distSq = (palR-r)^2 + (palG-g)^2 + (palB-b)^2	-- + (palA-a)^2
								end
								if distSq < bestDistSq then
									bestDistSq = distSq
									bestIndex = colorIndex
								end
							end
							dstp[0] = bestIndex
							dstp = dstp + 1
							srcp = srcp + image.channels
						end
						image = image1ch
					else
						image = image:toIndexed()
						for i,color in ipairs(image.palette) do
							self:edit_pokew(
								paletteRAM.addr + bit.lshift(bit.band(0xff, i-1 + self.paletteOffset), 1),
								rgba8888_4ch_to_5551(
									color[1],
									color[2],
									color[3],
									color[4] or 0xff
								)
							)
						end
					end
				end
				assert.eq(image.channels, 1, "image.channels")
--DEBUG:print'pasting image'
--DEBUG:print('currentSheetAddr', ('$%x'):format(currentSheetAddr))
				for j=0,image.height-1 do
					for i=0,image.width-1 do
						local destx = i + x
						local desty = j + y
						if destx >= 0 and destx < sheetRAM.image.width
						and desty >= 0 and desty < sheetRAM.image.height
						then
							local c = image.buffer[i + image.width * j]
							local r,g,b,a = rgba5551_to_rgba8888_4ch(ffi.cast(palettePtrType, paletteBlob.ramptr)[c])
							if not self.pasteTransparent or a > 0 then
								self:edit_poke(currentSheetAddr + destx + sheetRAM.image.width * desty, c)
							end
						end
					end
				end
				self.hist = nil
			end
		elseif app:keyp'z' then
			self:popUndo(shift)
		end
	end

	self:updateAndDrawNewUISceneGraph()
end

function EditSheet:popUndo(redo)
	local app = self.app
	local undoEntry = self.undo:pop(redo)
	if undoEntry then
		local sheetBlob = app.blobs.sheet[self.sheetBlobIndex+1]
		local paletteBlob = app.blobs.palette[self.paletteBlobIndex+1]
		-- copy to ROM
		ffi.copy(sheetBlob.image.buffer, undoEntry.sheet.buffer, sheetBlob.image:getBufferSize())
		ffi.copy(paletteBlob.image.buffer, undoEntry.palette.buffer, paletteBlob.image:getBufferSize())
		-- copy to RAM
		ffi.copy(sheetBlob.ramgpu.image.buffer, undoEntry.sheet.buffer, sheetBlob.ramgpu.image:getBufferSize())
		ffi.copy(paletteBlob.ramgpu.image.buffer, undoEntry.palette.buffer, paletteBlob.ramgpu.image:getBufferSize())
		sheetBlob.ramgpu.dirtyCPU = true
		paletteBlob.ramgpu.dirtyCPU = true

		self:updatePaletteSelIndexColor()
	end
end

function EditSheet:event(e)
	return self:handleEventNewUISceneGraph(e)
end

return EditSheet
