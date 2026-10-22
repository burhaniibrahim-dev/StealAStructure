local ZoneRegistry = function(player, ZONES)
    local character = player.Character or player.CharacterAdded:Wait()
    local root = character:WaitForChild("HumanoidRootPart")

    local foundZone = nil
    local foundPriority = 0

    for i, zone in ZONES do
        if not zone:IsDescendantOf(workspace) then continue end
        local pos = zone.CFrame:ToObjectSpace(root.CFrame).Position

        if (math.abs(pos.X) <= (zone.Size.X/2)) 
        and (math.abs(pos.Z) <= (zone.Size.Z/2)) then
            if foundZone ~= nil then -- inside a zone already
                local priority = zone:GetAttribute("Priority") or 0
                if foundPriority >= priority then
                    continue
                else
                    foundPriority = priority
                end
            end

            foundZone = zone

        end
    end

    if foundZone then
        return foundZone:GetAttribute("Id")
    else
        return nil
    end

end

return ZoneRegistry