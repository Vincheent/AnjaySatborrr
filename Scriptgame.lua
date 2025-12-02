require "samp.raknet"
local sampev = require "lib.samp.events"

local COLOR_OK   = 0x00FF00
local COLOR_INFO = 0x00BFFF
local COLOR_ERR  = 0xFF0000
local COLOR_WARN = 0xFFFF00

local keys = {
    N   = {value = 128,  type = 36}, 
    ALT = {value = 1024, type = 4 }, 
    Y   = {value = 64,   type = 36}  
}

local isActive        = false
local wasPaused       = false     
local textdrawActive  = false     
local fishTextdrawId  = nil      
local targetSlot      = 2         

-- deteksi textdraw inventory
local slotId = {}                 -- mapping index slot -> textdraw id
local gunakanId = nil             -- textdraw id tombol "Gunakan"
local posTolerance = 1.0

-- Koordinat grid 4x5 (20 slot) – sesuaikan jika layout server beda
local slotCoords = {
    [1]  = {x = 125.0, y = 137.0}, [2]  = {x = 164.0, y = 137.0}, [3]  = {x = 203.0, y = 137.0}, [4]  = {x = 242.0, y = 137.0}, [5]  = {x = 281.0, y = 137.0},
    [6]  = {x = 125.0, y = 189.0}, [7]  = {x = 164.0, y = 189.0}, [8]  = {x = 203.0, y = 189.0}, [9]  = {x = 242.0, y = 189.0}, [10] = {x = 281.0, y = 189.0},
    [11] = {x = 125.0, y = 241.0}, [12] = {x = 164.0, y = 241.0}, [13] = {x = 203.0, y = 241.0}, [14] = {x = 242.0, y = 241.0}, [15] = {x = 281.0, y = 241.0},
    [16] = {x = 125.0, y = 293.0}, [17] = {x = 164.0, y = 293.0}, [18] = {x = 203.0, y = 293.0}, [19] = {x = 242.0, y = 293.0}, [20] = {x = 281.0, y = 293.0},
}

local function SendKey(key)
    local _, playerId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if playerId then
        local memPtr = allocateMemory(68)
        if memPtr ~= 0 then
            sampStorePlayerOnfootData(playerId, memPtr)
            -- type 36 = onfoot keys, type 4 = special keys
            setStructElement(memPtr, key.type, (key.type == 36 and 1 or 2), key.value, false)
            sampSendOnfootData(memPtr)
            freeMemory(memPtr)
        end
    end
end

local function debounceKey()
    wasPaused = true
    lua_thread.create(function()
        wait(70)
        wasPaused = false
    end)
end

local function sendSelectTextDraw(id)
    if not id then return end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt16(bs, id)
    raknetSendRpc(83, bs) -- RPC ClickTextDraw
    raknetDeleteBitStream(bs)
end

local function openInventoryAndUse(slot)
    lua_thread.create(function()
        slot = tonumber(slot) or targetSlot
        if slot < 1 or slot > 20 then
            sampAddChatMessage(string.format("[AutoFish] Slot invalid: %s", tostring(slot)), COLOR_ERR)
            return
        end

    
        slotId = {}
        gunakanId = nil

        -- Buka inventory
        sampSendChat("/i")

        -- Tunggu IDs terdeteksi (RPC 134 handler yang isi slotId & gunakanId)
        local waited = 0
        local timeout = 4500
        while waited < timeout and (not slotId[slot] or not gunakanId) do
            wait(100)
            waited = waited + 100
        end

        if not slotId[slot] then
            sampAddChatMessage(string.format("[AutoFish] Gagal deteksi TextDraw slot %d", slot), COLOR_ERR)
            return
        end
        if not gunakanId then
            sampAddChatMessage("[AutoFish] Tombol 'Gunakan' belum terdeteksi!", COLOR_ERR)
            return
        end

        -- Klik slot → klik Gunakan → (biar aman) klik 65535 untuk 'release'
        sendSelectTextDraw(slotId[slot]); wait(79)
        sendSelectTextDraw(gunakanId);   wait(79)
        sendSelectTextDraw(65535)

        -- Setelah ini, server biasanya munculkan minigame (ALT/Y/N)
        -- Kita tunggu di event RPC 134 & TextDrawHide
    end)
end

-- ======== LOOP: Ulangi siklus ========
local function cycleOnce()
    if not isActive then return end
    openInventoryAndUse(targetSlot)
end

-- ======== SERVER MESSAGES (opsional penanganan gagal) ========
function sampev.onServerMessage(color, text)
    if not isActive then return end
    local lowerText = string.lower(text or "")
    -- Jika server mengirim pesan gagal (contoh: sampah/terputus), kita coba ulang siklus
    if lowerText:find("terputus") or lowerText:find("sampah") or lowerText:find("mendapatkan") or lowerText:find("berat") then
        lua_thread.create(function()
            wait(1200)
            if isActive and not textdrawActive then
                cycleOnce()
            end
        end)
    end
end

-- ======== RPC 134: Baca TextDraw ========
function onReceiveRpc(id, bs)
    if id ~= 134 then return end

    local pos = raknetBitStreamGetReadOffset(bs)
    raknetBitStreamSetReadOffset(bs, 0)

    local ok, d = pcall(function()
        local t = {}
        t.textDrawId        = raknetBitStreamReadInt16(bs)
        t.flags             = raknetBitStreamReadInt8(bs)
        local _fLW          = raknetBitStreamReadFloat(bs)
        local _fLH          = raknetBitStreamReadFloat(bs)
        local _dLetterColor = raknetBitStreamReadInt32(bs)
        local _fLineW       = raknetBitStreamReadFloat(bs)
        local _fLineH       = raknetBitStreamReadFloat(bs)
        local _dBoxColor    = raknetBitStreamReadInt32(bs)
        local _shadow       = raknetBitStreamReadInt8(bs)
        local _outline      = raknetBitStreamReadInt8(bs)
        local _bgColor      = raknetBitStreamReadInt32(bs)
        t.style             = raknetBitStreamReadInt8(bs)
        t.selectable        = raknetBitStreamReadInt8(bs)
        t.fX                = raknetBitStreamReadFloat(bs)
        t.fY                = raknetBitStreamReadFloat(bs)
        t.modelid           = raknetBitStreamReadInt16(bs)
        local _rx           = raknetBitStreamReadFloat(bs)
        local _ry           = raknetBitStreamReadFloat(bs)
        local _rz           = raknetBitStreamReadFloat(bs)
        local _zoom         = raknetBitStreamReadFloat(bs)
        local _c1           = raknetBitStreamReadInt16(bs)
        local _c2           = raknetBitStreamReadInt16(bs)
        local textLen       = raknetBitStreamReadInt16(bs)
        t.text              = (textLen and textLen > 0) and raknetBitStreamReadString(bs, textLen) or ""
        return t
    end)

    raknetBitStreamSetReadOffset(bs, pos)
    if not ok or not d then return end

    -- 1) DETEKSI TEXTDRAW INVENTORY (slot & tombol Gunakan)
    --    Heuristik: server sering pakai "LD_SPAC:white" pada sprite item/button
    if d.text and d.text:find("LD_SPAC:white") then
        -- map ke slot bila posisinya cocok
        for i, c in pairs(slotCoords) do
            if math.abs(d.fX - c.x) < posTolerance and math.abs(d.fY - c.y) < posTolerance then
                slotId[i] = d.textDrawId
            end
        end
        -- deteksi tombol gunakan (koordinat contoh; sesuaikan kalau beda server)
        if d.style == 4 and d.selectable == 1 and d.modelid == 0 then
            if math.abs(d.fX - 334.0) < 0.6 and math.abs(d.fY - 213.0) < 0.6 then
                gunakanId = d.textDrawId
            end
        end
    end

    -- 2) DETEKSI MINI-GAME FISH (ALT/Y/N)
    if not isActive or wasPaused then return end
    local txt = d.text or ""
    if txt == "" then return end

    local isPrompt = txt:find("Tekan %[N%] sekarang!") or
                     txt:find("Tekan %[ALT%] sekarang!") or
                     txt:find("Tekan %[Y%] sekarang!")

    if isPrompt then
        textdrawActive = true
        fishTextdrawId = d.textDrawId
        if txt:find("Tekan %[N%] sekarang!") then
            SendKey(keys.N)
            debounceKey()
        elseif txt:find("Tekan %[ALT%] sekarang!") then
            SendKey(keys.ALT)
            debounceKey()
        elseif txt:find("Tekan %[Y%] sekarang!") then
            SendKey(keys.Y)
            debounceKey()
        end
    end
end

-- ======== RPC 135 / TextDrawHide: selesai mini-game ========
function sampev.onTextDrawHide(id)
    if not isActive then return end
    if textdrawActive and id == fishTextdrawId then
        -- minigame selesai
        textdrawActive = false
        fishTextdrawId = nil

        -- tutup siklus sebentar, lalu ulangi: buka /i lagi & gunakan slot
        lua_thread.create(function()
            wait(500)
            if isActive and not textdrawActive then
                -- kembali ke awal: buka inventory dan gunakan item lagi
                cycleOnce()
            end
        end)
    end
end

-- ======== ENTRY POINT ========
function main()
    repeat wait(100) until isSampAvailable()
    wait(1000)

    sampAddChatMessage("[AutoFish] Siap. Gunakan /fishh untuk ON/OFF. /fishslot [1-20] untuk pilih slot.", COLOR_WARN)

    sampRegisterChatCommand("fishh", function()
        isActive = not isActive
        if isActive then
            textdrawActive = false
            fishTextdrawId = nil
            sampAddChatMessage(string.format("[AutoFish] AKTIF (slot=%d). Memulai siklus...", targetSlot), COLOR_OK)
            lua_thread.create(function()
                wait(400)
                cycleOnce()
            end)
        else
            textdrawActive = false
            fishTextdrawId = nil
            sampAddChatMessage("[AutoFish] NONAKTIF.", COLOR_INFO)
        end
    end)

    sampRegisterChatCommand("fishslot", function(p)
        local s = tonumber(p)
        if s and s >= 1 and s <= 20 then
            targetSlot = s
            sampAddChatMessage(string.format("[AutoFish] Slot diset ke %d.", targetSlot), COLOR_INFO)
        else
            sampAddChatMessage("[AutoFish] Usage: /fishslot [1-20]", COLOR_INFO)
        end
    end)

    -- idle loop
    while true do wait(1000) end
end
