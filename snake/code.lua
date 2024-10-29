w,h=32,32

sprites={
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
}

dirs={
	[0]={0,-1},
	[1]={0,1},
	[2]={-1,0},
	[3]={1,0},
}

placeFruit=[]do
	local empty=table()
	for j=0,h-1 do
		for i=0,w-1 do
			if mget(i,j)==sprites.empty then
				empty:insert{i,j}
			end
		end
	end
	if #empty==0 then	-- then the screen is full ... you mustve won ...
		trace'YOU WON'
		-- error or something
		reset()
		return
	end
	fruitX,fruitY=table.unpack(empty:pickRandom())
	mset(fruitX,fruitY,sprites.fruit)
end

reset=[]do
	-- stall
	for i=1,60 do flip() end
	
	for j=0,h-1 do
		for i=0,w-1 do
			mset(i,j,sprites.empty)
		end
	end
	
	dir=1
	nextDir=1
	snake=table()
	snakeX=tonumber(w//2)
	snakeY=tonumber(h//2)
	snake:insert{snakeX,snakeY}
	mset(snakeX,snakeY,sprites.snakeUp+dir)

	nextTick=time()
	speed=15
	
	placeFruit()
end
reset()

update=[]do
	cls(1)
	map(0,0,w,h,0,0)	--,0,true)

	if btn(0) and dir ~= 1 then
		nextDir=0
	elseif btn(1) and dir ~= 0 then
		nextDir=1
	elseif btn(2) and dir ~= 3 then
		nextDir=2
	elseif btn(3) and dir ~= 2 then
		nextDir=3
	end

	local t=time()
	if t < nextTick then return end
	nextTick=t+speed/60

	mset(snakeX,snakeY,snakeBodies[dir~1][nextDir] or sprites.snakeBody)
	dir=nextDir
	local dx,dy=table.unpack(dirs[dir])
	snakeX+=dx
	snakeY+=dy
	if snakeX<0 or snakeX>=w or snakeY<0 or snakeY>=h then
		trace'YOU LOSE'
		reset()
	end
	local i=mget(snakeX, snakeY) 
	mset(snakeX, snakeY, sprites.snakeUp+dir)
	if i==sprites.fruit then
		snake:insert(1,{snakeX,snakeY,dir})
		speed=math.max(1,speed-1)
		placeFruit()
	elseif i~=sprites.empty then
		trace'YOU LOSE'
		reset()
	else
		snake:insert(1, {snakeX, snakeY})
		local tailX,tailY,tailDir=table.unpack(snake:remove())
		mset(tailX,tailY,sprites.empty)
	end
end
