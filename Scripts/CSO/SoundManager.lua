-- Combat Sounds Overhaul, event driven. This file takes the place of CSO's own Scripts/CSO/SoundManager.lua, so
-- CSO's plugin attaches it and nothing new needs enabling. The sounds are played from where CSO installed them.
--
-- CSO swaps the vanilla weapon swishes and armor hit sounds for its own. The original asked every frame, on every
-- actor, whether one of seven vanilla sounds was playing. This one waits for whatever makes the engine play them,
-- and only then looks at the sound:
--   * Weapon Swish is played when an attack is released, right before the engine plays the release half of the
--     attack animation. That playBlended call reaches the handler below synchronously, so the swish is swapped the
--     moment it starts. An attack released before its wind-up reached "min attack" only plays the release half
--     once it gets there, so for WINDUP_WATCH seconds after a wind-up starts the swish is also looked for in onUpdate.
--   * SwishS / SwishM / SwishL come from "Sound: Swish*" text keys in creature attack animations. The engine plays
--     the sound as the key passes and hands the key to Lua in the same frame.
--   * Light / Medium / Heavy Armor Hit are played by the builtin Combat onHit handler, which runs after ours. A
--     successful hit is kept for a check that onUpdate makes later in the same Lua update, after all the hit events.
--   * Health Damage (Sound/Fx/body hit.wav) plays from the same handler on every hit that takes health, armored or
--     not. It is never replaced: this mod ships its own copy of the file. When that check finds it with no armor
--     sound, the hit landed on an unarmored spot (or on a creature), and a CSO impact is layered on top.
-- onUpdate does nothing unless one of those is pending.
--
-- Which CSO sounds answer depends on what the attack is made with (weaponKind: the swinging actor's right hand, or
-- the hit's weapon and attacker) and what it lands on: the builtin handler rolls a spot and plays the armor sound for
-- the weight of the armor there, or only Health Damage if there's none, and then the actor's body counts, from its
-- blood type. The *_SOUNDS tables below say which of the sorted categories go with what. An attack with no
-- categories keeps its vanilla sound: a creature's own attack swings with the vanilla swish, as it did in the original.
local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local vfs = require('openmw.vfs')
local I = require('openmw.interfaces')

-- the Nexus release workflow reads the first `version = ...` in this file
local VERSION = "1.0"

local WINDUP_WATCH = 1.5 -- seconds of simulation time an attack's wind-up is watched for an early release
local PITCH_MIN, PITCH_MAX = 0.85, 1.0 -- every CSO sound plays at a random pitch in between

local SOUND_DIRS = {
    swing = 'sound/fx/item/csoswing/',
    hit = 'sound/fx/item/csohit/',
}
local SOUND_EXTENSIONS = { wav = true, mp3 = true, ogg = true, flac = true }

-- Near copies of another CSO file, left out so that sound doesn't come up twice as often.
local DUPLICATES = {
    ['sound/fx/item/csoswing/swing6.wav'] = true, -- Swing5 trimmed a little shorter
}

-- CSO's SwingN and HitN files sorted by ear. Each entry is a number N, or a { first, last } range of them.
local SWING_CATEGORIES = {
    plain = { { 21, 23 } },            -- generic, no metal: hand-to-hand, maybe staves
    sharpMetal = { { 1, 6 } },         -- short blades, daggers
    metal = { { 11, 16 } },            -- generic: swords, staves
    ringingBlade = { { 24, 26 } },     -- one-handed long blades: like metal, but sharper and with a ring
    heavyMetal = { { 7, 10 } },        -- maces, axes, probably two-handed swords
    heavyMetalGeneric = { { 17, 20 } }, -- staves, polearms, spears, maybe two-handed maces, axes and swords
}
-- Hit68, Hit97 and Hit98 aren't sorted yet.
local HIT_CATEGORIES = {
    -- flesh
    flesh = { { 1, 10 } },
    punchyFlesh = { { 25, 29 } },
    crunchyFlesh = { 72, 79 },                             -- punchy and crunchy, maybe maces on unarmored
    fleshySlice = { { 61, 64 } },                          -- daggers and knives, maybe swords
    fleshyStab = { { 65, 67 }, 70, { 73, 76 } },
    stab = { 77, 78 },                                     -- simple stabs
    blade = { { 11, 17 } },                                -- simple blade hits
    -- armor
    armor = { { 18, 21 }, { 30, 32 }, { 57, 60 } },
    armorHeavy = { { 22, 24 }, { 33, 40 }, { 82, 95 }, { 99, 102 } }, -- maybe maces later; 82+ are HeavyWoodClubInto
    armorHeavyBlade = { 96 },                              -- with a ring
    armorFlesh = { { 41, 56 }, 71 },                       -- with a bloody layer
    armorCrunchyFlesh = { 80, 81 },
    armorStab = { 69 },                                    -- fleshy stab with a metal ring
}

-- Which categories answer an attack, by what it's made with: a weaponKind family with its hands (longBlade1), or
-- the family alone. `default` covers the rest; without one, the vanilla sound stays. Every file of every listed
-- category is in the draw.
local SWING_SOUNDS = {
    shortBlade = { 'sharpMetal' },
    longBlade1 = { 'ringingBlade', 'metal' },
    longBlade2 = { 'heavyMetal', 'heavyMetalGeneric' },
    blunt1 = { 'heavyMetal' },
    blunt2 = { 'heavyMetal', 'heavyMetalGeneric' },
    axe1 = { 'heavyMetal' },
    axe2 = { 'heavyMetal', 'heavyMetalGeneric' },
    spear = { 'heavyMetalGeneric' },
    staff = { 'plain', 'metal', 'heavyMetalGeneric' },
    thrown = { 'sharpMetal', 'plain' },
    handToHand = { 'plain' },
}
-- An unarmored spot, light armor, or a creature of flesh and blood
local FLESH_HIT_SOUNDS = {
    shortBlade = { 'fleshySlice', 'fleshyStab' },
    longBlade = { 'fleshySlice', 'blade' },
    blunt = { 'crunchyFlesh', 'punchyFlesh' },
    spear = { 'fleshyStab', 'stab' },
    handToHand = { 'punchyFlesh', 'flesh' },
    default = { 'flesh', 'punchyFlesh' }, -- axes, staves, thrown weapons, arrows, creatures' own attacks
}
-- Medium and heavy armor: an armor hit only takes health once it's through, so only the armor hits with flesh or
-- crunch in them. The plain clanks (armor, armorHeavy) would sound like the blow was stopped.
local FLESHY_ARMOR_HIT_SOUNDS = {
    shortBlade = { 'armorFlesh', 'armorStab' },
    spear = { 'armorFlesh', 'armorStab' },
    default = { 'armorFlesh', 'armorCrunchyFlesh' },
}
-- A creature of metal, which doesn't bleed
local METAL_BODY_HIT_SOUNDS = {
    shortBlade = { 'armorHeavy', 'armorHeavyBlade' },
    longBlade = { 'armorHeavy', 'armorHeavyBlade' },
    default = { 'armorHeavy' },
}
-- What the hit lands on -> the table above that answers it. Bone (skeletons, ghosts) has no sounds yet, so it keeps
-- only the body hit.
local HIT_SOUNDS = {
    light = FLESH_HIT_SOUNDS,
    medium = FLESHY_ARMOR_HIT_SOUNDS,
    heavy = FLESHY_ARMOR_HIT_SOUNDS,
    flesh = FLESH_HIT_SOUNDS,
    metal = METAL_BODY_HIT_SOUNDS,
}
-- false leaves unarmored hits with only the body hit, e.g. to tune it on its own: the CSO layer starts with it and
-- drowns it out. emit('Health Damage') plays the layer either way.
local LAYER_UNARMORED_HITS = true

-- Vanilla sound record -> which CSO folder answers it. Keys are lowercase, as sound ids are case insensitive and
-- text keys reach Lua lowercased. The body hit is layered over; the others are replaced.
local TAGS = {
    ['weapon swish'] = 'swing',
    swishs = 'swing',
    swishm = 'swing',
    swishl = 'swing',
    ['light armor hit'] = 'hit',
    ['medium armor hit'] = 'hit',
    ['heavy armor hit'] = 'hit',
    ['health damage'] = 'body',
}
local TAG_NAMES = {
    'Weapon Swish', 'SwishS', 'SwishM', 'SwishL', 'Light Armor Hit', 'Medium Armor Hit', 'Heavy Armor Hit', 'Health Damage',
}
local ARMOR_HIT_TAGS = { 'Light Armor Hit', 'Medium Armor Hit', 'Heavy Armor Hit' }
local WEAPON_SWISH = 'Weapon Swish'
local HEALTH_DAMAGE = 'Health Damage'

-- The weight of the armor on the spot a hit landed, by the sound the builtin handler played for it
local ARMOR_BY_TAG = {
    ['light armor hit'] = 'light',
    ['medium armor hit'] = 'medium',
    ['heavy armor hit'] = 'heavy',
    ['health damage'] = 'none',
}
-- An actor's body, by its record's blood type: 1 is the bone dust of skeletons and ghosts, 2 the sparks of dwemer
-- machines. Anything else bleeds.
local BODY_BY_BLOOD = { [1] = 'bone', [2] = 'metal' }

-- Weapon.TYPE -> what CSO calls it: the family, and the hands it takes
local Weapon = types.Weapon
local WEAPON_KINDS = {
    [Weapon.TYPE.ShortBladeOneHand] = { family = 'shortBlade', hands = 1 },
    [Weapon.TYPE.LongBladeOneHand] = { family = 'longBlade', hands = 1 }, -- longswords, broadswords, katanas
    [Weapon.TYPE.LongBladeTwoHand] = { family = 'longBlade', hands = 2 }, -- claymores, dai-katanas
    [Weapon.TYPE.BluntOneHand] = { family = 'blunt', hands = 1 },         -- maces, clubs
    [Weapon.TYPE.BluntTwoClose] = { family = 'blunt', hands = 2 },        -- warhammers
    [Weapon.TYPE.BluntTwoWide] = { family = 'staff', hands = 2 },
    [Weapon.TYPE.SpearTwoWide] = { family = 'spear', hands = 2 },         -- spears and polearms
    [Weapon.TYPE.AxeOneHand] = { family = 'axe', hands = 1 },
    [Weapon.TYPE.AxeTwoHand] = { family = 'axe', hands = 2 },
    [Weapon.TYPE.MarksmanThrown] = { family = 'thrown', hands = 1 },
    [Weapon.TYPE.MarksmanBow] = { family = 'bow', hands = 2 },
    [Weapon.TYPE.MarksmanCrossbow] = { family = 'crossbow', hands = 2 },
}
local HAND_TO_HAND = { family = 'handToHand' }
local NATURAL = { family = 'natural' } -- a creature's own claws, bites and blows
local OTHER = { family = 'other' }     -- something that isn't a weapon, or a weapon type no attack is made with

local sound = core.sound
local getEquipment = types.Actor.getEquipment
local RIGHT_HAND = types.Actor.EQUIPMENT_SLOT.CarriedRight
local isPlayer = types.Player.objectIsInstance(self.object)

local debugLog = false
local windupUntil = nil -- simulation time the current wind-up stops being watched
local pendingHit = nil  -- the last successful hit, whose sounds onUpdate looks for

local function inEntries(n, entries)
    if not n then return false end
    for _, entry in ipairs(entries) do
        if type(entry) == 'number' then
            if n == entry then return true end
        elseif n >= entry[1] and n <= entry[2] then
            return true
        end
    end
    return false
end

-- folder ('swing' or 'hit') -> { all = every file, [category] = its files }. Listed on first use rather than at
-- load: most actors never swing or get hit.
local files = nil
local function getFiles()
    if files then return files end
    files = {}
    local categoriesOf = { swing = SWING_CATEGORIES, hit = HIT_CATEGORIES }
    for folder, dir in pairs(SOUND_DIRS) do
        local all = {}
        for path in vfs.pathsWithPrefix(dir) do
            if SOUND_EXTENSIONS[path:match('%.(%w+)$')] and not DUPLICATES[path] then all[#all + 1] = path end
        end
        table.sort(all)
        if #all == 0 and isPlayer then
            print('[Combat Sounds Overhaul] No sounds in ' .. dir .. ' - is Combat Sounds Overhaul installed?')
        end
        local byCategory = { all = all }
        for category, entries in pairs(categoriesOf[folder]) do
            local list = {}
            for _, path in ipairs(all) do
                if inEntries(tonumber(path:match('(%d+)%.%w+$')), entries) then list[#list + 1] = path end
            end
            byCategory[category] = list
        end
        files[folder] = byCategory
    end
    return files
end

-- Every file of the given categories, merged once per list of categories
local pools = {}
local function pool(folder, categories)
    local list = pools[categories]
    if not list then
        list = {}
        for _, category in ipairs(categories) do
            for _, path in ipairs(getFiles()[folder][category] or {}) do list[#list + 1] = path end
        end
        pools[categories] = list
    end
    return list
end

local function endsWith(s, suffix)
    return s:sub(-#suffix) == suffix
end

-- What an attack is made with: the weapon's kind, or bare hands, or a creature's own attack. nil without either.
local function weaponKind(item, actor)
    if item then
        return Weapon.objectIsInstance(item) and WEAPON_KINDS[Weapon.record(item).type] or OTHER
    end
    if not actor then return nil end
    return types.Creature.objectIsInstance(actor) and NATURAL or HAND_TO_HAND
end

local function swingingWith()
    return weaponKind(getEquipment(self, RIGHT_HAND), self)
end

local body = nil
local function bodyType()
    if not body then
        body = BODY_BY_BLOOD[self.object.type.record(self.object).bloodType] or 'flesh'
    end
    return body
end

-- The categories a *_SOUNDS table gives an attack made with `weapon`, or nil
local function lookup(soundsTable, weapon)
    if not soundsTable then return nil end
    if weapon then
        local categories = weapon.hands and soundsTable[weapon.family .. weapon.hands] or soundsTable[weapon.family]
        if categories then return categories end
    end
    return soundsTable.default
end

-- What a hit with this tag lands on: armor by weight, or with no armor, the actor's body
local function landsOn(tag)
    local armor = ARMOR_BY_TAG[tag:lower()]
    if armor == 'none' then return bodyType() end
    return armor
end

-- A random CSO file for a vanilla tag and an attack made with `weapon`, or nil when no category answers it. force
-- draws from the whole folder then.
local function pickFor(tag, weapon, force)
    local folder = TAGS[tag:lower()]
    if not folder then return nil end
    local categories
    if folder == 'swing' then
        categories = lookup(SWING_SOUNDS, weapon)
    else
        folder = 'hit'
        categories = lookup(HIT_SOUNDS[landsOn(tag)], weapon)
    end
    local list = categories and pool(folder, categories)
    if (not list or #list == 0) and force then list = getFiles()[folder].all end
    if not list or #list == 0 then return nil end
    return list[math.random(#list)]
end

local function describe(via, weapon, tag)
    local parts = { via }
    if weapon then parts[#parts + 1] = weapon.family .. (weapon.hands and (' ' .. weapon.hands .. 'h') or '') end
    local armor = ARMOR_BY_TAG[tag:lower()]
    if armor == 'none' then
        parts[#parts + 1] = bodyType() .. ' body'
    elseif armor then
        parts[#parts + 1] = armor .. ' armor'
    end
    return table.concat(parts, ', ')
end

-- The one swap every path goes through: stop the vanilla sound on this actor and play a CSO one for it instead, or
-- for Health Damage, play one alongside it. weapon is what the attack is made with (weaponKind); a swing's is taken
-- from this actor's right hand when not given. Returns the file played, or nil.
local function swap(tag, options, via, weapon)
    local folder = TAGS[tag:lower()]
    if not folder then return nil end
    options = options or {}
    if not weapon then
        if options.weapon or options.attacker then
            weapon = weaponKind(options.weapon, options.attacker)
        elseif folder == 'swing' then
            weapon = swingingWith()
        end
    end
    local file = pickFor(tag, weapon, options.force)
    if not file then return nil end

    if folder ~= 'body' then sound.stopSound3d(tag, self) end
    local pitch = options.pitch or (PITCH_MIN + math.random() * (PITCH_MAX - PITCH_MIN))
    sound.playSoundFile3d(file, self, { volume = options.volume, pitch = pitch })
    if debugLog then
        print(string.format('[Combat Sounds Overhaul] %s: %s -> %s (%s, pitch %.2f)', self.recordId, tag, file,
            describe(via, weapon, tag), pitch))
    end
    return file
end

local function swapIfPlaying(tag, via, weapon)
    if sound.isSoundPlaying(tag, self) then return swap(tag, nil, via, weapon) end
    return nil
end

-- Wind-up plays "<attack> start" to "<attack> max attack"; the release plays from "<attack> max attack" on.
I.AnimationController.addPlayBlendedAnimationHandler(function(_, options)
    if not options then return end
    local startKey, stopKey = options.startKey or '', options.stopKey or ''
    if endsWith(startKey, ' max attack') then
        windupUntil = nil
        swapIfPlaying(WEAPON_SWISH, 'release')
    elseif endsWith(stopKey, ' max attack') and lookup(SWING_SOUNDS, swingingWith()) then
        windupUntil = core.getSimulationTime() + WINDUP_WATCH
    end
end)

-- "Sound: SwishM" arrives as group "sound", key "swishm"
I.AnimationController.addTextKeyHandler('sound', function(_, key)
    if TAGS[key] == 'swing' then swapIfPlaying(key, 'text key') end
end)

I.Combat.addOnHitHandler(function(attack)
    if attack.successful then pendingHit = attack end
end)

local function onUpdate()
    if pendingHit then
        local attack = pendingHit
        pendingHit = nil
        local weapon = weaponKind(attack.weapon, attack.attacker)
        local onArmor = false
        for _, tag in ipairs(ARMOR_HIT_TAGS) do
            if sound.isSoundPlaying(tag, self) then
                onArmor = true
                swap(tag, nil, 'hit', weapon)
            end
        end
        -- The handlers after ours have taken armor off this same attack table by now. Health left over is what
        -- plays Health Damage; checking the sound as well leaves out hits the builtin handler never got to.
        local health = attack.damage and attack.damage.health or 0
        if LAYER_UNARMORED_HITS and not onArmor and health > 0 and sound.isSoundPlaying(HEALTH_DAMAGE, self) then
            swap(HEALTH_DAMAGE, nil, 'unarmored hit', weapon)
        end
    end
    if windupUntil then
        if swapIfPlaying(WEAPON_SWISH, 'early release') or core.getSimulationTime() > windupUntil then
            windupUntil = nil
        end
    end
end

local function emit(tag, options)
    if type(tag) ~= 'string' then error('CombatSoundsOverhaul.emit: tag must be a string', 2) end
    return swap(tag, options, 'emit')
end

return {
    interfaceName = 'CombatSoundsOverhaul',
    ---
    -- Lets other scripts, and the Lua console (luap / luas), make CSO do what it does when it catches a vanilla sound.
    -- @usage I.CombatSoundsOverhaul.emit('Heavy Armor Hit')
    -- @usage I.CombatSoundsOverhaul.emit('Weapon Swish', { weapon = someDagger, pitch = 1.2 })
    -- @usage actor:sendEvent('CombatSoundsOverhaul_Emit', { tag = 'SwishL' })
    interface = {
        version = 1,
        modVersion = VERSION,

        --- Vanilla sound record ids CSO answers, e.g. 'Weapon Swish', 'Heavy Armor Hit' or 'Health Damage'.
        TAGS = TAG_NAMES,

        --- Runs CSO's swap for a vanilla tag on this actor, as if the engine had just played that sound here: stops
        -- the vanilla sound if it's playing and plays a CSO sound in its place, picked for the attack and what it
        -- lands on. 'Health Damage' is what a hit on no armor does: a CSO impact for this actor's body on top, with
        -- the vanilla sound left alone. A swing is made with this actor's right hand unless options say otherwise.
        -- @param #string tag One of TAGS, any case
        -- @param #table options (optional)
        --   weapon, attacker: what the attack is made with, as for a hit (a weapon object, and who holds it)
        --   force: play even when no category answers the attack, drawing from all of CSO's swings or hits
        --   volume, pitch: pitch is random between 0.85 and 1 otherwise
        -- @return #string VFS path of the sound played, or nil if nothing played
        emit = emit,

        --- A CSO file for a vanilla tag, picked as emit would pick it, without playing it. nil if nothing answers.
        pickFile = function(tag, options)
            options = options or {}
            local weapon
            if options.weapon or options.attacker then
                weapon = weaponKind(options.weapon, options.attacker)
            elseif TAGS[tostring(tag):lower()] == 'swing' then
                weapon = swingingWith()
            end
            return pickFor(tostring(tag), weapon, options.force)
        end,

        --- Prints every swap this actor makes: what caught it (release, early release, text key, hit, unarmored hit,
        -- emit, event), what the attack was made with, what it landed on, and the pitch.
        setDebug = function(enabled) debugLog = enabled and true or false end,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        -- { tag = ..., force = ..., volume = ..., pitch = ... }, for scripts that can't reach this actor's interface
        CombatSoundsOverhaul_Emit = function(data) swap(tostring(data.tag), data, 'event') end,
    },
}
