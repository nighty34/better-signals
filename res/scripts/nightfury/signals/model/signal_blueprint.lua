SignalBlueprint = {}
SignalBlueprint.__index = SignalBlueprint
SignalBlueprint.__type = "SignalBlueprint"

function SignalBlueprint:new(name, signalType, isAnimated, preSignalTriggerKey, preSignalTriggerValue)
    local obj = setmetatable({}, self)
    obj.name = name
    obj.type = signalType
    obj.animate = isAnimated
    obj.preSignalTriggerKey = preSignalTriggerKey
    obj.preSignalTriggerValue = preSignalTriggerValue

    return obj
end

function SignalBlueprint:fromParameters(name, parameters)
    if not parameters then
        return nil
    end

    return self:new(
        name,
        parameters.type or "main",
        parameters.isAnimated or false,
        parameters.preSignalTriggerKey or nil,
        parameters.preSignalTriggerValue or nil
    )
end

function SignalBlueprint:ensureMeta(obj)
    if getmetatable(obj) ~= self then
        setmetatable(obj, self)
    end
    return obj
end

function SignalBlueprint:getType()
    return self.type
end

function SignalBlueprint:isAnimated()
    return self.animate
end

function SignalBlueprint:getName()
    return self.name
end

function SignalBlueprint:getPreSignalTiggerKey()
    return self.preSignalTriggerKey
end

function SignalBlueprint:getPreSignalTriggerValue()
    return self.preSignalTriggerValue
end

return SignalBlueprint