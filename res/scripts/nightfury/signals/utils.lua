local utils =  {}
local config_debug = false

--- Get speed of edge by edgeId
--- @param edgeId table reference to edge
--- @param transportNetwork table api.type.ComponentType.TRANSPORT_NETWORK
--- @return number speed as number or math.huge if speed can't be evaluated
function utils.getEdgeSpeed(edgeId, transportNetwork)
	local speed = math.huge
	if not (transportNetwork == nil) then
		local index = 1 + edgeId.index
		if index > #transportNetwork.edges then
			print("Index is too high on " .. edgeId.edge)
		else
			local edges = transportNetwork.edges[index]

			speed = math.min(edges.speedLimit, speed)
			speed = math.min(edges.curveSpeedLimit, speed)
		end
	end
	return speed * 3.6
end

-- Get component from entity
-- @param entityId reference to entity given as number
-- @param componentId id of the component that should be returned
-- @return retuns component or nil if the component isn't attatched to referenced entity
function utils.getComponentProtected(entityId, componentId)
	if pcall(function() api.engine.getComponent(entityId, componentId) end) then
		return api.engine.getComponent(entityId, componentId)
	else
		return nil
	end
end

-- Update existing construction
-- @param params parameter by which the new construction should be build
-- @param reference is a reference to the old entity. This is used to check if the new entity still holds the same id as before
function utils.updateConstruction(params, reference)
	params.params.seed = nil

	local proposal = api.type.SimpleProposal.new()
	proposal.constructionsToRemove = {}
	local pd = api.engine.util.proposal.makeProposalData(proposal, {})
	if pd.errorState.critical == true then
		print(pd.errorState.messages[1] .. " : " .. params.fileName)
	else
		if pcall(function () 
			local check = game.interface.upgradeConstruction(params.id, params.fileName, params.params)
			if check ~= reference then
				print("Construction upgrade error")
			end
		end) then
		else
			print("Programmical Error during Upgrade")
		end
	end
end

-- Get minimal value from table
-- @param tbl table with number values
-- @return lowest value as a number
function utils.getMinValue(tbl)
	local minValue = math.huge
	for _, value in ipairs(tbl) do
		minValue = math.min(minValue, value)
	end

	return minValue
end


-- I had a rare issue where checksums collided so didn't update red signal to a green signal. I think it's due to the addition - You normally multiply for checksums
-- We make sure the last 2 numbers in the checksum are determined by signal state and index. This forces an update if a signal goes from green to red
---Updates signal paths with checksums
---@param res [SignalPath]
function utils.addChecksumToSignals(res)
	local cleanChecksum = 0
	for i = #res, 1, -1 do
		local currentSegment = res[i]
		cleanChecksum = cleanChecksum + utils.checksum(currentSegment.entity, currentSegment.signal_state, currentSegment.signal_speed)

		-- signalUniqueSum - a number between 0 and 7 indicative of the state of the signal and 2 following signals. Using bitwise maths
		local signalStateVal = currentSegment.signal_state
		if currentSegment.following_signal then
			signalStateVal = signalStateVal + (currentSegment.following_signal.signal_state * 2)
			if currentSegment.following_signal.following_signal then
				signalStateVal = signalStateVal + (currentSegment.following_signal.following_signal.signal_state * 4)
			end
		end
		currentSegment.checksum = (cleanChecksum * 100) + (i * 10) + signalStateVal
	end
end

-- Create Checksum from values
-- @param operator this is a multiplier which will be multiplied to the final checksum
-- @param ... all the values that should from the final checksum
-- @return returns a checksum as number
function utils.checksum(operator, ...)
	local args = {...}
	local localsum = 0
		for _, arg in ipairs(args) do
		if arg ~= nil then
			localsum = localsum + tonumber(arg)
		end
	end

	return localsum * operator
end

-- Check if string starts with substring
-- @param str string that should be checked
-- @param start string that should be checked for
-- @return returns true if str starts with start. Otherwise false
function utils.starts_with(str, start)
	return str:sub(1, #start) == start
end

-- Remove all values from table by value
-- @param tbl table that should be removed from
-- @param remove value that should be removed
function utils.removeFromTableByValue(tbl, remove)
	for key, value in ipairs(tbl) do
		if value == remove then
			table.remove(tbl, key)
		end
	end
end

-- Check if table contains
-- @param tbl table that should is checked
-- @param value the value that is checked for
-- @return returns true if value is in tbl. Otherwise false
function utils.contains(tbl, value)
	local found = false
		for _, v in pairs(tbl) do
			if v == value then
				found = true
			end
		end
	return found
end


function utils.deepCopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == 'table' then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[utils.deepCopy(orig_key)] = utils.deepCopy(orig_value)
		end
		setmetatable(copy, utils.deepCopy(getmetatable(orig)))
	else
		copy = orig
	end
	return copy
end

function utils.dictToString(tbl)
	if tbl == nil then
		return ""
	end

    local result = "{"
    for k, v in pairs(tbl) do
        result = result .. "[" .. tostring(k) .. "] = " .. tostring(v) .. ", "
    end
    result = result:sub(1, -3) .. "}"  -- Remove last comma and space
    return result
end

---Print a message when debug
---@param ... unknown
function utils.debugPrint(...)
	if config_debug then
		print(...)
	end
end


function utils.debugPrintVehicle(vehicleId)
	if config_debug then
		print("----------")
		local vehNameEnt = api.engine.getComponent(vehicleId, api.type.ComponentType.NAME)
		print("Vehicle " .. vehicleId .. " Name: " .. vehNameEnt.name)
	end
end

return utils