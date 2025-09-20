-- not yet used...
local BlobDataAbs = require 'numo9.blob.dataabs'

local BlobBrush = BlobDataAbs:subclass()

BlobBrush.filenamePrefix = 'brush'
BlobBrush.filenameSuffix = '.lua'

return BlobBrush
