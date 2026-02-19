-- ============================================================
-- GRAVE BUILDER + SYNC
-- Synapse X / Solara / Velocity / KRNL / Fluxus
-- ============================================================

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- НАСТРОЙКИ
-- ============================================================
local API_KEY       = "$2a$10$MCM7FTbZMBt2ei7K2jwHI.vGnwQ0M3.l9u6.QEcjL5zuFPViZvA.2"
local BIN_ID        = "6995cf2c43b1c97be988c014"
local SYNC_URL      = "https://api.jsonbin.io/v3/b/" .. BIN_ID
local POLL_INTERVAL = 12
local PUSH_DELAY    = 3
local PUSH_COOLDOWN = 5

-- ============================================================
-- ПОИСК HTTP ФУНКЦИИ (исправленный синтаксис)
-- ============================================================
local httpRequest = nil
local httpName    = "не найдено"

print("[GraveSync] Ищем HTTP функцию...")

-- ИСПРАВЛЕНО: цикл вместо цепочки or
local httpCandidates = {
    {"syn.request",         function() return syn.request         end},
    {"request",             function() return request             end},
    {"http.request",        function() return http.request        end},
    {"http_request",        function() return http_request        end},
    {"fluxus.request",      function() return fluxus.request      end},
    {"genv.syn.request",    function() return getgenv().syn.request    end},
    {"genv.request",        function() return getgenv().request        end},
    {"genv.http_request",   function() return getgenv().http_request   end},
    {"genv.http.request",   function() return getgenv().http.request   end},
    {"genv.fluxus.request", function() return getgenv().fluxus.request end},
}

for _, candidate in ipairs(httpCandidates) do
    local name   = candidate[1]
    local getter = candidate[2]
    local ok, fn = pcall(getter)
    if ok and type(fn) == "function" then
        httpRequest = fn
        httpName    = name
        print("[GraveSync] ✓ HTTP найден: " .. name)
        break
    else
        print("[GraveSync] — нет: " .. name)
    end
end

local syncEnabled = httpRequest ~= nil
print("[GraveSync] sync: " .. tostring(syncEnabled) .. " | fn: " .. httpName)

-- ============================================================
-- СОСТОЯНИЕ
-- ============================================================
local myClientId   = LocalPlayer.Name .. "_" .. tostring(math.random(100000,999999))
local lastVersion  = -1
local builtModels  = {}
local localGraves  = {}
local polling      = false
local pollTimer    = 0
local pendingPush  = nil
local pushTimer    = 0
local lastPushTime = 0

-- ============================================================
-- УТИЛИТЫ GUI
-- ============================================================
local function addCorner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = p
    return c
end

local function addStroke(p, col, th)
    local s = Instance.new("UIStroke")
    s.Color     = col or Color3.fromRGB(60,60,60)
    s.Thickness = th or 1
    s.Parent    = p
    return s
end

-- ============================================================
-- УТИЛИТЫ ПОСТРОЕНИЯ
-- ============================================================
local function makePart(model, name, size, cf, color, mat, tr)
    local p        = Instance.new("Part")
    p.Name         = name
    p.Size         = size
    p.CFrame       = cf
    p.Anchored     = true
    p.CanCollide   = false
    p.Color        = color or Color3.fromRGB(140,140,140)
    p.Material     = mat   or Enum.Material.SmoothPlastic
    p.Transparency = tr    or 0
    p.CastShadow   = true
    p.Parent       = model
    return p
end

local function makeWedge(model, name, size, cf, color, mat)
    local p      = Instance.new("WedgePart")
    p.Name       = name
    p.Size       = size
    p.CFrame     = cf
    p.Anchored   = true
    p.CanCollide = false
    p.Color      = color or Color3.fromRGB(140,140,140)
    p.Material   = mat   or Enum.Material.SmoothPlastic
    p.Parent     = model
    return p
end

local function v3t(v)
    return {x = v.X, y = v.Y, z = v.Z}
end

local function tv3(t)
    return Vector3.new(t.x, t.y, t.z)
end

local function genId()
    return myClientId
        .. "_" .. math.floor(os.clock() * 10000)
        .. "_" .. math.random(1000, 9999)
end

-- Цвета
local SC = Color3.fromRGB(150,145,135)
local DC = Color3.fromRGB(85,82,75)
local RC = Color3.fromRGB(75,58,45)
local SG = Color3.fromRGB(140,140,140)
local DG = Color3.fromRGB(80,80,80)

-- ============================================================
-- HTTP СЛОЙ
-- ============================================================
local function doReq(opts)
    if not syncEnabled then return nil end
    local ok, res = pcall(httpRequest, {
        Url     = opts.Url,
        Method  = opts.Method  or "GET",
        Headers = opts.Headers or {},
        Body    = opts.Body    or nil,
    })
    if not ok then
        warn("[GraveSync] HTTP error: " .. tostring(res))
        return nil
    end
    if res then
        res.StatusCode = res.StatusCode or res.status or 0
        res.Body       = res.Body       or res.body   or ""
    end
    return res
end

local function jEncode(t)
    local ok, r = pcall(HttpService.JSONEncode, HttpService, t)
    return ok and r or nil
end

local function jDecode(s)
    if not s or s == "" then return nil end
    local ok, r = pcall(HttpService.JSONDecode, HttpService, s)
    return ok and r or nil
end

-- ============================================================
-- JSONBIN
-- ============================================================
local function binGet()
    if not syncEnabled then return nil, nil end

    local res = doReq({
        Url    = SYNC_URL .. "/latest",
        Method = "GET",
        Headers = {
            ["X-Master-Key"] = API_KEY,
            ["X-Bin-Meta"]   = "false",
        },
    })
    if not res then return nil, nil end

    local code = res.StatusCode
    local body = res.Body

    if code == 429 then
        warn("[GraveSync] 429 Rate limit!")
        return nil, nil
    end
    if code == 400 then
        return {graves={}, removed={}}, 0
    end
    if code ~= 200 then
        warn("[GraveSync] GET " .. tostring(code) .. " | " .. tostring(body):sub(1,100))
        return nil, nil
    end

    local parsed = jDecode(body)
    if not parsed then return nil, nil end

    local version = (parsed.metadata and parsed.metadata.version) or 0
    local data    = parsed.record or parsed
    if type(data) ~= "table" then data = {} end
    data.graves  = data.graves  or {}
    data.removed = data.removed or {}
    return data, version
end

local function binPut(data)
    if not syncEnabled then return false end

    local now = os.clock()
    if (now - lastPushTime) < PUSH_COOLDOWN then
        return false
    end
    lastPushTime = now

    local safe = {
        graves  = data.graves  or {},
        removed = data.removed or {},
    }

    -- Дедупликация removed
    local seen  = {}
    local clean = {}
    for _, id in ipairs(safe.removed) do
        if not seen[id] then
            seen[id] = true
            table.insert(clean, id)
        end
    end
    if #clean > 100 then
        local trimmed = {}
        for i = #clean - 99, #clean do
            table.insert(trimmed, clean[i])
        end
        clean = trimmed
    end
    safe.removed = clean

    local body = jEncode(safe)
    if not body or body == "" then
        warn("[GraveSync] jEncode nil!")
        return false
    end

    local res = doReq({
        Url    = SYNC_URL,
        Method = "PUT",
        Headers = {
            ["Content-Type"] = "application/json",
            ["X-Master-Key"] = API_KEY,
        },
        Body = body,
    })
    if not res then return false end

    local code = res.StatusCode
    if code == 429 then
        warn("[GraveSync] 429 при PUT!")
        return false
    end
    if code ~= 200 then
        warn("[GraveSync] PUT " .. tostring(code) .. " | " .. tostring(res.Body):sub(1,100))
        return false
    end
    return true
end

local function initBin()
    local data, _ = binGet()
    if not data then
        binPut({graves={}, removed={}})
    end
end

-- ============================================================
-- АВАТАР
-- ============================================================
local function cloneAvatarParts(tp, parent)
    local char = tp and tp.Character
    if not char then return nil, nil, nil end

    local folder  = Instance.new("Model")
    folder.Name   = "AvatarCopy"
    folder.Parent = parent

    local bodyNames = {
        "Head","UpperTorso","LowerTorso",
        "LeftUpperArm","LeftLowerArm","LeftHand",
        "RightUpperArm","RightLowerArm","RightHand",
        "LeftUpperLeg","LeftLowerLeg","LeftFoot",
        "RightUpperLeg","RightLowerLeg","RightFoot",
        "Torso","Left Arm","Right Arm","Left Leg","Right Leg",
    }

    local cloned = {}
    for _, nm in ipairs(bodyNames) do
        local p = char:FindFirstChild(nm)
        if p and p:IsA("BasePart") then
            local cl = p:Clone()
            for _, v in ipairs(cl:GetDescendants()) do
                if v:IsA("Script") or v:IsA("LocalScript")
                or v:IsA("Motor6D") or v:IsA("Weld")
                or v:IsA("WeldConstraint") or v:IsA("BodyMover") then
                    v:Destroy()
                end
            end
            cl.Anchored   = true
            cl.CanCollide = false
            cl.Parent     = folder
            cloned[nm]    = cl
        end
    end

    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Accessory") then
            local cl = ch:Clone()
            local h  = cl:FindFirstChild("Handle")
            if h then
                h.Anchored   = true
                h.CanCollide = false
                for _, v in ipairs(h:GetDescendants()) do
                    if v:IsA("Weld") or v:IsA("WeldConstraint")
                    or v:IsA("Script") or v:IsA("LocalScript") then
                        v:Destroy()
                    end
                end
            end
            cl.Parent = folder
        elseif ch:IsA("Shirt") or ch:IsA("Pants") or ch:IsA("BodyColors") then
            ch:Clone().Parent = folder
        end
    end

    return folder, cloned, char
end

local function positionLying(folder, cloned, origChar, centerCF)
    local hrp = origChar:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    for nm, cl in pairs(cloned) do
        local orig = origChar:FindFirstChild(nm)
        if orig then
            cl.CFrame = centerCF * hrp.CFrame:ToObjectSpace(orig.CFrame)
        end
    end
    for _, ch in ipairs(folder:GetChildren()) do
        if ch:IsA("Accessory") then
            local handle  = ch:FindFirstChild("Handle")
            local origAcc = nil
            for _, oc in ipairs(origChar:GetChildren()) do
                if oc:IsA("Accessory") and oc.Name == ch.Name then
                    origAcc = oc
                    break
                end
            end
            if handle and origAcc then
                local oh = origAcc:FindFirstChild("Handle")
                if oh then
                    handle.CFrame = centerCF * hrp.CFrame:ToObjectSpace(oh.CFrame)
                end
            end
        end
    end
end

local function placeHead(tp, parent, headPos)
    local char = tp and tp.Character
    if not char then return end
    local head = char:FindFirstChild("Head")
    if not head then return end

    local cl = head:Clone()
    for _, v in ipairs(cl:GetDescendants()) do
        if v:IsA("Script") or v:IsA("LocalScript")
        or v:IsA("Motor6D") or v:IsA("Weld") or v:IsA("WeldConstraint") then
            v:Destroy()
        end
    end
    cl.Anchored   = true
    cl.CanCollide = false
    cl.CFrame     = CFrame.new(headPos) * CFrame.Angles(0, math.rad(180), 0)
    cl.Parent     = parent

    for _, acc in ipairs(char:GetChildren()) do
        if acc:IsA("Accessory") then
            local oh = acc:FindFirstChild("Handle")
            if oh then
                local acl = acc:Clone()
                local clh = acl:FindFirstChild("Handle")
                if clh then
                    for _, v in ipairs(clh:GetDescendants()) do
                        if v:IsA("Weld") or v:IsA("WeldConstraint")
                        or v:IsA("Script") or v:IsA("LocalScript") then
                            v:Destroy()
                        end
                    end
                    clh.Anchored   = true
                    clh.CanCollide = false
                    clh.CFrame     = cl.CFrame * head.CFrame:ToObjectSpace(oh.CFrame)
                end
                acl.Parent = parent
            end
        end
    end
end

-- ============================================================
-- СТРОИТЕЛИ
-- ============================================================
local function buildGrave(origin, style, pName, tp)
    local m    = Instance.new("Model")
    m.Name     = "Grave_" .. pName

    local slab = makePart(m, "Slab",
        Vector3.new(4, 0.25, 7),
        CFrame.new(origin + Vector3.new(0, 0.125, 0)),
        Color3.fromRGB(75,65,55))

    makePart(m, "Mound",
        Vector3.new(3.5, 0.18, 6.5),
        CFrame.new(origin + Vector3.new(0, 0.27, 0)),
        Color3.fromRGB(65,50,35), Enum.Material.Grass)

    local stonePos = Vector3.new(origin.X, origin.Y + 1.9,  origin.Z - 2.8)
    local capPos   = Vector3.new(origin.X, origin.Y + 3.7,  origin.Z - 2.8)
    local crossZ   = origin.Z - 2.8

    if style == "rip" then
        local stone = makePart(m, "Stone",
            Vector3.new(2.4, 3.2, 0.45),
            CFrame.new(stonePos),
            SG)

        local cap = makePart(m, "Cap",
            Vector3.new(2.4, 0.45, 0.45),
            CFrame.new(capPos) * CFrame.Angles(0, 0, math.rad(90)),
            SG)

        local mesh    = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.Cylinder
        mesh.Scale    = Vector3.new(1, 1, 1)
        mesh.Parent   = cap

        local sg          = Instance.new("SurfaceGui")
        sg.Face           = Enum.NormalId.Back
        sg.SizingMode     = Enum.SurfaceGuiSizingMode.PixelsPerStud
        sg.PixelsPerStud  = 60
        sg.Parent         = stone

        local lb              = Instance.new("TextLabel")
        lb.Size               = UDim2.new(1, 0, 1, 0)
        lb.BackgroundTransparency = 1
        lb.TextColor3         = Color3.fromRGB(30, 30, 30)
        lb.Text               = "R.I.P\n" .. pName
        lb.Font               = Enum.Font.GothamBold
        lb.TextScaled         = true
        lb.Parent             = sg

    elseif style == "cross" then
        makePart(m, "CV",
            Vector3.new(0.35, 4.2, 0.35),
            CFrame.new(Vector3.new(origin.X, origin.Y + 2.4, crossZ)),
            DG)
        makePart(m, "CH",
            Vector3.new(2.2, 0.35, 0.35),
            CFrame.new(Vector3.new(origin.X, origin.Y + 3.4, crossZ)),
            DG)
        makePart(m, "CB",
            Vector3.new(1.0, 0.25, 0.6),
            CFrame.new(Vector3.new(origin.X, origin.Y + 0.38, crossZ)),
            DG)
    end

    if tp then
        placeHead(tp, m, Vector3.new(origin.X, origin.Y + 1.6, origin.Z + 1.0))
    end

    m.PrimaryPart = slab
    m.Parent      = workspace
    return m
end

local function buildCrypt(origin, pName, tp)
    local m     = Instance.new("Model")
    m.Name      = "Crypt_" .. pName
    local w,d,h = 9, 13, 6

    makePart(m,"Floor",  Vector3.new(w,0.3,d),
        CFrame.new(origin+Vector3.new(0,0.15,0)), SC)
    makePart(m,"WallBk", Vector3.new(w,h,0.5),
        CFrame.new(origin+Vector3.new(0,h/2,-d/2)), SC)
    makePart(m,"WallL",  Vector3.new(0.5,h,d),
        CFrame.new(origin+Vector3.new(-w/2,h/2,0)), SC)
    makePart(m,"WallR",  Vector3.new(0.5,h,d),
        CFrame.new(origin+Vector3.new(w/2,h/2,0)), SC)
    makePart(m,"WallFL", Vector3.new(2.8,h,0.5),
        CFrame.new(origin+Vector3.new(-(w/2)+1.4,h/2,d/2)), SC)
    makePart(m,"WallFR", Vector3.new(2.8,h,0.5),
        CFrame.new(origin+Vector3.new((w/2)-1.4,h/2,d/2)), SC)
    makePart(m,"Lintel", Vector3.new(3.4,1.5,0.5),
        CFrame.new(origin+Vector3.new(0,h-0.75,d/2)), SC)
    makePart(m,"Roof",   Vector3.new(w+0.8,0.4,d+0.8),
        CFrame.new(origin+Vector3.new(0,h+0.2,0)), DC)

    local pedH = 1.6
    local ped  = makeWedge(m, "Ped",
        Vector3.new(w+0.8, pedH, 2.5),
        CFrame.new(origin+Vector3.new(0, h+pedH/2+0.4, d/2+1.25))
            * CFrame.Angles(0, math.rad(180), 0),
        SC)

    local sg         = Instance.new("SurfaceGui")
    sg.Face          = Enum.NormalId.Front
    sg.SizingMode    = Enum.SurfaceGuiSizingMode.PixelsPerStud
    sg.PixelsPerStud = 35
    sg.Parent        = ped

    local lb              = Instance.new("TextLabel")
    lb.Size               = UDim2.new(1,0,1,0)
    lb.BackgroundTransparency = 1
    lb.TextColor3         = Color3.fromRGB(20,20,20)
    lb.Text               = pName
    lb.Font               = Enum.Font.GothamBold
    lb.TextScaled         = true
    lb.Parent             = sg

    makePart(m,"RCV", Vector3.new(0.3,2.5,0.3),
        CFrame.new(origin+Vector3.new(0,h+1.65,0)), DG)
    makePart(m,"RCH", Vector3.new(1.4,0.3,0.3),
        CFrame.new(origin+Vector3.new(0,h+2.5,0)), DG)

    for _, xOff in ipairs({-1.4, 1.4}) do
        makePart(m,"Col", Vector3.new(0.5,h,0.5),
            CFrame.new(origin+Vector3.new(xOff,h/2,d/2)), SC)
    end

    local sz = -d/2 + 4.5
    makePart(m,"SBase", Vector3.new(2.6,0.7,6),
        CFrame.new(origin+Vector3.new(0,0.65,sz)),
        Color3.fromRGB(160,155,145))
    makePart(m,"SLid", Vector3.new(2.4,0.28,5.8),
        CFrame.new(origin+Vector3.new(0,1.04,sz)),
        Color3.fromRGB(175,170,160))

    if tp and tp.Character then
        local folder, cloned, origChar = cloneAvatarParts(tp, m)
        if folder and cloned then
            positionLying(folder, cloned, origChar,
                CFrame.new(origin+Vector3.new(0, 1.4, sz))
                    * CFrame.Angles(math.rad(-90), math.rad(180), 0))
        end
    end

    m.PrimaryPart = m:FindFirstChild("Floor")
    m.Parent      = workspace
    return m
end

local function buildChapel(origin)
    local m     = Instance.new("Model")
    m.Name      = "Chapel"
    local w,d,h = 11, 16, 8

    makePart(m,"Found", Vector3.new(w+1.5,0.6,d+1.5),
        CFrame.new(origin+Vector3.new(0,0.3,0)),
        Color3.fromRGB(100,95,85))
    makePart(m,"WB", Vector3.new(w,h,0.55),
        CFrame.new(origin+Vector3.new(0,h/2,-d/2)), SC)
    makePart(m,"WL", Vector3.new(0.55,h,d),
        CFrame.new(origin+Vector3.new(-w/2,h/2,0)), SC)
    makePart(m,"WR", Vector3.new(0.55,h,d),
        CFrame.new(origin+Vector3.new(w/2,h/2,0)), SC)

    local doorW = 3.5
    local sideW = (w - doorW) / 2
    makePart(m,"WFL", Vector3.new(sideW,h,0.55),
        CFrame.new(origin+Vector3.new(-(doorW/2+sideW/2),h/2,d/2)), SC)
    makePart(m,"WFR", Vector3.new(sideW,h,0.55),
        CFrame.new(origin+Vector3.new( (doorW/2+sideW/2),h/2,d/2)), SC)
    makePart(m,"DL",  Vector3.new(doorW,h-5.5,0.55),
        CFrame.new(origin+Vector3.new(0, 5.5+(h-5.5)/2, d/2)), SC)

    local rH = 3.5
    makeWedge(m,"RoofB", Vector3.new(w+1,rH,d/2+0.5),
        CFrame.new(origin+Vector3.new(0,h+rH/2,-d/4))
            * CFrame.Angles(0,math.rad(180),0), RC)
    makeWedge(m,"RoofF", Vector3.new(w+1,rH,d/2+0.5),
        CFrame.new(origin+Vector3.new(0,h+rH/2,d/4)), RC)

    local tW     = 4
    local tH     = 13
    local towerX = origin.X + w/2 + tW/2 + 0.2
    local towerZ = origin.Z + d/2 - tW/2 - 1

    makePart(m,"Tower", Vector3.new(tW,tH,tW),
        CFrame.new(Vector3.new(towerX, origin.Y+tH/2, towerZ)), SC)
    makePart(m,"Bell",  Vector3.new(tW,0.3,tW),
        CFrame.new(Vector3.new(towerX, origin.Y+tH+0.15, towerZ)), SC)

    local spH = 4
    makeWedge(m,"SpF", Vector3.new(tW,spH,tW/2),
        CFrame.new(Vector3.new(towerX, origin.Y+tH+spH/2, towerZ-tW/4)), RC)
    makeWedge(m,"SpB", Vector3.new(tW,spH,tW/2),
        CFrame.new(Vector3.new(towerX, origin.Y+tH+spH/2, towerZ+tW/4))
            * CFrame.Angles(0,math.rad(180),0), RC)

    makePart(m,"TCV", Vector3.new(0.3,2.8,0.3),
        CFrame.new(Vector3.new(towerX, origin.Y+tH+spH+1.6, towerZ)), DG)
    makePart(m,"TCH", Vector3.new(1.6,0.3,0.3),
        CFrame.new(Vector3.new(towerX, origin.Y+tH+spH+2.4, towerZ)), DG)

    local fW = w + 10
    local fD = d + 10
    local fH = 1.3
    local fC = Color3.fromRGB(55,48,40)

    makePart(m,"FkB", Vector3.new(fW,fH,0.2),
        CFrame.new(origin+Vector3.new(0,fH/2,-fD/2)), fC)
    makePart(m,"FkF", Vector3.new(fW,fH,0.2),
        CFrame.new(origin+Vector3.new(0,fH/2, fD/2)), fC)
    makePart(m,"FkL", Vector3.new(0.2,fH,fD),
        CFrame.new(origin+Vector3.new(-fW/2,fH/2,0)), fC)
    makePart(m,"FkR", Vector3.new(0.2,fH,fD),
        CFrame.new(origin+Vector3.new( fW/2,fH/2,0)), fC)

    for i = 0, 9 do
        local xp = -fW/2 + (i/9)*fW
        makePart(m,"SpkF"..i, Vector3.new(0.14,0.45,0.14),
            CFrame.new(origin+Vector3.new(xp, fH+0.22,  fD/2)), DG)
        makePart(m,"SpkB"..i, Vector3.new(0.14,0.45,0.14),
            CFrame.new(origin+Vector3.new(xp, fH+0.22, -fD/2)), DG)
    end

    m.Parent = workspace
    return m
end

local function buildCemetery(origin, pList)
    local offsets = {
        Vector3.new(-6,0,-5), Vector3.new(0,0,-5), Vector3.new(6,0,-5),
        Vector3.new(-6,0, 3), Vector3.new(0,0, 3), Vector3.new(6,0, 3),
    }
    local styles = {"rip","cross","rip","cross","rip","cross"}
    for i, off in ipairs(offsets) do
        local tp = pList[i]
        local pn = tp and tp.Name or ("Soul_"..i)
        buildGrave(origin + off, styles[i], pn, tp)
    end
    buildChapel(origin + Vector3.new(0, 0, -22))
end

local function clearGraves()
    for _, v in ipairs(workspace:GetChildren()) do
        if v:IsA("Model") and (
            v.Name:sub(1,6) == "Grave_" or
            v.Name:sub(1,6) == "Crypt_" or
            v.Name == "Chapel" or
            v.Name == "Cemetery"
        ) then
            v:Destroy()
        end
    end
end

-- ============================================================
-- BUILD FROM PAYLOAD
-- ============================================================
local function buildFromPayload(payload)
    if not payload or not payload.id then return end
    if builtModels[payload.id] then return end
    if not payload.origin then return end

    local ok, origin = pcall(tv3, payload.origin)
    if not ok then
        warn("[GraveSync] tv3 error: " .. tostring(origin))
        return
    end

    local pName = payload.playerName or "Unknown"
    local tp    = Players:FindFirstChild(pName)
    local model = nil

    if payload.graveType == "grave" then
        model = buildGrave(origin, payload.style or "rip", pName, tp)
    elseif payload.graveType == "crypt" then
        model = buildCrypt(origin, pName, tp)
    elseif payload.graveType == "cemetery" then
        local lst = {}
        for _, nm in ipairs(payload.playerNames or {}) do
            local p = Players:FindFirstChild(nm)
            table.insert(lst, p or {Name=nm, Character=nil})
        end
        buildCemetery(origin, lst)
        builtModels[payload.id] = true
        return
    end

    if model then
        builtModels[payload.id] = model
        print("[GraveSync] ✓ " .. pName .. " от " .. tostring(payload.owner))
    end
end

-- ============================================================
-- SYNC
-- ============================================================
RunService.Heartbeat:Connect(function(dt)
    if pendingPush and pushTimer > 0 then
        pushTimer = pushTimer - dt
        if pushTimer <= 0 then
            local d = pendingPush
            pendingPush = nil
            task.spawn(function()
                local ok = binPut(d)
                print("[GraveSync] Push: " .. tostring(ok))
            end)
        end
    end
end)

local function schedulePush(data)
    pendingPush = data
    pushTimer   = PUSH_DELAY
end

local function syncBuild(payload)
    if not syncEnabled then return end
    payload.owner = myClientId
    localGraves[payload.id] = payload
    task.spawn(function()
        local data = binGet()
        if not data then
            data = {graves={}, removed={}}
        end
        local newRem = {}
        for _, id in ipairs(data.removed) do
            if id ~= payload.id then
                table.insert(newRem, id)
            end
        end
        data.removed = newRem
        local exists = false
        for _, g in ipairs(data.graves) do
            if g.id == payload.id then
                exists = true
                break
            end
        end
        if not exists then
            table.insert(data.graves, payload)
        end
        schedulePush(data)
        print("[GraveSync] → Push запланирован: " .. tostring(payload.playerName))
    end)
end

local function syncRemove(ids)
    if not syncEnabled or #ids == 0 then return end
    task.spawn(function()
        local data = binGet()
        if not data then return end
        local idSet = {}
        for _, id in ipairs(ids) do
            idSet[id] = true
        end
        local newG = {}
        for _, g in ipairs(data.graves) do
            if not idSet[g.id] then
                table.insert(newG, g)
            end
        end
        data.graves = newG
        for _, id in ipairs(ids) do
            table.insert(data.removed, id)
            localGraves[id] = nil
        end
        schedulePush(data)
        print("[GraveSync] → Удаление: " .. #ids)
    end)
end

local function syncRemoveAll()
    local ids = {}
    for id in pairs(localGraves) do
        table.insert(ids, id)
    end
    if #ids > 0 then
        syncRemove(ids)
    end
end

-- ============================================================
-- POLLING
-- ============================================================
RunService.Heartbeat:Connect(function(dt)
    if not syncEnabled then return end
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    if polling then return end
    pollTimer = 0
    polling   = true

    task.spawn(function()
        local ok, err = pcall(function()
            local data, version = binGet()
            if not data then return end
            if version > 0 and version <= lastVersion then return end
            if version > 0 then lastVersion = version end

            for _, id in ipairs(data.removed or {}) do
                if not localGraves[id] then
                    local mdl = builtModels[id]
                    if mdl and type(mdl) ~= "boolean" then
                        pcall(function() mdl:Destroy() end)
                    end
                    builtModels[id] = nil
                end
            end

            for _, payload in ipairs(data.graves or {}) do
                if payload.owner ~= myClientId then
                    pcall(buildFromPayload, payload)
                end
            end
        end)
        if not ok then
            warn("[GraveSync] poll error: " .. tostring(err))
        end
        polling = false
    end)
end)

-- Старт
task.delay(4, function()
    if not syncEnabled then
        warn("[GraveSync] HTTP недоступен")
        return
    end
    print("[GraveSync] Инициализация bin...")
    initBin()
    task.wait(2)
    local data, version = binGet()
    if not data then
        warn("[GraveSync] Данные недоступны")
        return
    end
    lastVersion = version or -1
    local cnt = 0
    for _, payload in ipairs(data.graves or {}) do
        if payload.owner ~= myClientId then
            pcall(buildFromPayload, payload)
            cnt = cnt + 1
        end
    end
    print("[GraveSync] ✓ Загружено: " .. cnt)
end)

-- ============================================================
-- GUI
-- ============================================================
local oldGui = LocalPlayer.PlayerGui:FindFirstChild("GraveBuilder")
if oldGui then oldGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name           = "GraveBuilder"
screenGui.ResetOnSpawn   = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent         = LocalPlayer.PlayerGui

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0,380,0,600)
frame.Position         = UDim2.new(0.5,-190,0.5,-300)
frame.BackgroundColor3 = Color3.fromRGB(22,22,22)
frame.BorderSizePixel  = 0
frame.Parent           = screenGui
addCorner(frame,12)
addStroke(frame, Color3.fromRGB(55,55,55), 1.5)

-- Drag
local drag,ds,sp = false,nil,nil
frame.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        drag=true; ds=i.Position; sp=frame.Position
    end
end)
frame.InputChanged:Connect(function(i)
    if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - ds
        frame.Position = UDim2.new(
            sp.X.Scale, sp.X.Offset + d.X,
            sp.Y.Scale, sp.Y.Offset + d.Y)
    end
end)
frame.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then drag=false end
end)

-- Шапка
local tb = Instance.new("Frame")
tb.Size             = UDim2.new(1,0,0,44)
tb.BackgroundColor3 = Color3.fromRGB(15,15,15)
tb.BorderSizePixel  = 0
tb.Parent           = frame
addCorner(tb,12)

local tl = Instance.new("TextLabel")
tl.Size                  = UDim2.new(1,-100,1,0)
tl.Position              = UDim2.new(0,10,0,0)
tl.BackgroundTransparency = 1
tl.TextColor3            = Color3.fromRGB(220,220,220)
tl.Text                  = "⚰️  Grave Builder"
tl.Font                  = Enum.Font.GothamBold
tl.TextSize              = 18
tl.TextXAlignment        = Enum.TextXAlignment.Left
tl.Parent                = tb

local sd = Instance.new("TextLabel")
sd.Size                  = UDim2.new(0,92,0,16)
sd.Position              = UDim2.new(1,-96,0,14)
sd.BackgroundTransparency = 1
sd.TextColor3            = syncEnabled
    and Color3.fromRGB(100,220,100)
    or  Color3.fromRGB(220,80,80)
sd.Text                  = syncEnabled
    and ("● " .. httpName)
    or  "● NO SYNC"
sd.Font                  = Enum.Font.GothamBold
sd.TextSize              = 8
sd.TextXAlignment        = Enum.TextXAlignment.Right
sd.Parent                = tb

if syncEnabled then
    local bt = 0
    RunService.Heartbeat:Connect(function(dt)
        bt = bt + dt
        if bt > 1 then bt = 0 end
        if sd and sd.Parent then
            sd.TextTransparency = (bt > 0.5) and 0.4 or 0
        end
    end)
end

-- Scroll
local scroll = Instance.new("ScrollingFrame")
scroll.Size                  = UDim2.new(1,0,1,-44)
scroll.Position              = UDim2.new(0,0,0,44)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel       = 0
scroll.ScrollBarThickness    = 4
scroll.ScrollBarImageColor3  = Color3.fromRGB(90,90,90)
scroll.CanvasSize            = UDim2.new(0,0,0,0)
scroll.Parent                = frame

local sl = Instance.new("UIListLayout")
sl.Padding = UDim.new(0,8)
sl.Parent  = scroll

local sp2 = Instance.new("UIPadding")
sp2.PaddingTop    = UDim.new(0,10)
sp2.PaddingLeft   = UDim.new(0,10)
sp2.PaddingRight  = UDim.new(0,10)
sp2.PaddingBottom = UDim.new(0,10)
sp2.Parent        = scroll

local function ac()
    scroll.CanvasSize = UDim2.new(0,0,0, sl.AbsoluteContentSize.Y + 20)
end
sl:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(ac)

local function sec(txt)
    local l = Instance.new("TextLabel")
    l.Size                  = UDim2.new(1,0,0,20)
    l.BackgroundTransparency = 1
    l.TextColor3            = Color3.fromRGB(140,140,140)
    l.Text                  = txt
    l.Font                  = Enum.Font.GothamBold
    l.TextSize              = 11
    l.TextXAlignment        = Enum.TextXAlignment.Left
    l.Parent                = scroll
    return l
end

local function mkBtn(txt, bg, tc)
    local orig = bg or Color3.fromRGB(55,55,55)
    local b    = Instance.new("TextButton")
    b.Size             = UDim2.new(1,0,0,34)
    b.BackgroundColor3 = orig
    b.TextColor3       = tc or Color3.fromRGB(220,220,220)
    b.Text             = txt
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 13
    b.AutoButtonColor  = false
    b.Parent           = scroll
    addCorner(b,6)
    addStroke(b, Color3.fromRGB(70,70,70))
    b.MouseEnter:Connect(function()
        b.BackgroundColor3 = orig:Lerp(Color3.fromRGB(255,255,255), 0.1)
    end)
    b.MouseLeave:Connect(function()
        b.BackgroundColor3 = orig
    end)
    return b
end

-- Список игроков
sec("👥  Игроки на сервере:")

local pscroll = Instance.new("ScrollingFrame")
pscroll.Size                 = UDim2.new(1,0,0,110)
pscroll.BackgroundColor3     = Color3.fromRGB(30,30,30)
pscroll.BorderSizePixel      = 0
pscroll.ScrollBarThickness   = 3
pscroll.ScrollBarImageColor3 = Color3.fromRGB(80,80,80)
pscroll.CanvasSize           = UDim2.new(0,0,0,0)
pscroll.Parent               = scroll
addCorner(pscroll,6)

local pll = Instance.new("UIListLayout")
pll.Padding = UDim.new(0,3)
pll.Parent  = pscroll

local plp = Instance.new("UIPadding")
plp.PaddingTop   = UDim.new(0,4)
plp.PaddingLeft  = UDim.new(0,4)
plp.PaddingRight = UDim.new(0,4)
plp.Parent       = pscroll

local selP  = {}
local pBtns = {}

local ml = Instance.new("TextLabel")
ml.Size                  = UDim2.new(1,0,0,18)
ml.BackgroundTransparency = 1
ml.TextColor3            = Color3.fromRGB(120,200,120)
ml.Text                  = "Выбрано: никого"
ml.Font                  = Enum.Font.Gotham
ml.TextSize              = 11
ml.TextXAlignment        = Enum.TextXAlignment.Left
ml.Parent                = scroll

local function updML()
    local ns = {}
    for k, v in pairs(selP) do
        if type(k) == "userdata" then
            table.insert(ns, k.Name)
        elseif type(k) == "string" and k:sub(1,10) == "__offline__" then
            table.insert(ns, v.Name .. "✍")
        end
    end
    if #ns == 0 then
        ml.Text = "Выбрано: никого"
    else
        ml.Text = "Выбрано (" .. #ns .. "): " .. table.concat(ns, ", ")
    end
end

local function refPL()
    for _, b in ipairs(pBtns) do
        if b and b.Parent then b:Destroy() end
    end
    pBtns = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        local b = Instance.new("TextButton")
        b.Size             = UDim2.new(1,-8,0,24)
        b.BackgroundColor3 = selP[plr]
            and Color3.fromRGB(55,95,55)
            or  Color3.fromRGB(45,45,48)
        b.TextColor3      = Color3.fromRGB(200,200,200)
        b.Text            = "  " .. plr.Name
        b.Font            = Enum.Font.Gotham
        b.TextSize        = 12
        b.TextXAlignment  = Enum.TextXAlignment.Left
        b.AutoButtonColor = false
        b.Parent          = pscroll
        addCorner(b,4)
        b.MouseButton1Click:Connect(function()
            if selP[plr] then
                selP[plr] = nil
                b.BackgroundColor3 = Color3.fromRGB(45,45,48)
            else
                selP[plr] = true
                b.BackgroundColor3 = Color3.fromRGB(55,95,55)
            end
            updML()
        end)
        table.insert(pBtns, b)
    end
    pscroll.CanvasSize = UDim2.new(0,0,0, pll.AbsoluteContentSize.Y + 8)
end

refPL()
pll:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    pscroll.CanvasSize = UDim2.new(0,0,0, pll.AbsoluteContentSize.Y + 8)
end)

local rlb = mkBtn("🔄  Обновить список", Color3.fromRGB(40,40,60))
rlb.MouseButton1Click:Connect(function()
    selP = {}
    refPL()
    updML()
end)

-- Ввод вручную
sec("✍️  Имя вручную (офлайн):")

local mi = Instance.new("TextBox")
mi.Size              = UDim2.new(1,0,0,32)
mi.BackgroundColor3  = Color3.fromRGB(38,38,38)
mi.TextColor3        = Color3.fromRGB(255,255,255)
mi.PlaceholderText   = "Имя игрока..."
mi.PlaceholderColor3 = Color3.fromRGB(90,90,90)
mi.Text              = ""
mi.Font              = Enum.Font.Gotham
mi.TextSize          = 13
mi.ClearTextOnFocus  = false
mi.Parent            = scroll
addCorner(mi,6)
addStroke(mi, Color3.fromRGB(60,60,70))

local amb = mkBtn("➕  Добавить в выбор", Color3.fromRGB(40,60,80))
amb.MouseButton1Click:Connect(function()
    local name = (mi.Text or ""):match("^%s*(.-)%s*$")
    if not name or name == "" then return end
    local onl = Players:FindFirstChild(name)
    if onl then
        selP[onl] = true
        refPL()
    else
        local key = "__offline__" .. name
        if not selP[key] then
            selP[key] = {Name=name, Character=nil}
            local l2 = Instance.new("TextLabel")
            l2.Size             = UDim2.new(1,-8,0,24)
            l2.BackgroundColor3 = Color3.fromRGB(60,50,30)
            l2.TextColor3       = Color3.fromRGB(220,200,150)
            l2.Text             = "  ✍ " .. name .. " (офлайн)"
            l2.Font             = Enum.Font.Gotham
            l2.TextSize         = 12
            l2.TextXAlignment   = Enum.TextXAlignment.Left
            l2.Parent           = pscroll
            addCorner(l2,4)
            table.insert(pBtns, l2)
            pscroll.CanvasSize = UDim2.new(0,0,0, pll.AbsoluteContentSize.Y+8)
        end
    end
    updML()
    mi.Text = ""
end)

-- Тип
sec("🪦  Тип могилы:")
local stNms = {"RIP камень","Крест","Склеп"}
local stCls = {
    Color3.fromRGB(55,55,85),
    Color3.fromRGB(75,45,45),
    Color3.fromRGB(45,65,45),
}
local stIdx = 1
local stb   = mkBtn("▶  " .. stNms[1], stCls[1])
stb.MouseButton1Click:Connect(function()
    stIdx = stIdx % #stNms + 1
    stb.Text             = "▶  " .. stNms[stIdx]
    stb.BackgroundColor3 = stCls[stIdx]
end)

-- Режим
sec("♻️  Режим размещения:")
local repMode = false
local repBtn  = mkBtn("▶  Добавить рядом", Color3.fromRGB(50,50,50))
repBtn.MouseButton1Click:Connect(function()
    repMode = not repMode
    repBtn.Text             = repMode
        and "▶  Заменить существующие"
        or  "▶  Добавить рядом"
    repBtn.BackgroundColor3 = repMode
        and Color3.fromRGB(90,50,20)
        or  Color3.fromRGB(50,50,50)
end)

-- Действия
sec("⚙️  Действия:")

local function getPL()
    local lst = {}
    for k, v in pairs(selP) do
        if type(k) == "userdata" then
            table.insert(lst, k)
        elseif type(k) == "string" and k:sub(1,10) == "__offline__" then
            table.insert(lst, v)
        end
    end
    if #lst == 0 then
        table.insert(lst, LocalPlayer)
    end
    return lst
end

local function footPos()
    local c = LocalPlayer.Character
    if not c then return Vector3.new(0,0,0) end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    if not hrp then return Vector3.new(0,0,0) end
    return Vector3.new(hrp.Position.X, hrp.Position.Y - 3, hrp.Position.Z)
end

local function bye()
    screenGui:Destroy()
    pcall(function() script:Destroy() end)
end

-- Одиночная могила
local b1 = mkBtn("⚰️  Построить могилу", Color3.fromRGB(55,130,55))
b1.MouseButton1Click:Connect(function()
    if repMode then clearGraves(); syncRemoveAll(); builtModels = {} end
    local fp  = footPos()
    local sk  = ({"rip","cross","crypt"})[stIdx]
    local pl  = getPL()
    local tp  = pl[1]
    local pn  = tp and tp.Name or LocalPlayer.Name
    local payload = {
        id         = genId(),
        graveType  = (sk == "crypt") and "crypt" or "grave",
        origin     = v3t(fp),
        playerName = pn,
        style      = sk,
        owner      = myClientId,
        timestamp  = os.time(),
    }
    local mdl
    if sk == "crypt" then
        mdl = buildCrypt(fp, pn, tp)
    else
        mdl = buildGrave(fp, sk, pn, tp)
    end
    builtModels[payload.id] = mdl
    syncBuild(payload)
    bye()
end)

-- Кладбище
local b2 = mkBtn("🏚️  Кладбище + Часовня", Color3.fromRGB(100,65,30))
b2.MouseButton1Click:Connect(function()
    if repMode then clearGraves(); syncRemoveAll(); builtModels = {} end
    local fp = footPos()
    local pl = getPL()
    local ns = {}
    for _, p in ipairs(pl) do table.insert(ns, p.Name) end
    buildCemetery(fp, pl)
    local payload = {
        id          = genId(),
        graveType   = "cemetery",
        origin      = v3t(fp),
        playerName  = LocalPlayer.Name,
        playerNames = ns,
        owner       = myClientId,
        timestamp   = os.time(),
    }
    builtModels[payload.id] = true
    syncBuild(payload)
    bye()
end)

-- Склеп
local b3 = mkBtn("🏛️  Построить склеп", Color3.fromRGB(40,60,80))
b3.MouseButton1Click:Connect(function()
    if repMode then clearGraves(); syncRemoveAll(); builtModels = {} end
    local fp = footPos()
    local pl = getPL()
    local tp = pl[1]
    local pn = tp and tp.Name or LocalPlayer.Name
    local payload = {
        id         = genId(),
        graveType  = "crypt",
        origin     = v3t(fp),
        playerName = pn,
        style      = "crypt",
        owner      = myClientId,
        timestamp  = os.time(),
    }
    builtModels[payload.id] = buildCrypt(fp, pn, tp)
    syncBuild(payload)
    bye()
end)

-- Удалить
local b4 = mkBtn("🗑️  Удалить все могилы", Color3.fromRGB(80,25,25))
b4.MouseButton1Click:Connect(function()
    clearGraves()
    syncRemoveAll()
    builtModels = {}
end)

-- Закрыть
local b5 = mkBtn("✖  Закрыть", Color3.fromRGB(40,40,40), Color3.fromRGB(180,180,180))
b5.MouseButton1Click:Connect(bye)

ac()
print("[GraveBuilder] ✓ " .. myClientId .. " | " .. httpName)
