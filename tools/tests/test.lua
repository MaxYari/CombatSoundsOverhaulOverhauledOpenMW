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

-- The categories as the script has them (tools/sound_sorting.py writes them from the sorting folders): name -> numbers
local function categoriesIn(tableName)
    local f = assert(io.open(SCRIPT))
    local body = assert(f:read('a'):match('\nlocal ' .. tableName .. ' = (%b{})'), tableName)
    f:close()
    local numbers = {}
    for name, entries in pairs(assert((loadstring or load)('return ' .. body))()) do
        local list = {}
        for _, e in ipairs(entries) do
            if type(e) == 'number' then list[#list + 1] = e else for n = e[1], e[2] do list[#list + 1] = n end end
        end
        numbers[name] = list
    end
    return numbers
end
local SWINGS, HITS = categoriesIn('SWING_CATEGORIES'), categoriesIn('HIT_CATEGORIES')
-- The numbers up to `last` in none of the categories, which never play
local function uncategorized(categories, last)
    local inOne, out = {}, {}
    for _, numbers in pairs(categories) do for _, n in ipairs(numbers) do inOne[n] = true end end
    for n = 1, last do if not inOne[n] then out[#out + 1] = n end end
    return out
end
-- The set of paths a list of categories should draw from
local function expected(folder, categories)
    local set = {}
    for _, category in ipairs(categories) do
        for _, n in ipairs(assert((folder == 'swing' and SWINGS or HITS)[category], category)) do
            set[string.format('sound/fx/item/cso%s/%s%d.wav', folder, folder, n)] = true
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
-- Everything pickFile comes up with over many draws, on the main script or the given interface
local function draws(tag, options, iface)
    local seen = {}
    for _ = 1, 3000 do
        local f = (iface or api).pickFile(tag, options)
        if f then seen[f] = true end
    end
    return seen
end

local function lastFile() local p = stub.filesPlayed[#stub.filesPlayed]; return p and p.file end
local function isSwing(f) return f ~= nil and f:find('^sound/fx/item/csoswing/') ~= nil end
local function isHit(f) return f ~= nil and f:find('^sound/fx/item/csohit/') ~= nil end

local W = function(typeName) return stub.weapon('w', typeName) end
local SWORD = W('LongBladeOneHand')
local SWORD_SWINGS = expected('swing', { 'ringingBladeMetal', 'bladeMetal' })
local DEFAULT_FLESH = expected('hit', { 'FleshHit', 'metallicPunchyFleshHit' })
local MEDIUM_HIT = expected('hit', { 'armorMediumPureHit' })
local HEAVY_HIT = expected('hit', { 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit' })
local CHOP, THRUST = 0, 2 -- I.Combat.ATTACK_TYPES
-- The files the last hit played that are in `set`
local function playedIn(set)
    local found = {}
    for _, p in ipairs(stub.filesPlayed) do if set[p.file] then found[#found + 1] = p end end
    return found
end
local RINGS = expected('hit', { 'RingingBladePure', 'BluntRingPure' })
local METALLIC = expected('hit', { 'metallicPunchyFleshHit' })
local PURE_ARMOR = expected('hit', { 'armorMediumPureHit', 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit', 'stabPure' })
-- What the last hit played, by role: the flesh under armor (at 60% of `volume`), the rings, and the hit drawn
local function roles(volume)
    volume = volume or 1
    local r = { under = {}, rings = {}, main = {} }
    for _, p in ipairs(stub.filesPlayed) do
        if math.abs(p.options.volume - volume * 0.6) < 1e-9 then r.under[#r.under + 1] = p
        elseif RINGS[p.file] then r.rings[#r.rings + 1] = p
        else r.main[#r.main + 1] = p end
    end
    return r
end
-- The rules for a hit on armor over a living body; returns what went wrong, or nil
local function armorRulesBroken(volume)
    local r = roles(volume)
    if #r.main > 1 or #r.under > 1 then return 'more than one hit or flesh' end
    if #r.main + #r.under == 0 then return 'nothing played' end
    if #r.under == 1 and #r.main == 1 and not PURE_ARMOR[r.main[1].file] then return 'flesh under a hit that is not pure' end
    if #r.main == 1 and METALLIC[r.main[1].file] and #r.under > 0 then return 'flesh under a metallic punchy hit' end
    if #r.main == 1 and PURE_ARMOR[r.main[1].file] and #r.under == 0 then return 'a pure hit with no flesh under it' end
    if #r.rings > 0 and #r.main == 0 then return 'a ring with no hit' end
    return nil
end
local function union(...)
    local set = {}
    for _, t in ipairs({ ... }) do for k in pairs(t) do set[k] = true end end
    return set
end

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
check(pitch >= 0.9 and pitch <= 1.1, string.format('at a pitch between 0.9 and 1.1 (%.3f)', pitch))
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
    local r = roles()
    check(stub.stopped[1] == 'Medium Armor Hit' and armorRulesBroken() == nil
        and (#r.under == 1 or METALLIC[r.main[1].file]), 'medium armor gets its hit, the flesh under it or a metallic punch ('
        .. label .. ' defender)')
    check(stub.playing['health damage'] == true, 'Health Damage keeps playing on top (' .. label .. ')')
end
-- 2000 hits on heavy armor, by nothing in particular: the drawn hit is pure or metallic punchy
local broken, underRuns, pureWithUnder, metallicRuns, runs = nil, 0, 0, 0, 2000
for _ = 1, runs do
    armorHit('Heavy Armor Hit')
    broken = broken or armorRulesBroken()
    local r = roles()
    if #r.under == 1 then
        underRuns = underRuns + 1
        if #r.main == 1 then pureWithUnder = pureWithUnder + 1 end
    elseif #r.main == 1 and METALLIC[r.main[1].file] then
        metallicRuns = metallicRuns + 1
    end
end
check(broken == nil, 'every hit on heavy armor keeps to the rules' .. (broken and (': ' .. broken) or ''))
check(underRuns + metallicRuns == runs, 'each gets the flesh under a pure hit, or a metallic punch alone')
check(pureWithUnder / underRuns > 0.7 and pureWithUnder / underRuns < 0.8,
    string.format('the pure hit comes with 75%% of the flesh sounds (%.3f)', pureWithUnder / underRuns))
check(metallicRuns > 0 and underRuns > metallicRuns, 'metallic punches come up, less often than pure hits')
local pitchOk = true
for _, p in ipairs(stub.filesPlayed) do pitchOk = pitchOk and p.options.pitch >= 0.9 and p.options.pitch <= 1.1 end
check(pitchOk, 'hits play at a pitch between 0.9 and 1.1 too')
local RINGING = expected('hit', { 'RingingBladePure' })
local rings, withHit = 0, 0
broken = nil
for _ = 1, 3000 do
    armorHit('Medium Armor Hit', { successful = true, damage = { health = 10 }, attacker = stub.npc(),
        weapon = W('LongBladeOneHand'), type = CHOP, sourceType = 'melee' })
    broken = broken or armorRulesBroken()
    local r = roles()
    if #r.main == 1 then withHit, rings = withHit + 1, rings + #playedIn(RINGING) end
end
check(broken == nil, 'a longsword on medium armor keeps to the rules' .. (broken and (': ' .. broken) or ''))
check(rings / withHit > 0.25 and rings / withHit < 0.35,
    string.format('and rings on top of 30%% of its hits (%.3f)', rings / withHit))
armorHit('Light Armor Hit', { successful = true, damage = { health = 10 }, attacker = stub.npc(),
    weapon = W('ShortBladeOneHand') })
check(stub.stopped[1] == 'Light Armor Hit' and #stub.filesPlayed == 1
    and inSet(expected('hit', { 'FleshSlice', 'FleshHit', 'metallicPunchyFleshHit' }), lastFile()),
    'light armor is swapped for the flesh sounds of the weapon, alone')

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
local function pools(tag, cases, iface)
    for _, c in ipairs(cases) do
        local seen = draws(tag, { weapon = c.weapon and W(c.weapon), attacker = c.attacker, attackType = c.attackType }, iface)
        local want = expected(c.folder or 'hit', c.categories)
        check(sameSet(seen, want), string.format('%s by %s%s: %s (%d files)', tag, c.label,
            c.attackType == THRUST and ' thrust' or '', table.concat(c.categories, ' + '), count(seen)))
    end
end
local npc, creature = stub.npc(), stub.creature()
pools('Weapon Swish', {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'sharpMetal', 'ringingBladeMetal' }, folder = 'swing' },
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'ringingBladeMetal', 'bladeMetal' }, folder = 'swing' },
    { label = 'claymore', weapon = 'LongBladeTwoHand', categories = { 'bladeMetal' }, folder = 'swing' },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'heavyMetal' }, folder = 'swing' },
    { label = 'warhammer', weapon = 'BluntTwoClose', categories = { 'heavyMetal' }, folder = 'swing' },
    { label = 'war axe', weapon = 'AxeOneHand', categories = { 'heavyMetal' }, folder = 'swing' },
    { label = 'battle axe', weapon = 'AxeTwoHand', categories = { 'heavyMetal' }, folder = 'swing' },
    { label = 'spear', weapon = 'SpearTwoWide', categories = { 'plain' }, folder = 'swing' },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = CHOP, categories = { 'plain' }, folder = 'swing' },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = THRUST, categories = { 'bladeMetal', 'ringingBladeMetal' }, folder = 'swing' },
    { label = 'longsword', weapon = 'LongBladeOneHand', attackType = THRUST, categories = { 'ringingBladeMetal', 'bladeMetal' }, folder = 'swing' },
    { label = 'staff', weapon = 'BluntTwoWide', categories = { 'plain', 'bladeMetal' }, folder = 'swing' },
    { label = 'throwing star', weapon = 'MarksmanThrown', categories = { 'sharpMetal', 'plain' }, folder = 'swing' },
    { label = 'fists', attacker = npc, categories = { 'plain' }, folder = 'swing' },
})
check(api.pickFile('Weapon Swish', { attacker = creature }) == nil, "Weapon Swish by a creature's own attack: nothing")
local SPEAR_THRUST_SWINGS = expected('swing', { 'bladeMetal', 'ringingBladeMetal' })
local function spearSwing(attackName, early)
    stub.reset()
    stub.rightHand = W('SpearTwoWide')
    stub.windUp(attackName)
    stub.enginePlays('Weapon Swish')
    if early then onUpdate(0.016) end
    stub.release(attackName)
    return lastFile()
end
check(inSet(SPEAR_THRUST_SWINGS, spearSwing('thrust')), 'a spear thrust whooshes with metallic and ringing blades')
check(inSet(expected('swing', { 'plain' }), spearSwing('chop')) and inSet(expected('swing', { 'plain' }), spearSwing('slash')),
    'its chops and slashes with the plain whooshes')
check(inSet(SPEAR_THRUST_SWINGS, spearSwing('thrust', true)), 'an early released thrust is still a thrust')
stub.rightHand = nil
check(api.pickFile('Weapon Swish', { weapon = W('MarksmanBow') }) == nil, 'Weapon Swish by a bow: nothing')
local fleshCases = {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'FleshSlice', 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'dagger', weapon = 'ShortBladeOneHand', attackType = THRUST, categories = { 'FleshStab', 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'longsword', weapon = 'LongBladeOneHand', attackType = THRUST, categories = { 'FleshStab', 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'claymore', weapon = 'LongBladeTwoHand', categories = { 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'claymore', weapon = 'LongBladeTwoHand', attackType = THRUST, categories = { 'FleshStab', 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'metallicPunchyFleshHit' } },
    { label = 'mace', weapon = 'BluntOneHand', attackType = THRUST, categories = { 'metallicPunchyFleshHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = THRUST, categories = { 'FleshStab', 'metallicPunchyFleshHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = CHOP, categories = { 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'fists', attacker = npc, categories = { 'FleshHit' } },
    { label = 'fists', attacker = npc, attackType = THRUST, categories = { 'FleshHit' } },
    { label = 'axe', weapon = 'AxeTwoHand', categories = { 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'staff', weapon = 'BluntTwoWide', attackType = THRUST, categories = { 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'arrow', weapon = 'MarksmanBow', categories = { 'FleshStab', 'FleshHit' } },
    { label = 'bolt', weapon = 'MarksmanCrossbow', categories = { 'FleshStab', 'FleshHit' } },
    { label = 'throwing star', weapon = 'MarksmanThrown', categories = { 'FleshStab', 'FleshHit', 'metallicPunchyFleshHit' } },
    { label = 'claws', attacker = creature, attackType = THRUST, categories = { 'FleshHit', 'metallicPunchyFleshHit' } },
}
pools('Health Damage', fleshCases)
pools('Light Armor Hit', { fleshCases[1], fleshCases[2], fleshCases[7], fleshCases[13] })
-- The armor hit drawn for medium and heavy armor; the rings are layers, not in the draw
pools('Medium Armor Hit', {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'armorMediumPureHit', 'metallicPunchyFleshHit' } },
    { label = 'dagger', weapon = 'ShortBladeOneHand', attackType = THRUST, categories = { 'armorMediumPureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'armorMediumPureHit', 'metallicPunchyFleshHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = THRUST, categories = { 'armorMediumPureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', categories = { 'armorMediumPureHit', 'metallicPunchyFleshHit' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'armorMediumPureHit', 'metallicPunchyFleshHit' } },
    { label = 'mace', weapon = 'BluntOneHand', attackType = THRUST, categories = { 'armorMediumPureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'fists', attacker = npc, categories = { 'armorMediumPureHit' } },
    { label = 'claws', attacker = creature, attackType = THRUST, categories = { 'armorMediumPureHit', 'metallicPunchyFleshHit' } },
    { label = 'arrow', weapon = 'MarksmanBow', categories = { 'armorMediumPureHit' } },
})
pools('Heavy Armor Hit', {
    { label = 'dagger', weapon = 'ShortBladeOneHand', categories = { 'armorHeavyBladePureHit', 'metallicPunchyFleshHit' } },
    { label = 'dagger', weapon = 'ShortBladeOneHand', attackType = THRUST, categories = { 'armorHeavyBladePureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'claymore', weapon = 'LongBladeTwoHand', categories = { 'armorHeavyBladePureHit', 'metallicPunchyFleshHit' } },
    { label = 'axe', weapon = 'AxeTwoHand', categories = { 'armorHeavyBladePureHit', 'metallicPunchyFleshHit' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'armorHeavyBluntPureHit', 'metallicPunchyFleshHit' } },
    { label = 'mace', weapon = 'BluntOneHand', attackType = THRUST, categories = { 'armorHeavyBluntPureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'staff', weapon = 'BluntTwoWide', categories = { 'armorHeavyBluntPureHit', 'metallicPunchyFleshHit' } },
    { label = 'staff', weapon = 'BluntTwoWide', attackType = THRUST, categories = { 'armorHeavyBladePureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'fists', attacker = npc, categories = { 'armorHeavyBluntPureHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', categories = { 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit', 'metallicPunchyFleshHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = THRUST, categories = { 'armorHeavyBladePureHit', 'stabPure', 'metallicPunchyFleshHit' } },
    { label = 'claws', attacker = creature, attackType = THRUST, categories = { 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit', 'metallicPunchyFleshHit' } },
    { label = 'arrow', weapon = 'MarksmanBow', categories = { 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit' } },
})
-- The bone sounds, the rings (layers only) and the files in no category never come up as the hit drawn here
local heard = {}
for _, tag in ipairs({ 'Health Damage', 'Light Armor Hit', 'Medium Armor Hit', 'Heavy Armor Hit' }) do
    for _, c in ipairs(fleshCases) do
        for f in pairs(draws(tag, { weapon = c.weapon and W(c.weapon), attacker = c.attacker, attackType = c.attackType })) do
            heard[f] = true
        end
    end
end
local leaked = uncategorized(HITS, 102)
for _, category in ipairs({ 'cutPure', 'BoneHit', 'BluntBoneHit', 'RingingBladePure', 'BluntRingPure' }) do
    for _, n in ipairs(HITS[category]) do leaked[#leaked + 1] = n end
end
local drawnWrong = {}
for _, n in ipairs(leaked) do
    if heard[string.format('sound/fx/item/csohit/hit%d.wav', n)] then drawnWrong[#drawnWrong + 1] = n end
end
check(#drawnWrong == 0, 'bone-only, ring and uncategorized hits are never drawn for armor or flesh' ..
    (#drawnWrong > 0 and (' (drawn: ' .. table.concat(drawnWrong, ', ') .. ')') or ''))

print('\n== bodies ==')
local function bodyHit(bloodType, weapon, extra)
    stub.bloodType = bloodType
    local s = loadScript(true)
    stub.reset()
    local hit = { successful = true, damage = { health = 10 }, attacker = npc, weapon = weapon }
    for k, v in pairs(extra or {}) do hit[k] = v end
    stub.hit(hit)
    stub.enginePlays('Health Damage')
    s.engineHandlers.onUpdate(0.016)
    stub.bloodType = 0
    return s
end
local ANY_FLESH = expected('hit', { 'FleshHit', 'metallicPunchyFleshHit', 'FleshSlice', 'FleshStab' })
bodyHit(2, W('BluntOneHand'))
check(#stub.stopped == 0 and inSet(expected('hit', { 'armorHeavyBluntPureHit' }), stub.filesPlayed[1].file)
    and #playedIn(ANY_FLESH) == 0, 'a dwemer machine (sparks) gets a heavy blunt hit over the body hit, no flesh')
bodyHit(2, W('ShortBladeOneHand'))
check(inSet(expected('hit', { 'armorHeavyBladePureHit' }), stub.filesPlayed[1].file), 'and a heavy blade hit for blades')
local bone = bodyHit(1, W('BluntOneHand'))
check(#stub.filesPlayed == 1 and #stub.stopped == 0 and inSet(expected('hit', { 'cutPure', 'BluntBoneHit', 'BoneHit' }), lastFile()),
    'a skeleton (bone dust) gets a pure or bone hit over the body hit')
pools('Health Damage', {
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'cutPure', 'BoneHit' } },
    { label = 'longsword', weapon = 'LongBladeOneHand', attackType = THRUST, categories = { 'stabPure', 'BoneHit' } },
    { label = 'spear', weapon = 'SpearTwoWide', attackType = THRUST, categories = { 'stabPure', 'BoneHit' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'cutPure', 'BluntBoneHit', 'BoneHit' } },
    { label = 'fists', attacker = npc, attackType = THRUST, categories = { 'cutPure', 'BoneHit' } },
    { label = 'claws', attacker = creature, attackType = THRUST, categories = { 'cutPure', 'BoneHit' } },
    { label = 'arrow', weapon = 'MarksmanBow', categories = { 'cutPure', 'BoneHit' } },
}, bone.interface)
bodyHit(1, W('SpearTwoWide'), { type = THRUST, sourceType = 'melee' })
check(inSet(expected('hit', { 'stabPure', 'BoneHit' }), lastFile()), 'a real spear thrust into a skeleton stabs')
local rangedBone = {}
for _ = 1, 400 do
    bodyHit(1, W('SpearTwoWide'), { type = THRUST, sourceType = 'ranged' })
    rangedBone[lastFile()] = true
end
check(sameSet(rangedBone, expected('hit', { 'cutPure', 'BoneHit' })), 'but only a melee attack counts as a thrust')
bodyHit(0, W('BluntOneHand'))
check(inSet(expected('hit', { 'metallicPunchyFleshHit' }), lastFile()), 'blood is flesh')
-- An armored actor that doesn't bleed has no flesh under its armor, so the armor hit always plays
stub.bloodType = 1
local undead = loadScript(true)
local alwaysArmor = true
for _ = 1, 300 do
    stub.reset()
    stub.hit({ successful = true, damage = { health = 10 } })
    stub.enginePlays('Health Damage')
    stub.enginePlays('Medium Armor Hit')
    undead.engineHandlers.onUpdate(0.016)
    local r = roles()
    alwaysArmor = alwaysArmor and #r.main == 1 and #r.under == 0
end
stub.bloodType = 0
check(alwaysArmor, 'an armored skeleton gets its hit every time, with no flesh under it')
-- What the body counts as, from the blood type and, for ghosts, the record's name and model
local function bodyOf(bloodType, name, model)
    stub.bloodType, stub.record = bloodType, { name = name, model = model, id = 'test_creature' }
    local body = loadScript(true).interface.getBody()
    stub.bloodType, stub.record = 0, {}
    return body
end
local bodies = {
    { 0, 'Nix-Hound', 'r\\nixhound.nif', 'Unarmored' },
    { 2, 'Steam Centurion', 'r\\steam_centurion.nif', 'Metal' },
    { 1, 'Skeleton Champion', 'r\\skeleton.nif', 'Bone' },
    { 1, 'Bonelord', 'r\\bonelord.nif', 'Bone' },
    { 1, 'Bonewolf', 'r\\undeadwolf_2.nif', 'Bone' },
    { 1, 'Ancestor Ghost', 'r\\ancestorghost.nif', 'Ghost' },
    { 1, 'Kanit Ashurnisammis', 'r\\ancestorghost.nif', 'Ghost' },
    { 1, 'Dahrk Mezalf', 'r\\dwarvenspecter.nif', 'Ghost' },
    { 1, 'Gateway Haunt', 'r\\ancestorghost.nif', 'Ghost' },
    { 1, 'Welkynd Spirit', 'pc\\cr\\pc_ayl_guard_01.nif', 'Ghost' },
    { 5, 'Ancestor Ghost', 'r\\ancestorghost.nif', 'Ghost' },
    { 5, 'Scamp', 'r\\scamp.nif', 'Unarmored' },
    { 0, 'Ghostgate Guard', 'b\\guard.nif', 'Unarmored' },
}
for _, b in ipairs(bodies) do
    local got = bodyOf(b[1], b[2], b[3])
    check(got == b[4], string.format('%s (blood type %d) is %s (%s)', b[2], b[1], b[4], tostring(got)))
end
stub.bloodType, stub.record = 1, { name = 'Ancestor Ghost', model = 'r\\ancestorghost.nif' }
local ghost = bodyHit(1, W('BluntOneHand'))
check(#stub.filesPlayed == 1 and ghost.interface.getBody() == 'Ghost' and inSet(expected('hit', { 'cutPure' }), lastFile()),
    'a ghost gets a pure cut over the body hit')
pools('Health Damage', {
    { label = 'longsword', weapon = 'LongBladeOneHand', categories = { 'cutPure' } },
    { label = 'longsword', weapon = 'LongBladeOneHand', attackType = THRUST, categories = { 'stabPure' } },
    { label = 'mace', weapon = 'BluntOneHand', categories = { 'cutPure' } },
    { label = 'claws', attacker = creature, categories = { 'cutPure' } },
}, ghost.interface)
stub.record = {}
-- each load takes over the stubbed engine hooks, so go back to a fresh copy of the main one
script = loadScript(true)
api, onUpdate = script.interface, script.engineHandlers.onUpdate

print('\n== the interface ==')
stub.reset()
stub.rightHand = nil
check(inSet(union(HEAVY_HIT, DEFAULT_FLESH), api.emit('Heavy Armor Hit')) and #playedIn(DEFAULT_FLESH) == 1,
    'emit plays what a hit on armor would: the flesh under it, and 75% of the time the armor hit')
check(stub.stopped[1] == 'Heavy Armor Hit', 'and stops the vanilla one, as a real swap would')
check(isHit(api.emit('light armor hit')), 'tags are case insensitive')
check(inSet(expected('swing', { 'plain' }), api.emit('Weapon Swish')), 'an unarmed swing is a hand-to-hand one')
check(inSet(expected('swing', { 'sharpMetal', 'ringingBladeMetal' }), api.emit('Weapon Swish', { weapon = W('ShortBladeOneHand') })),
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
local swingsHeard = {}
for _, typeName in ipairs({ 'ShortBladeOneHand', 'LongBladeOneHand', 'LongBladeTwoHand', 'BluntOneHand', 'AxeTwoHand',
    'SpearTwoWide', 'BluntTwoWide', 'MarksmanThrown' }) do
    for f in pairs(draws('SwishM', { weapon = W(typeName), attackType = THRUST })) do swingsHeard[f] = true end
    for f in pairs(draws('SwishM', { weapon = W(typeName) })) do swingsHeard[f] = true end
end
local swingLeaks = {}
for _, n in ipairs(uncategorized(SWINGS, 26)) do
    if swingsHeard[string.format('sound/fx/item/csoswing/swing%d.wav', n)] then swingLeaks[#swingLeaks + 1] = n end
end
check(#uncategorized(SWINGS, 26) > 0 and #swingLeaks == 0, 'swings in no category, like Swing6, never come up')

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
    check(line:find('(release, ' .. s[2] .. ', ', 1, true) ~= nil, s[1] .. ' swings as ' .. s[2])
end
check(swingWith(nil):find('(release, handToHand, plain, pitch ', 1, true) ~= nil, 'no weapon swings as handToHand')
local line
for _ = 1, 50 do
    line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('AxeTwoHand') }, 'Heavy Armor Hit')
    if line:find(', underneath, pitch ', 1, true) then break end
end
check(line:find('Heavy Armor Hit', 1, true) and line:find('(hit, axe 2h, heavy armor, ', 1, true)
    and line:find(', underneath, pitch ', 1, true), 'a two-handed axe on heavy armor, with the flesh underneath')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('ShortBladeOneHand') }, 'Light Armor Hit')
check(line:find('(hit, shortBlade 1h, light armor, ', 1, true) ~= nil, 'a dagger on light armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('LongBladeOneHand'), type = THRUST,
    sourceType = 'melee' }, 'Medium Armor Hit')
check(line:find('(hit, longBlade 1h thrust, medium armor, ', 1, true) ~= nil, 'a longsword thrust on medium armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc })
check(line:find('(unarmored hit, handToHand, flesh body, FleshHit, pitch ', 1, true) ~= nil, 'a punch on an unarmored spot')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = creature })
check(line:find('(unarmored hit, natural, flesh body, ', 1, true) ~= nil, "a creature's own attack")
line = hitBy({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('MarksmanBow'), ammo = 'iron arrow' })
check(line:find('(unarmored hit, bow 2h, flesh body, ', 1, true) ~= nil, 'an arrow counts as its bow')
line = hitBy({ successful = true, damage = { health = 5 } })
check(line:find('(unarmored hit, flesh body, ', 1, true) ~= nil, 'a hit with no attacker and no weapon has neither')
stub.reset()
line = logged(function() api.emit('Medium Armor Hit') end)
check(line:find('(emit, medium armor, ', 1, true) ~= nil, 'emit of an armor hit knows its armor')
api.setDebug(false)

print('\n== playSwing and playHit ==')
local WEAPON, ARMOR = api.WEAPON, api.ARMOR
check(WEAPON.AxeTwoHanded == 'AxeTwoHanded' and ARMOR.Heavy == 'Heavy', 'WEAPON and ARMOR are enums of names')
check(not pcall(function() return WEAPON.Swrod end), 'a misspelled enum name is an error')
stub.reset()
local f = api.playSwing(WEAPON.ShortBlade, 0.5)
local played = stub.filesPlayed[1]
check(inSet(expected('swing', { 'sharpMetal', 'ringingBladeMetal' }), f) and played.file == f, 'playSwing plays a swing for the weapon')
check(played.options.volume == 0.5 and played.options.pitch >= 0.9 and played.options.pitch <= 1.1,
    'at the volume given and a random pitch')
check(#stub.stopped == 0, 'and stops nothing')
stub.reset()
api.playSwing(WEAPON.Staff)
check(stub.filesPlayed[1].options.volume == 1, 'volume is 1 when not given')
check(api.playSwing(WEAPON.Natural) == nil and api.playSwing(WEAPON.Bow) == nil, 'weapons with no swings play nothing')
local spearSeen = {}
for _ = 1, 2000 do spearSeen[api.playSwing(WEAPON.Spear, 1, THRUST)] = true end
check(sameSet(spearSeen, expected('swing', { 'bladeMetal', 'ringingBladeMetal' })), 'playSwing takes the attack type: a spear thrust')
check(not pcall(api.playSwing, WEAPON.Spear, 1, 'jab'), 'a bad attack type for playSwing is an error')
check(not pcall(api.playSwing, 'Swrod') and not pcall(api.playSwing, WEAPON.Axe, -1)
    and not pcall(api.playSwing, WEAPON.Axe, 'loud'), 'an unknown weapon or a bad volume is an error')
-- On medium and heavy armor the first sound played is the armor hit, or the flesh under it when the armor doesn't roll
local hitCases = {
    { ARMOR.Heavy, nil, nil, { 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit', 'FleshHit', 'metallicPunchyFleshHit' } },
    { ARMOR.Medium, WEAPON.ShortBlade, nil, { 'armorMediumPureHit', 'FleshSlice', 'FleshHit', 'metallicPunchyFleshHit' } },
    { ARMOR.Medium, WEAPON.HandToHand, nil, { 'armorMediumPureHit', 'FleshHit' } },
    { ARMOR.Medium, WEAPON.ShortBlade, THRUST, { 'armorMediumPureHit', 'stabPure', 'FleshStab', 'FleshHit', 'metallicPunchyFleshHit' } },
    { ARMOR.Light, WEAPON.HandToHand, nil, { 'FleshHit' } },
    { ARMOR.Unarmored, WEAPON.Blunt, nil, { 'metallicPunchyFleshHit' } },
    { ARMOR.Unarmored, WEAPON.LongBladeTwoHanded, THRUST, { 'FleshStab', 'FleshHit', 'metallicPunchyFleshHit' } },
    { ARMOR.Metal, WEAPON.LongBlade, nil, { 'armorHeavyBladePureHit' } },
    { ARMOR.Metal, nil, nil, { 'armorHeavyBladePureHit', 'armorHeavyBluntPureHit' } },
    { ARMOR.Bone, nil, nil, { 'cutPure', 'BoneHit' } },
    { ARMOR.Bone, WEAPON.Spear, THRUST, { 'stabPure', 'BoneHit' } },
    { ARMOR.Ghost, nil, nil, { 'cutPure' } },
    { ARMOR.Ghost, WEAPON.Spear, THRUST, { 'stabPure' } },
}
for _, c in ipairs(hitCases) do
    local seen = {}
    for _ = 1, 3000 do seen[api.playHit(c[1], 0.7, c[2], c[3])] = true end
    check(sameSet(seen, expected('hit', c[4])), string.format('playHit %s by %s%s: %s', c[1], c[2] or 'anything',
        c[3] == THRUST and ' thrust' or '', table.concat(c[4], ' + ')))
end
stub.reset()
api.playHit(ARMOR.Light, 0.3)
check(stub.filesPlayed[1].options.volume == 0.3 and #stub.stopped == 0, 'playHit plays at the volume given, stopping nothing')
check(not pcall(api.playHit, 'Chainmail') and not pcall(api.playHit, ARMOR.Heavy, 1, 'Swrod')
    and not pcall(api.playHit, ARMOR.Heavy, 1, WEAPON.Spear, 7), 'an unknown armor, weapon or attack type is an error')
check(not pcall(api.emit, 'Heavy Armor Hit', { attackType = 'stab' }) and not pcall(api.pickFile, 'Heavy Armor Hit', { attackType = 9 }),
    'so is a bad attack type for emit and pickFile')
stub.reset()
script.eventHandlers.CombatSoundsOverhaul_PlaySwing({ weapon = WEAPON.Spear, volume = 0.9, attackType = THRUST })
script.eventHandlers.CombatSoundsOverhaul_PlayHit({ armor = ARMOR.Heavy, volume = 0.4, weapon = WEAPON.Spear, attackType = THRUST })
local swingPlayed = table.remove(stub.filesPlayed, 1)
local eventHit = roles(0.4)
check(inSet(expected('swing', { 'bladeMetal', 'ringingBladeMetal' }), swingPlayed.file) and swingPlayed.options.volume == 0.9
    and armorRulesBroken(0.4) == nil and (#eventHit.main == 0
        or inSet(expected('hit', { 'armorHeavyBladePureHit', 'stabPure', 'metallicPunchyFleshHit' }), eventHit.main[1].file)),
    'the PlaySwing and PlayHit events do the same')

print('\n== play handlers ==')
-- A fresh copy, so the handlers added here don't stay on the main one
local h = loadScript(true)
local cso = h.interface
local seen = {}
cso.addOnPlayHandler(function(info) seen[#seen + 1] = info end)
stub.reset()
stub.rightHand = SWORD
stub.windUp('chop')
stub.enginePlays('Weapon Swish')
stub.release('chop')
local info = seen[1]
check(info and info.kind == 'swing' and info.tag == 'Weapon Swish' and info.weapon == 'LongBlade' and info.armor == nil
    and info.attackType == CHOP and info.via == 'release' and info.layered == false and info.file == lastFile(),
    'a handler hears about a swing before it plays, with its attack type')
seen = {}
stub.reset()
local main, under = nil, nil
for _ = 1, 50 do
    seen = {}
    stub.reset()
    stub.hit({ successful = true, damage = { health = 5 }, attacker = npc, weapon = W('AxeTwoHand'), type = CHOP, sourceType = 'melee' })
    stub.enginePlays('Health Damage')
    stub.enginePlays('Heavy Armor Hit')
    h.engineHandlers.onUpdate(0.016)
    for _, i in ipairs(seen) do
        if not i.layered then main = i elseif i.underneath then under = i end
    end
    if main and main.category == 'armorHeavyBladePureHit' and under then break end
    main, under = nil, nil
end
check(main and main.kind == 'hit' and main.tag == 'Heavy Armor Hit' and main.weapon == 'AxeTwoHanded' and main.armor == 'Heavy'
    and main.attackType == CHOP and main.via == 'hit' and main.category == 'armorHeavyBladePureHit',
    'and about a hit, with the weapon, armor, attack type and category')
check(under and under.layered and under.volume == 0.6 and (under.category == 'FleshHit' or under.category == 'metallicPunchyFleshHit'),
    'and about the flesh under it')
seen = {}
stub.reset()
stub.hit({ successful = true, damage = { health = 5 }, attacker = npc })
stub.enginePlays('Health Damage')
h.engineHandlers.onUpdate(0.016)
info = seen[1]
check(info and info.tag == 'Health Damage' and info.armor == 'Unarmored' and info.weapon == 'HandToHand' and info.layered == true
    and info.attackType == nil and info.category == 'FleshHit', 'a layer over the body hit says so; a punch has no attack type')
seen = {}
cso.playHit(cso.ARMOR.Metal, 0.6)
check(seen[1] and seen[1].tag == nil and seen[1].via == 'playHit' and seen[1].armor == 'Metal' and seen[1].volume == 0.6,
    'playHit goes through the handlers too')
cso.addOnPlayHandler(function(i) i.file = 'sound/custom.wav'; i.volume = 0.25; i.pitch = 1.5 end)
stub.reset()
cso.emit('Medium Armor Hit')
local allCustom = #stub.filesPlayed > 0
for _, p in ipairs(stub.filesPlayed) do
    allCustom = allCustom and p.file == 'sound/custom.wav' and p.options.volume == 0.25 and p.options.pitch == 1.5
end
check(allCustom, 'a handler can change the file, volume and pitch')
cso.addOnPlayHandler(function() return false end) -- the newest handler now stops everything
seen = {}
stub.reset()
stub.enginePlays('Heavy Armor Hit')
check(cso.emit('Heavy Armor Hit') == nil and #stub.filesPlayed == 0, 'a handler returning false stops the sound')
check(stub.stopped[1] == 'Heavy Armor Hit' and stub.playing['heavy armor hit'] == nil, 'the vanilla sound stays stopped')
check(#seen == 0, 'and the older handlers are skipped')
check(not pcall(cso.addOnPlayHandler, 'nope'), 'a handler has to be a function')
-- back to the main copy for what follows
script = loadScript(true)
api, onUpdate = script.interface, script.engineHandlers.onUpdate

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
check(#stub.filesPlayed >= 1 and isHit(stub.filesPlayed[1].file), 'armor hits are still swapped')
check(inSet(DEFAULT_FLESH, muted.interface.emit('Health Damage')), 'emit Health Damage still plays the layer')

print(string.format('\n%d checks, %d failures', checks, failures))
os.exit(failures == 0 and 0 or 1)
