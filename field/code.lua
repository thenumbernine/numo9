-- title = Field
-- saveid = field
-- author = Chris Moore
-- description = turn based strategy game of competing orthogonal fields

--#include ext/class.lua
--#include ext/range.lua
--#include vec/vec2.lua
--#include numo9/autotile.lua

rot=0x4000
sprites={
	empty					=0,
	branchNone				=34,
	branchRight				=1,
	branchDown				=1+rot,
	branchLeft				=1+rot*2,
	branchUp				=1+rot*3,
	branchUpDown			=2+rot,
	branchUpLeft			=3,
	branchUpRight			=3+rot,
	branchDownRight			=3+rot*2,
	branchDownLeft			=3+rot*3,
	branchLeftRight			=2,
	branchRightUpLeft		=5,
	branchUpLeftDown		=5+rot,
	branchLeftDownRight		=5+rot*2,
	branchDownRightUp		=5+rot*3,
	branchEndRight			=4+rot*2,
	branchEndDown			=4+rot*3,
	branchEndLeft			=4,
	branchEndUp				=4+rot,
	branchVertOverHorz		=32,
	branchHorzOverVert		=32+rot,
	branchAll				=33,
	cursor					=6,
}

-- mountains
-- mountain template is up, down, left, right
autotile_sheet9_branch_sides4bit = {
	-- 0 sides
	[0      ] = sprites.branchNone,				--
	-- 1 side
	[1      ] = sprites.branchEndRight,			-- R
	[  2    ] = sprites.branchEndUp,			--   U
	[    4  ] = sprites.branchEndLeft,			--     L
	[      8] = sprites.branchEndDown,			--       D

	[1|2    ] = sprites.branchUpRight,			-- R U
	[1  |4  ] = sprites.branchLeftRight,		-- R   L
	[1    |8] = sprites.branchDownRight,		-- R     D
	[  2|4  ] = sprites.branchUpLeft,			--   U L
	[  2  |8] = sprites.branchUpDown,			--   U   D
	[    4|8] = sprites.branchDownLeft,			--     L D

	-- 3 sides
	[1|2|4  ] = sprites.branchRightUpLeft,		-- R U L
	[1|2  |8] = sprites.branchDownRightUp,		-- R U   D
	[1  |4|8] = sprites.branchLeftDownRight,	-- R   L D
	[  2|4|8] = sprites.branchUpLeftDown,		--   U L D

	-- 4 sides
	[1|2|4|8] = sprites.branchAll,				-- R U L D

}
numo9_autotile={
	AutotileSides4bit{
		t=autotile_sheet9_branch_sides4bit,
	},
}
--trace('tinv', numo9_autotile[1].tinv)

boardSize = vec2(8,8)
cursor = vec2(0,0)
numPlayers=2
currentTurn=0
turnState=nil
inputPlayers=nil


redraw=||do
	cls()
	text('player '..(currentTurn+1).."'s turn")
	matident()
	mattrans(128-(boardSize.x<<2),128-(boardSize.y<<2))

--	clip(0,0,boardSize.x<<3,boardSize.y<<3)
	for dy=-1,1 do
		for dx=-1,1 do
			local sx = (dx * boardSize.x) << 3
			local sy = (dy * boardSize.y) << 3
			tilemap(0,0,boardSize.x,boardSize.y,sx,sy)
		end
	end
	rectb(-1, -1, (boardSize.x<<3)+2, (boardSize.y<<3)+2, 12)

	if turnState == 'choosing' and (time() * 3) & 1 == 1 then
		rect(cursor.x << 3, cursor.y << 3, 8, 8, 12)
	else
		spr(
			sprites.cursor,
			cursor.x<<3,
			cursor.y<<3,
			1,1,
			0,
			1,1,
			currentTurn<<5)
	end

	matident()
--	clip(-9999,-9999,9999,9999)
end

-- currently 8 players max since I'm using tile palette for team
getTileTeam=|i,j|do
	local tile = tget(0,i,j)
	if tile == 0 then return end
	return (tile >> 10) & 7
end

nextTurn=||do
	currentTurn+=1
	currentTurn%=numPlayers
	turnState = 'moving'
	for j=0,boardSize.y-1 do
		for i=0,boardSize.x-1 do
			if getTileTeam(i,j) == currentTurn then
				cursor:set(i,j)
				goto cursorInitd
			end
		end
	end
::cursorInitd::

	-- [[ same-computer
	inputPlayers=range(0,numPlayers-1)
	--]]
	--[[ multiple consoles
	inputPlayers=table{currentTurn}
	--]]
end

newGame=||do
	numPlayers=2
	turn=0
	for j=0,boardSize.y-1 do
		for i=0,boardSize.x-1 do
			tset(i,j,0)
		end
	end

	-- init locations
	for playerIndexPlus1,start in ipairs(table{
		{pos=vec2(0,0)},
		{pos=(boardSize/2):floor()},
	}:sub(1,numPlayers)) do
		local i,j = start.pos:unpack()
		tset(0,i,j,sprites.branchNone|((playerIndexPlus1-1)<<10))
	end

	done=false

	currentTurn = -1
	nextTurn()
end

local dirNames = table.map(dirForName, |i,name| (name,i))

inSplash=true
update=||do
	if inSplash then
		cls()
		local x,y = 24, 48
		local txt=|s|do text(s,x,y,0xc,-1) y+=8 end
		txt'FIELD!!!!'
		txt'create the biggest field and win!'
		txt''
		txt'Each turn, players take turns making moves.'
		txt'A move consist of placing the cursor on a'
		txt' piece, then push B, then push a direction to'
		txt' branch off that piece.'
		txt'You cannot cross over your own piece.'
		txt'You cannot cross over a corner or branch.'
		txt''
		txt'press any JP button to continue...'
		for i=0,7 do
			if btnr(i) then
				inSplash=false
				newGame()
			end
		end
		return
	end

	redraw()

	nextDir=nil
	for _,playerIndex in ipairs(inputPlayers) do
		if turnState=='moving' then
			for dirIndex,dirName in pairs(dirNames) do
				if btnp(dirName, playerIndex, 20, 5) then
					cursor+=dirvecs[dirIndex]
					cursor%=boardSize
					goto inputHandled
				end
			end

			if btnp('a', playerIndex)
			or btnp('b', playerIndex)
			then
				local cursorTeam=getTileTeam(cursor.x, cursor.y)
				if cursorTeam==currentTurn then
					turnState='choosing'
					goto inputHandled
				end
			end
		elseif turnState=='choosing' then
			for dirIndex,dirName in pairs(dirNames) do
				if btnp(dirName,playerIndex) then
					nextDir=dirIndex
					goto inputHandled
				end
			end

			if btnp('a',playerIndex)
			or btnp('b',playerIndex)
			then
				turnState='moving'
				goto inputHandled
			end
		end
	end
::inputHandled::

	if nextDir then
		local moveVert=nextDir&1==0
		local moveHorz=not moveVert
		local dir=dirvecs[nextDir]
		local newpos=(cursor+dir)%boardSize
		local spriteIndex=tget(0,newpos:unpack())
		local spriteTeam = (spriteIndex>>10)&7
		spriteIndex&=0x3ff

		-- check for free movement or overlap/underlap ...
		local blocked
		local crossingOver
		if spriteIndex~=sprites.empty then
			if (
				moveVert
				and (spriteIndex==sprites.branchLeftRight)
			)
			or (
				moveHorz
				and (spriteIndex==sprites.branchUpDown)
			)
			then
				-- skip
				crossingOver = true
				if btn'y' or btn'x' then
					crossingOver = false
				end
			elseif spriteIndex==sprites.branchEndUp
			or spriteIndex==sprites.branchEndDown
			or spriteIndex==sprites.branchEndLeft
			or spriteIndex==sprites.branchEndRight
			then
				done=true
			else
				blocked=true
			end
		end

		if not blocked then
			local settile=|x,y|do
				local tile = numo9_autotile[1]:change(0,x,y)
trace(x,y,tile)
				tile |= (currentTurn<<10)
				tset(0,x,y,tile)
			end
			-- TODO all neighbors as well
			settile(cursor:unpack())
			settile(newpos:unpack())

			nextTurn()
		end
	end
end
