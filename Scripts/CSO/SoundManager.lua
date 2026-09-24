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
--     sound, the hit landed on an unarmored spot (or on a creature), and one of CSO's fleshy impacts is layered on top.
-- onUpdate does nothing unless one of those is pending.
--
-- Every swap knows what the attack is made with (weaponKind: the swinging actor's right hand, or the hit's weapon and
-- attacker), and a hit knows the weight of the armor on the spot it landed: the builtin handler rolls the spot and
-- plays the armor sound for that weight, or only Health Damage if there's no armor there. Nothing picks sounds by
-- them yet; setDebug shows them.
--
-- Swings keep the original's condition: the actor holds something in its right hand. The original checked that on
-- whoever the sound played on, which for armor hits is the one being hit, so an unarmed actor in armor kept the
-- vanilla armor sounds. Hits are swapped regardless now.
local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local vfs = require('openmw.vfs')
local I = require('openmw.interfaces')

-- the Nexus release workflow reads the first `version = ...` in this file
local VERSION = "1.0"

local WINDUP_WATCH = 1.5 -- seconds of simulation time an attack's wind-up is watched for an early release

local SOUND_DIRS = {
    swing = 'sound/fx/item/csoswing/',
    hit = 'sound/fx/item/csohit/',
}
local SOUND_EXTENSIONS = { wav = true, mp3 = true, ogg = true, flac = true }

-- Near copies of another CSO file, left out so that sound doesn't come up twice as often.
local DUPLICATES = {
    ['sound/fx/item/csoswing/swing6.wav'] = true, -- Swing5 trimmed a little shorter
}

-- CSO's SwingN files sorted by ear, the same way as the hits below. Not used yet: every swing draws from all of them.
local SWING_CATEGORIES = {
    plain = { { 21, 23 } },            -- generic, no metal: hand-to-hand, maybe staves
    sharpMetal = { { 1, 6 } },         -- short blades, daggers
    metal = { { 11, 16 } },            -- generic: swords, staves
    ringingBlade = { { 24, 26 } },     -- one-handed long blades: like metal, but sharper and with a ring
    heavyMetal = { { 7, 10 } },        -- maces, axes, probably two-handed swords
    heavyMetalGeneric = { { 17, 20 } }, -- staves, polearms, spears, maybe two-handed maces, axes and swords
}

-- CSO's HitN files sorted by ear. Each entry is a HitN number, or a { first, last } range of them. Hit68, Hit97 and
-- Hit98 aren't sorted yet.
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
-- The categories layered over Health Damage on unarmored hits. The rest wait for a use: armor hits still draw from
-- every Hit file.
local UNARMORED_HITS = { 'flesh', 'punchyFlesh' }
-- false leaves unarmored hits with only the body hit, e.g. to tune it on its own: the fleshy layer starts with it
-- and drowns it out. emit('Health Damage') plays the layer either way.
local LAYER_UNARMORED_HITS = true

-- Vanilla sound record -> the CSO set played for it. Keys are lowercase, as sound ids are case insensitive and
-- text keys reach Lua lowercased. The unarmored set is layered over the vanilla sound; the others replace it.
local TAGS = {
    ['weapon swish'] = 'swing',
    swishs = 'swing',
    swishm = 'swing',
    swishl = 'swing',
    ['light armor hit'] = 'hit',
    ['medium armor hit'] = 'hit',
    ['heavy armor hit'] = 'hit',
    ['health damage'] = 'unarmored',
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

local function inCategories(n, categories)
    if not n then return false end
    for _, category in ipairs(categories) do
        for _, entry in ipairs(HIT_CATEGORIES[category]) do
            if type(entry) == 'number' then
                if n == entry then return true end
            elseif n >= entry[1] and n <= entry[2] then
                return true
            end
        end
    end
    return false
end

-- Listed on first use rather than at load: most actors never swing or get hit.
local files = nil
local function getFiles(kind)
    if not files then
        files = {}
        for k, dir in pairs(SOUND_DIRS) do
            local list = {}
            for path in vfs.pathsWithPrefix(dir) do
                if SOUND_EXTENSIONS[path:match('%.(%w+)$')] and not DUPLICATES[path] then list[#list + 1] = path end
            end
            table.sort(list)
            files[k] = list
            if #list == 0 and isPlayer then
                print('[Combat Sounds Overhaul] No sounds in ' .. dir .. ' - is Combat Sounds Overhaul installed?')
            end
        end
        files.unarmored = {}
        for _, path in ipairs(files.hit) do
            if inCategories(tonumber(path:match('/hit(%d+)%.%w+$')), UNARMORED_HITS) then
                files.unarmored[#files.unarmored + 1] = path
            end
        end
    end
    return files[kind]
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

local function describe(via, weapon, armor)
    local parts = { via }
    if weapon then parts[#parts + 1] = weapon.family .. (weapon.hands and (' ' .. weapon.hands .. 'h') or '') end
    if armor then parts[#parts + 1] = armor == 'none' and 'no armor' or (armor .. ' armor') end
    return table.concat(parts, ', ')
end

local function pickFile(tag)
    local kind = TAGS[tag:lower()]
    local list = kind and getFiles(kind)
    if not list or #list == 0 then return nil end
    return list[math.random(#list)]
end

-- The one swap every path goes through: stop the vanilla sound on this actor and play a random CSO one instead,
-- or for Health Damage, play one alongside it. weapon is what the attack is made with (weaponKind); a swing's is
-- taken from this actor's right hand when not given. The armor hit comes from the tag. Returns the file played, or nil.
local function swap(tag, options, via, weapon)
    local kind = TAGS[tag:lower()]
    if not kind then return nil end
    options = options or {}
    local rightHand = getEquipment(self, RIGHT_HAND)
    if kind == 'swing' and not options.force and not rightHand then return nil end
    local file = pickFile(tag)
    if not file then return nil end
    if kind == 'swing' and not weapon then weapon = weaponKind(rightHand, self) end
    local armor = ARMOR_BY_TAG[tag:lower()]

    if kind ~= 'unarmored' then sound.stopSound3d(tag, self) end
    if options.volume or options.pitch then
        sound.playSoundFile3d(file, self, { volume = options.volume, pitch = options.pitch })
    else
        sound.playSoundFile3d(file, self)
    end
    if debugLog then
        print(string.format('[Combat Sounds Overhaul] %s: %s -> %s (%s)', self.recordId, tag, file,
            describe(via, weapon, armor)))
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
    elseif endsWith(stopKey, ' max attack') and getEquipment(self, RIGHT_HAND) then
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
    -- @usage I.CombatSoundsOverhaul.emit('Weapon Swish', { force = true, pitch = 1.2 })
    -- @usage actor:sendEvent('CombatSoundsOverhaul_Emit', { tag = 'SwishL' })
    interface = {
        version = 1,
        modVersion = VERSION,

        --- Vanilla sound record ids CSO answers, e.g. 'Weapon Swish', 'Heavy Armor Hit' or 'Health Damage'.
        TAGS = TAG_NAMES,

        --- Runs CSO's swap for a vanilla tag on this actor, as if the engine had just played that sound here: stops
        -- the vanilla sound if it's playing and plays a random CSO sound in its place. 'Health Damage' is what an
        -- unarmored hit does: a fleshy CSO impact on top, with the vanilla sound left alone. A swing tag needs
        -- something in the actor's right hand, like an engine swing does, unless options.force is set.
        -- @param #string tag One of TAGS, any case
        -- @param #table options (optional) force, volume, pitch
        -- @return #string VFS path of the sound played, or nil if nothing played
        emit = emit,

        --- A random CSO file for a vanilla tag, without playing it. nil for tags CSO doesn't replace.
        pickFile = function(tag) return pickFile(tostring(tag)) end,

        --- Prints every swap this actor makes: what caught it (release, early release, text key, hit, unarmored hit,
        -- emit, event), what the attack was made with, and for hits the armor on the spot it landed.
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
