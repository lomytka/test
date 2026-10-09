-- ═══════════════════════════════════════════════════
--  AutoBuy + AutoRoll + AutoCollect (orbs + leaves)
-- ═══════════════════════════════════════════════════

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local player = Players.LocalPlayer

-- ─── RemoteEvents ───
local TypedRemote = ReplicatedStorage
    :FindFirstChild("Shared")
    :FindFirstChild("Packages")
    :FindFirstChild("TypedRemote")

local BuyLeaf   = TypedRemote:FindFirstChild("BuyLeaf")
local StartRoll = TypedRemote:FindFirstChild("StartRoll")

-- ═══════════════════════════════════════════════════
--  ОБЩИЕ ДАННЫЕ
-- ═══════════════════════════════════════════════════

local ALL_LEAVES = {
    "Alder", "AshTree", "Aspen", "Banana", "Beech", "Birch", "Cherry",
    "DatePalm", "Dogwood", "Elm", "FanPalm", "FieldMaple", "Fig",
    "Ginkgo", "Hawthorn", "Hazel", "Holly", "HorseChestnut",
    "JapaneseMaple", "Laurel", "Magnolia", "MapleLeaf", "Olive",
    "Papaya", "PinOak", "Poplar", "RedOak", "Redbud", "Rowan",
    "Sassafras", "Sweetgum", "Sycamore", "TulipTree", "WhiteOak",
    "Willow",
}

local COL_X = {-16, 84, 185}
local ROW_Z = {-597, -304}

local function nearestIndex(list, value)
    local best, bestD
    for i, v in ipairs(list) do
        local d = math.abs(value - v)
        if not bestD or d < bestD then
            bestD = d
            best = i
        end
    end
    return best, bestD
end

local function detectPlot()
    local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local pos = hrp.Position
    local col = nearestIndex(COL_X, pos.X)
    local row = nearestIndex(ROW_Z, pos.Z)
    return "Plot" .. ((row - 1) * 3 + col)
end

local function findPlotModel(plotName)
    local map = workspace:FindFirstChild("Map")
    local folder = map and map:FindFirstChild(plotName)
    if not folder then return nil end
    for _, child in ipairs(folder:GetChildren()) do
        if child.Name:match("^Plot_%d+$") then
            return child
        end
    end
end

-- ═══════════════════════════════════════════════════
--  СОСТОЯНИЕ
-- ═══════════════════════════════════════════════════

local state = {
    -- AutoBuy
    buyEnabled = false,
    slots = {},
    connections = {},
    selected = {},
    -- AutoRoll
    rollEnabled = false,
    rollThread = nil,
    rollInterval = 10,
    -- AutoCollect
    collectEnabled = false,
    collectThread = nil,
    collectPlot = nil,
    -- GUI
    guiVisible = true,
    toggleKey = Enum.KeyCode.RightShift,
    waitingForBind = false,
}

-- ═══════════════════════════════════════════════════
--  AUTO BUY
-- ═══════════════════════════════════════════════════

local function checkSlot(index, slot)
    if not state.buyEnabled then return end
    if not slot then return end
    local top = slot:FindFirstChild("Top")
    if not top then return end
    for _, child in ipairs(top:GetChildren()) do
        if state.selected[child.Name] then
            BuyLeaf:FireServer(index)
            print("[AutoBuy] Куплен", child.Name, "в слоте", index)
            break
        end
    end
end

local function startWatching()
    for _, c in ipairs(state.connections) do c:Disconnect() end
    state.connections = {}
    for i, slot in pairs(state.slots) do
        if slot then
            checkSlot(i, slot)
            local top = slot:FindFirstChild("Top")
            if top then
                table.insert(state.connections, top.ChildAdded:Connect(function()
                    checkSlot(i, slot)
                end))
            end
        end
    end
end

local function stopWatching()
    for _, c in ipairs(state.connections) do c:Disconnect() end
    state.connections = {}
end

-- ═══════════════════════════════════════════════════
--  AUTO ROLL
-- ═══════════════════════════════════════════════════

local function startRollLoop()
    if state.rollThread then return end
    state.rollThread = task.spawn(function()
        while state.rollEnabled do
            StartRoll:FireServer(nil)
            print("[AutoRoll] Прокрут. Следующий через", state.rollInterval)
            task.wait(state.rollInterval)
        end
        state.rollThread = nil
    end)
end

local function stopRollLoop()
    state.rollEnabled = false
    if state.rollThread then
        task.cancel(state.rollThread)
        state.rollThread = nil
    end
end

-- ═══════════════════════════════════════════════════
--  AUTO COLLECT (orbs + leaves)
-- ═══════════════════════════════════════════════════

local ARRIVE_DISTANCE = 4
local STUCK_TIMEOUT = 8
local LOOP_DELAY = 0.2
local SCAN_INTERVAL = 0.3
local ORB_PRIORITY = true
local E_PRESS_DELAY = 0.1
local E_RELEASE_DELAY = 0.05

local function GetChar()
    local char = player.Character
    if not char then return nil, nil, nil end
    return char,
        char:FindFirstChild("HumanoidRootPart"),
        char:FindFirstChild("Humanoid")
end

local function PressE()
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(E_RELEASE_DELAY)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
end

local function FindMyPlot()
    local map = workspace:FindFirstChild("Map")
    if not map then return nil end
    local myUserId = player.UserId
    for _, child in ipairs(map:GetChildren()) do
        if child.Name:match("^Plot%d+$") then
            for _, inner in ipairs(child:GetChildren()) do
                if inner.Name:match("^Plot_%d+$") then
                    local ownerId = tonumber(inner.Name:match("Plot_(%d+)"))
                    if ownerId == myUserId then
                        return { plotName = child.Name, innerName = inner.Name, instance = inner }
                    end
                    break
                end
            end
        end
    end
    return nil
end

local function CollectOrbsFromFolder(folder, orbType)
    local result = {}
    if not folder then return result end
    for _, orb in ipairs(folder:GetChildren()) do
        table.insert(result, { obj = orb, key = orb.Name, type = orbType })
    end
    return result
end

local function GetAllOrbs()
    if not state.collectPlot then return {} end
    local orbs = {}
    local leafOrbs = state.collectPlot.instance:FindFirstChild("LeafOrbs")
    if not leafOrbs then return orbs end
    for _, entry in ipairs(CollectOrbsFromFolder(leafOrbs:FindFirstChild("TraitOrb"), "trait")) do
        table.insert(orbs, entry)
    end
    for _, entry in ipairs(CollectOrbsFromFolder(leafOrbs:FindFirstChild("MultiOrb"), "multi")) do
        table.insert(orbs, entry)
    end
    return orbs
end

local function GetMyLeaves()
    if not state.collectPlot then return {} end
    local leaves = {}
    local folder = state.collectPlot.instance:FindFirstChild("SpawnedLeaves")
    if not folder then return leaves end
    for _, leaf in ipairs(folder:GetChildren()) do
        table.insert(leaves, { obj = leaf, key = leaf:GetAttribute("Key") or leaf.Name, type = "leaf" })
    end
    return leaves
end

local function GetObjPosition(obj)
    local target = obj:FindFirstChild("CollectPart")
        or obj:FindFirstChild("CenterPart")
        or obj:FindFirstChild("ModelAnchor")
        or obj:FindFirstChildWhichIsA("BasePart", true)
    if target then return target.Position end
    if obj:IsA("BasePart") then return obj.Position end
    return nil
end

local function GetNearestTarget()
    local _, root = GetChar()
    if not root then return nil end
    local bestOrb, bestOrbPos, bestOrbDist = nil, nil, math.huge
    local bestLeaf, bestLeafPos, bestLeafDist = nil, nil, math.huge

    for _, entry in ipairs(GetAllOrbs()) do
        local pos = GetObjPosition(entry.obj)
        if pos then
            local d = (pos - root.Position).Magnitude
            if d < bestOrbDist then bestOrb, bestOrbPos, bestOrbDist = entry, pos, d end
        end
    end
    for _, entry in ipairs(GetMyLeaves()) do
        local pos = GetObjPosition(entry.obj)
        if pos then
            local d = (pos - root.Position).Magnitude
            if d < bestLeafDist then bestLeaf, bestLeafPos, bestLeafDist = entry, pos, d end
        end
    end

    if ORB_PRIORITY and bestOrb then return bestOrb, bestOrbPos end
    if bestOrb and bestOrbDist <= bestLeafDist then return bestOrb, bestOrbPos end
    if bestLeaf then return bestLeaf, bestLeafPos end
    return bestOrb, bestOrbPos
end

local function GoToTarget(entry, position)
    local _, root, humanoid = GetChar()
    if not root or not humanoid then return false end

    print("[" .. entry.type .. "] → " .. entry.key)
    humanoid:MoveTo(position)
    local timeout = tick() + STUCK_TIMEOUT
    local arrived = false

    while state.collectEnabled do
        if not root.Parent then return false end
        if (root.Position - position).Magnitude <= ARRIVE_DISTANCE then
            arrived = true; break
        end
        if tick() > timeout then return false end
        task.wait(0.1)
    end

    if not arrived then return false end
    print("[" .. entry.type .. "] ✅ " .. entry.key)

    if entry.type == "trait" or entry.type == "multi" then
        task.wait(E_PRESS_DELAY)
        PressE()
        print("[" .. entry.type .. "] ⌨ E")
        task.wait(0.3)
    end
    return true
end

local function StartCollectLoop()
    if state.collectThread then return end
    state.collectEnabled = true
    state.collectThread = task.spawn(function()
        state.collectPlot = FindMyPlot()
        if not state.collectPlot then
            warn("[AutoCollect] ❌ Твой плот не найден!")
            state.collectEnabled = false
            state.collectThread = nil
            return
        end
        print("[AutoCollect] ✅ Плот:", state.collectPlot.plotName)

        while state.collectEnabled do
            local entry, pos = GetNearestTarget()
            if entry and pos then
                GoToTarget(entry, pos)
            else
                task.wait(SCAN_INTERVAL)
            end
            task.wait(LOOP_DELAY)
        end
        state.collectThread = nil
    end)
end

local function StopCollectLoop()
    state.collectEnabled = false
    if state.collectThread then
        task.cancel(state.collectThread)
        state.collectThread = nil
    end
    local _, _, humanoid = GetChar()
    if humanoid then
        local _, root = GetChar()
        if root then humanoid:MoveTo(root.Position) end
    end
end

-- ═══════════════════════════════════════════════════
--  GUI
-- ═══════════════════════════════════════════════════

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoAllGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

-- Маленькая кнопка открытия
local openBtn = Instance.new("TextButton")
openBtn.Size = UDim2.new(0, 44, 0, 44)
openBtn.Position = UDim2.new(0, 20, 0, 20)
openBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 50)
openBtn.Text = "🌿"
openBtn.TextSize = 22
openBtn.Font = Enum.Font.GothamBold
openBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
openBtn.Visible = false
openBtn.Parent = screenGui
Instance.new("UICorner", openBtn).CornerRadius = UDim.new(0, 22)

-- Главное окно
local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 260, 0, 640)
mainFrame.Position = UDim2.new(0, 20, 0, 40)
mainFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui
Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -60, 0, 30)
title.BackgroundTransparency = 1
title.Text = "🌿 AutoAll"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Position = UDim2.new(0, 10, 0, 0)
title.Parent = mainFrame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -32, 0, 2)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.Parent = mainFrame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local infoLabel = Instance.new("TextLabel")
infoLabel.Size = UDim2.new(1, -10, 0, 20)
infoLabel.Position = UDim2.new(0, 5, 0, 30)
infoLabel.BackgroundTransparency = 1
infoLabel.Text = "Плот: — | orbs: — | leaves: —"
infoLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 11
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.Parent = mainFrame

-- ─── AutoCollect ───
local collectBtn = Instance.new("TextButton")
collectBtn.Size = UDim2.new(1, -10, 0, 32)
collectBtn.Position = UDim2.new(0, 5, 0, 53)
collectBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
collectBtn.Text = "🎯 AutoCollect (orbs E > leaves): OFF"
collectBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
collectBtn.Font = Enum.Font.GothamBold
collectBtn.TextSize = 12
collectBtn.Parent = mainFrame
Instance.new("UICorner", collectBtn).CornerRadius = UDim.new(0, 6)

-- ─── AutoRoll ───
local rollBtn = Instance.new("TextButton")
rollBtn.Size = UDim2.new(1, -10, 0, 32)
rollBtn.Position = UDim2.new(0, 5, 0, 90)
rollBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
rollBtn.Text = "🎲 AutoRoll: OFF"
rollBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
rollBtn.Font = Enum.Font.GothamBold
rollBtn.TextSize = 13
rollBtn.Parent = mainFrame
Instance.new("UICorner", rollBtn).CornerRadius = UDim.new(0, 6)

-- ─── Интервал ───
local intervalLabel = Instance.new("TextLabel")
intervalLabel.Size = UDim2.new(0.5, 0, 0, 26)
intervalLabel.Position = UDim2.new(0, 5, 0, 127)
intervalLabel.BackgroundTransparency = 1
intervalLabel.Text = "Интервал (сек):"
intervalLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
intervalLabel.Font = Enum.Font.Gotham
intervalLabel.TextSize = 12
intervalLabel.TextXAlignment = Enum.TextXAlignment.Left
intervalLabel.Parent = mainFrame

local intervalBox = Instance.new("TextBox")
intervalBox.Size = UDim2.new(0.45, 0, 0, 26)
intervalBox.Position = UDim2.new(0.53, 0, 0, 127)
intervalBox.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
intervalBox.TextColor3 = Color3.fromRGB(255, 255, 255)
intervalBox.Font = Enum.Font.Gotham
intervalBox.TextSize = 13
intervalBox.Text = tostring(state.rollInterval)
intervalBox.ClearTextOnFocus = false
intervalBox.Parent = mainFrame
Instance.new("UICorner", intervalBox).CornerRadius = UDim.new(0, 6)

intervalBox.FocusLost:Connect(function()
    local num = tonumber(intervalBox.Text)
    if not num or num < 1 then num = 10 end
    if num > 3600 then num = 3600 end
    state.rollInterval = num
    intervalBox.Text = tostring(num)
end)

-- ─── Скролл листьев ───
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -10, 0, 280)
scroll.Position = UDim2.new(0, 5, 0, 160)
scroll.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.CanvasSize = UDim2.new(0, 0, 0, #ALL_LEAVES * 26 + 6)
scroll.Parent = mainFrame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 2)
listLayout.Parent = scroll

local function createLeafRow(leafName)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -8, 0, 24)
    row.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    row.Text = ""
    row.Parent = scroll
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

    local check = Instance.new("TextLabel")
    check.Size = UDim2.new(0, 20, 0, 20)
    check.Position = UDim2.new(0, 3, 0, 2)
    check.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    check.Text = ""
    check.Parent = row
    Instance.new("UICorner", check).CornerRadius = UDim.new(0, 4)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -28, 1, 0)
    label.Position = UDim2.new(0, 28, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = leafName
    label.TextColor3 = Color3.fromRGB(230, 230, 230)
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    local function refresh()
        if state.selected[leafName] then
            check.BackgroundColor3 = Color3.fromRGB(50, 180, 80)
            check.Text = "✓"
            check.TextColor3 = Color3.fromRGB(255, 255, 255)
            check.Font = Enum.Font.GothamBold
            check.TextSize = 14
        else
            check.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
            check.Text = ""
        end
    end

    row.MouseButton1Click:Connect(function()
        state.selected[leafName] = not state.selected[leafName]
        refresh()
    end)
    refresh()
end

for _, leaf in ipairs(ALL_LEAVES) do
    createLeafRow(leaf)
end

-- ─── Кнопка AutoBuy ───
local buyBtn = Instance.new("TextButton")
buyBtn.Size = UDim2.new(1, -10, 0, 36)
buyBtn.Position = UDim2.new(0, 5, 0, 448)
buyBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
buyBtn.Text = "🛒 AutoBuy: OFF"
buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
buyBtn.Font = Enum.Font.GothamBold
buyBtn.TextSize = 14
buyBtn.Parent = mainFrame
Instance.new("UICorner", buyBtn).CornerRadius = UDim.new(0, 6)

-- ─── Массовые кнопки ───
local function makeSmallButton(text, xPos, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.32, 0, 0, 26)
    b.Position = UDim2.new(xPos, 0, 0, 490)
    b.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    b.Text = text
    b.TextColor3 = Color3.fromRGB(220, 220, 220)
    b.Font = Enum.Font.Gotham
    b.TextSize = 11
    b.Parent = mainFrame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(callback)
end

makeSmallButton("Все", 0.02, function()
    for _, leaf in ipairs(ALL_LEAVES) do state.selected[leaf] = true end
end)
makeSmallButton("Ничего", 0.34, function()
    for _, leaf in ipairs(ALL_LEAVES) do state.selected[leaf] = false end
end)
makeSmallButton("Инверт.", 0.66, function()
    for _, leaf in ipairs(ALL_LEAVES) do state.selected[leaf] = not state.selected[leaf] end
end)

-- ─── Пресеты интервала ───
local presets = {{"5с",5},{"10с",10},{"30с",30},{"60с",60}}
for i, preset in ipairs(presets) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.23, 0, 0, 22)
    b.Position = UDim2.new(0.02 + (i-1) * 0.245, 0, 0, 522)
    b.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    b.Text = preset[1]
    b.TextColor3 = Color3.fromRGB(220, 220, 220)
    b.Font = Enum.Font.Gotham
    b.TextSize = 11
    b.Parent = mainFrame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
    b.MouseButton1Click:Connect(function()
        state.rollInterval = preset[2]
        intervalBox.Text = tostring(preset[2])
    end)
end

-- ─── Кнопка Бинда ───
local bindBtn = Instance.new("TextButton")
bindBtn.Size = UDim2.new(1, -10, 0, 30)
bindBtn.Position = UDim2.new(0, 5, 0, 552)
bindBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
bindBtn.Text = "🎹 Бинд: " .. state.toggleKey.Name
bindBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
bindBtn.Font = Enum.Font.Gotham
bindBtn.TextSize = 12
bindBtn.Parent = mainFrame
Instance.new("UICorner", bindBtn).CornerRadius = UDim.new(0, 6)

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -10, 0, 20)
hint.Position = UDim2.new(0, 5, 0, 585)
hint.BackgroundTransparency = 1
hint.Text = "Нажми " .. state.toggleKey.Name .. " чтобы скрыть/показать"
hint.TextColor3 = Color3.fromRGB(140, 140, 140)
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Parent = mainFrame

-- ═══════════════════════════════════════════════════
--  ПОКАЗАТЬ / СКРЫТЬ
-- ═══════════════════════════════════════════════════

local function setVisible(visible)
    state.guiVisible = visible
    mainFrame.Visible = visible
    openBtn.Visible = not visible
end

openBtn.MouseButton1Click:Connect(function() setVisible(true) end)
closeBtn.MouseButton1Click:Connect(function() setVisible(false) end)

-- ═══════════════════════════════════════════════════
--  ОБРАБОТЧИКИ
-- ═══════════════════════════════════════════════════

collectBtn.MouseButton1Click:Connect(function()
    if state.collectEnabled then
        StopCollectLoop()
        collectBtn.Text = "🎯 AutoCollect (orbs E > leaves): OFF"
        collectBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    else
        collectBtn.Text = "🎯 AutoCollect (orbs E > leaves): ON"
        collectBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 50)
        StartCollectLoop()
    end
end)

rollBtn.MouseButton1Click:Connect(function()
    state.rollEnabled = not state.rollEnabled
    if state.rollEnabled then
        rollBtn.Text = string.format("🎲 AutoRoll: ON (%ds)", state.rollInterval)
        rollBtn.BackgroundColor3 = Color3.fromRGB(30, 100, 160)
        startRollLoop()
    else
        rollBtn.Text = "🎲 AutoRoll: OFF"
        rollBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        stopRollLoop()
    end
end)

buyBtn.MouseButton1Click:Connect(function()
    if state.buyEnabled then
        state.buyEnabled = false
        stopWatching()
        buyBtn.Text = "🛒 AutoBuy: OFF"
        buyBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        return
    end

    local any = false
    for _, v in pairs(state.selected) do if v then any = true break end end
    if not any then
        warn("[AutoBuy] Не выбран ни один лист")
        return
    end

    local plotName = detectPlot()
    local plotModel = plotName and findPlotModel(plotName)
    if not plotModel then
        warn("[AutoBuy] Плот не найден")
        return
    end

    state.slots = {
        [1] = plotModel:FindFirstChild("RollSlot1"),
        [2] = plotModel:FindFirstChild("RollSlot2"),
        [3] = plotModel:FindFirstChild("RollSlot3"),
    }
    state.buyEnabled = true
    startWatching()
    buyBtn.Text = "🛒 AutoBuy: ON"
    buyBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 50)
end)

bindBtn.MouseButton1Click:Connect(function()
    state.waitingForBind = true
    bindBtn.Text = "🎹 Нажми любую клавишу..."
    bindBtn.BackgroundColor3 = Color3.fromRGB(160, 130, 30)
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if state.waitingForBind then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            state.toggleKey = input.KeyCode
            state.waitingForBind = false
            bindBtn.Text = "🎹 Бинд: " .. state.toggleKey.Name
            bindBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
            hint.Text = "Нажми " .. state.toggleKey.Name .. " чтобы скрыть/показать"
        end
        return
    end
    if not processed and input.KeyCode == state.toggleKey then
        setVisible(not state.guiVisible)
    end
end)

-- ═══════════════════════════════════════════════════
--  АВТО-ОБНОВЛЕНИЕ ИНФО
-- ═══════════════════════════════════════════════════

task.spawn(function()
    while true do
        if state.collectPlot then
            local o = #GetAllOrbs()
            local l = #GetMyLeaves()
            infoLabel.Text = state.collectPlot.plotName .. " | orbs: " .. o .. " | leaves: " .. l
        end
        task.wait(0.5)
    end
end)

-- ═══════════════════════════════════════════════════
--  DRAGGABLE
-- ═══════════════════════════════════════════════════

do
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
        end
    end)
    title.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    title.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
end

print("[AutoAll] GUI готов. Бинд:", state.toggleKey.Name)
-- 1. Расширить окно под картинку
mainFrame.Size = UDim2.new(0, 240, 0, 800)

-- 2. Подвал
local footer = Instance.new("Frame")
footer.Size = UDim2.new(1, 0, 0, 100)
footer.Position = UDim2.new(0, 0, 1, -100)
footer.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
footer.BorderSizePixel = 0
footer.Parent = mainFrame

Instance.new("UICorner", footer).CornerRadius = UDim.new(0, 8)

-- 3. Картинка
local footerImg = Instance.new("ImageLabel")
footerImg.Size = UDim2.new(1, -16, 1, -16)
footerImg.Position = UDim2.new(0, 8, 0, 8)
footerImg.BackgroundTransparency = 1
footerImg.ScaleType = Enum.ScaleType.Fit
footerImg.Parent = footer

-- 4. Загрузка
local IMAGE_URL  = "https://raw.githubusercontent.com/lomytka/test/main/9jpm0pr.png"
local IMAGE_FILE = "gofren_patrol.png"

local function loadFooterImage()
    if not (writefile and getcustomasset and isfile) then
        warn("[Image] Экзекьютор не поддерживает writefile/getcustomasset")
        footerImg.Image = ""
        return
    end
    if not isfile(IMAGE_FILE) then
        local ok, data = pcall(function() return game:HttpGet(IMAGE_URL) end)
        if not ok or not data then
            warn("[Image] Не удалось скачать:", data)
            return
        end
        writefile(IMAGE_FILE, data)
    end
    local ok, assetId = pcall(function() return getcustomasset(IMAGE_FILE) end)
    if not ok then
        warn("[Image] getcustomasset ошибка:", assetId)
        return
    end
    footerImg.Image = assetId
end

loadFooterImage()
