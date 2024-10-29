w,h=32,32
hflip=0x4000
vflip=0x8000
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
	snakeUpRight=33|hflip,
	snakeDownLeft=33|vflip,
	snakeDownRight=33|hflip|vflip,
	snakeLeftRight=34,
	snakeEndUp=64,
	snakeEndDown=64|vflip,
	snakeEndLeft=65,
	snakeEndRight=65|vflip,
	snakeVertOverHorz=96,
	snakeHorzOverVert=97,
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
end
reset()

update=[]do
	cls(1)
	map(0,0,w,h,0,0)

	nextDir=nil
	if btnp(0,0,5,5) and dir ~= 1 then
		nextDir=0
	elseif btnp(1,0,5,5) and dir ~= 0 then
		nextDir=1
	elseif btnp(2,0,5,5) and dir ~= 3 then
		nextDir=2
	elseif btnp(3,0,5,5) and dir ~= 2 then
		nextDir=3
	end

	if nextDir then
		local dx,dy=table.unpack(dirs[nextDir])
		newX=snakeX+dx
		newY=snakeY+dy
		newX%=w
		newY%=h
		local i=mget(newX, newY)
		
		-- check for free movement or overlap/underlap ...
		blocked=nil
		if i~=sprites.empty then
			if (
				(nextDir==0 or nextDir==1) 
				and (i==sprites.snakeLeftRight) 
				and mget(newX+dx,newY+dy)==sprites.empty
			)
			or (
				(nextDir==2 or nextDir==3) 
				and (i==sprites.snakeUpDown) 
				and mget(newX+dx,newY+dy)==sprites.empty
			)
			then
				-- skip
				mset(newX,newY,sprites.snakeVertOverHorz)
				newX+=dx
				newY+=dy
			else
				blocked=true
			end
		end

		if not blocked then
			mset(snakeX,snakeY,snakeBodies[dir~1][nextDir] or sprites.snakeBody)
			dir=nextDir
			mset(newX,newY,sprites.snakeUp+dir)
			snake:insert(1,{newX,newY,dir})
			snakeX,snakeY=newX,newY
		end
	end
end
