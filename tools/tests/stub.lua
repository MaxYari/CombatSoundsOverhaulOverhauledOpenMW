-- Minimal fake of the OpenMW Lua API, enough to load SoundManager.lua and drive it the way the engine does.
local M = {}

M.simulationTime = 100.0
M.playing = {}     -- lowercase sound id -> true, the vanilla sounds playing on the actor
M.filesPlayed = {} -- { file = ..., options = ... } per playSoundFile3d
M.infos = {}       -- the play handler info of each sound played, for scripts loaded by test.lua
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
    M.playing, M.filesPlayed, M.stopped, M.infos = {}, {}, {}, {}
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

-- The actor the script runs on. Set isCreature on it for a creature; bloodType is read once per script load.
local selfObject = { recordId = 'test_actor' }
M.selfObject = selfObject
M.isPlayer = false
M.bloodType = 0
M.record = {} -- name, model, id of the actor's record
selfObject.type = {
    record = function()
        return { bloodType = M.bloodType, name = M.record.name, model = M.record.model, id = M.record.id }
    end,
}

M.WEAPON_TYPE = {
    ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2, BluntOneHand = 3, BluntTwoClose = 4,
    BluntTwoWide = 5, SpearTwoWide = 6, AxeOneHand = 7, AxeTwoHand = 8, MarksmanBow = 9, MarksmanCrossbow = 10,
    MarksmanThrown = 11, Arrow = 12, Bolt = 13,
}
function M.weapon(recordId, typeName)
    return { recordId = recordId, isWeapon = true, weaponType = assert(M.WEAPON_TYPE[typeName], typeName) }
end
function M.item(recordId) return { recordId = recordId } end
function M.npc() return { recordId = 'test_npc' } end
function M.creature() return { recordId = 'test_creature', isCreature = true } end

-- An actor that keeps the events sent to it: { name = ..., data = ... }
function M.eventTaker(recordId)
    local actor = { recordId = recordId, events = {} }
    function actor:sendEvent(name, data) self.events[#self.events + 1] = { name = name, data = data } end
    return actor
end
M.nearby = { players = {}, actors = {} }

-- The vanilla swing sounds, as in Morrowind.esm
M.soundRecords = {
    ['weapon swish'] = { fileName = 'sound/fx/swoosh 1.wav' },
    swishs = { fileName = 'sound/fx/swoosh 2.wav' },
    swishm = { fileName = 'sound/fx/swoosh 1.wav' },
    swishl = { fileName = 'sound/fx/swoosh 3.wav' },
}

-- storage.playerSection: get, set and subscribe, with set calling the subscribers as the engine does
M.sections = {}
local function section(key)
    if not M.sections[key] then
        local s = { values = {}, subscribers = {} }
        function s:get(k) return self.values[k] end
        function s:set(k, v)
            self.values[k] = v
            for _, fn in ipairs(self.subscribers) do fn(key, k) end
        end
        function s:subscribe(fn) self.subscribers[#self.subscribers + 1] = fn end
        M.sections[key] = s
    end
    return M.sections[key]
end
M.settingsPages, M.settingsGroups = {}, {}

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
            records = setmetatable({}, { __index = function(_, id) return M.soundRecords[id] end }),
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
        Creature = { objectIsInstance = function(obj) return obj.isCreature == true end },
        Weapon = {
            TYPE = M.WEAPON_TYPE,
            objectIsInstance = function(obj) return obj.isWeapon == true end,
            record = function(obj) return { type = obj.weaponType } end,
        },
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
    ['openmw.async'] = { callback = function(_, fn) return fn end },
    ['openmw.nearby'] = M.nearby,
    ['openmw.storage'] = { playerSection = section },
    ['openmw.util'] = {
        makeStrictReadOnly = function(t)
            return setmetatable({}, {
                __index = function(_, k)
                    local v = t[k]
                    if v == nil then error('Key not found: ' .. tostring(k), 2) end
                    return v
                end,
                __newindex = function() error('Table is read only', 2) end,
            })
        end,
    },
    ['openmw_aux.util'] = {
        -- as in resources/vfs/openmw_aux/util.lua: newest first, true once a handler returns false
        callEventHandlers = function(handlers, ...)
            if handlers then
                for i = #handlers, 1, -1 do
                    if handlers[i](...) == false then return true end
                end
            end
            return false
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
        -- as in scripts/omw/settings: a setting starts at its default
        Settings = {
            registerPage = function(options) M.settingsPages[options.key] = options end,
            registerGroup = function(options)
                M.settingsGroups[options.key] = options
                for _, setting in ipairs(options.settings) do
                    if section(options.key):get(setting.key) == nil then
                        section(options.key):set(setting.key, setting.default)
                    end
                end
            end,
        },
        Combat = {
            addOnHitHandler = function(fn) M.hitHandlers[#M.hitHandlers + 1] = fn end,
            ATTACK_TYPES = { Chop = 0, Slash = 1, Thrust = 2 },
            ATTACK_SOURCE_TYPES = { Magic = 'magic', Melee = 'melee', Ranged = 'ranged', Unspecified = 'unspecified' },
        },
    },
}

return M
