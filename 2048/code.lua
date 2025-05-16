--#include ext/range.lua
--#include vec/vec2.lua

local fontWidthAddr = ffi.offsetof('RAM','fontWidth')
for i=0,255 do
	poke(fontWidthAddr+i,8)
end

local dirvecs = table{
	[0] = vec2(1,0),
	[1] = vec2(0,1),
	[2] = vec2(-1,0),
	[3] = vec2(0,-1),
}

local size = vec2(4,4)

local addNumber=[]do
	local zeroes = table()
	for i,col in ipairs(board) do
		for j,v in ipairs(col) do
			if v == 0 then
				zeroes:insert(vec2(i,j))
			end
		end
	end
	if #zeroes == 0 then
		msg = 'you lost'
	end
	local pos = zeroes:pickRandom()
	board[pos.x][pos.y] = math.random(1,2) << 1
end

resetGame=[]do
	board = range(size.x):mapi([] range(size.y):mapi([] 0))
	addNumber()
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

local fontSize = vec2(2,2)
update=[]do
	cls()
	for i,col in ipairs(board) do
		for j,v in ipairs(col) do
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
		text(msg, 128, 128)
		return
	end

	-- dir = which way we are pushing blocks
	for i,dir in pairs(dirvecs) do
		if btnp(i) then
			local moved
--trace('press', i)
			local right = dir:cplxmul(vec2(0,1))
			for i=2,math.abs(size:dot(dir)) do
				for j=1,math.abs(size:dot(right)) do
					local pos = right * j - dir * i
--trace('check', dir, i, j, pos, modpos(pos), getmod(pos))
					local srcval = getmod(pos)
					if srcval ~= 0 then
--trace'found'
						local dstk
						for k=i-1,1,-1 do
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
