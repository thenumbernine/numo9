-- title = Dungeons-n-Munchers
-- saveid = dungeons-n-munchers
-- author = Chris Moore
-- description = Number Munchers but with D&D and maybe MMO or something idk

local class = require 'ext.class'
local vec2 = require 'vec.vec2'

local sprites = {
	empty = 0,
	solid = 2,
	player = 2*32,
	player_chomp = 2*32+3,
	heart = 32,
}

local flagshift=table{
	'solid',	-- 1
}:mapi(|k,i| (i-1,k)):setmetatable(nil)
local flags=table(flagshift):map(|v| 1<<v):setmetatable(nil)

local mapTypes=table{
	[0]={			-- empty
		name = 'empty',
	},
	[2]={	-- solid
		name='solid',
		flags=flags.solid,
	},
}
for k,v in pairs(mapTypes) do
	v.index = k
	v.flags ??= 0
end
local mapTypeForName = mapTypes:map(|v,k| (v, v.name))



local mapwidth = 256
local mapheight = 256
require 'obj.sys'.mapwidth = mapwidth
require 'obj.sys'.mapheight = mapheight
local objs = require 'obj.sys'.objs
local Object = require 'obj.sys'.Object
Object.tileSize:set(2,2)
--Object.spriteSize:set(1/3, 1/3)

local solndesc = 'x % 3 == 1'
local solnfunc = |value| value % 3 == 1

local cells = table()	-- key = [x][y]
local getCell = |x,y| cells[x]?[y]

--local Cell = Object:subclass()
-- don't do O(n) rendering for cells...
local Cell = class()
Cell.init = table.union
Cell.pixelWidth = 16
Cell.draw = |:|do
	self.pixelWidth = text(
		self.valueStr,
		(self.pos.x + .5) * 16 - .5 * self.pixelWidth,
		(self.pos.y + .5) * 16 - 4
	)
end

local Player = Object:subclass()
Player.size = 1
Player.health = 3
Player.gold = 0
Player.chompDuration = .2

Player.draw=|:|do
	spr(
		self.sprite,		-- spriteIndex
		16 * self.pos.x,
		16 * self.pos.y,
		3,		-- tilesWide
		3,		-- tilesHigh
		0,		-- orientation2D
		2/3,	-- scaleX
		2/3		-- scaleY
	)
end

function Player:update()
	if self.nextInputTime then
		if time() <= self.nextInputTime then return end
		self.nextInputTime = nil
	end

	if btnp'y' then
		local cell = getCell(self.pos:unpack())
		if cell and cell.value then
			self.chompCell = cell
			self.chompTime = time()
		end
	end

	self.sprite = sprites.player
	if self.chompTime then
		if time() - self.chompTime < self.chompDuration then
			if math.random(2) == 2 then
				self.sprite = sprites.player_chomp
			else
				self.sprite = sprites.player
			end
		else
			local value = self.chompCell.value
			local canDigest = solnfunc(value) == 0
			if canDigest then
				-- give points or health or something
				player.gold += cell.gold or 1
			else
				-- do damage or something
				player.health -= 1
				if player.health <= 0 then
					-- die or idk
				end
			end

			-- clear the cell's number .. it's been eaten
			self.chompCell.value = nil
			-- unlink us from the cell
			self.chompCell = nil
			-- evaluate the chomp
			self.chompTime = nil
		end
	else
		-- can't move while chomping
		for k=0,3 do
			if btn(k) then
				local dir = vec2.dirvecs[k]
				local newpos = self.pos + dir
				local solid = newpos.x < 0 or newpos.x >= mapwidth
					or newpos.y < 0 or newpos.y >= mapheight
					or mapTypes![tget(0,newpos.x,newpos.y)].flags & flags.solid ~= 0
				if not solid then
					self.pos:set(newpos:unpack())
				end
				self.nextInputTime = time() + .1
			end
		end
	end
end


local viewPos = vec2()	-- set
local ulPos = vec2()	-- calculated
local lrPos = vec2()	-- calculated


update=||do
	-- hmm mode() at global level doesn't seem to work ...
	--local screenw, screenh = 256,256
	--local screenw, screenh = 336, 189 mode(18)	-- 16:9 336x189x16bpp-RGB565
	--local screenw, screenh = 480, 270 mode(42)	-- 16:9 480x270x8bpp-indexed
	mode(-1)	-- use native res 16bpp
	local screenw, screenh = tonumber(peekw(ramaddr'screenWidth')), tonumber(peekw(ramaddr'screenHeight'))

	if player then
		viewPos:set(player.pos)
	end

	cls(0)
	matident()

	local tileSize = 16
	mattrans(screenw * .5, screenh * .5)
	local viewScale = screenw / 320
	matscale(viewScale, viewScale)	-- zoom in on the board
	mattrans(-viewPos.x * tileSize, -viewPos.y * tileSize)
	ulPos:set(
		viewPos.x - screenw * .5 / viewScale,
		viewPos.y - screenh * .5 / viewScale
	)
	lrPos:set(
		viewPos.x + screenw * .5 / viewScale,
		viewPos.y + screenh * .5 / viewScale
	)
	tilemap(
		0,0,
		256,256,
		0,0,
		0,	-- tilemapIndexOffset
		1)	-- draw16x16Sprites

	for _,o in ipairs(objs) do
		o:update()
	end

	for _,o in ipairs(objs) do
		o:draw()
	end
	-- also draw cells
	for y=math.floor(ulPos.y),math.ceil(lrPos.y) do
		for x=math.floor(ulPos.x),math.ceil(lrPos.x) do
			local col = cells[x]
			if col then
				local cell = col[y]
				if cell then
					cell:draw()
				end
			end
		end
	end

	matident()

	-- draw gui
	if player then
		for i=1,player.health do
			spr(sprites.heart,
				(i-1)<<4, screenh - 16,
				2, 2)
		end
	end

	text(solndesc, screenw/2, 0, nil, nil, 2, 2)
	text('$'..player.gold, screenw/2, screenh - 16, nil, nil, 2, 2)
	text(tostring(viewPos), screenw/2, screenh - 32, nil, nil, 2, 2)

	-- remove dead
	for i=#objs,1,-1 do
		if objs[i].removeMe then objs:remove(i) end
	end
end

local init=||do
--	local playerStarts = table()
	for i=0,mapwidth-1 do
		for j=0,mapheight-1 do
			if math.random() < .2 then
				tset(0, i, j, mapTypeForName.solid.index)
			else
--				playerStarts:insert(vec2(i,j))
			end
		end
	end

	local randomPos = || vec2(math.random(mapwidth),math.random(mapheight))-1
	player = Player{
		--pos=playerStarts:pickRandom(),
		pos=randomPos(),
		--pos=vec2(),
	}

	for i=1,1000 do
		local pos = randomPos()
		cells[pos.x] ??= {}
		local value = math.random(0,20)
		cells[pos.x][pos.y] = Cell{
			pos = pos,
			value = value,
			valueStr = tostring(value),
		}
	end
end

init()
