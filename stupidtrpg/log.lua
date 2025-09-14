Log=class{
	index=0,
	lines=table(),
	size=4,
	__call=|:,s|do
		local lines = string.split(s, '\n')
		for _,line in ipairs(lines) do
			line=self.index..'> '..line
			while #line>ui.size.x do
				self.lines:insert(line:sub(1,ui.size.x))
				line = line:sub(ui.size.x+1)
				self.index+=1
			end
			self.lines:insert(line)
			self.index+=1
		end
		while #self.lines > self.size do
			self.lines:remove(1)
		end
	end,
	render=|:|do
		for i=1,self.size do
			local line = self.lines[i]
			con.locate(1, ui.size.y+i)
			if line then
				con.write(line)
			end
			con.clearline()
		end
	end,
}
log=Log()
