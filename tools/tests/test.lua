-- Runs SoundManager.lua against a stubbed OpenMW API, so the wiring can be checked without starting the game:
--
--     lua tools/tests/test.lua
--     CSO_DIR=".../Combat Sounds Overhaul-53859-2-0-1703458093/CSO2.0" lua tools/tests/test.lua
--
-- With CSO_DIR set, the sounds are listed from a real CSO install instead of made-up names.
local here = arg[0]:gsub('[^/]*$', '')
package.path = package.path .. ';' .. here .. '?.lua'
local SCRIPT = here .. '../../Scripts/CSO/SoundManager.lua'

local stub = require('stub')
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print('  FAIL: ' .. what)
    else
        print('  ok:   ' .. what)
    end
end

local csoDir = os.getenv('CSO_DIR')
if csoDir then
    stub.vfsPaths = stub.listDir(csoDir)
else
    for i = 1, 26 do stub.vfsPaths[#stub.vfsPaths + 1] = 'sound/fx/item/csoswing/swing' .. i .. '.wav' end
    for i = 1, 102 do stub.vfsPaths[#stub.vfsPaths + 1] = 'sound/fx/item/csohit/hit' .. i .. '.wav' end
    stub.vfsPaths[#stub.vfsPaths + 1] = 'sound/fx/item/csohit/readme.txt'
    stub.vfsPaths[#stub.vfsPaths + 1] = 'sound/fx/item/csohitextra/hit1.wav'
end

local realRequire = require
-- Loads the script fresh, with the unarmored layer switched on or off whatever it ships with. The actor's body is
-- read from stub.bloodType the first time it's needed.
local function loadScript(layer)
    local f = assert(io.open(SCRIPT))
    local src, n = f:read('a'):gsub('local LAYER_UNARMORED_HITS = %a+', 'local LAYER_UNARMORED_HITS = ' .. tostring(layer))
    f:close()
    assert(n == 1, 'LAYER_UNARMORED_HITS not found in ' .. SCRIPT)
    stub.playBlendedHandlers, stub.textKeyHandlers, stub.hitHandlers = {}, {}, {}
    _G.require = function(name) return stub.packages[name] or realRequire(name) end
    local loaded = assert((loadstring or load)(src, '@' .. SCRIPT))()
    _G.require = realRequire
    return loaded
end
local script = loadScript(true)
local api = script.interface
local onUpdate = script.engineHandlers.onUpdate

-- The categories as they were sorted by ear, written out again so the script's tables are checked against them.
local function range(a, b) local t = {} for n = a, b do t[#t + 1] = n end return t end
local SWINGS = {
    plain = range(21, 23), sharpMetal = range(1, 6), metal = range(11, 16), ringingBlade = range(24, 26),
    heavyMetal = range(7, 10), heavyMetalGeneric = range(17, 20),
}
local HITS = {
    flesh = range(1, 10), punchyFlesh = range(25, 29), crunchyFlesh = { 72, 79 }, fleshySlice = range(61, 64),
    fleshyStab = { 65, 66, 67, 70, 73, 74, 75, 76 }, stab = { 77, 78 }, blade = range(11, 17),
    armor = { 18, 19, 20, 21, 30, 31, 32, 57, 58, 59, 60 },
    armorHeavy = (function() local t = range(22, 24)
        for _, r in ipairs({ range(33, 40), range(82, 95), range(99, 102) }) do for _, n in ipairs(r) do t[#t + 1] = n end end
        return t end)(),
    armorHeavyBlade = { 96 },
}
-- The set of paths a list of categories should draw from (Swing6 is left out as a near copy of Swing5)
local function expected(folder, categories)
    local set = {}
    for _, category in ipairs(categories) do
        for _, n in ipairs((folder == 'swing' and SWINGS or HITS)[category]) do
            local path = string.format('sound/fx/item/cso%s/%s%d.wav', folder, folder, n)
            if path ~= 'sound/fx/item/csoswing/swing6.wav' then set[path] = true end
        end
    end
    return set
end
local function inSet(set, f) return f ~= nil and set[f] == true end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function sameSet(a, b)
    if count(a) ~= count(b) then return false end
    for k in pairs(a) do if not b[k] then return false end end
    return true
end
-- Everything pickFile comes up with over many draws
local function draws(tag, options)
    local seen = {}
    for _ = 1, 3000 do
        local f = api.pickFile(tag, options)
        if f then seen[f] = true end
    end
    return seen
end

local function lastFile() local p = stub.filesPlayed[#stub.filesPlayed]; return p and p.file end
local function isSwing(f) return f ~= nil and f:find('^sound/fx/item/csoswing/') ~= nil end
local function isHit(f) return f ~= nil and f:find('^sound/fx/item/csohit/') ~= nil end

local W = function(typeName) return stub.weapon('w', typeName) end
local SWORD = W('LongBladeOneHand')
local SWORD_SWINGS = expected('swing', { 'ringingBlade', 'metal' })
local DEFAULT_FLESH = expected('hit', { 'flesh', 'punchyFlesh' })

print('\n== loading ==')
check(script.interfaceName == 'CombatSoundsOverhaul', 'provides I.CombatSoundsOverhaul')
check(#stub.playBlendedHandlers == 1, 'hooks the animation controller')
check(#(stub.textKeyHandlers.sound or {}) == 1, 'listens to "sound" text keys')
check(#stub.hitHandlers == 1, 'adds an onHit handler')
check(onUpdate ~= nil, 'has an onUpdate')

print('\n== onUpdate with nothing pending ==')
stub.reset()
stub.rightHand = SWORD
stub.enginePlays('Weapon Swish')
stub.enginePlays('Heavy Armor Hit')
onUpdate(0.016)
check(#stub.filesPlayed == 0 and #stub.stopped == 0, 'does not look at sounds on its own')

print('\n== swing released after the wind-up ==')
stub.reset()
stub.rightHand = SWORD
stub.windUp('chop')
stub.enginePlays('Weapon Swish') -- prepareHit, right before the release animation
stub.release('chop')
check(stub.stopped[1] == 'Weapon Swish', 'the vanilla swish is stopped in the release call')
check(#stub.filesPlayed == 1 and inSet(SWORD_SWINGS, lastFile()), 'and a longsword swing plays')
local pitch = stub.filesPlayed[1].options.pitch
check(pitch >= 0.85 and pitch <= 1.0, string.format('at a pitch between 0.85 and 1 (%.3f)', pitch))
check(lastFile() and not lastFile():find('%.txt$'), 'only sound files are picked')
onUpdate(0.016)
check(#stub.filesPlayed == 1, 'onUpdate does not swap it a second time')

print('\n== swing released before the wind-up reached "min attack" ==')
stub.reset()
stub.windUp('slash')
stub.enginePlays('Weapon Swish') -- released early: prepareHit now, release animation only later
onUpdate(0.016)
check(#stub.filesPlayed == 1 and inSet(SWORD_SWINGS, lastFile()), 'the swish is swapped in the same frame')
stub.release('slash')
check(#stub.filesPlayed == 1, 'the late release animation does not swap again')

print('\n== wind-up that never releases ==')
stub.reset()
stub.windUp('thrust')
stub.simulationTime = stub.simulationTime + 2
onUpdate(0.016)
stub.enginePlays('Weapon Swish') -- a swish from somewhere else, long after
onUpdate(0.016)
check(#stub.filesPlayed == 0, 'the watch expires and stops looking')

print('\n== nothing, or no weapon, in the right hand ==')
stub.reset()
stub.rightHand = nil
stub.windUp('chop')
stub.enginePlays('Weapon Swish')
stub.release('chop')
check(#stub.filesPlayed == 1 and inSet(expected('swing', { 'plain' }), lastFile()),
    'a hand-to-hand swing gets a plain whoosh')
stub.reset()
stub.selfObject.isCreature = true
stub.windUp('chop')
stub.enginePlays('Weapon Swish')
stub.release('chop')
onUpdate(0.016)
check(#stub.filesPlayed == 0 and #stub.stopped == 0, "a creature's own attack keeps the vanilla swish")
stub.selfObject.isCreature = nil
stub.reset()
stub.rightHand = stub.item('pick_apprentice_01')
stub.enginePlays('Weapon Swish')
stub.release('chop')
check(#stub.filesPlayed == 0, 'so does anything that is not a weapon')
stub.reset()
stub.rightHand = W('MarksmanBow')
stub.windUp('shoot')
stub.enginePlays('Weapon Swish')
onUpdate(0.016)
stub.release('shoot')
check(#stub.filesPlayed == 0 and #stub.stopped == 0, 'a bow is left alone')

print('\n== creature "Sound: SwishM" text keys ==')
stub.reset()
stub.selfObject.isCreature = true
stub.rightHand = SWORD
stub.enginePlays('swishm')
stub.textKey('sound', 'swishm')
check(stub.stopped[1] == 'swishm' and inSet(SWORD_SWINGS, lastFile()), 'a creature with a longsword swings like one')
stub.reset()
stub.textKey('sound', 'swishl') -- key without the sound actually playing
check(#stub.filesPlayed == 0, 'nothing plays when the vanilla sound is not playing')
stub.reset()
stub.enginePlays('Health Damage')
stub.textKey('sound', 'health damage')
check(#stub.filesPlayed == 0, 'other sound keys are left alone')
stub.reset()
stub.rightHand = nil
stub.enginePlays('swishs')
stub.textKey('sound', 'swishs')
check(#stub.filesPlayed == 0, 'unarmed creatures keep the vanilla swish')
stub.selfObject.isCreature = nil

print('\n== hits on armor ==')
local function armorHit(tag, attack)
    stub.reset()
    stub.hit(attack or { successful = true, damage = { health = 10 } })
    stub.enginePlays('Health Damage') -- builtin onHit, after ours
    stub.enginePlays(tag)
    onUpdate(0.016)
end
for _, hand in ipairs({ SWORD, false }) do
    stub.rightHand = hand or nil
    armorHit('Medium Armor Hit')
    local label = hand and 'armed' or 'unarmed'
    check(stub.stopped[1] == 'Medium Armor Hit' and #stub.filesPlayed == 1
        and inSet(expected('hit', { 'armor' }), lastFile()), 'medium armor gets an armor hit (' .. label .. ' defender)')
    check(stub.playing['health damage'] == true, 'Health Damage keeps playing on top (' .. label .. ')')
end
armorHit('Heavy Armor Hit')
check(stub.stopped[1] == 'Heavy Armor Hit' and inSet(expected('hit', { 'armorHeavy' }), lastFile()),
    'heavy armor gets a heavy armor hit')
local pitchOk = true
for _, p in ipairs(stub.filesPlayed) do pitchOk = pitchOk and p.options.pitch >= 0.85 and p.options.pitch <= 1.0 end
check(pitchOk, 'hits play at a pitch between 0.85 and 1 too')
armorHit('Light Armor Hit', { successful = true, damage = { health = 10 }, attacker = stub.npc(),
    weapon = W('ShortBladeOneHand') })
check(stub.stopped[1] == 'Light Armor Hit' and #stub.filesPlayed == 1
    and inSet(expected('hit', { 'fleshySlice', 'fleshyStab' }), lastFile()),
    'light armor is swapped for the flesh sounds of the weapon')

print('\n== hits on no armor ==')
for _, hand in ipairs({ SWORD, false }) do
    stub.reset()
    stub.rightHand = hand or nil
    stub.hit({ successful = true, damage = { health = 10 } })
    stub.enginePlays('Health Damage') -- the roll landed on an unarmored slot
    onUpdate(0.016)
    local label = hand and 'armed' or 'unarmed'
    check(#stub.filesPlayed == 1 and inSet(DEFAULT_FLESH, lastFile()), 'a fleshy CSO hit is layered on (' .. label .. ' defender)')
    check(#stub.stopped == 0 and stub.playing['health damage'] == true, 'over the vanilla Health Damage (' .. label .. ')')
end
stub.reset()
local attack = { successful = true, damage = { health = 0 } }
stub.hit(attack)
attack.damage.health = 4 -- the handlers after ours work on the same table
stub.enginePlays('Health Damage')
onUpdate(0.016)
check(#stub.filesPlayed == 1 and inSet(DEFAULT_FLESH, lastFile()), 'the damage is read once every handler has had it')
stub.reset()
stub.enginePlays('Health Damage') -- still going from an earlier hit
stub.hit({ successful = true, damage = { fatigue = 10 } })
onUpdate(0.016)
check(#stub.filesPlayed == 0, 'a hit to fatigue alone gets nothing, even with an earlier Health Damage playing')
stub.reset()
stub.hit({ successful = true, damage = { health = 10 } })
onUpdate(0.016) -- no Health Damage: god mode, or a handler stopped the builtin one
check(#stub.filesPlayed == 0, 'nothing is layered when Health Damage did not play')
stub.reset()
stub.hit({ successful = false })
stub.enginePlays('Heavy Armor Hit')
onUpdate(0.016)
check(#stub.filesPlayed == 0, 'a miss makes no check')
stub.reset()
stub.hit({ successful = true })
onUpdate(0.016)
stub.enginePlays('Light Armor Hit')
onUpdate(0.016)
check(#stub.filesPlayed == 0, 'the check is made once per hit, not kept up')

print('\n== what the attack is made with, and what it lands on ==')
local function pools(tag, cases)
    for _, c in ipairs(cases) do
        local seen = draws(tag, { weapon = c.weapon and W(c.weapon), attacker = c.attacker })
        local want = expected(c.folder or 'hit', c.categories)
        check(sameSet(seen, want), string.format('%s by %s: %s (%d files)', tag, c.label,
            table.concat(c.categories, ' + '), count(seen)))
    end
end
local npc, creature = stub.npc(), stub.creature()
pools('Weapon Swish', {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'sharpMetal' }, folder = 'swing' },
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'ringingBlade', 'metal' }, folder = 'swing' },
    { label = 'claymore', weapon = 'LongBladeTwoHand', categories = { 'heavyMetal', 'heavyMetalGeneric' }, folder = 'swing' },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'heavyMetal' }, folder = 'swing' },
    { label = 'warhammer', weapon = 'BluntTwoClose', categories = { 'heavyMetal', 'heavyMetalGeneric' }, folder = 'swing' },
    { label = 'war axe', weapon = 'AxeOneHand', categories = { 'heavyMetal' }, folder = 'swing' },
    { label = 'battle axe', weapon = 'AxeTwoHand', categories = { 'heavyMetal', 'heavyMetalGeneric' }, folder = 'swing' },
    { label = 'spear', weapon = 'SpearTwoWide', categories = { 'heavyMetalGeneric' }, folder = 'swing' },
    { label = 'staff', weapon = 'BluntTwoWide', categories = { 'plain', 'metal', 'heavyMetalGeneric' }, folder = 'swing' },
    { label = 'throwing star', weapon = 'MarksmanThrown', categories = { 'sharpMetal', 'plain' }, folder = 'swing' },
    { label = 'fists', attacker = npc, categories = { 'plain' }, folder = 'swing' },
})
check(api.pickFile('Weapon Swish', { attacker = creature }) == nil, "Weapon Swish by a creature's own attack: nothing")
check(api.pickFile('Weapon Swish', { weapon = W('MarksmanBow') }) == nil, 'Weapon Swish by a bow: nothing')
local fleshCases = {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'fleshySlice', 'fleshyStab' } },
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'fleshySlice', 'blade' } },
    { label = 'claymore', weapon = 'LongBladeTwoHand', categories = { 'fleshySlice', 'blade' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'crunchyFlesh', 'punchyFlesh' } },
    { label = 'spear', weapon = 'SpearTwoWide', categories = { 'fleshyStab', 'stab' } },
    { label = 'fists', attacker = npc, categories = { 'punchyFlesh', 'flesh' } },
    { label = 'axe', weapon = 'AxeTwoHand', categories = { 'flesh', 'punchyFlesh' } },
    { label = 'staff', weapon = 'BluntTwoWide', categories = { 'flesh', 'punchyFlesh' } },
    { label = 'arrow', weapon = 'MarksmanBow', categories = { 'flesh', 'punchyFlesh' } },
    { label = 'claws', attacker = creature, categories = { 'flesh', 'punchyFlesh' } },
}
pools('Health Damage', fleshCases)
pools('Light Armor Hit', { fleshCases[1], fleshCases[4], fleshCases[7] })
pools('Medium Armor Hit', {
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'armor' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'armor' } },
    { label = 'claws', attacker = creature, categories = { 'armor' } },
})
pools('Heavy Armor Hit', {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'armorHeavy', 'armorHeavyBlade' } },
    { label = 'claymore', weapon = 'LongBladeTwoHand', categories = { 'armorHeavy', 'armorHeavyBlade' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'armorHeavy' } },
    { label = 'claws', attacker = creature, categories = { 'armorHeavy' } },
})
-- armorFlesh, armorCrunchyFlesh and armorStab have flesh in them and aren't used; 68, 97 and 98 aren't sorted
local heard = {}
for _, tag in ipairs({ 'Health Damage', 'Light Armor Hit', 'Medium Armor Hit', 'Heavy Armor Hit' }) do
    for _, c in ipairs(fleshCases) do
        for f in pairs(draws(tag, { weapon = c.weapon and W(c.weapon), attacker = c.attacker })) do heard[f] = true end
    end
end
local leaked = {}
for n = 41, 56 do leaked[#leaked + 1] = n end
for _, n in ipairs({ 71, 80, 81, 69, 68, 97, 98 }) do leaked[#leaked + 1] = n end
local played = {}
for _, n in ipairs(leaked) do
    if heard[string.format('sound/fx/item/csohit/hit%d.wav', n)] then played[#played + 1] = n end
end
check(#played == 0, 'the fleshy armor hits and the unsorted ones never play' ..
    (#played > 0 and (' (played: ' .. table.concat(played, ', ') .. ')') or ''))

print('\n== bodies ==')
local function bodyHit(bloodType, weapon)
    stub.bloodType = bloodType
    local s = loadScript(true)
    stub.reset()
    stub.hit({ successful = true, damage = { health = 10 }, attacker = npc, weapon = weapon })
    stub.enginePlays('Health Damage')
    s.engineHandlers.onUpdate(0.016)
    stub.bloodType = 0
    return s
end
bodyHit(2, W('BluntOneHand'))
check(#stub.filesPlayed == 1 and #stub.stopped == 0 and inSet(expected('hit', { 'armorHeavy' }), lastFile()),
    'a dwemer machine (sparks) gets a heavy armor hit over the body hit')
bodyHit(2, W('ShortBladeOneHand'))
check(inSet(expected('hit', { 'armorHeavy', 'armorHeavyBlade' }), lastFile()), 'and blades ring on it like on heavy armor')
local bone = bodyHit(1, W('BluntOneHand'))
check(#stub.filesPlayed == 0 and stub.playing['health damage'] == true, 'a skeleton or ghost (bone dust) keeps only the body hit')
check(bone.interface.pickFile('Health Damage') == nil, 'nothing answers a bone body yet')
bodyHit(0, W('BluntOneHand'))
check(inSet(expected('hit', { 'crunchyFlesh', 'punchyFlesh' }), lastFile()), 'blood is flesh')
-- each load takes over the stubbed engine hooks, so go back to a fresh copy of the main one
script = loadScript(true)
api, onUpdate = script.interface, script.engineHandlers.onUpdate

print('\n== the interface ==')
stub.reset()
stub.rightHand = nil
check(inSet(expected('hit', { 'armorHeavy' }), api.emit('Heavy Armor Hit')), 'emit plays a CSO hit for an armor tag')
check(stub.stopped[1] == 'Heavy Armor Hit', 'and stops the vanilla one, as a real swap would')
check(isHit(api.emit('light armor hit')), 'tags are case insensitive')
check(inSet(expected('swing', { 'plain' }), api.emit('Weapon Swish')), 'an unarmed swing is a hand-to-hand one')
check(inSet(expected('swing', { 'sharpMetal' }), api.emit('Weapon Swish', { weapon = W('ShortBladeOneHand') })),
    'options.weapon picks for that weapon')
stub.selfObject.isCreature = true
check(api.emit('Weapon Swish') == nil, "a creature's own swing plays nothing")
check(isSwing(api.emit('Weapon Swish', { force = true, pitch = 1.3, volume = 0.5 })), 'unless forced')
check(stub.filesPlayed[#stub.filesPlayed].options.pitch == 1.3 and stub.filesPlayed[#stub.filesPlayed].options.volume == 0.5,
    'volume and pitch are passed on')
stub.selfObject.isCreature = nil
stub.reset()
stub.enginePlays('Health Damage')
check(inSet(DEFAULT_FLESH, api.emit('Health Damage')), 'emit Health Damage plays a fleshy CSO hit')
check(#stub.stopped == 0 and stub.playing['health damage'] == true, 'and leaves the vanilla one playing')
check(api.emit('Hand To Hand Hit') == nil and api.emit('nonsense') == nil, 'tags CSO does not answer play nothing')
check(not pcall(api.emit, nil), 'a missing tag is an error')
stub.rightHand = SWORD
check(inSet(SWORD_SWINGS, api.pickFile('SwishL')) and api.pickFile('miss') == nil, 'pickFile')
check(#api.TAGS == 8, 'TAGS lists the eight vanilla sounds')
stub.reset()
script.eventHandlers.CombatSoundsOverhaul_Emit({ tag = 'SwishS' })
check(inSet(SWORD_SWINGS, lastFile()), 'the CombatSoundsOverhaul_Emit event does the same')
check(not draws('SwishM')['sound/fx/item/csoswing/swing6.wav'] and
    not draws('SwishM', { weapon = W('ShortBladeOneHand') })['sound/fx/item/csoswing/swing6.wav'],
    'Swing6, a near copy of Swing5, never comes up')

print('\n== the debug line ==')
local realPrint = print
local function logged(fn)
    local lines = {}
    _G.print = function(line) lines[#lines + 1] = line end
    local ok, err = pcall(fn)
    _G.print = realPrint
    assert(ok, err)
    return table.concat(lines, '\n')
end
api.setDebug(true)
local function swingWith(item)
    stub.reset()
    stub.rightHand = item
    return logged(function()
        stub.windUp('chop')
        stub.enginePlays('Weapon Swish')
        stub.release('chop')
    end)
end
local function hitBy(hit, armorTag)
    stub.reset()
    return logged(function()
        stub.hit(hit)
        if armorTag then stub.enginePlays(armorTag) end
        stub.enginePlays('Health Damage')
        onUpdate(0.016)
    end)
end
local swingNames = {
    { 'ShortBladeOneHand', 'shortBlade 1h' }, { 'LongBladeOneHand', 'longBlade 1h' },
    { 'LongBladeTwoHand', 'longBlade 2h' }, { 'BluntOneHand', 'blunt 1h' }, { 'BluntTwoClose', 'blunt 2h' },
    { 'BluntTwoWide', 'staff 2h' }, { 'SpearTwoWide', 'spear 2h' }, { 'AxeOneHand', 'axe 1h' },
    { 'AxeTwoHand', 'axe 2h' }, { 'MarksmanThrown', 'thrown 1h' },
}
for _, s in ipairs(swingNames) do
    local line = swingWith(W(s[1]))
    check(line:find('(release, ' .. s[2] .. ', pitch ', 1, true) ~= nil, s[1] .. ' swings as ' .. s[2])
end
check(swingWith(nil):find('(release, handToHand, pitch ', 1, true) ~= nil, 'no weapon swings as handToHand')
local line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('AxeTwoHand') }, 'Heavy Armor Hit')
check(line:find('Heavy Armor Hit', 1, true) and line:find('(hit, axe 2h, heavy armor, pitch ', 1, true),
    'a two-handed axe on heavy armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('ShortBladeOneHand') }, 'Light Armor Hit')
check(line:find('(hit, shortBlade 1h, light armor, pitch ', 1, true) ~= nil, 'a dagger on light armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc })
check(line:find('(unarmored hit, handToHand, flesh body, pitch ', 1, true) ~= nil, 'a punch on an unarmored spot')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = creature })
check(line:find('(unarmored hit, natural, flesh body, pitch ', 1, true) ~= nil, "a creature's own attack")
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('MarksmanBow'), ammo = 'iron arrow' })
check(line:find('(unarmored hit, bow 2h, flesh body, pitch ', 1, true) ~= nil, 'an arrow counts as its bow')
line = hitBy({ successful = true, damage = { health = 5 } })
check(line:find('(unarmored hit, flesh body, pitch ', 1, true) ~= nil, 'a hit with no attacker and no weapon has neither')
stub.reset()
line = logged(function() api.emit('Medium Armor Hit') end)
check(line:find('(emit, medium armor, pitch ', 1, true) ~= nil, 'emit of an armor hit knows its armor')
api.setDebug(false)

print('\n== unarmored layer switched off ==')
local muted = loadScript(false)
stub.reset()
stub.rightHand = SWORD
for i = #stub.hitHandlers, 1, -1 do stub.hitHandlers[i]({ successful = true, damage = { health = 10 } }) end
stub.enginePlays('Health Damage')
muted.engineHandlers.onUpdate(0.016)
check(#stub.filesPlayed == 0 and stub.playing['health damage'] == true, 'an unarmored hit keeps only the body hit')
stub.reset()
stub.hit({ successful = true, damage = { health = 10 } })
stub.enginePlays('Heavy Armor Hit')
muted.engineHandlers.onUpdate(0.016)
check(#stub.filesPlayed == 1 and isHit(lastFile()), 'armor hits are still swapped')
check(inSet(DEFAULT_FLESH, muted.interface.emit('Health Damage')), 'emit Health Damage still plays the layer')

print(string.format('\n%d checks, %d failures', checks, failures))
os.exit(failures == 0 and 0 or 1)
