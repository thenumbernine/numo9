w,h=32,32

sprites={
	empty=0,
	--empty=7,
	snakeUp=1,
	snakeDown=2,
	snakeLeft=3,
	snakeRight=4,
	snakeBody=5,
	fruit=6,
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
	fruitX,fruitY = table.unpack(empty:pickRandom())
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
	snakeX = math.random(0,w-1)
	snakeY = math.random(0,h-1)
	snake:insert{snakeX,snakeY}
	mset(snakeX,snakeY,sprites.snakeUp+dir)

	nextTick=time()
	speed=15
	
	placeFruit()
end
reset()

update=[]do
	cls(1)
	map(0,0,w,h,0,0)

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
	nextTick = t+speed/60

	mset(snakeX, snakeY, sprites.snakeBody)
	dir=nextDir
	local dx,dy = table.unpack(dirs[dir])
	snakeX+=dx
	snakeY+=dy
	if snakeX<0 or snakeX>=w or snakeY<0 or snakeY>=h then
		trace'YOU LOSE'
		reset()
	end
	local i = mget(snakeX, snakeY) 
	mset(snakeX, snakeY, sprites.snakeUp+dir)
	if i == sprites.fruit then
		snake:insert(1, {snakeX, snakeY})
		speed=math.max(1,speed-1)
		placeFruit()
	elseif i ~= 0 then
		trace'YOU LOSE'
		reset()
	else
		snake:insert(1, {snakeX, snakeY})
		local tailX, tailY = table.unpack(snake:remove())
		mset(tailX, tailY, sprites.empty)
	end
end
