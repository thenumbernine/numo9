math.randomseed(tstamp())
--#include ext/class.lua

local mapw,maph=32,32
local maxPlayers=64

local sprites={
	empty=0,
	snakeUp=1,
	snakeDown=2,
	snakeLeft=3,
	snakeRight=4,
	snakeBody=5,
	fruit=6,
	snakeUpDown=32,
	snakeUpLeft=33,
	snakeUpRight=34,
	snakeDownLeft=35,
	snakeDownRight=36,
	snakeLeftRight=37,
	snakeEndUp=64,
	snakeEndDown=65,
	snakeEndLeft=66,
	snakeEndRight=67,
}
local snakeBodies={
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
}

local dirs={
	[0]={0,-1},
	[1]={0,1},
	[2]={-1,0},
	[3]={1,0},
}

local findEmpty=||do
	local empty=table()
	for j=0,maph-1 do
		for i=0,mapw-1 do
			if mget(i,j)==sprites.empty then
				empty:insert{i,j}
			end
		end
	end
	if #empty==0 then return end
	return table.unpack(empty:pickRandom())
end

local placeFruit=||do
	local fruitX,fruitY=findEmpty()
	if not fruitX then	-- then the screen is full ... you mustve won ...
		message'YOU WON ... I think'
		-- error or something
		reset()
		return
	end
	mset(fruitX,fruitY,sprites.fruit)
end

local lastMessageTime
local messages=table()
local message=|s|do
	messages:insert(s)
	lastMessageTime=time()
end

local Player=class()
Player.init=|:,index|do
	self.index=index
end
Player.spawn=|:,x,y|do
	self.dir=1
	self.nextDir=1
	self.body=table()
	self.x=x
	self.y=y
	self.body:insert{x=self.x,y=self.y}
	mset(self.x,self.y,sprites.snakeUp+self.dir)
end
Player.getInput=|:|do
	if btn('up',self.index) and self.dir ~= 1 then
		self.nextDir=0
	elseif btn('down',self.index) and self.dir ~= 0 then
		self.nextDir=1
	elseif btn('left',self.index) and self.dir ~= 3 then
		self.nextDir=2
	elseif btn('right',self.index) and self.dir ~= 2 then
		self.nextDir=3
	end
end
Player.update=|:|do
	mset(self.x,self.y,snakeBodies[self.dir~1][self.nextDir] or sprites.snakeBody)
	self.dir=self.nextDir
	local dx,dy=table.unpack(dirs[self.dir])
	self.x+=dx
	self.y+=dy
	self.x%=mapw
	self.y%=maph
	--[[ walls?
	if self.x<0 or self.x>=mapw or self.y<0 or self.y>=maph then
		message('player '..self.index..' died!')
		self:die()
	end
	--]]
	local i=mget(self.x, self.y) 
	mset(self.x, self.y, sprites.snakeUp+self.dir)
	if i==sprites.fruit then
		self.body:insert(1,{x=self.x,y=self.y,dir=self.dir})
		--speed=math.max(1,speed-1)
		placeFruit()
	elseif i~=sprites.empty then
		message('player '..self.index..' died!')
--trace'dying'
--trace('pos', self.x, self.y)
--trace('body', self.body:mapi(|link|link.x..','..link.y):concat' ')
		self:die()
	else
		self.body:insert(1, {x=self.x,y=self.y})
		local tail = self.body:remove()
		mset(tail.x,tail.y,sprites.empty)
	end
end
-- remove the player's body from the map and respawn them somewhere in the map
Player.die=|:|do
	for _,link in ipairs(self.body) do
		mset(link.x, link.y, sprites.empty)
	end

	local x,y = findEmpty()
	if not x then 
		return
		-- TODO can't respawn the player
	end
	self:spawn(x,y)
end

local players={}

-- reset the whole game
reset=||do
	-- stall
	for i=1,60 do yield() end
	
	for j=0,maph-1 do
		for i=0,mapw-1 do
			mset(i,j,sprites.empty)
		end
	end

	local x,y = findEmpty()
	if not x then
		error'PLAYER CANT SPAWN ON RESET - SOMETHING IS WRONG'
	end
	for _,player in ipairs(players) do
		player:spawn(x,y)
	end

	nextTick=time()
	speed=10

	for i=1,10 do
		placeFruit()
	end
end
reset()

update=||do
	cls(1)
	tilemap(0,0,mapw,maph,0,0)
	
	if #messages>0 then
		text(messages[1], 0, 0, 0xfc, -1)	-- TODO make this not a part of the gameplay
		if time()>lastMessageTime+5 then
			messages:remove(1)
			if #messages>0 then
				lastMessageTime=time()
			end
		end
	end

	-- check new players
	for playerIndex=0,maxPlayers-1 do
		local player = players[playerIndex]
		if player then
			player:getInput()
		else
			for buttonIndex=0,7 do
				if btn(buttonIndex,playerIndex) then
					local x,y = findEmpty()
					if x then
						player = Player(playerIndex)
						player:spawn(x,y)
						players[playerIndex] = player
					end
				end
			end
		end
	end

	for _,player in pairs(players) do
		player:getInput()
	end

	local t=time()
	if t < nextTick then return end
	nextTick=t+speed/60

	for _,player in pairs(players) do
		player:update()
	end
end
