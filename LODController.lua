-- ReplicatedFirst/LODController.lua
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
local worldRoot = Workspace

local growAssets = ReplicatedStorage:WaitForChild("GrowAssets")
local plantsFolder = growAssets:WaitForChild("Plants")
local cropsFolder = growAssets:WaitForChild("Crops")
local lodPlantsFolder = growAssets:WaitForChild("LOD"):WaitForChild("Plants")
local lodCropsFolder = growAssets:WaitForChild("LOD"):WaitForChild("Crops")

local currentPosition, lastPosition

local LODSystem = {}	
LODSystem.CELL_SIZE = 50 -- Size of each grid cell in studs
LODSystem.LOD_RADIUS = 100 
LODSystem.CHECK_INTERVAL = 0.2
LODSystem.TAG_NAME = "FarmObject"

-- Grid data structures
LODSystem.grid = {} -- [cellKey] = {model1, model2, ...}
LODSystem.modelToCell = {} -- [model] = cellKey
LODSystem.activeModels = {} -- [model] = true (currently in high LOD)
LODSystem.initializedModels = {} -- [model] = true (already processed)

local MAX_SWAPS_PER_FRAME = 6
local swapQueue = {}
local isUpdating = false
local isSwapping = false
local lastCheck = 0

local function countCells()
	local count = 0
	for _ in pairs(LODSystem.grid) do
		count = count + 1
	end
	return count
end

local function getCellKey(position)
	local x = math.floor(position.X / LODSystem.CELL_SIZE)
	local y = math.floor(position.Y / LODSystem.CELL_SIZE)
	local z = math.floor(position.Z / LODSystem.CELL_SIZE)
	return string.format("%d,%d,%d", x, y, z)
end

local function isInRange(model, playerPosition)
	local radiusSquared = LODSystem.LOD_RADIUS * LODSystem.LOD_RADIUS

	if model.PrimaryPart then
		local offset = model.PrimaryPart.Position - playerPosition
		local distSquared = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z

		return distSquared <= radiusSquared
	end
end

local function getNearbyCells(position, radius)
	local nearbyModels = {}
	local cellRadius = math.ceil(radius / LODSystem.CELL_SIZE)
	local centerKey = getCellKey(position)
	local cx, cy, cz = centerKey:match("([^,]+),([^,]+),([^,]+)")
	cx, cy, cz = tonumber(cx), tonumber(cy), tonumber(cz)

	for x = -cellRadius, cellRadius do
		for y = -cellRadius, cellRadius do
			for z = -cellRadius, cellRadius do
				local key = string.format("%d,%d,%d", cx + x, cy + y, cz + z)

				if LODSystem.grid[key] then
					for _, model in ipairs(LODSystem.grid[key]) do
						table.insert(nearbyModels, model)
					end
				end
			end
		end
	end

	return nearbyModels
end

local function swapModelVisuals(plantModel, toHighPoly)
	isSwapping = true

	if not plantModel or not plantModel.Name:match("_Plant$") then 
		isSwapping = false
		return false
	end

	if not plantModel.Parent then 
		isSwapping = false
		return false
	end

	local plantModelName = plantModel.Name
	local cropName = plantModelName:gsub("_Plant$", ""):gsub("LOD_", "")
	local targetPlantName, sourcePlantFolder, sourceCropFolder

	if toHighPoly then
		targetPlantName = cropName .. "_Plant"
		sourcePlantFolder = plantsFolder
		sourceCropFolder = cropsFolder
	else
		targetPlantName = "LOD_" .. cropName .. "_Plant"
		sourcePlantFolder = lodPlantsFolder
		sourceCropFolder = lodCropsFolder
	end

	local updatedPlantModel = sourcePlantFolder:FindFirstChild(cropName):FindFirstChild(targetPlantName)
	if not updatedPlantModel then 
		warn("No updatedPlantModel found in source folder" .. sourcePlantFolder .." for swapPlantModel") 
		isSwapping = false 
		return false
	end

	local clonedPlantModel = updatedPlantModel:Clone()

	if plantModel.PrimaryPart and clonedPlantModel.PrimaryPart then
		clonedPlantModel:SetPrimaryPartCFrame(plantModel.PrimaryPart.CFrame)
	end
	
	local oldPlantVisualsFolder = plantModel.visuals
	local updatedPlantVisualsFolder = clonedPlantModel.visuals
	
	updatedPlantVisualsFolder.Parent = plantModel
	
	oldPlantVisualsFolder:Destroy()
	clonedPlantModel:Destroy()
	
	-- crops
	for _, cropModel in pairs(plantModel.cropModels:GetChildren()) do	
		local existingComponents = cropModel:FindFirstChild("components")
		if not existingComponents then
			isSwapping = false
			return false
		end
		
		if not cropModel.PrimaryPart then 
			isSwapping = false
			return false
		end
		
		local cropName = cropModel:GetAttribute("CropId")
		if not cropName then
			local count = 0
			while count <= 10 do
				cropName = cropModel:GetAttribute("CropId")
				if cropName then break end
				task.wait(1)
				count += 1
			end
			
			if not cropName then
				warn("No cropName found from CropId attribute on cropModel " .. cropModel.Name .. ". (Did you forget to add one?)")
				return
			end
		end

		local fullCropName = cropModel:GetAttribute("FullCropName")
		if not fullCropName then 
			warn("fullCropName was nil for cropModel ", cropModel) 
			isSwapping = false
			return false 
		end
		
		if fullCropName:match("_stage_") then
			print(fullCropName .. ": Premature crop, skipping")
			continue
		end

		local slotNumber = cropModel.Name:match("%d+")
		local targetCropName
		
		if toHighPoly then
			targetCropName = fullCropName
		else
			targetCropName = "LOD_" .. fullCropName
		end
		
		if not targetCropName then 
			warn("TargetCropName was nil for crop " .. cropName) 
			isSwapping = false
			return false 
    	end
		
		local newCropModel = sourceCropFolder:WaitForChild(cropName, 3):WaitForChild(targetCropName, 3)
		
		if not newCropModel then 
			warn("newCropModel was nil for crop " .. cropName) 
			isSwapping = false
			return false 
		end
		
		local clonedCropModel = newCropModel:Clone()
		clonedCropModel:SetAttribute("ModelType", "Crop")
		clonedCropModel.Name = "Crop" .. slotNumber
		
		local oldCropVisualsFolder = cropModel:WaitForChild("visuals", 4)
		if not oldCropVisualsFolder then
			warn("No crop visuals folder found in crop " .. cropModel.Name)
			isSwapping = false
			return false
		end
		
		local updatedCropVisualsFolder = clonedCropModel:WaitForChild("visuals", 4)
		if not updatedCropVisualsFolder then
			warn("No crop visuals folder found in cloned crop " .. clonedCropModel.Name)
			isSwapping = false
			return false
		end

		if not cropModel.PrimaryPart then
			warn("No primary part found for crop model " .. cropModel.Name)		

			isSwapping = false
			return false
		end
		
		if not clonedCropModel.PrimaryPart then
			warn("No primary part found for cloned crop model " .. clonedCropModel.Name)
			
			isSwapping = false
			return false
		end
		
		clonedCropModel:SetPrimaryPartCFrame(cropModel.PrimaryPart.CFrame)
		updatedCropVisualsFolder.Parent = cropModel
		oldCropVisualsFolder:Destroy()
	end	
	
	isSwapping = false
	
	return true
end

local function update(playerPosition)
	if not isUpdating then		
		isUpdating = true
		currentPosition = humanoidRootPart.Position

		if currentPosition ~= lastPosition then
			--print("Player moving")
			local nearbyModels = getNearbyCells(playerPosition, LODSystem.LOD_RADIUS)
			local modelsInRange = {}
			local radiusSquared = LODSystem.LOD_RADIUS * LODSystem.LOD_RADIUS

			for _, model in ipairs(nearbyModels) do
				if model.PrimaryPart then
					local offset = model.PrimaryPart.Position - playerPosition
					local distSquared = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z

					if distSquared <= radiusSquared then
						modelsInRange[model] = true
					end
				end
			end

			for model in pairs(modelsInRange) do
				if not LODSystem.activeModels[model] then
					--print("Swapping to high poly")
					table.insert(swapQueue, {model = model, toHighPoly = true})
					LODSystem.activeModels[model] = true
				end
			end

			local modelsToRemove = {}

			for model, _ in pairs(LODSystem.activeModels) do
				if not modelsInRange[model] then
					table.insert(modelsToRemove, model)
				end
			end

			for i = #modelsToRemove, 1, -1 do
				local model = modelsToRemove[i]
				--print("Swapping to low poly")	
				table.insert(swapQueue, {model = model, toHighPoly = false})
				LODSystem.activeModels[model] = nil
			end

			lastPosition = currentPosition
		end

		isUpdating = false
	end
end

local function registerModel(plantModel)
	if not plantModel.PrimaryPart then 
		print("Model has no PrimaryPart. Retrying...")
		local count = 0
		
		while count <= 10 do
			print(count .. "...")
			count += 1
			if plantModel.PrimaryPart then 
				print("Primary part found after " .. count .. " retries") 
				break 
			end
			task.wait(1)
		end
		
		if not plantModel.PrimaryPart then
			warn("Model has no primary part after 10 second timeout")
			return
		end
	end

	local cellKey = getCellKey(plantModel.PrimaryPart.Position)

	if not LODSystem.grid[cellKey] then
		LODSystem.grid[cellKey] = {}
	end

	table.insert(LODSystem.grid[cellKey], plantModel)
	LODSystem.modelToCell[plantModel] = cellKey

	if isInRange(plantModel, humanoidRootPart.Position) then
		LODSystem.activeModels[plantModel] = true
	else
		swapModelVisuals(plantModel, false)
	end

end

local function deregisterModel(plantModel)
	if isSwapping then return end

	local cellKey = LODSystem.modelToCell[plantModel]
	if not cellKey or not LODSystem.grid[cellKey] then return end

	local cell = LODSystem.grid[cellKey]
	for i, m in ipairs(cell) do
		if m == plantModel then
			table.remove(cell, i)
			break
		end
	end

	if #cell == 0 then
		LODSystem.grid[cellKey] = nil
	end

	LODSystem.modelToCell[plantModel] = nil

	if LODSystem.activeModels[plantModel] then
		swapModelVisuals(plantModel, false)
		LODSystem.activeModels[plantModel] = nil
	end
end

local function initialize()
	print("Initializing LOD System...")

	local existingModels = CollectionService:GetTagged(LODSystem.TAG_NAME)

	for _, model in ipairs(existingModels) do
		registerModel(model)
	end

	CollectionService:GetInstanceAddedSignal(LODSystem.TAG_NAME):Connect(function(model)
		registerModel(model)
	end)

	CollectionService:GetInstanceRemovedSignal(LODSystem.TAG_NAME):Connect(function(model)
		deregisterModel(model)
	end)

	print("LOD System initialized")
	print("Grid cells:", countCells())
	lastPosition = currentPosition
end

local function start()
	task.spawn(function()
		while true do
			local processed = 0
			for i = #swapQueue, 1, -1 do
				if processed >= MAX_SWAPS_PER_FRAME then break end
					
				local job = table.remove(swapQueue, i)
				if job and job.model then
					swapModelVisuals(job.model, job.toHighPoly)
					processed += 1
				end
			end
			RunService.Heartbeat:Wait() -- yield one frame
		end
	end)
	
	RunService.Heartbeat:Connect(function(dt)
		lastCheck = lastCheck + dt

		if lastCheck >= LODSystem.CHECK_INTERVAL then
			if humanoidRootPart then
				update(humanoidRootPart.Position)
			end
			lastCheck = 0
		end
	end)

	print("LOD System started")
end

task.spawn(function()
	initialize()
	start()
end)
