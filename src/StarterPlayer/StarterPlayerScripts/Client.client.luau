--Responsibility: Startup Client Functions
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _Networker = require(ReplicatedStorage.Shared.Networker.Client)

local ClickService = require(ReplicatedStorage.Client.ClickService)

ClickService.Init()

--=====================================================================

