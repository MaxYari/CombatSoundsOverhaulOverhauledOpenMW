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

- **Weapon Swish**, the swing of every melee and thrown attack, hand-to-hand included. It is swapped as the attack is released. A creature's own attacks, its claws and bites, keep the vanilla swish.
- **SwishS, SwishM, SwishL**, played by the `Sound: Swish` keys in creature attack animations, when the creature holds a weapon.
- **Light, Medium and Heavy Armor Hit**, whenever a hit lands on a piece of armor.

Every CSO sound plays at a slightly random pitch, between 0.85 and 1.

## How the sounds are picked

CSO's sounds are sorted by ear into groups, and each attack draws from every group that suits it.

**Swings, by weapon:**

- Short blades: sharp metallic whooshes.
- One-handed long blades: ringing blade whooshes and generic metallic ones.
- Maces and one-handed axes: heavy metallic whooshes.
- Two-handed swords, warhammers and battle axes: heavy metallic whooshes, plus the more generic heavy ones.
- Spears: generic heavy metallic whooshes.
- Staves: plain, metallic and generic heavy whooshes.
- Thrown weapons: sharp metallic and plain whooshes.
- Hand-to-hand: plain whooshes.

**Hits, by what they land on:**

- Heavy armor: heavy armor impacts, with a ringing blade impact added for blades.
- Medium armor: armor impacts.
- Light armor, an unarmored spot, or a creature of flesh and blood: flesh impacts for the weapon. Short blades slice and stab, long blades slice and cut, blunt weapons crunch and punch, spears stab, and fists punch. Everything else gets general flesh and punchy impacts.
- Dwemer machines count as heavy armor. Skeletons and ghosts have no sounds of their own yet, so they keep only the body hit.

## The body hit sound

Every hit that takes health also plays the body hit, "Health Damage" (`Sound\Fx\body hit.wav`), whether it lands on armor or not. This mod ships a simplified version of it in place of the vanilla one, and it always plays.

- On armor, CSO's impact replaces the vanilla armor sound and plays on top of the body hit.
- Where there's no armor, CSO's impact is layered on top of the body hit. The original CSO left those hits with the body hit alone.

## Differences from the original

- Sounds are picked for the weapon and for what it hits. The original drew any swing and any hit at random.
- Hits that don't land on armor get a CSO impact on top of the body hit.
- Hand-to-hand swings get plain CSO whooshes. The original left them vanilla.
- Armor hits are replaced whatever the struck actor holds. The original replaced them only on actors holding something in their right hand. It made that check on whoever the sound played on, and for a hit that is the one being hit.
- The sounds are found by listing CSO's `Sound\Fx\Item\CSOSwing` and `Sound\Fx\Item\CSOHit` folders and sorting them into groups by the number in their names. A few are left out:
  - `Swing6`, a near copy of `Swing5`.
  - `Hit41` to `Hit56`, `Hit69`, `Hit71`, `Hit80` and `Hit81`, armor impacts with flesh in them.
  - `Hit68`, `Hit97` and `Hit98`, which aren't sorted yet.
- Nothing listens for sounds any more, only for the engine's own attacks, animation keys and hits. So a vanilla swish or armor hit that another mod plays itself stays vanilla. Such a mod can use the interface below instead.

## For developers

Every NPC, creature and the player has `I.CombatSoundsOverhaul`. Pass it a vanilla sound id and CSO does what it does when it catches that sound: it stops the vanilla sound on that actor if it is playing, and plays a CSO sound picked for the attack in its place.

```lua
local I = require('openmw.interfaces')

I.CombatSoundsOverhaul.emit('Heavy Armor Hit')

-- A hit by a particular weapon, or a swing with one
I.CombatSoundsOverhaul.emit('Heavy Armor Hit', { weapon = someWarhammer })
I.CombatSoundsOverhaul.emit('Weapon Swish', { weapon = someDagger, volume = 0.8, pitch = 1.1 })

-- What a hit on no armor does: a CSO impact for the actor's body on top, the vanilla sound left alone
I.CombatSoundsOverhaul.emit('Health Damage')

-- A creature's own swing has no CSO sound; force draws from all of CSO's swings instead
I.CombatSoundsOverhaul.emit('Weapon Swish', { force = true })
```

- `emit(tag, options)` returns the path of the sound it played, or `nil` if it played nothing. `options` is optional and can hold:
  - `weapon` and `attacker`: what the attack is made with. Without them, a swing uses the actor's right hand, and a hit uses the general sounds for what it lands on.
  - `force`: play something even when CSO has no sound for the attack.
  - `volume` and `pitch`. The pitch is random between 0.85 and 1 otherwise.
- `TAGS` lists the ids CSO answers: `Weapon Swish`, `SwishS`, `SwishM`, `SwishL`, `Light Armor Hit`, `Medium Armor Hit`, `Heavy Armor Hit` and `Health Damage`, in any case.
- `pickFile(tag, options)` returns the CSO file `emit` would pick, without playing it.
- `setDebug(true)` prints every swap the actor makes to `openmw.log`, with:
  - what caught it,
  - what the attack was made with, for example `axe 2h`, `staff 2h`, `handToHand`, or `natural` for a creature's own attack,
  - what it landed on (the armor weight, or the actor's body),
  - the pitch.
- Scripts that can't reach the actor's interfaces, such as global scripts, can send it an event: `actor:sendEvent('CombatSoundsOverhaul_Emit', { tag = 'SwishL' })`.

To try it in game, open the console and type `luap` to work on the player, or click an NPC and type `luas` to work on that NPC. Then run `I.CombatSoundsOverhaul.emit('Heavy Armor Hit')`.

<!-- nexus-skip-section -->
## Working on the mod

The script can be exercised without starting the game. `tools/tests/` stubs the OpenMW Lua API and drives the script through swings, early releases, creature swish keys, armored and unarmored hits, the sounds each weapon and body draws from, and the interface:

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
