w,h=32,32
hflip=0x4000
vflip=0x8000
sprites={
	empty=0,
	snakeUp=1,
	snakeDown=2,
	snakeLeft=3,
	snakeRight=4,
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
	snakeEndRight=65|hflip,
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
	tail={
		[0]=sprites.snakeEndUp,
		[1]=sprites.snakeEndDown,
		[2]=sprites.snakeEndLeft,
		[3]=sprites.snakeEndRight,
	},
}

dirs={
	[0]={0,-1},
	[1]={0,1},
	[2]={-1,0},
	[3]={1,0},
}

local snakeHist=table()
pushSnakeHist=[]do
	snakeHist:insert(snake:mapi([s]{table.unpack(s)}))
end
popSnakeHist=[]do
	snake=snakeHist:remove()
	snakeX,snakeY,dir=table.unpack(snake[1])
	done=false
end

reset=[]do
	for j=0,h-1 do
		for i=0,w-1 do
			mset(i,j,0)
		end
	end
	snakeHist=table()
	done=false
	dir=4
	snake=table()
	snakeX=tonumber(w//2)
	snakeY=tonumber(h//2)
	snake:insert{snakeX,snakeY,dir}
end

snakeCalcSprite=[i]do
	local prevLinkDir = i>1 and snake[i-1][3] or nil
	local x,y,linkDir,crossing,linkDone = table.unpack(snake[i])
	if crossing then
		return sprites[crossing]
	elseif #snake==1 then
		return sprites.snakeDown
	else
		if i==1 then
			if done then
				return snakeBodies[linkDir][linkDir~1]
			else
				return sprites.snakeUp + linkDir
			end
		elseif i==#snake then
			if done then
				return snakeBodies[prevLinkDir][prevLinkDir~1]	-- use prevLinkDir since linkDir for the tail is 4 / invalid
			else
				return snakeBodies.tail[prevLinkDir]
			end
		else
			return snakeBodies[prevLinkDir][linkDir~1]
		end
	end
end

redraw=[]do
	cls(1)
	map(0,0,w,h,0,0)
	local prevLinkDir
	for i,link in ipairs(snake) do
		local x,y,linkDir,crossing = table.unpack(link)
		local spriteIndex = snakeCalcSprite(i)
		local sx = spriteIndex & hflip ~= 0
		local sy = spriteIndex & vflip ~= 0
		spr(spriteIndex&0x3ff,(x + (sx and 1 or 0))<<3,(y + (sy and 1 or 0))<<3,1,1,0,-1,0,0xff,sx and -1 or 1,sy and -1 or 1)
		prevLinkDir=linkDir
	end
end
snakeGet=[x,y]do
	for i=#snake,1,-1 do
		local link=snake[i]
		if link[1]==x and link[2]==y then 
			return snakeCalcSprite(i), i
		end
	end
	return sprites.empty
end

reset()
update=[]do
	redraw()

	if btnp(4) and #snakeHist>0 then
		popSnakeHist()
		if snake[1][4] then	-- don't leave us hanging at a crossing
			popSnakeHist()
		end
		return
	end
	if btnp(6) then
		reset()
		return
	end
	if done then return end

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
		local moveVert=nextDir&2==0
		local moveHorz=not moveVert
		local dx,dy=table.unpack(dirs[nextDir])
		newX=snakeX+dx
		newY=snakeY+dy
		newX%=w
		newY%=h
		local spriteIndex,snakeIndex=snakeGet(newX, newY)

		-- check for free movement or overlap/underlap ...
		blocked=nil
		if spriteIndex~=sprites.empty then
			-- TODO multiple over/under?
			if (
				moveVert
				and (spriteIndex==sprites.snakeLeftRight)
				and snakeGet(newX+dx,newY+dy)==sprites.empty
			)
			or (
				moveHorz
				and (spriteIndex==sprites.snakeUpDown)
				and snakeGet(newX+dx,newY+dy)==sprites.empty
			)
			then
				-- skip
				local vertOverHorz = moveVert
				if btn(5) or btn(7) then
					vertOverHorz = not vertOverHorz
				end
				local crossing = vertOverHorz
					and 'snakeVertOverHorz'
					or 'snakeHorzOverVert'
				local j=sprites[crossing]
				pushSnakeHist()
				snake[snakeIndex][4]=crossing
				snake:insert(1,{newX,newY,nextDir,crossing})
				newX+=dx
				newY+=dy
			elseif moveVert and (spriteIndex==sprites.snakeEndUp or spriteIndex==sprites.snakeEndDown) then
				--snake:last()[3]=sprites.snakeUpDown
				done=true
			elseif moveHorz and (spriteIndex==sprites.snakeEndLeft or spriteIndex==sprites.snakeEndRight) then
				--snake:last()[3]=sprites.snakeLeftRight
				done=true
			else
				blocked=true
			end
		end

		if not blocked then
			dir=nextDir
			pushSnakeHist()
			snake:insert(1,{newX,newY,dir,nil,done})
			snakeX,snakeY=newX,newY
		end
	end
end
