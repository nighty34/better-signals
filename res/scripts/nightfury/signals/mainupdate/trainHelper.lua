local trainHelper = {}

local modelsLengthCache = {}

---Get's trains within a radius from a coordinate position on the map
---@param coord any
---@param range number
---@return table<number, api.type.ComponentType.TRANSPORT_VEHICLE> map of vehicleId to vehicle component
function trainHelper.getTrainsToEvaluate(coord, range)
	local vehicleIds = game.interface.getEntities({pos=coord, radius = range}, {type="VEHICLE"})
	local trains = trainHelper.getTrains(vehicleIds)
	return trains
end


--- @param vehicleIds [string] | [number]
--- @return table<number, api.type.ComponentType.TRANSPORT_VEHICLE>
--- returns table with key vehicle Id, and value vehicles (api.type.ComponentType.TRANSPORT_VEHICLE, not vehicle Id)
function trainHelper.getTrains(vehicleIds)
	local matrix={}
	for _, vehicleId in pairs(vehicleIds) do
		local vehicle = trainHelper.getVehicleComponent(vehicleId)
		if vehicle and vehicle.carrier then
			if vehicle.carrier == api.type.enum.JournalEntryCarrier.RAIL then
				matrix[vehicleId] = vehicle
			end
		end
	end
	return matrix
end

--- @param vehicleId string | number
--- @return boolean
function trainHelper.isTrain(vehicleId)
	local vehicle = trainHelper.getVehicleComponent(vehicleId)
	if vehicle and vehicle.carrier then
		if vehicle.carrier == api.type.enum.JournalEntryCarrier.RAIL then
			return true
		end
	end
	return false
end
--- Gets the Vehicle component (api.engine.getComponent(lineId, api.type.ComponentType.TRANSPORT_VEHICLE)) safely
---@param vehicleId number | string : the id of the entity
---@return api.type.ComponentType.TRANSPORT_VEHICLE | nil
function trainHelper.getVehicleComponent(vehicleId)
	if type(vehicleId) == "string" then vehicleId = tonumber(vehicleId) end
	if not(type(vehicleId) == "number") then return nil end

	local exists = api.engine.entityExists(vehicleId)

	if exists then
		local vehComp = api.engine.getComponent(vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE)
		if vehComp and vehComp.config then
			return vehComp
		end
	end

	return nil
end

---Locations of trains. Return map of edge to vehicleId. Index is edgeId for fast lookup
---@param trains table<number, api.type.ComponentType.TRANSPORT_VEHICLE>
---@return table<number, vehicleId> mapEdgeIdsToTrains Map of edgeEntityId to vehicleId. Indexed by edgeEntityId for faster lookup
function trainHelper.computeTrainLocs(trains)
	local mapEdgeIdsToTrains = {}
	for vehicleId, vehComp in pairs(trains) do
		local edges = trainHelper.edgesTrainIsOn(vehicleId, vehComp)
		for _, edgeEntityId in ipairs(edges) do
		mapEdgeIdsToTrains[edgeEntityId] = vehicleId
		end
	end
	return mapEdgeIdsToTrains
end


---Get all the edges occupied by train
---@param vehicleId number
---@param vehComp any
---@return table<number> list of edges occupied by train
function trainHelper.edgesTrainIsOn(vehicleId, vehComp)
	local edgeEntityIds = {}
	-- Get Egde for midpoint of train
	local path = api.engine.getComponent(vehicleId, api.type.ComponentType.MOVE_PATH)
	local midpointIdx = trainHelper.getPathIdxForTrainMidpoint(path)
	if midpointIdx > 0 then
		local midpointEdgeId = path.path.edges[midpointIdx].edgeId.entity
		table.insert(edgeEntityIds, midpointEdgeId)

		-- find train length
		local trainLength = trainHelper.getTrainLength(vehComp)
		local edgeLength = trainHelper.getEdgeLength(midpointEdgeId)
		local targetLen = trainLength - edgeLength
		if trainLength < edgeLength then
		return edgeEntityIds
		end

		local sideTargetLen = targetLen/2
		-- Add edges to both sides till hit length of train
		local forward = trainHelper.edgesTillLength(path, midpointIdx, sideTargetLen, -1)
		local backwards = trainHelper.edgesTillLength(path, midpointIdx, sideTargetLen, 1)
		return trainHelper.join(edgeEntityIds, forward, backwards)
	end

	return edgeEntityIds
end

---Get's a train position on the map
---@param vehicleId any must be a train
---@return [number]|nil - X,y coordinates
function trainHelper.getTrainPos(vehicleId)
	local path = api.engine.getComponent(vehicleId, api.type.ComponentType.MOVE_PATH)
	local midpointIdx = trainHelper.getPathIdxForTrainMidpoint(path)
	if midpointIdx > 0 then
		local midpointEdgeId = path.path.edges[midpointIdx].edgeId.entity
		local entity = api.engine.getComponent(midpointEdgeId, api.type.ComponentType.BASE_EDGE)
		if entity then
			local nodePos = trainHelper.getNodePos(entity.node0)
			return { nodePos.x, nodePos.y}
		end
	end

	return nil
end

function trainHelper.getNodePos(nodeId)
	local comp = api.engine.getComponent(nodeId, api.type.ComponentType.BASE_NODE)
	local position = comp.position
	return position
end

--- Get edges till target length reached
--- @param path any path component of vehicle
--- @param startIdx number index in path.edges to start from
--- @param targetLen number target length to reach  
--- @param increment number either 1 or -1 to go forward or backward
--- @return table<number> list of edgeEntityIds
function trainHelper.edgesTillLength(path, startIdx, targetLen, increment)
	local res = {}
	local totalLen = 0
	local endIdx = 1
	if increment == 1 then
		endIdx = #path.path.edges
	end

	local prevEdgeId =  path.path.edges[startIdx].edgeId.entity
	for i = startIdx + increment, endIdx, increment do
		local edgeEntityId = path.path.edges[i].edgeId.entity
		if prevEdgeId ~= edgeEntityId  then
		table.insert(res, edgeEntityId)
		totalLen = totalLen + trainHelper.getEdgeLength(edgeEntityId)
		if totalLen > targetLen + 50 then
			break
		end
		end
	end
	return res
end

---Edge id for for midpoint of train
---@param path any
---@return number
function trainHelper.getPathIdxForTrainMidpoint(path)
	if path and path.dyn then
		local positionIdx = path.dyn.pathPos.edgeIndex
		if path.dyn.speed == 0 then
		-- stopped train
		if #path.path.edges == 1 or (#path.path.edges > 0 and positionIdx < 1) then
			positionIdx = 1
		end
		end
		if #path.path.edges > 0 and positionIdx == 0 then
		-- happens when half train cutoff (signal added on track train is occupying or train changed)
		positionIdx = 1
		end
		return positionIdx
	end

	return -1
end

function trainHelper.getTrainLength(vehicleComp)
	local length = 0
		for _, trainUnit in pairs(vehicleComp.transportVehicleConfig.vehicles) do
		local modelLength = modelsLengthCache[trainUnit.part.modelId]
		if modelLength == nil then
		local model = api.res.modelRep.get(trainUnit.part.modelId)
		modelsLengthCache[trainUnit.part.modelId] = model.boundingInfo.bbMax.x - model.boundingInfo.bbMin.x
		modelLength = model.boundingInfo.bbMax.x - model.boundingInfo.bbMin.x
		end

		length = length + modelLength
	end
	return length
end

---Gets edge length
---@param edgeId number
---@return integer
function trainHelper.getEdgeLength(edgeId)
	local edgeTn = api.engine.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
	local length = 0
	if edgeTn and edgeTn.edges then
		local edges = edgeTn.edges
		for i = 1, #edges, 1 do
		length = length + edges[i].geometry.length
		end
	end
	return length
end

---@param vehicleComp any
-- returns returns line name of vehicle
function trainHelper.getLineNameOfVehicle(vehicleComp)
	if vehicleComp and vehicleComp.line then
		return trainHelper.getEntityName(vehicleComp.line)
	else
		return "ERROR"
	end
end

--- Gets the name of an entity
---@param entityId number | string : the id of the entity
---@return string : entityName
function trainHelper.getEntityName(entityId)
	if type(entityId) == "string" then entityId = tonumber(entityId) end
	if not(type(entityId) == "number") then return "ERROR" end

	local exists = api.engine.entityExists(entityId)

	if exists then
		local entity = api.engine.getComponent(entityId, api.type.ComponentType.NAME)
		if entity and entity.name then
			return entity.name
		end
	end

	return "ERROR"
end

-- Can move to utils
function trainHelper.join(table1, table2, table3)
	local newTable = {}
	for _, v in ipairs(table1) do
		table.insert(newTable, v)
	end
	for _, v in ipairs(table2) do
		table.insert(newTable, v)
	end
	for _, v in ipairs(table3) do
		table.insert(newTable, v)
	end
	return newTable
end

return trainHelper