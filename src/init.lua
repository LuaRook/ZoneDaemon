local EnumList = require(script.Parent.EnumList)
local Signal = require(script.Parent.Signal)
local TableUtil = require(script.Parent.TableUtil)
local Timer = require(script.Parent.Timer)
local Trove = require(script.Parent.Trove)

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local IS_STREAMING = workspace.StreamingEnabled

local RNG = Random.new()
local MAX_PART_SIZE = 2048
local EPSILON = 0.001

local Characters = {}
local RootParts = {}

local ZoneDaemon = {}
ZoneDaemon.__index = ZoneDaemon

ZoneDaemon.Accuracy = EnumList.new("Accuracy", { "Precise", "High", "Medium", "Low", "UltraLow" })
ZoneDaemon.Detection = EnumList.new("Detection", { "Character", "RootPart" })

ZoneDaemon.DefaultOverlapParams = OverlapParams.new()
ZoneDaemon.DefaultOverlapParams.FilterDescendantsInstances = {}
ZoneDaemon.DefaultOverlapParams.FilterType = Enum.RaycastFilterType.Include

type Signal<T> = typeof(Signal.new()) & {
	Connect: ((T) -> ()),
}

export type ZoneDaemon = typeof(ZoneDaemon) & {
	OnPartEntered: Signal<BasePart>,
	OnPlayerEntered: Signal<BasePart>,
	OnPartLeft: Signal<BasePart>,
	OnPlayerLeft: Signal<Player>,
	OnTableFirstWrite: Signal<nil>,
	OnTableClear: Signal<nil>,
}

local function convertAccuracyToNumber(input)
	if input == ZoneDaemon.Accuracy.High then
		return 0.1
	elseif input == ZoneDaemon.Accuracy.Medium then
		return 0.5
	elseif input == ZoneDaemon.Accuracy.Low then
		return 1
	elseif input == ZoneDaemon.Accuracy.UltraLow then
		return 3
	else
		return EPSILON
	end
end

local function createCube(cubeCFrame, cubeSize, container)
	if cubeSize.X > MAX_PART_SIZE or cubeSize.Y > MAX_PART_SIZE or cubeSize.Z > MAX_PART_SIZE then
		local quarterSize = cubeSize * 0.25
		local halfSize = cubeSize * 0.5

		createCube(cubeCFrame * CFrame.new(-quarterSize.X, -quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(-quarterSize.X, -quarterSize.Y, quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(-quarterSize.X, quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(-quarterSize.X, quarterSize.Y, quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, -quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, -quarterSize.Y, quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, quarterSize.Y, -quarterSize.Z), halfSize, container)
		createCube(cubeCFrame * CFrame.new(quarterSize.X, quarterSize.Y, quarterSize.Z), halfSize, container)
	else
		local part = Instance.new("Part")
		part.CFrame = cubeCFrame
		part.Size = cubeSize

		part.Anchored = true
		part.Parent = container
	end
end

local function isValidContainer(container)
	local listOfParts = {}

	if container then
		if typeof(container) == "table" then
			listOfParts = container
		else
			local children = container:GetChildren()

			if #children > 0 then
				local isContainerABasePart = container:IsA("BasePart")
				local list = table.create(#children + (if isContainerABasePart then 1 else 0))

				if isContainerABasePart then
					table.insert(list, container)
				end

				for _, object in pairs(children) do
					if object:IsA("BasePart") then
						table.insert(list, object)
					else
						warn("ZoneDaemon should only be used on instances with children only containing BaseParts.")
					end
				end

				listOfParts = list
				return listOfParts
			end

			if container:IsA("BasePart") then
				listOfParts = { container }
				return listOfParts
			end
		end
	end

	return if #listOfParts > 0 or IS_STREAMING then listOfParts else nil
end

function ZoneDaemon.new(container, accuracy)
	local listOfParts = isValidContainer(container)
	if not listOfParts then
		error("Invalid Container Type")
	end

	local self = setmetatable({}, ZoneDaemon)
	self._id = HttpService:GenerateGUID(false)
	self._trove = Trove.new()
	self._busy = false
	self._containerParts = listOfParts
	self._intersectingParts = {}
	self._newPartsArray = {}
	self._interactingPartsArray = {}
	self._interactingPlayersArray = {}
	self._elements = {}
	self._currentElements = {}
	self._elementQueryListeners = {}

	self.OverlapParams = ZoneDaemon.DefaultOverlapParams
	self.FilterDescendantsInstances = Characters

	self.OnPartEntered = self._trove:Construct(Signal)
	self.OnPlayerEntered = self._trove:Construct(Signal)
	self.OnPartLeft = self._trove:Construct(Signal)
	self.OnPlayerLeft = self._trove:Construct(Signal)
	self.OnTableFirstWrite = self._trove:Construct(Signal)
	self.OnTableClear = self._trove:Construct(Signal)

	if not IS_SERVER then
		self.OnLocalPlayerEntered = self._trove:Construct(Signal)
		self.OnLocalPlayerLeft = self._trove:Construct(Signal)

		self._trove:Connect(self.OnPlayerEntered, function(Player)
			if Player == Players.LocalPlayer then
				self.OnLocalPlayerEntered:Fire()
			end
		end)

		self._trove:Connect(self.OnPlayerLeft, function(Player)
			if Player == Players.LocalPlayer then
				self.OnLocalPlayerLeft:Fire()
			end
		end)
	end

	local numberAccuracy
	if typeof(accuracy) == "number" then
		numberAccuracy = accuracy
	else
		if not accuracy or not ZoneDaemon.Accuracy:BelongsTo(accuracy) then
			accuracy = ZoneDaemon.Accuracy.High
		end
		numberAccuracy = convertAccuracyToNumber(accuracy)
	end

	self._timer = self._trove:Add(Timer.new(numberAccuracy))
	self._trove:Connect(self._timer.Tick, function()
		if not self._busy then
			table.clear(self._newPartsArray)
			table.clear(self._intersectingParts)
		end
		if #self._containerParts == 0 then
			return
		end

		self._busy = true
		if self.OverlapParams == ZoneDaemon.DefaultOverlapParams then
			self.OverlapParams.FilterDescendantsInstances = self.FilterDescendantsInstances
		end

		local canZonesInGroupIntersect = if self.Group then self.Group:CanZonesTriggerOnIntersect() else true
		for _, part in ipairs(self._containerParts) do
			local newParts = workspace:GetPartsInPart(part, self.OverlapParams)
			for _, newPart in ipairs(newParts) do
				if not canZonesInGroupIntersect and newPart:GetAttribute(self.Group.GroupName) then
					continue
				end
				table.insert(self._newPartsArray, newPart)
				self._intersectingParts[newPart] = part
			end

			table.clear(newParts)
			newParts = nil
		end

		for _, newPart in
			ipairs(TableUtil.Filter(self._newPartsArray, function(part)
				return not table.find(self._interactingPartsArray, part)
			end))
		do
			self.OnPartEntered:Fire(newPart)
			if not canZonesInGroupIntersect then
				newPart:SetAttribute(self.Group.GroupName, true)
				newPart:SetAttribute("ZoneGUID", self._id)
			end
		end

		for _, oldPart in
			ipairs(TableUtil.Filter(self._interactingPartsArray, function(part)
				return not table.find(self._newPartsArray, part)
			end))
		do
			self.OnPartLeft:Fire(oldPart)
			if not canZonesInGroupIntersect then
				oldPart:SetAttribute(self.Group.GroupName, nil)
				oldPart:SetAttribute("ZoneGUID", nil)
			end
		end

		local isInteractingArrayEmpty = #self._interactingPartsArray == 0
		local isNewPartsArrayEmpty = #self._newPartsArray == 0
		if isInteractingArrayEmpty and not isNewPartsArrayEmpty then
			self.OnTableFirstWrite:Fire()
		elseif isNewPartsArrayEmpty and not isInteractingArrayEmpty then
			self.OnTableClear:Fire()
		end

		isInteractingArrayEmpty = nil
		isNewPartsArrayEmpty = nil

		table.clear(self._interactingPartsArray)
		self._interactingPartsArray = table.clone(self._newPartsArray)

		local currentPlayers = {}
		local selectedElement: { [Player]: { dist: number, element: string | nil, elementValue: any } } = {}

		for _, part in ipairs(self._interactingPartsArray) do
			local character = part:FindFirstAncestorOfClass("Model")
			local player = Players:GetPlayerFromCharacter(character)
			if not player then
				continue
			end

			local intersectedPart = self._intersectingParts[part]
			if not intersectedPart then
				continue
			end

			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if #self._elements > 0 and rootPart then
				if not self._currentElements[player] then
					self._currentElements[player] = {}
				end
				if not selectedElement[player] then
					selectedElement[player] = {
						dist = math.huge,
						element = nil,
						elementValue = nil,
					}
				end

				local trueClosestPos = math.huge
				local positions = {
					intersectedPart.Position + Vector3.new(0, intersectedPart.Size.Y, 0),
					intersectedPart.Position + Vector3.new(0, -intersectedPart.Size.Y, 0),
					intersectedPart.Position + Vector3.new(intersectedPart.Size.X, 0, 0),
					intersectedPart.Position + Vector3.new(-intersectedPart.Size.X, 0, 0),
					intersectedPart.Position + Vector3.new(0, 0, intersectedPart.Size.Z),
					intersectedPart.Position + Vector3.new(0, 0, -intersectedPart.Size.Z),
				}

				for _, pos in ipairs(positions) do
					trueClosestPos = math.min(trueClosestPos, (pos - rootPart).Magnitude)
				end

				table.clear(positions)
				positions = nil

				for _, element in ipairs(self._elements) do
					if trueClosestPos < selectedElement[player].dist then
						selectedElement[player] = {
							dist = trueClosestPos,
							element = element,
							elementValue = intersectedPart:GetAttribute(element),
						}
					end
				end
			end

			if not table.find(currentPlayers, player) then
				if
					canZonesInGroupIntersect
					and self.Group
					and player:GetAttribute(self.Group.GroupName)
					and player:GetAttribute("ZoneGUID") ~= self._id
				then
					continue
				end
				table.insert(currentPlayers, player)
			end
		end

		for player, dict in pairs(selectedElement) do
			if not self._currentElements[player] then
				self._currentElements[player] = {}
			end
			local last = self._currentElements[player][dict.element]
			self._currentElements[player][dict.element] = dict.elementValue

			if
				last ~= self._currentElements[player][dict.element]
				and self._elementQueryListeners[player]
				and self._elementQueryListeners[player][dict.element]
			then
				self._elementQueryListeners[player][dict.element]:Fire(dict.elementValue)
			end
		end

		for _, removedPlayer in
			ipairs(TableUtil.Filter(self._interactingPlayersArray, function(currentPlayer)
				return not table.find(currentPlayers, currentPlayer)
			end))
		do
			self.OnPlayerLeft:Fire(removedPlayer)
			if self._elementQueryListeners[removedPlayer] then
				for _, element in ipairs(self._elements) do
					self._elementQueryListeners[removedPlayer][element]:Fire(nil)
					self._currentElements[removedPlayer][element] = nil
				end
			end
			if not canZonesInGroupIntersect then
				removedPlayer:SetAttribute(self.Group.GroupName, nil)
				removedPlayer:SetAttribute("ZoneGUID", nil)
			end
		end

		for _, newPlayer in
			ipairs(TableUtil.Filter(currentPlayers, function(currentPlayer)
				return not table.find(self._interactingPlayersArray, currentPlayer)
			end))
		do
			self.OnPlayerEntered:Fire(newPlayer)
			if not canZonesInGroupIntersect then
				newPlayer:SetAttribute(self.Group.GroupName, true)
				newPlayer:SetAttribute("ZoneGUID", self._id)
			end
		end

		table.clear(self._interactingPlayersArray)
		self._interactingPlayersArray = currentPlayers

		table.clear(selectedElement)
		selectedElement = nil

		self._busy = false
	end)

	self:StartChecks()
	return self
end

function ZoneDaemon.fromRegion(cframe, size, accuracy)
	local container = Instance.new("Model")
	createCube(cframe, size, container)

	return ZoneDaemon.new(container, accuracy)
end

function ZoneDaemon.fromTag(tagName, accuracy)
	local self = ZoneDaemon.new(CollectionService:GetTagged(tagName) or {}, accuracy)

	self._trove:Connect(CollectionService:GetInstanceAddedSignal(tagName), function(instance)
		table.insert(self._containerParts, instance)
	end)

	self._trove:Connect(CollectionService:GetInstanceRemovedSignal(tagName), function(instance)
		table.remove(self._containerParts, table.find(self._containerParts, instance))
	end)

	return self
end

function ZoneDaemon:AddElement(elementName, defaultValue)
	assert(not table.find(self._elements, elementName), "Already defined element name!")

	for _, part in ipairs(self._containerParts) do
		if not part:GetAttribute(elementName) and not defaultValue then
			error("Part " .. part:GetFullName() .. " did not have an element attribute and a default was not provided!")
		elseif defaultValue and (not part:GetAttribute(elementName)) then
			part:SetAttribute(elementName, defaultValue)
		end
	end
	table.insert(self._elements, elementName)
end

function ZoneDaemon:QueryElementForPlayer(elementName, player)
	if not (self:FindPlayer(player)) then
		return
	end
	return self._currentElements[player][elementName]
end

function ZoneDaemon:QueryElementForLocalPlayer(elementName)
	assert(not IS_SERVER, "This function can only be called on the client!")
	return self:QueryElementForPlayer(elementName, Players.LocalPlayer)
end

function ZoneDaemon:ListenToElementChangesForPlayer(elementName, player)
	if not self._elementQueryListeners[player] then
		self._elementQueryListeners[player] = {}
	end
	if self._elementQueryListeners[player][elementName] then
		self._elementQueryListeners[player][elementName]:Destroy()
	end

	local signal = self._trove:Construct(Signal)
	self._elementQueryListeners[player][elementName] = signal

	return signal
end

function ZoneDaemon:ListenToElementChangesForLocalPlayer(elementName)
	assert(not IS_SERVER, "This function can only be called on the client!")
	return self:ListenToElementChangesForPlayer(elementName, Players.LocalPlayer)
end

function ZoneDaemon:StartChecks()
	self._timer:StartNow()
end

function ZoneDaemon:HaltChecks()
	self._timer:Stop()
end
ZoneDaemon.StopChecks = ZoneDaemon.HaltChecks

function ZoneDaemon:IsInGroup(): boolean
	return self.Group ~= nil
end

function ZoneDaemon:Hide()
	for _, part in pairs(self._containerParts) do
		part.Transparency = 1
		part.Locked = true
	end
end

function ZoneDaemon:AdjustAccuracy(input)
	if ZoneDaemon.Accuracy:BelongsTo(input) then
		self._timer.Interval = convertAccuracyToNumber(input)
	elseif type(input) == "number" then
		self._timer.Interval = input
	end
end

function ZoneDaemon:AdjustDetection(input)
	if not ZoneDaemon.Detection:BelongsTo(input) then
		error(string.format("%q is not a valid member of the Detection EnumList.", tostring(input)))
	end

	local filterDescendantsInstances = if input == ZoneDaemon.Detection.Character then Characters else RootParts
	self.FilterDescendantsInstances = filterDescendantsInstances
end

function ZoneDaemon:GetRandomPoint(): Vector3
	local selectedPart = self._containerParts[RNG:NextInteger(1, #self._containerParts)]
	return (selectedPart.CFrame * CFrame.new(
		RNG:NextNumber(-selectedPart.Size.X / 2, selectedPart.Size.X / 2),
		RNG:NextNumber(-selectedPart.Size.Y / 2, selectedPart.Size.Y / 2),
		RNG:NextNumber(-selectedPart.Size.Z / 2, selectedPart.Size.Z / 2)
	)).Position
end

function ZoneDaemon:GetPlayers(): { Player }
	return self._interactingPlayersArray
end

function ZoneDaemon:FilterPlayers(callback: (plr: Player) -> boolean): { Player }
	return TableUtil.Filter(self:GetPlayers(), callback)
end

function ZoneDaemon:FindPlayer(player): boolean
	return table.find(self:GetPlayers(), player) ~= nil
end

function ZoneDaemon:FindLocalPlayer(): boolean
	assert(not IS_SERVER, "This function can only be called on the client!")
	return self:FindPlayer(Players.LocalPlayer)
end

function ZoneDaemon:SetOverlapParams(overlapParams)
	self.OverlapParams = overlapParams
end

local function PlayerAdded(player: Player)
	local characterTrove = Trove.new()

	local function CharacterAdded(character)
		local humanoid = character:WaitForChild("Humanoid")
		local rootPart = character:WaitForChild("HumanoidRootPart")

		table.insert(Characters, character)
		table.insert(RootParts, rootPart)

		characterTrove:Add(function()
			TableUtil.SwapRemoveFirstValue(Characters, character)
			TableUtil.SwapRemoveFirstValue(RootParts, rootPart)
		end)

		characterTrove:Connect(humanoid.Died, function()
			characterTrove:Clean()
		end)
	end
	local function CharacterRemoving(_)
		characterTrove:Clean()
	end

	player.CharacterAdded:Connect(CharacterAdded)
	player.CharacterRemoving:Connect(CharacterRemoving)
end

Players.PlayerAdded:Connect(PlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(PlayerAdded, player)
end

return ZoneDaemon
