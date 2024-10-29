w,h=32,32

sprites={
	empty=7,
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
	snake=table()
	snakeX = math.random(0,w-1)
	snakeY = math.random(0,h-1)
	snake:insert{snakeX,snakeY}
	mset(snakeX,snakeY,sprites.snakeUp+dir)


	nextTick=time()
	speed=1/2
	
	placeFruit()
end
reset()

update=[]do
	map(0,0,w,h,0,0)

	for i=0,3 do
		if btn(i) then
			dir=i
		end
	end

	local t=time()
	if t < nextTick then return end
	nextTick = t+speed
trace()
--trace('setting body', snakeX, snakeY, sprites.snakeBody)
	mset(snakeX, snakeY, sprites.snakeBody)
	local dx,dy = table.unpack(dirs[dir])
	snakeX+=dx
	snakeY+=dy
	if snakeX<0 or snakeX>=w or snakeY<0 or snakeY>=h then
		trace'YOU LOSE'
		reset()
	end
	local i = mget(snakeX, snakeY) 
	if i == sprites.fruit then
		snake:insert(1, {snakeX, snakeY})
	elseif i ~= 0 then
		trace'YOU LOSE'
		reset()
	else
		snake:insert(1, {snakeX, snakeY})
		local tailX, tailY = table.unpack(snake:remove())
trace('removing', tailX, tailY, sprites.empty)
		mset(tailX, tailY, sprites.empty)
	end
trace('setting ', snakeX, snakeY, sprites.snakeUp+dir)
	mset(snakeX, snakeY, sprites.snakeUp+dir)
end
