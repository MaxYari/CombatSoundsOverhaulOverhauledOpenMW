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
--
-- Every CSO sound, caught or asked for through the interface, goes through play(), where handlers other scripts add
-- with I.CombatSoundsOverhaul.addOnPlayHandler can change it or stop it.
local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local vfs = require('openmw.vfs')
local util = require('openmw.util')
local auxUtil = require('openmw_aux.util')
local I = require('openmw.interfaces')

-- the Nexus release workflow reads the first `version = ...` in this file
local VERSION = "1.0"

local WINDUP_WATCH = 1.5 -- seconds of simulation time an attack's wind-up is watched for an early release
local PITCH_MIN, PITCH_MAX = 0.9, 1.1 -- every CSO sound plays at a random pitch in between

local SOUND_DIRS = {
    swing = 'sound/fx/item/csoswing/',
    hit = 'sound/fx/item/csohit/',
}
local SOUND_EXTENSIONS = { wav = true, mp3 = true, ogg = true, flac = true }


-- CSO's SwingN and HitN files sorted by ear. Each entry is a number N, or a { first, last } range of them. A file can
-- be in more than one category, and one in none never plays (Swing6, a near copy of Swing5, is in none).
-- tools/sound_sorting.py lays these out as folders of copies to sort by ear, and writes them back here.
local SWING_CATEGORIES = {
    plain = { { 21, 23 } },                 -- generic, no metal: hand-to-hand, staves, spears' swings
    sharpMetal = { { 1, 5 } },              -- short blades, daggers
    bladeMetal = { { 11, 16 } },            -- metallic blade whooshes: swords, staves, spears' thrusts
    ringingBladeMetal = { { 24, 26 } },     -- like bladeMetal, sharper and with a ring: long blades, daggers, spears' thrusts
    heavyMetal = { { 7, 10 }, { 17, 20 } }, -- maces, warhammers, axes
}
-- Hit68, Hit97 and Hit98 aren't sorted yet.
local HIT_CATEGORIES = {
    -- flesh
    FleshHit = { { 1, 10 } },
    metallicPunchyFleshHit = { { 25, 29 } },
    FleshSlice = { { 61, 64 } },
    FleshStab = { { 65, 68 }, 70, { 73, 76 } },
    -- bone
    stabPure = { 77, 78 },
    cutPure = { { 11, 17 } },
    BoneHit = { 79 },
    -- armor
    armorHeavyPureHit = { { 22, 24 }, { 33, 40 }, { 82, 95 }, { 97, 102 } },
    armorMediumPureHit = { { 41, 56 }, 71, 72 },
    BluntBoneHit = { 80, 81 },
    BluntRingPure = { 69 },
    RingingBladePure = { { 18, 21 }, 30 },
    ringingBladeOnMetalPure = { 31, 32, { 57, 60 }, 96 },
}

-- Which categories answer an attack, by what it's made with: a weaponKind family with its hands (longBlade1), or
-- the family alone. A thrust with a weapon first looks for those keys with Thrust on the end (longBlade1Thrust,
-- longBladeThrust), then the plain ones, then `thrust`. `default` covers the rest; without one, the vanilla sound
-- stays. Every file of every listed category is in the draw.
local SWING_SOUNDS = {
    shortBlade = { 'sharpMetal', 'ringingBladeMetal' },
    longBlade1 = { 'ringingBladeMetal', 'bladeMetal' },
    longBlade2 = { 'bladeMetal' },
    blunt = { 'heavyMetal' },
    axe = { 'heavyMetal' },
    spear = { 'plain' },
    spearThrust = { 'bladeMetal', 'ringingBladeMetal' },
    staff = { 'plain', 'bladeMetal' },
    thrown = { 'sharpMetal', 'plain' },
    handToHand = { 'plain' },
}
-- An unarmored spot, light armor, or a creature of flesh and blood. The fleshy stabs are only for thrusts.
local FLESH_HIT_SOUNDS = {
    shortBlade = { 'FleshSlice', 'FleshHit' },
    shortBladeThrust = { 'FleshStab', 'FleshHit' },
    longBlade = { 'FleshHit' },
    longBladeThrust = { 'FleshStab', 'FleshHit' },
    spearThrust = { 'FleshStab' },
    blunt = { 'metallicPunchyFleshHit' },
    handToHand = { 'metallicPunchyFleshHit', 'FleshHit' },
    default = { 'FleshHit', 'metallicPunchyFleshHit' }, -- axes, staves, spears' swings, thrown weapons, arrows, creatures' own attacks
}
-- Medium and heavy armor, on top of the flesh sounds of the weapon (HIT_SOUNDS). The blunt ring is only for
-- thrusts, as the fleshy stabs are on flesh.
local FLESHY_ARMOR_HIT_SOUNDS = {
    shortBladeThrust = { 'armorMediumPureHit', 'BluntRingPure' },
    longBladeThrust = { 'armorMediumPureHit', 'BluntRingPure' },
    spearThrust = { 'armorMediumPureHit', 'BluntRingPure' },
    default = { 'armorMediumPureHit', 'BluntBoneHit' },
}
-- Skeletons, liches, bonelords: the same for every weapon
local BONE_HIT_SOUNDS = {
    thrust = { 'stabPure' },
    default = { 'cutPure' },
}
-- A creature of metal, which doesn't bleed
local METAL_BODY_HIT_SOUNDS = {
    shortBlade = { 'armorHeavyPureHit', 'ringingBladeOnMetalPure' },
    longBlade = { 'armorHeavyPureHit', 'ringingBladeOnMetalPure' },
    default = { 'armorHeavyPureHit' },
}
-- What the hit lands on -> the tables above that answer it; an attack draws from what each of them gives it. Medium
-- and heavy armor get the flesh sounds of the weapon as well as the armor ones. Ghosts have no sounds yet, so they
-- keep only the body hit.
local HIT_SOUNDS = {
    light = { FLESH_HIT_SOUNDS },
    medium = { FLESHY_ARMOR_HIT_SOUNDS, FLESH_HIT_SOUNDS },
    heavy = { FLESHY_ARMOR_HIT_SOUNDS, FLESH_HIT_SOUNDS },
    flesh = { FLESH_HIT_SOUNDS },
    metal = { METAL_BODY_HIT_SOUNDS },
    bone = { BONE_HIT_SOUNDS },
}
local SWING_TABLES = { SWING_SOUNDS }
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
-- Vanilla gives ghosts the same bone dust as skeletons. An actor that doesn't bleed red and has one of these in its
-- name, model or record id is a ghost instead; that also catches ghosts a mod moved to a blood type of their own.
local GHOST_WORDS = { 'ghost', 'spectre', 'specter', 'spirit', 'haunt', 'wraith', 'phantom', 'apparition' }

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

-- The interface's names for what an attack is made with, and for what a hit lands on
local WEAPON_BY_NAME = {
    ShortBlade = WEAPON_KINDS[Weapon.TYPE.ShortBladeOneHand],
    LongBlade = WEAPON_KINDS[Weapon.TYPE.LongBladeOneHand],
    LongBladeTwoHanded = WEAPON_KINDS[Weapon.TYPE.LongBladeTwoHand],
    Blunt = WEAPON_KINDS[Weapon.TYPE.BluntOneHand],
    BluntTwoHanded = WEAPON_KINDS[Weapon.TYPE.BluntTwoClose],
    Staff = WEAPON_KINDS[Weapon.TYPE.BluntTwoWide],
    Spear = WEAPON_KINDS[Weapon.TYPE.SpearTwoWide],
    Axe = WEAPON_KINDS[Weapon.TYPE.AxeOneHand],
    AxeTwoHanded = WEAPON_KINDS[Weapon.TYPE.AxeTwoHand],
    Thrown = WEAPON_KINDS[Weapon.TYPE.MarksmanThrown],
    Bow = WEAPON_KINDS[Weapon.TYPE.MarksmanBow],
    Crossbow = WEAPON_KINDS[Weapon.TYPE.MarksmanCrossbow],
    HandToHand = HAND_TO_HAND,
    Natural = NATURAL,
}
local ARMOR_BY_NAME = {
    Unarmored = 'flesh', -- also a creature of flesh and blood
    Light = 'light',
    Medium = 'medium',
    Heavy = 'heavy',
    Metal = 'metal',     -- a creature of metal: dwemer machines
    Bone = 'bone',       -- skeletons, liches, bonelords
    Ghost = 'ghost',     -- ghosts, spectres, spirits, which have no sounds yet
}
local function invert(t)
    local inverted = {}
    for k, v in pairs(t) do inverted[v] = k end
    return inverted
end
local NAME_OF_WEAPON = invert(WEAPON_BY_NAME)
local NAME_OF_SURFACE = invert(ARMOR_BY_NAME)
local function enum(byName)
    local t = {}
    for name in pairs(byName) do t[name] = name end
    return util.makeStrictReadOnly(t)
end

local sound = core.sound
local getEquipment = types.Actor.getEquipment
local RIGHT_HAND = types.Actor.EQUIPMENT_SLOT.CarriedRight
local isPlayer = types.Player.objectIsInstance(self.object)

local debugLog = false
local windupUntil = nil  -- simulation time the current wind-up stops being watched
local windupAttack = nil -- chop, slash or thrust: the attack being wound up
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

-- folder ('swing' or 'hit') -> { all = every file in some category, [category] = its files }. Listed on first use
-- rather than at load: most actors never swing or get hit.
local files = nil
local function getFiles()
    if files then return files end
    files = {}
    local categoriesOf = { swing = SWING_CATEGORIES, hit = HIT_CATEGORIES }
    for folder, dir in pairs(SOUND_DIRS) do
        local found = {}
        for path in vfs.pathsWithPrefix(dir) do
            if SOUND_EXTENSIONS[path:match('%.(%w+)$')] then found[#found + 1] = path end
        end
        table.sort(found)
        if #found == 0 and isPlayer then
            print('[Combat Sounds Overhaul] No sounds in ' .. dir .. ' - is Combat Sounds Overhaul installed?')
        end
        local all, inAll = {}, {}
        local byCategory = { all = all }
        for category, entries in pairs(categoriesOf[folder]) do
            local list = {}
            for _, path in ipairs(found) do
                if inEntries(tonumber(path:match('(%d+)%.%w+$')), entries) then
                    list[#list + 1] = path
                    if not inAll[path] then
                        inAll[path] = true
                        all[#all + 1] = path
                    end
                end
            end
            byCategory[category] = list
        end
        table.sort(all)
        files[folder] = byCategory
    end
    return files
end

-- Every file of the given categories, merged once per list of categories. A file in two of them is still in
-- the draw once.
local pools = {}
local function pool(folder, categories)
    local key = folder .. ':' .. table.concat(categories, '+')
    local list = pools[key]
    if not list then
        list = {}
        local added = {}
        for _, category in ipairs(categories) do
            for _, path in ipairs(getFiles()[folder][category] or {}) do
                if not added[path] then
                    added[path] = true
                    list[#list + 1] = path
                end
            end
        end
        pools[key] = list
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
        local record = self.object.type.record(self.object)
        body = BODY_BY_BLOOD[record.bloodType] or 'flesh'
        if record.bloodType ~= 0 and body ~= 'metal' then
            local words = ((record.name or '') .. ' ' .. (record.model or '') .. ' ' .. (record.id or '')):lower()
            for _, word in ipairs(GHOST_WORDS) do
                if words:find(word, 1, true) then
                    body = 'ghost'
                    break
                end
            end
        end
    end
    return body
end

-- Whether an attack counts as a thrust: a melee attack made with a weapon, of I.Combat.ATTACK_TYPES.Thrust. An
-- unarmed creature's attack type only says which of its three attacks it used, so that never counts.
local ATTACK_TYPES = I.Combat.ATTACK_TYPES
local THRUST = ATTACK_TYPES.Thrust
-- An attack animation's keys start with the attack: "thrust start", "thrust max attack". "shoot" has no type.
local ATTACK_BY_NAME = { chop = ATTACK_TYPES.Chop, slash = ATTACK_TYPES.Slash, thrust = ATTACK_TYPES.Thrust }
local function attackTypeOf(key)
    return ATTACK_BY_NAME[key:match('^(%a+) ')]
end
local function isThrust(weapon, attackType)
    return attackType == THRUST and weapon ~= nil and weapon.hands ~= nil
end

-- The categories a *_SOUNDS table gives an attack made with `weapon`, or nil
local function lookup(soundsTable, weapon, attackType)
    if not soundsTable then return nil end
    local thrust = isThrust(weapon, attackType)
    if weapon then
        local withHands = weapon.hands and (weapon.family .. weapon.hands)
        local categories = thrust and (withHands and soundsTable[withHands .. 'Thrust'] or soundsTable[weapon.family .. 'Thrust'])
            or withHands and soundsTable[withHands] or soundsTable[weapon.family]
        if categories then return categories end
    end
    return thrust and soundsTable.thrust or soundsTable.default
end

-- What a hit with this tag lands on: armor by weight, or with no armor, the actor's body
local function landsOn(tag)
    local armor = ARMOR_BY_TAG[tag:lower()]
    if armor == 'none' then return bodyType() end
    return armor
end

-- A random file from the categories the given *_SOUNDS tables give an attack made with `weapon`, or nil when none
-- answers. force draws from the whole folder then.
local function pickFrom(folder, soundsTables, weapon, force, attackType)
    local categories = nil
    for _, soundsTable in ipairs(soundsTables or {}) do
        local found = lookup(soundsTable, weapon, attackType)
        if found then
            categories = categories or {}
            for _, category in ipairs(found) do categories[#categories + 1] = category end
        end
    end
    local list = categories and pool(folder, categories)
    if (not list or #list == 0) and force then list = getFiles()[folder].all end
    if not list or #list == 0 then return nil end
    return list[math.random(#list)]
end

-- A random CSO file for a vanilla tag and an attack made with `weapon`
local function pickFor(tag, weapon, force, attackType)
    local folder = TAGS[tag:lower()]
    if folder == 'swing' then return pickFrom('swing', SWING_TABLES, weapon, force, attackType) end
    if folder then return pickFrom('hit', HIT_SOUNDS[landsOn(tag)], weapon, force, attackType) end
    return nil
end

local IS_ARMOR = { light = true, medium = true, heavy = true }
local function describe(via, weapon, surface, attackType)
    local parts = { via }
    if weapon then
        parts[#parts + 1] = weapon.family .. (weapon.hands and (' ' .. weapon.hands .. 'h') or '')
            .. (isThrust(weapon, attackType) and ' thrust' or '')
    end
    if surface then parts[#parts + 1] = surface .. (IS_ARMOR[surface] and ' armor' or ' body') end
    return table.concat(parts, ', ')
end

-- Handlers other scripts on this actor add to hear about a CSO sound before it plays, newest first
local playHandlers = {}

-- Every CSO sound goes through here: the handlers see it first, may change its file, volume and pitch, and one
-- returning false stops it. Returns the file played, or nil.
local function play(file, kind, surface, weapon, tag, via, volume, pitch, attackType)
    local info = {
        file = file,
        volume = volume or 1,
        pitch = pitch or (PITCH_MIN + math.random() * (PITCH_MAX - PITCH_MIN)),
        kind = kind,
        tag = tag,
        weapon = weapon and NAME_OF_WEAPON[weapon],
        armor = surface and NAME_OF_SURFACE[surface],
        attackType = attackType,
        layered = tag ~= nil and TAGS[tag:lower()] == 'body',
        via = via,
    }
    local stopped = auxUtil.callEventHandlers(playHandlers, info)
    if debugLog then
        print(string.format('[Combat Sounds Overhaul] %s: %s -> %s (%s, pitch %.2f)%s', self.recordId, tag or kind,
            tostring(info.file), describe(via, weapon, surface, attackType), info.pitch,
            stopped and ' - stopped by a handler' or ''))
    end
    if stopped or not info.file then return nil end
    sound.playSoundFile3d(info.file, self, { volume = info.volume, pitch = info.pitch })
    return info.file
end

-- The one swap every vanilla sound goes through: stop it on this actor and play a CSO one for it instead, or for
-- Health Damage, play one alongside it. The vanilla sound is stopped even if a handler stops the CSO one. weapon is
-- what the attack is made with (weaponKind); a swing's is taken from this actor's right hand when not given.
-- Returns the file played, or nil.
local function swap(tag, options, via, weapon, attackType)
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
    if attackType == nil then attackType = options.attackType end
    local file = pickFor(tag, weapon, options.force, attackType)
    if not file then return nil end

    if folder ~= 'body' then sound.stopSound3d(tag, self) end
    return play(file, folder == 'swing' and 'swing' or 'hit', landsOn(tag), weapon, tag, via, options.volume, options.pitch,
        attackType)
end

local function checkVolume(volume, caller)
    if volume ~= nil and (type(volume) ~= 'number' or volume < 0) then
        error('CombatSoundsOverhaul.' .. caller .. ': volume must be a number of 0 or more', 3)
    end
    return volume
end

local function checkWeapon(weapon, caller)
    local kind = WEAPON_BY_NAME[weapon]
    if not kind then
        error('CombatSoundsOverhaul.' .. caller .. ': weapon must be one of CombatSoundsOverhaul.WEAPON, not '
            .. tostring(weapon), 3)
    end
    return kind
end


local function checkAttackType(attackType, caller)
    if attackType ~= nil and attackType ~= ATTACK_TYPES.Chop and attackType ~= ATTACK_TYPES.Slash
        and attackType ~= ATTACK_TYPES.Thrust then
        error('CombatSoundsOverhaul.' .. caller .. ': attackType must be one of I.Combat.ATTACK_TYPES, not '
            .. tostring(attackType), 3)
    end
    return attackType
end

local function playSwing(weapon, volume, attackType)
    local kind = checkWeapon(weapon, 'playSwing')
    volume = checkVolume(volume, 'playSwing')
    attackType = checkAttackType(attackType, 'playSwing')
    local file = pickFrom('swing', SWING_TABLES, kind, nil, attackType)
    return file and play(file, 'swing', nil, kind, nil, 'playSwing', volume, nil, attackType)
end

local function playHit(armor, volume, weapon, attackType)
    local surface = ARMOR_BY_NAME[armor]
    if not surface then
        error('CombatSoundsOverhaul.playHit: armor must be one of CombatSoundsOverhaul.ARMOR, not ' .. tostring(armor), 2)
    end
    volume = checkVolume(volume, 'playHit')
    local kind = weapon ~= nil and checkWeapon(weapon, 'playHit') or nil
    attackType = checkAttackType(attackType, 'playHit')
    local file = pickFrom('hit', HIT_SOUNDS[surface], kind, nil, attackType)
    return file and play(file, 'hit', surface, kind, nil, 'playHit', volume, nil, attackType)
end

local function swapIfPlaying(tag, via, weapon, attackType)
    if sound.isSoundPlaying(tag, self) then return swap(tag, nil, via, weapon, attackType) end
    return nil
end

-- Wind-up plays "<attack> start" to "<attack> max attack"; the release plays from "<attack> max attack" on.
I.AnimationController.addPlayBlendedAnimationHandler(function(_, options)
    if not options then return end
    local startKey, stopKey = options.startKey or '', options.stopKey or ''
    if endsWith(startKey, ' max attack') then
        windupUntil = nil
        swapIfPlaying(WEAPON_SWISH, 'release', nil, attackTypeOf(startKey))
    elseif endsWith(stopKey, ' max attack') and lookup(SWING_SOUNDS, swingingWith()) then
        windupUntil = core.getSimulationTime() + WINDUP_WATCH
        windupAttack = attackTypeOf(stopKey)
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
        -- chop, slash or thrust, for a melee attack made with a weapon
        local attackType = attack.weapon and attack.sourceType == I.Combat.ATTACK_SOURCE_TYPES.Melee and attack.type or nil
        local onArmor = false
        for _, tag in ipairs(ARMOR_HIT_TAGS) do
            if sound.isSoundPlaying(tag, self) then
                onArmor = true
                swap(tag, nil, 'hit', weapon, attackType)
            end
        end
        -- The handlers after ours have taken armor off this same attack table by now. Health left over is what
        -- plays Health Damage; checking the sound as well leaves out hits the builtin handler never got to.
        local health = attack.damage and attack.damage.health or 0
        if LAYER_UNARMORED_HITS and not onArmor and health > 0 and sound.isSoundPlaying(HEALTH_DAMAGE, self) then
            swap(HEALTH_DAMAGE, nil, 'unarmored hit', weapon, attackType)
        end
    end
    if windupUntil then
        if swapIfPlaying(WEAPON_SWISH, 'early release', nil, windupAttack) or core.getSimulationTime() > windupUntil then
            windupUntil = nil
        end
    end
end

local function emit(tag, options)
    if type(tag) ~= 'string' then error('CombatSoundsOverhaul.emit: tag must be a string', 2) end
    if options then checkAttackType(options.attackType, 'emit') end
    return swap(tag, options, 'emit')
end

return {
    interfaceName = 'CombatSoundsOverhaul',
    ---
    -- Lets other scripts, and the Lua console (luap / luas), make CSO do what it does when it catches a vanilla sound.
    -- @usage I.CombatSoundsOverhaul.emit('Heavy Armor Hit')
    -- @usage I.CombatSoundsOverhaul.emit('Weapon Swish', { weapon = someDagger, pitch = 1.2 })
    -- @usage local cso = I.CombatSoundsOverhaul
    -- cso.playSwing(cso.WEAPON.AxeTwoHanded, 0.8)
    -- cso.playHit(cso.ARMOR.Heavy, 1, cso.WEAPON.Blunt)
    -- cso.playHit(cso.ARMOR.Unarmored, 1, cso.WEAPON.Spear, I.Combat.ATTACK_TYPES.Thrust)
    -- @usage actor:sendEvent('CombatSoundsOverhaul_Emit', { tag = 'SwishL' })
    interface = {
        version = 1,
        modVersion = VERSION,

        --- Vanilla sound record ids CSO answers, e.g. 'Weapon Swish', 'Heavy Armor Hit' or 'Health Damage'.
        TAGS = TAG_NAMES,

        --- What an attack is made with: ShortBlade, LongBlade, LongBladeTwoHanded, Blunt, BluntTwoHanded (warhammers),
        -- Staff, Spear, Axe, AxeTwoHanded, Thrown, Bow, Crossbow, HandToHand, Natural (a creature's own attack).
        WEAPON = enum(WEAPON_BY_NAME),

        --- What a hit lands on: Unarmored (also a creature of flesh), Light, Medium, Heavy, Metal (a creature of
        -- metal, like a dwemer machine), Bone (skeletons, liches, bonelords) and Ghost (ghosts, spectres, spirits).
        -- Ghost has no sounds yet.
        ARMOR = enum(ARMOR_BY_NAME),

        --- What this actor's body counts as when a hit lands on no armor: one of ARMOR, but only Unarmored (flesh and
        -- blood), Metal, Bone or Ghost. Read from its blood type, and for ghosts its name and model.
        getBody = function() return NAME_OF_SURFACE[bodyType()] end,

        --- Plays a CSO swing on this actor for a weapon, at a random pitch between 0.9 and 1.1.
        -- @param weapon One of WEAPON
        -- @param #number volume (optional) Volume multiplier, 1 by default
        -- @param attackType (optional) One of I.Combat.ATTACK_TYPES. A spear's thrust whooshes differently.
        -- @return #string VFS path of the sound played, or nil if nothing played (Natural, Bow and Crossbow have no
        -- swings, and a play handler can stop it)
        playSwing = playSwing,

        --- Plays a CSO hit on this actor for what it lands on, at a random pitch between 0.9 and 1.1.
        -- @param armor One of ARMOR
        -- @param #number volume (optional) Volume multiplier, 1 by default
        -- @param weapon (optional) One of WEAPON: what the hit is made with, which picks among the sounds for the armor
        -- @param attackType (optional) One of I.Combat.ATTACK_TYPES. A thrust with a weapon picks the stabs.
        -- @return #string VFS path of the sound played, or nil if nothing played
        playHit = playHit,

        --- Adds a handler that hears about every CSO sound on this actor just before it plays, newest handler first.
        -- It gets a table it may change: file, volume and pitch are what will play. The rest describe the sound:
        --   kind: 'swing' or 'hit'
        --   tag: the vanilla sound id it answers, or nil when played through playSwing / playHit
        --   weapon: one of WEAPON, or nil when unknown
        --   armor: one of ARMOR for a hit
        --   attackType: one of I.Combat.ATTACK_TYPES for a swing or a melee hit made with a weapon (and when asked
        --   for), otherwise nil
        --   layered: true when it plays over the vanilla body hit rather than in place of a vanilla sound
        --   via: what set it off (release, early release, text key, hit, unarmored hit, emit, event, playSwing, playHit)
        -- Returning false stops the sound and skips the older handlers. A vanilla sound it answers stays stopped.
        -- Add it from a script attached after this one, as a handler added to I.Combat would be.
        -- @param #function handler function(info)
        addOnPlayHandler = function(handler)
            if type(handler) ~= 'function' then error('CombatSoundsOverhaul.addOnPlayHandler: handler must be a function', 2) end
            playHandlers[#playHandlers + 1] = handler
        end,

        --- Runs CSO's swap for a vanilla tag on this actor, as if the engine had just played that sound here: stops
        -- the vanilla sound if it's playing and plays a CSO sound in its place, picked for the attack and what it
        -- lands on. 'Health Damage' is what a hit on no armor does: a CSO impact for this actor's body on top, with
        -- the vanilla sound left alone. A swing is made with this actor's right hand unless options say otherwise.
        -- @param #string tag One of TAGS, any case
        -- @param #table options (optional)
        --   weapon, attacker: what the attack is made with, as for a hit (a weapon object, and who holds it)
        --   attackType: one of I.Combat.ATTACK_TYPES. A thrust with a weapon picks the stabs, and a spear's thrust
        --   whooshes differently.
        --   force: play even when no category answers the attack, drawing from all of CSO's swings or hits
        --   volume, pitch: pitch is random between 0.9 and 1.1 otherwise
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
            return pickFor(tostring(tag), weapon, options.force, checkAttackType(options.attackType, 'pickFile'))
        end,

        --- Prints every CSO sound this actor plays: what set it off, what the attack was made with, what it landed on,
        -- the pitch, and whether a play handler stopped it.
        setDebug = function(enabled) debugLog = enabled and true or false end,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
    -- For scripts that can't reach this actor's interface, such as global scripts
    eventHandlers = {
        -- { tag = ..., weapon = ..., attacker = ..., force = ..., volume = ..., pitch = ... }, as for emit
        CombatSoundsOverhaul_Emit = function(data) swap(tostring(data.tag), data, 'event') end,
        -- { weapon = one of WEAPON, volume = ..., attackType = one of I.Combat.ATTACK_TYPES }
        CombatSoundsOverhaul_PlaySwing = function(data) playSwing(data.weapon, data.volume, data.attackType) end,
        -- { armor = one of ARMOR, volume = ..., weapon = one of WEAPON, attackType = one of I.Combat.ATTACK_TYPES }
        CombatSoundsOverhaul_PlayHit = function(data) playHit(data.armor, data.volume, data.weapon, data.attackType) end,
    },
}
