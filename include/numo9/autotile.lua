--#include ext/class.lua

-- autotile will vary per sheet
-- I could pass the current sheet as an extra arg ... or make the sheet a table key ...
-- I'll make this for the world map (sheet 9 / palette 1)
-- TODO make an include/numo9/autotile.lua for all this functionality
local buildAutotileInv = |t| do
	local tinv = {}
	for k,v in pairs(t) do
		if type(v) == 'number' then
			tinv[v] = k
		elseif type(v) == 'table' then
			for _,i in ipairs(v) do
				tinv[i] = k
			end
		end
	end
	return tinv
end

--[[ ? : operator has parnethesis / parsing order problems
local autotileChoose = |v| type(v) == 'table' ? table.pickRandom(v) : v
--]]
-- [[
local autotileChoose = |v| do
	if type(v) == 'table' then
		return table.pickRandom(v)
	end
	return v
end
--]]


local Autotile = class()
Autotile.init = |:, args| do
	for k,v in pairs(args) do self[k] = v end
end
Autotile.paint = |:, tilemap, x, y| do
	-- Simplest is just return the center tile
	-- But TODO x and y are fractional.
	-- For corner-autotiles, you can read each corner's bit,
	-- then set the appropriate corner-bit,
	-- then lookup and return that tile.
	return autotileChoose(self.t[15])
end

local AutotileSides4bit = Autotile:subclass()
-- I could merge 4bit corners and 4bit sides into 8bit ... hmm ... and prioritize by bit counts i.e. number of tiles valid ... but for now only one or the other is used ...
AutotileSides4bit.change = |:, tilemap, x, y| do
	local t = self.t
	local tinv = self.tinv
	x = math.floor(x)
	y = math.floor(y)

-- [[ only test the bit for the side next to us
-- hmm doesnt always work ...
	local sideflags =
		  (((tinv[tget(tilemap, x+1, y  )] or 0) >> 2) & 1)	-- find the right tile's bitflags, shift its left tile (2) into our right tile (0) bit ...
		| (((tinv[tget(tilemap, x  , y+1)] or 0) >> 2) & 2)	-- find the up tile's bitflags, shift its down bit (3) into our up bit (1) ...
		| (((tinv[tget(tilemap, x-1, y  )] or 0) << 2) & 4)	-- find the left tile's bitflags, shift its right bit (0) into our right bit (2)
		| (((tinv[tget(tilemap, x  , y-1)] or 0) << 2) & 8)	-- find the down tile's bitflags, shift its up bit (1) into our down bit (3)
--]]
--[[ if any exists then we have a neighbor
-- doesn't do so well for corners ...
	local sideflags =
		  (tinv[tget(tilemap, x+1, y  )] and 1 or 0)
		| (tinv[tget(tilemap, x  , y+1)] and 2 or 0)
		| (tinv[tget(tilemap, x-1, y  )] and 4 or 0)
		| (tinv[tget(tilemap, x  , y-1)] and 8 or 0)
--]]
	return autotileChoose(t[sideflags])
end

local AutotileCorners4bit = Autotile:subclass()
AutotileCorners4bit.change = |:, tilemap, x, y| do
	local t = self.t
	local tinv = self.tinv
	x = math.floor(x)
	y = math.floor(y)
	-- how to get corner bits ...
	-- its gonna be consensus of 3 dif tiles ...
	-- TODO I could just return a central tile value and a single function that does this kernel, instead of doing a kernel twice...
	-- store the neighbors around x+dx, y+dy
	local neighbors = {}
	for dx=-1,1 do
		neighbors[dx] = {}
		for dy=-1,1 do
			neighbors[dx][dy] = tinv[tget(tilemap, x+dx, y+dy)]
				or 0
		end
	end
	-- now we use our consensus
	local corners = {}
	for xlr=0,1 do
		corners[xlr] = {}
		for ylr=0,1 do
			-- consensus will be if any is set to our autotile type then consider the corner to be set
			-- I could do 'all' or 'average' as well
			corners[xlr][ylr] = 1 & (
				  (neighbors[xlr-1][ylr-1] >> 3)	-- upper-left neighbor's lower-right bit
				| (neighbors[xlr  ][ylr-1] >> 2)	-- upper-right neighbor's lower-left bit
				| (neighbors[xlr-1][ylr  ] >> 1)	-- lower-left neighbor's upper-right bit
				| (neighbors[xlr  ][ylr  ]     )	-- lower-right neighbor's upper-left bit
			)
		end
	end
	local cornerFlags =
		   corners[0][0]		-- upper-left
		| (corners[1][0] << 1)	-- upper-right
		| (corners[0][1] << 2)	-- lower-left
		| (corners[1][1] << 3)	-- lower-right
	return autotileChoose(t[cornerFlags])	-- can be nil in the case that we dont have a replacing autotile
end
