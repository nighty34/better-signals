local utils = require "nightfury/signals/utils"


BetterSignal = {}
BetterSignal.__index = BetterSignal
BetterSignal.__type = "BetterSignal"

function BetterSignal:new(signal_entity, construction, signalBlueprint)
    local obj = setmetatable({}, self)
    obj.entity = signal_entity
    obj.construction = construction
    obj.signalBlueprint = signalBlueprint

    obj.signal_state = 0 -- 0 = red, 1 = green
    obj.signal_speed = 0 -- speed between this and the next signal
    obj.paramsOverride = {} -- values fed by waypoints
    obj.previousSignal = nil
    obj.nextSignal = nil
    obj.checksum = 0 -- Checksum to evaluate when the signal needs to be updated
    obj.changed = 0
    obj.isStation = false
    obj.isPreSignal = false
    return obj
end

function BetterSignal:setSignalState(signal_state, signalSpeed, paramsOverride, nextSignal)
    self.signal_state = signal_state
    self.signal_speed = signalSpeed
    self.paramsOverride = paramsOverride
    self.nextSignal = nextSignal
end

function BetterSignal:setPreviousSignal(previousSignal)
    self.previousSignal = previousSignal
end

function BetterSignal:setStation(isStation)
    self.isStation = isStation
end

function BetterSignal:getEntity()
    return self.entity
end

function BetterSignal:getBluePrint()
    return self.signalBlueprint
end

function BetterSignal:getBluePrintName()
    if self.signalBlueprint and self.signalBlueprint.name then
        return self.signalBlueprint.name
    end
    return ""
end

function BetterSignal:isAnimated()
    return self.signalBlueprint and self.signalBlueprint:isAnimated()
end

function BetterSignal:getAsSavedEntry()
    if self.signalBlueprint and self.signalBlueprint.name then
        return {
            construction = self.construction,
            entity = self.entity,
            signalBlueprintName = self.signalBlueprint.name,
        }
    end
    return  {
        construction = self.construction,
        entity = self.entity,
    }
end

function BetterSignal:getAsFollowingSignal()
    if self.nextSignal then
        return {
            signal_state = self.nextSignal.signal_state,
            signal_speed = self.nextSignal.signal_speed,
            previous_speed = self.signal_speed,
            isStation = self.isStation,
            paramsOverride = self.nextSignal.paramsOverride,
            params = self:getConstructionParameters(true),
            following_signal = self.nextSignal:getAsFollowingSignal()
        }
    else
        return {
            signal_state = 0,
            signal_speed = 0,
            previous_speed = self.signal_speed,
            isStation = true, -- todo
            paramsOverride = {}
        }
    end
end

function BetterSignal:isChanged()
    return self.changed == 2
end

function BetterSignal:getConstructionId()
    return self.construction
end

function BetterSignal:getIsStation()
    return self.isStation
end

function BetterSignal:isBetterSignal()
    return self.construction ~= nil
end

function BetterSignal:getConstruction()
    return game.interface.getEntity(self.construction)
end

function BetterSignal:getConstructionParameters(onlyBuildingParams)
    if self.construction and api.engine.entityExists(self.construction) then
        local construction = game.interface.getEntity(self.construction) -- can fail
        if construction and construction.params then
            if onlyBuildingParams then
                construction.params.following_signal = nil
                construction.params.signal_speed = nil
                construction.params.signal_state = nil
                construction.params.paramsOverride = nil
                construction.params.isStation = nil
                construction.params.previous_speed = nil
                construction.params.checksum = nil
            end
            return construction.params
        end
    end
    return {}
end

function BetterSignal:getSignalState()
    return self.signal_state
end

function BetterSignal:getPreviousSpeed()
    if self.previousSignal then
        return self.previousSignal:getSignalSpeed()
    end
    return 0
end

function BetterSignal:getSignalSpeed()
    return math.floor(self.signal_speed)
end

function BetterSignal:getParamOverride()
    return self.paramsOverride
end

function BetterSignal:moveChangedValue()
    self.changed = self.changed * 2
end

function BetterSignal:setChangedFlag()
    self.changed = 1
end

function BetterSignal:resetChangedFlag()
    self.changed = 0
end

function BetterSignal:getChanged()
    return self.changed
end

function BetterSignal:getChecksum()
    local checksum = 0
    if self.nextSignal then
        checksum = self.nextSignal:getChecksum()
    end
    return utils.checksum(self.entity, self.construction or 0, self.signal_state, self.signal_speed, checksum)
end

return BetterSignal