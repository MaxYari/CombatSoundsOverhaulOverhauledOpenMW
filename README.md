# Combat Sounds Overhaul - Event Driven

A drop-in replacement for the script of [Combat Sounds Overhaul](https://www.nexusmods.com/morrowind/mods/53859) (CSO) by Jyggalagpuff. It uses the same sounds and does the same job: weapon swings and armor hits play CSO's randomized sounds instead of the vanilla ones.

The difference is in how it notices them. The original checked every actor, every frame, for any of seven vanilla sounds. This version reacts to the attack animations and hit events that make the engine play those sounds, and does nothing in between.

## How to install

- **Requires OpenMW 0.51 or newer.**
- **Requires [Combat Sounds Overhaul](https://www.nexusmods.com/morrowind/mods/53859) 2.0**, installed and enabled as usual. This mod plays CSO's sounds from where CSO installs them, so CSO must stay installed.
- Add this mod's folder to your data folders **below** Combat Sounds Overhaul, so that its `Scripts/CSO/SoundManager.lua` replaces CSO's. There is nothing new to enable in Content Files, because CSO's own plugin loads the replaced script.
- If you have the [Combat Sounds Overhaul - Optimization Patch](https://www.nexusmods.com/morrowind/mods/58744), remove it. Both replace the same file, so only the one lower in the list takes effect.

If this is your first OpenMW mod, [read this first](https://modding-openmw.com/tips/installing-mods/).

## What gets replaced

- **Weapon Swish**, the swing of any melee or thrown attack, when the attacker holds something in their right hand. It is swapped as the attack is released.
- **SwishS, SwishM, SwishL**, played by the `Sound: Swish` keys in creature attack animations, when the creature holds something in its right hand.
- **Light, Medium and Heavy Armor Hit**, whenever a hit lands on a piece of armor.

## The body hit sound

Every hit that takes health also plays the body hit, "Health Damage" (`Sound\Fx\body hit.wav`), whether it lands on armor or not. This mod ships a simplified version of it in place of the vanilla one, and it always plays.

- On armor, one of CSO's hits plays on top of it.
- On an unarmored spot or a creature, one of CSO's fleshy impacts (`Hit1` to `Hit17`) plays on top of it. The original CSO left these hits with the vanilla sound alone.

## Differences from the original

- Hits that don't land on armor get a fleshy CSO impact on top of the body hit.
- Armor hits are replaced whatever the struck actor holds. The original replaced them only on actors holding something in their right hand. It made that check on whoever the sound played on, and for a hit that is the one being hit.
- The sounds are found by listing CSO's `Sound\Fx\Item\CSOSwing` and `Sound\Fx\Item\CSOHit` folders, so any sound file added there joins the rotation.
- Nothing listens for sounds any more, only for the engine's own attacks, animation keys and hits. So a vanilla swish or armor hit that another mod plays itself stays vanilla. Such a mod can use the interface below instead.

## For developers

Every NPC, creature and the player has `I.CombatSoundsOverhaul`. Pass it a vanilla sound id and CSO does what it does when it catches that sound: it stops the vanilla sound on that actor if it is playing, and plays a random CSO sound in its place.

```lua
local I = require('openmw.interfaces')

I.CombatSoundsOverhaul.emit('Heavy Armor Hit')
I.CombatSoundsOverhaul.emit('Weapon Swish', { volume = 0.8, pitch = 1.1 })

-- What an unarmored hit does: a fleshy CSO impact on top, the vanilla sound left alone
I.CombatSoundsOverhaul.emit('Health Damage')

-- Swing ids need something in the actor's right hand, the same as an engine swing.
-- force skips that check, e.g. for an unarmed attack you want a CSO swing for:
I.CombatSoundsOverhaul.emit('Weapon Swish', { force = true })
```

- `emit(tag, options)` returns the path of the sound it played, or `nil` if it played nothing. `options` is optional and can hold `force`, `volume` and `pitch`.
- `TAGS` lists the ids CSO answers: `Weapon Swish`, `SwishS`, `SwishM`, `SwishL`, `Light Armor Hit`, `Medium Armor Hit`, `Heavy Armor Hit` and `Health Damage`, in any case.
- `pickFile(tag)` returns a random CSO file for an id without playing it.
- `setDebug(true)` prints every swap the actor makes, along with what caught it.
- Scripts that can't reach the actor's interfaces, such as global scripts, can send it an event: `actor:sendEvent('CombatSoundsOverhaul_Emit', { tag = 'SwishL' })`.

To try it in game, open the console and type `luap` to work on the player, or click an NPC and type `luas` to work on that NPC. Then run `I.CombatSoundsOverhaul.emit('Heavy Armor Hit')`.

<!-- nexus-skip-section -->
## Working on the mod

The script can be exercised without starting the game. `tools/tests/` stubs the OpenMW Lua API and drives the script through swings, early releases, creature swish keys, armored and unarmored hits, and the interface:

```sh
luajit tools/tests/test.lua
CSO_DIR="<path to>/CSO2.0" luajit tools/tests/test.lua   # list the sounds from a real CSO install
```

`.github/workflows/nexus-release.yml` runs those tests on every push to `main`. It packs the mod and uploads it to Nexus only when the last commit's message starts with `[nexus]`. Before the first release, fill in `NEXUS_PAGE`, `NEXUSMODS_FILE_ID` and `NEXUSMODS_MOD_ID` at the top of that file, and add the `NEXUSMODS_API_KEY` repository secret. The version published is the first `version = ...` in `Scripts/CSO/SoundManager.lua`.

Enable the README → BBCode hook once per clone:

```sh
git config core.hooksPath .githooks
```

## Credits

[Combat Sounds Overhaul](https://www.nexusmods.com/morrowind/mods/53859) and its sounds are by Jyggalagpuff, made from the assets of Impact Sounds. This mod only replaces its script, and needs it installed. The event-driven script is by Max Yari.
