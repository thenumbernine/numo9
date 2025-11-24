-- title = Field
-- saveid = field
-- author = Chris Moore
-- description = turn based strategy game of competing orthogonal fields

--#include ext/class.lua
--#include ext/range.lua
--#include vec/vec2.lua

rot=0x4000
sprites={
	empty					=0,
	snakeRight				=1,
	snakeDown				=1+rot,
	snakeLeft				=1+rot*2,
	snakeUp					=1+rot*3,
	snakeUpDown				=2+rot,
	snakeUpLeft				=3,
	snakeUpRight			=3+rot,
	snakeDownRight			=3+rot*2,
	snakeDownLeft			=3+rot*3,
	snakeLeftRight			=2,
	snakeEndRight			=4+rot*2,
	snakeEndDown			=4+rot*3,
	snakeEndLeft			=4,
	snakeEndUp				=4+rot,
	snakeVertOverHorz		=5,
	snakeHorzOverVert		=5+rot,
	cursor					=6,
}
snakeBodies={
	[0]={
		[0]=sprites.snakeUpDown,
		[1]=sprites.snakeUpDown,
		[2]=sprites.snakeUpLeft,
		[3]=sprites.snakeUpRight,
	},
	[1]={
		[0]=sprites.snakeUpDown,
		[1]=sprites.snakeUpDown,
		[2]=sprites.snakeDownLeft,
		[3]=sprites.snakeDownRight,
	},
	[2]={
		[0]=sprites.snakeUpLeft,
		[1]=sprites.snakeDownLeft,
		[2]=sprites.snakeLeftRight,
		[3]=sprites.snakeLeftRight
	},
	[3]={
		[0]=sprites.snakeUpRight,
		[1]=sprites.snakeDownRight,
		[2]=sprites.snakeLeftRight,
		[3]=sprites.snakeLeftRight,
	},
	head={
		[0]=sprites.snakeUp,
		[1]=sprites.snakeDown,
		[2]=sprites.snakeLeft,
		[3]=sprites.snakeRight,
	},
	tail={
		[0]=sprites.snakeEndUp,
		[1]=sprites.snakeEndDown,
		[2]=sprites.snakeEndLeft,
		[3]=sprites.snakeEndRight,
	},
}

dirIndexForName={
	up=0,
	down=1,
	left=2,
	right=3,
}
dirNameForIndex=table.map(dirIndexForName,|v,k|(k,v)):setmetatable(nil)
dirs={
	[0]={0,-1},
	[1]={0,1},
	[2]={-1,0},
	[3]={1,0},
}

table.equals=|a,b|do
	local ka=table.keys(a)
	local kb=table.keys(b)
	if #ka~=#kb then return false end
	for _,k in ipairs(ka) do
		if a[k]~=b[k] then return false end
	end
	return true
end

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
	tilemap(0,0,boardSize.x,boardSize.y)
	spr(
		sprites.cursor,
		cursor.x<<3,
		cursor.y<<3,
		1,1,
		0,
		1,1,
		currentTurn<<5)
	matident()
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
		tset(0,i,j,sprites.snakeUp|((playerIndexPlus1-1)<<10))
	end

	done=false

	currentTurn = -1
	nextTurn()
end

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
		if turnState == 'moving' then
			if btnp('up', playerIndex, 5, 5) then
				cursor.y -= 1
			end
			if btnp('down', playerIndex, 5, 5) then
				cursor.y += 1
			end
			if btnp('left', playerIndex, 5, 5) then
				cursor.x -= 1
			end
			if btnp('right', playerIndex, 5, 5) then
				cursor.x += 1
			end
			cursor.x %= boardSize.x
			cursor.y %= boardSize.y

			if btnp('a', playerIndex)
			or btnp('b', playerIndex)
			then
				local cursorTeam = getTileTeam(cursor.x, cursor.y)
	trace('cursorTeam', cursorTeam)			
				if cursorTeam == currentTurn then
					turnState = 'choosing'
				end
			end
		elseif turnState == 'choosing' then
			if btnp'up' then
				nextDir=0
			elseif btnp'down' then
				nextDir=1
			elseif btnp'left' then
				nextDir=2
			elseif btnp'right' then
				nextDir=3
			end
		end
	end

	if nextDir then
		local moveVert=nextDir&2==0
		local moveHorz=not moveVert
		local dx,dy=table.unpack(dirs[nextDir])
		newX=cursor.x+dx
		newY=cursor.y+dy
		newX%=boardSize.x
		newY%=boardSize.y
		local spriteIndex=tget(0,newX,newY)
		local spriteTeam = (spriteIndex>>10)&7
		spriteIndex&=0x3ff

		-- check for free movement or overlap/underlap ...
		local blocked
		local crossingOver
		if spriteIndex~=sprites.empty then
			if (
				moveVert
				and (spriteIndex==sprites.snakeLeftRight)
			)
			or (
				moveHorz
				and (spriteIndex==sprites.snakeUpDown)
			)
			then
				-- skip
				crossingOver = true
				if btn(5) or btn(7) then
					crossingOver = false
				end
			elseif spriteIndex==sprites.snakeEndUp
			or spriteIndex==sprites.snakeEndDown
			or spriteIndex==sprites.snakeEndLeft
			or spriteIndex==sprites.snakeEndRight
			then
				done=true
			else
				blocked=true
			end
		end

		if not blocked then
			-- TODO adjust previous tile
			-- adjust current tile
			tset(0,newX,newY,sprites.snakeUp|(currentTurn<<10))
			nextTurn()
		end
	end
end
