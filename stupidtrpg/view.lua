View=class()
View.size=(screenSize/16):floor()
View.bbox=box2(1,View.size)
View.center = (View.size/2):ceil()
View.update=|:,mapCenter|do
	self.delta= mapCenter - self.center
end
View.drawBorder=|:,b|do
	rectb(
		16 * b.min.x,
		16 * b.min.y,
		16 * (b.max.x - b.min.x),
		16 * (b.max.y - b.min.y),
		12
	)
end
view = View()
