--#include ext/range.lua
--#include vec/vec2.lua
--#include vec/vec3.lua

-- [[
local size = vec2(4,4)
local fontSize = vec2(2,2)
--]]
--[[
local size = vec2(8,8)
local fontSize = vec2(1,1)
--]]


local fontWidthAddr = ffi.offsetof('RAM','fontWidth')
for i=0,255 do
	poke(fontWidthAddr+i,8)
end

local randomColor = [] do
	local v = (vec3(math.random(), math.random(), math.random()):unit() * 31):floor()
	return v.x | (v.y << 5) | (v.z << 10) | 0x8000
end

local palAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'palette')
for i=0,255 do
	pokew(palAddr + (i<<1), randomColor())
end

local dirvecs = table{
	[0] = vec2(1,0),
	[1] = vec2(0,1),
	[2] = vec2(-1,0),
	[3] = vec2(0,-1),
}

local rndb = [] math.random(0,255)

local colors = {}

local addNumber=[]do
	local zeroes = table()
	for i,col in ipairs(board) do
		for j,v in ipairs(col) do
			if v == 0 then
				zeroes:insert(vec2(i,j))
			end
		end
	end
	-- welp it shouldn't even have none to choose from in the first place ...
	if #zeroes == 0 then
trace'you lost'
		msg = 'you lost'
	end
	local pos = zeroes:pickRandom()
	board[pos.x][pos.y] = math.random(1,2) << 1
--[[ here TODO don't end the game if there's any valid moves left
	if #zeroes == 0 then
trace'you lost'
		msg = 'you lost'
	end
--]]
end

resetGame=[]do
-- [[ testing
	board = range(size.x):mapi([i] range(size.y):mapi([j] 1<<math.max(i,2)))
--]]
--[[
	board = range(size.x):mapi([] range(size.y):mapi([] 0))
	addNumber()
--]]
end

local modpos = [pos]do
	local x,y = pos:unpack()
	if x < 0 then x += size.x + 1 end
	if y < 0 then y += size.y + 1 end
	assert.le(1, x)
	assert.le(x, size.x)
	assert.le(1, y)
	assert.le(y, size.y)
--trace('modpos from='..pos..' to='..vec2(x,y))
	return vec2(x,y)
end
local getmod = [pos]do
	pos = modpos(pos)
	return board[pos.x][pos.y]
end
local setmod = [pos, value]do
	pos = modpos(pos)
	board[pos.x][pos.y] = value
end

update=[]do
	cls()
	for i,col in ipairs(board) do
		for j,v in ipairs(col) do
			colors[v] ??= rndb()
			rect(
				(i-1)/size.x * 256,
				(j-1)/size.y * 256,
				256 / size.x,
				256 / size.y,
				colors[v])

			text(
				tostring(v),
				(i - 1) / size.x * 256,
				(j - .5) / size.y * 256,
				nil,
				nil,
				fontSize.x,
				fontSize.y)
		end
	end

	if msg then
		text(msg, 100, 128, nil, nil, 4, 4)
		return
	end

	-- dir = which way we are pushing blocks
	for i,dir in pairs(dirvecs) do
		if btnp(i) then
			local moved
--trace('press', i)
			local right = dir:cplxmul(vec2(0,1))
			for j=1,math.abs(size:dot(right)) do
				local mink = 1
				for i=2,math.abs(size:dot(dir)) do
					local pos = right * j - dir * i
--trace('check', dir, i, j, pos, modpos(pos), getmod(pos))
					local srcval = getmod(pos)
					if srcval ~= 0 then
--trace'found'
						local dstk
						for k=i-1,mink,-1 do
							local pk = right * j - dir * k
--trace('check dst', k, pk)
							if getmod(pk) ~= 0 and getmod(pk) ~= srcval then break end
							dstk = k
							if getmod(pk) == srcval then break end	-- combine
						end
--trace('found', dstk)
						if dstk then
							-- then move
							moved = true
							local pk = right * j - dir * dstk
--trace('moving to', pk)

--trace('board[', pk, '] was', getmod(pk))
--trace('set', pk, 'to pos', pos, 'value', getmod(pos))
							setmod(pk, getmod(pk) + getmod(pos))
--trace('board[', pk, '] is', getmod(pk))

--trace('board[', pos, '] was', getmod(pos))
--trace('set', pos, 'to', 0)
							setmod(pos, 0)
--trace('board[', pos, '] is', getmod(pos))
							mink = dstk+1
						end
					end
				end
			end
			if moved then
--trace('board')
--trace(board:mapi([col] col:concat','):concat'\n')
				addNumber()
			end
		end
	end
end

resetGame()
