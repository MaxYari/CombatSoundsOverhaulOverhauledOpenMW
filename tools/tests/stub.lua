-- Minimal fake of the OpenMW Lua API, enough to load SoundManager.lua and drive it the way the engine does.
local M = {}

M.simulationTime = 100.0
M.playing = {}     -- lowercase sound id -> true, the vanilla sounds playing on the actor
M.filesPlayed = {} -- { file = ..., options = ... } per playSoundFile3d
M.stopped = {}     -- sound ids passed to stopSound3d
M.rightHand = nil  -- whatever the actor holds in its right hand
M.vfsPaths = {}    -- normalized VFS paths the vfs stub lists

M.playBlendedHandlers = {}
M.textKeyHandlers = {} -- groupname -> { handler, ... }
M.hitHandlers = {}

-- Returns the paths under `dir` (a real CSO install) the way the VFS lists them: lowercase, forward slashes.
function M.listDir(dir)
    local paths = {}
    local p = io.popen('cd "' .. dir .. '" && find . -type f')
    for line in p:lines() do paths[#paths + 1] = line:gsub('^%./', ''):lower() end
    p:close()
    return paths
end

-- The engine playing a vanilla sound record on the actor, e.g. from prepareHit or applyArmor.
function M.enginePlays(tag) M.playing[tag:lower()] = true end

function M.reset()
    M.playing, M.filesPlayed, M.stopped = {}, {}, {}
end

-- The engine's own attack animation calls, as CharacterController::updateWeaponState makes them.
function M.windUp(attack)
    for i = #M.playBlendedHandlers, 1, -1 do
        M.playBlendedHandlers[i]('weapononehand', { startKey = attack .. ' start', stopKey = attack .. ' max attack' })
    end
end
function M.release(attack)
    for i = #M.playBlendedHandlers, 1, -1 do
        M.playBlendedHandlers[i]('weapononehand', { startKey = attack .. ' max attack', stopKey = attack .. ' hit' })
    end
end
function M.textKey(groupname, key)
    for _, list in ipairs({ M.textKeyHandlers[groupname] or {}, M.textKeyHandlers[''] or {} }) do
        for i = #list, 1, -1 do list[i](groupname, key) end
    end
end
function M.hit(attack)
    for i = #M.hitHandlers, 1, -1 do M.hitHandlers[i](attack) end
end

local selfObject = { recordId = 'test_actor' }
M.isPlayer = false

M.packages = {
    ['openmw.core'] = {
        getSimulationTime = function() return M.simulationTime end,
        sound = {
            isSoundPlaying = function(tag, obj)
                assert(obj ~= nil, 'isSoundPlaying needs an object')
                return M.playing[tag:lower()] == true
            end,
            stopSound3d = function(tag, obj)
                assert(obj ~= nil, 'stopSound3d needs an object')
                M.stopped[#M.stopped + 1] = tag
                M.playing[tag:lower()] = nil
            end,
            playSoundFile3d = function(file, obj, options)
                assert(obj ~= nil, 'playSoundFile3d needs an object')
                M.filesPlayed[#M.filesPlayed + 1] = { file = file, options = options }
            end,
        },
    },
    ['openmw.self'] = setmetatable({ object = selfObject }, { __index = selfObject }),
    ['openmw.types'] = {
        Actor = {
            EQUIPMENT_SLOT = { CarriedRight = 16 },
            getEquipment = function(_, slot)
                assert(slot == 16, 'only the right hand is ever asked for')
                return M.rightHand
            end,
        },
        Player = { objectIsInstance = function() return M.isPlayer end },
    },
    ['openmw.vfs'] = {
        pathsWithPrefix = function(prefix)
            local i = 0
            return function()
                repeat
                    i = i + 1
                    local path = M.vfsPaths[i]
                    if path and path:sub(1, #prefix) == prefix then return path end
                until not path
                return nil
            end
        end,
    },
    ['openmw.interfaces'] = {
        AnimationController = {
            addPlayBlendedAnimationHandler = function(fn) M.playBlendedHandlers[#M.playBlendedHandlers + 1] = fn end,
            addTextKeyHandler = function(groupname, fn)
                groupname = groupname or ''
                M.textKeyHandlers[groupname] = M.textKeyHandlers[groupname] or {}
                table.insert(M.textKeyHandlers[groupname], fn)
            end,
        },
        Combat = {
            addOnHitHandler = function(fn) M.hitHandlers[#M.hitHandlers + 1] = fn end,
        },
    },
}

return M
