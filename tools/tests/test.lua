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
_G.require = function(name) return stub.packages[name] or realRequire(name) end
local script = assert(loadfile(SCRIPT))()
_G.require = realRequire

local api = script.interface
local onUpdate = script.engineHandlers.onUpdate

local function lastFile() local p = stub.filesPlayed[#stub.filesPlayed]; return p and p.file end
local function isSwing(f) return f ~= nil and f:find('^sound/fx/item/csoswing/') ~= nil end
local function isHit(f) return f ~= nil and f:find('^sound/fx/item/csohit/') ~= nil end
local SWORD = { recordId = 'iron longsword' }

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
stub.reset()
stub.hit({ successful = true, damage = { health = 10 } })
stub.enginePlays('Health Damage') -- the roll landed on an unarmored slot
onUpdate(0.016)
check(#stub.filesPlayed == 0 and #stub.stopped == 0, 'an unarmored hit only has the vanilla Health Damage')
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
check(api.emit('Health Damage') == nil and api.emit('nonsense') == nil, 'tags CSO does not replace play nothing')
check(not pcall(api.emit, nil), 'a missing tag is an error')
check(isSwing(api.pickFile('SwishL')) and api.pickFile('miss') == nil, 'pickFile')
check(#api.TAGS == 7, 'TAGS lists the seven vanilla sounds')
stub.reset()
stub.rightHand = SWORD
script.eventHandlers.CombatSoundsOverhaul_Emit({ tag = 'SwishS' })
check(isSwing(lastFile()), 'the CombatSoundsOverhaul_Emit event does the same')

print('\n== the sound lists ==')
local swings, hits = {}, {}
for _ = 1, 3000 do swings[api.pickFile('SwishM')] = true; hits[api.pickFile('Light Armor Hit')] = true end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
check(count(swings) == 26, 'all 26 swings come up (' .. count(swings) .. ')')
check(count(hits) == 102, 'all 102 hits come up (' .. count(hits) .. ')')

print(string.format('\n%d checks, %d failures', checks, failures))
os.exit(failures == 0 and 0 or 1)
