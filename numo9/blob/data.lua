local BlobDataAbs = require 'numo9.blob.dataabs'

local BlobData = BlobDataAbs:subclass()

BlobData.filenamePrefix = 'data'
BlobData.filenameSuffix = '.bin'

return BlobData
