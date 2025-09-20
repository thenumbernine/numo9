local BlobDataAbs = require 'numo9.blob.dataabs'

local BlobMusic = BlobDataAbs:subclass()

BlobMusic.filenamePrefix = 'music'
BlobMusic.filenameSuffix = '.bin'

return BlobMusic 
