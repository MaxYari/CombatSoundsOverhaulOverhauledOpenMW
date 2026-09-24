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
-- Loads the script with the unarmored layer switched on or off, whatever it ships with.
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

local function lastFile() local p = stub.filesPlayed[#stub.filesPlayed]; return p and p.file end
local function isSwing(f) return f ~= nil and f:find('^sound/fx/item/csoswing/') ~= nil end
local function isHit(f) return f ~= nil and f:find('^sound/fx/item/csohit/') ~= nil end
-- flesh and punchy flesh, the categories layered over unarmored hits
local function isUnarmored(f)
    local n = isHit(f) and tonumber(f:match('/hit(%d+)%.wav$'))
    return n ~= nil and ((n >= 1 and n <= 10) or (n >= 25 and n <= 29))
end
local SWORD = stub.weapon('iron longsword', 'LongBladeOneHand')

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
check(#stub.filesPlayed == 1 and isSwing(lastFile()), 'and a CSO swing plays')
check(lastFile() and not lastFile():find('%.txt$'), 'only sound files are picked')
onUpdate(0.016)
check(#stub.filesPlayed == 1, 'onUpdate does not swap it a second time')

print('\n== swing released before the wind-up reached "min attack" ==')
stub.reset()
stub.windUp('slash')
stub.enginePlays('Weapon Swish') -- released early: prepareHit now, release animation only later
onUpdate(0.016)
check(#stub.filesPlayed == 1 and isSwing(lastFile()), 'the swish is swapped in the same frame')
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

print('\n== nothing in the right hand ==')
stub.reset()
stub.rightHand = nil
stub.windUp('chop')
stub.enginePlays('Weapon Swish')
stub.release('chop')
onUpdate(0.016)
check(#stub.filesPlayed == 0 and #stub.stopped == 0, 'hand-to-hand keeps the vanilla swish')

print('\n== creature "Sound: SwishM" text keys ==')
stub.reset()
stub.rightHand = SWORD
stub.enginePlays('swishm')
stub.textKey('sound', 'swishm')
check(stub.stopped[1] == 'swishm' and isSwing(lastFile()), 'swapped for a CSO swing')
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

print('\n== armor hits ==')
for _, armed in ipairs({ true, false }) do
    stub.reset()
    stub.rightHand = armed and SWORD or nil
    stub.hit({ successful = true, damage = { health = 10 } })
    stub.enginePlays('Health Damage')  -- builtin onHit, after ours
    stub.enginePlays('Medium Armor Hit')
    onUpdate(0.016)
    local label = armed and 'armed' or 'unarmed'
    check(stub.stopped[1] == 'Medium Armor Hit' and #stub.filesPlayed == 1 and isHit(lastFile()),
        'the armor sound becomes a CSO hit (' .. label .. ' defender)')
    check(stub.playing['health damage'] == true, 'Health Damage keeps playing on top (' .. label .. ')')
end

print('\n== unarmored hits ==')
for _, armed in ipairs({ true, false }) do
    stub.reset()
    stub.rightHand = armed and SWORD or nil
    stub.hit({ successful = true, damage = { health = 10 } })
    stub.enginePlays('Health Damage') -- the roll landed on an unarmored slot, or on a creature
    onUpdate(0.016)
    local label = armed and 'armed' or 'unarmed'
    check(#stub.filesPlayed == 1 and isUnarmored(lastFile()), 'a fleshy CSO hit is layered on (' .. label .. ' defender)')
    check(#stub.stopped == 0 and stub.playing['health damage'] == true, 'over the vanilla Health Damage (' .. label .. ')')
end
stub.reset()
local attack = { successful = true, damage = { health = 0 } }
stub.hit(attack)
attack.damage.health = 4 -- the handlers after ours work on the same table
stub.enginePlays('Health Damage')
onUpdate(0.016)
check(#stub.filesPlayed == 1 and isUnarmored(lastFile()), 'the damage is read once every handler has had it')
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

print('\n== the interface ==')
stub.reset()
stub.rightHand = nil
check(isHit(api.emit('Heavy Armor Hit')), 'emit plays a CSO hit for an armor tag')
check(stub.stopped[1] == 'Heavy Armor Hit', 'and stops the vanilla one, as a real swap would')
check(isHit(api.emit('light armor hit')), 'tags are case insensitive')
check(api.emit('Weapon Swish') == nil, 'a swing tag needs something in the right hand')
check(isSwing(api.emit('Weapon Swish', { force = true, pitch = 1.3 })), 'unless forced')
check(stub.filesPlayed[#stub.filesPlayed].options.pitch == 1.3, 'volume and pitch are passed on')
stub.reset()
stub.enginePlays('Health Damage')
check(isUnarmored(api.emit('Health Damage')), 'emit Health Damage plays a fleshy CSO hit')
check(#stub.stopped == 0 and stub.playing['health damage'] == true, 'and leaves the vanilla one playing')
check(api.emit('Hand To Hand Hit') == nil and api.emit('nonsense') == nil, 'tags CSO does not answer play nothing')
check(not pcall(api.emit, nil), 'a missing tag is an error')
check(isSwing(api.pickFile('SwishL')) and api.pickFile('miss') == nil, 'pickFile')
check(#api.TAGS == 8, 'TAGS lists the eight vanilla sounds')
stub.reset()
stub.rightHand = SWORD
script.eventHandlers.CombatSoundsOverhaul_Emit({ tag = 'SwishS' })
check(isSwing(lastFile()), 'the CombatSoundsOverhaul_Emit event does the same')

print('\n== the sound lists ==')
local swings, hits, flesh = {}, {}, {}
for _ = 1, 3000 do
    swings[api.pickFile('SwishM')] = true
    hits[api.pickFile('Light Armor Hit')] = true
    flesh[api.pickFile('Health Damage')] = true
end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function all(t, pred) for k in pairs(t) do if not pred(k) then return false end end; return true end
check(count(swings) == 25 and not swings['sound/fx/item/csoswing/swing6.wav'],
    'all 25 swings come up, without Swing6, a near copy of Swing5 (' .. count(swings) .. ')')
check(count(hits) == 102, 'all 102 hits come up (' .. count(hits) .. ')')
check(count(flesh) == 15 and all(flesh, isUnarmored), 'unarmored hits get Hit1 to Hit10 and Hit25 to Hit29 (' .. count(flesh) .. ')')

print('\n== what the attack is made with, and the armor it lands on ==')
-- The debug line is where both show for now: nothing picks sounds by them yet.
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
local function hitBy(attack, armorTag)
    stub.reset()
    return logged(function()
        stub.hit(attack)
        if armorTag then stub.enginePlays(armorTag) end
        stub.enginePlays('Health Damage')
        onUpdate(0.016)
    end)
end
local swings = {
    { 'ShortBladeOneHand', 'shortBlade 1h' }, { 'LongBladeOneHand', 'longBlade 1h' },
    { 'LongBladeTwoHand', 'longBlade 2h' }, { 'BluntOneHand', 'blunt 1h' }, { 'BluntTwoClose', 'blunt 2h' },
    { 'BluntTwoWide', 'staff 2h' }, { 'SpearTwoWide', 'spear 2h' }, { 'AxeOneHand', 'axe 1h' },
    { 'AxeTwoHand', 'axe 2h' }, { 'MarksmanThrown', 'thrown 1h' },
}
for _, s in ipairs(swings) do
    local line = swingWith(stub.weapon('w', s[1]))
    check(line:find('(release, ' .. s[2] .. ')', 1, true) ~= nil, s[1] .. ' swings as ' .. s[2])
end
check(swingWith(stub.item('pick_apprentice_01')):find('(release, other)', 1, true) ~= nil,
    'something in the right hand that is not a weapon is other')
stub.rightHand = SWORD
local line = hitBy({ successful = true, damage = { health = 5 }, attacker = stub.npc(),
    weapon = stub.weapon('w', 'AxeTwoHand') }, 'Heavy Armor Hit')
check(line:find('Heavy Armor Hit', 1, true) and line:find('(hit, axe 2h, heavy armor)', 1, true),
    'a two-handed axe on heavy armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = stub.npc(),
    weapon = stub.weapon('w', 'ShortBladeOneHand') }, 'Light Armor Hit')
check(line:find('(hit, shortBlade 1h, light armor)', 1, true) ~= nil, 'a dagger on light armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = stub.npc(),
    weapon = stub.weapon('w', 'BluntOneHand') }, 'Medium Armor Hit')
check(line:find('(hit, blunt 1h, medium armor)', 1, true) ~= nil, 'a mace on medium armor')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = stub.npc() })
check(line:find('(unarmored hit, handToHand, no armor)', 1, true) ~= nil, 'a punch on an unarmored spot')
line = hitBy({ successful = true, damage = { health = 5 }, attacker = stub.creature() })
check(line:find('(unarmored hit, natural, no armor)', 1, true) ~= nil, "a creature's own attack")
line = hitBy({ successful = true, damage = { health = 5 }, attacker = stub.npc(),
    weapon = stub.weapon('w', 'MarksmanBow'), ammo = 'iron arrow' })
check(line:find('(unarmored hit, bow 2h, no armor)', 1, true) ~= nil, 'an arrow counts as its bow')
line = hitBy({ successful = true, damage = { health = 5 } })
check(line:find('(unarmored hit, no armor)', 1, true) ~= nil, 'a hit with no attacker and no weapon has neither')
stub.reset()
line = logged(function() api.emit('Medium Armor Hit') end)
check(line:find('(emit, medium armor)', 1, true) ~= nil, 'emit of an armor hit knows its armor')
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
check(isUnarmored(muted.interface.emit('Health Damage')), 'emit Health Damage still plays the layer')

print(string.format('\n%d checks, %d failures', checks, failures))
os.exit(failures == 0 and 0 or 1)
