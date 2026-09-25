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

- Medium and heavy armor: armor impacts with flesh or a crunch in them, since an armor hit only draws blood once it's through. A thrust with a blade or spear gets stabs with a metal ring among them, and everything else gets crunchy ones.
- Light armor, an unarmored spot, or a creature of flesh and blood: flesh impacts for the weapon:
  - Short blades: slices and flesh impacts.
  - Long blades: flesh impacts.
  - A thrust with a blade or spear: stabs. Blades keep their flesh impacts among them.
  - Blunt weapons: crunches and punches.
  - Fists: punches, crunches and flesh impacts.
  - Everything else, spears' swings included: flesh and punchy impacts.
- Dwemer machines get clean heavy armor clanks, with a ringing blade impact added for blades.
- Skeletons, liches and bonelords get plain metallic hits, or plain stabs for a thrust, whatever the weapon.
- Ghosts, spectres and spirits have no sounds of their own yet, so they keep only the body hit. The game gives ghosts the same bone dust as skeletons, so they're told apart by their name and model.

A thrust only counts as one for a melee attack made with a weapon.

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
  - `Hit18` to `Hit21`, `Hit30` to `Hit32` and `Hit57` to `Hit60`, plain armor clanks. The plain heavy clanks only play on Dwemer machines.
  - `Hit68`, `Hit97` and `Hit98`, which aren't sorted yet.
- Nothing listens for sounds any more, only for the engine's own attacks, animation keys and hits. So a vanilla swish or armor hit that another mod plays itself stays vanilla. Such a mod can use the interface below instead.

## For developers

Every NPC, creature and the player has `I.CombatSoundsOverhaul`. Everything it plays, plays on that actor.

### Swapping a vanilla sound

Pass `emit` a vanilla sound id, and CSO does what it does when it catches that sound: it stops the vanilla sound on that actor if it is playing, and plays a CSO sound picked for the attack in its place.

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
  - `attackType`: one of `I.Combat.ATTACK_TYPES`, for a hit. A thrust with a weapon picks the stabs.
  - `force`: play something even when CSO has no sound for the attack.
  - `volume` and `pitch`. The pitch is random between 0.85 and 1 otherwise.
- `TAGS` lists the ids CSO answers: `Weapon Swish`, `SwishS`, `SwishM`, `SwishL`, `Light Armor Hit`, `Medium Armor Hit`, `Heavy Armor Hit` and `Health Damage`, in any case.
- `pickFile(tag, options)` returns the CSO file `emit` would pick, without playing it.

### Playing a sound for a weapon or an armor

`playSwing` and `playHit` play a CSO sound straight away, without a vanilla sound to replace. What they play is chosen from two enums:

- `WEAPON`: `ShortBlade`, `LongBlade`, `LongBladeTwoHanded`, `Blunt`, `BluntTwoHanded` (warhammers), `Staff`, `Spear`, `Axe`, `AxeTwoHanded`, `Thrown`, `Bow`, `Crossbow`, `HandToHand`, and `Natural` for a creature's own attack.
- `ARMOR`: `Unarmored` (also a creature of flesh), `Light`, `Medium`, `Heavy`, `Metal` for a creature of metal like a Dwemer machine, `Bone` for skeletons, liches and bonelords, and `Ghost` for ghosts, spectres and spirits.

```lua
local cso = I.CombatSoundsOverhaul

cso.playSwing(cso.WEAPON.AxeTwoHanded, 0.8)       -- weapon, volume multiplier
cso.playHit(cso.ARMOR.Heavy, 1, cso.WEAPON.Blunt) -- armor, volume multiplier, and optionally the weapon
-- and optionally the attack type, one of I.Combat.ATTACK_TYPES
cso.playHit(cso.ARMOR.Unarmored, 1, cso.WEAPON.Spear, I.Combat.ATTACK_TYPES.Thrust)
```

- Both return the path of the sound played, or `nil` if nothing played. `Natural`, `Bow` and `Crossbow` have no swings, and `Ghost` has no hits yet.
- `getBody()` returns what the actor's body counts as when a hit lands on no armor: `Unarmored`, `Metal`, `Bone` or `Ghost`.
- The volume multiplier is 1 if left out. The pitch is random between 0.85 and 1.
- An unknown name is an error, and so is a misspelled enum field such as `cso.WEAPON.Swrod`.

### Hearing about a sound before it plays

`addOnPlayHandler(handler)` calls `handler(info)` just before every CSO sound the actor plays. That covers the swaps, `emit`, `playSwing` and `playHit`. Handlers run newest first, the same way as `I.Combat.addOnHitHandler`. Add yours from a script attached after this one.

`info` holds:

- `file`, `volume` and `pitch`: what is about to play. The handler can change any of them.
- `kind`: `'swing'` or `'hit'`.
- `tag`: the vanilla sound id it answers, or `nil` from `playSwing` and `playHit`.
- `weapon`: one of `WEAPON`, or `nil` if unknown.
- `armor`: one of `ARMOR`, for a hit.
- `attackType`: one of `I.Combat.ATTACK_TYPES`, for a hit by a melee weapon, or when one was asked for.
- `layered`: `true` when it plays on top of the vanilla body hit, rather than in place of a vanilla sound.
- `via`: what set it off. This is `release`, `early release`, `text key`, `hit`, `unarmored hit`, `emit`, `event`, `playSwing` or `playHit`.

Returning `false` stops the sound and skips the older handlers. A vanilla sound CSO was replacing stays stopped either way.

```lua
I.CombatSoundsOverhaul.addOnPlayHandler(function(info)
    if info.kind == 'hit' and info.weapon == I.CombatSoundsOverhaul.WEAPON.HandToHand then
        info.volume = info.volume * 0.5 -- softer punches
    end
    if info.file:find('hit69') then return false end -- never this one
end)
```

### From other scripts

Scripts that can't reach the actor's interface, such as global scripts, can send the actor an event:

- `CombatSoundsOverhaul_Emit`: `{ tag = 'SwishL' }`, plus any of `emit`'s options.
- `CombatSoundsOverhaul_PlaySwing`: `{ weapon = ..., volume = ... }`.
- `CombatSoundsOverhaul_PlayHit`: `{ armor = ..., volume = ..., weapon = ..., attackType = ... }`.

### Debugging

`setDebug(true)` prints every CSO sound the actor plays to `openmw.log`, with:

- what set it off,
- what the attack was made with, for example `axe 2h`, `staff 2h`, `handToHand`, or `natural` for a creature's own attack,
- what it landed on: the armor weight, or the actor's body,
- the pitch,
- whether a play handler stopped it.

To try it in game, open the console and type `luap` to work on the player, or click an NPC and type `luas` to work on that NPC. Then run `I.CombatSoundsOverhaul.emit('Heavy Armor Hit')` or `I.CombatSoundsOverhaul.playSwing('Staff', 1)`.

<!-- nexus-skip-section -->
## Working on the mod

The script can be exercised without starting the game. `tools/tests/` stubs the OpenMW Lua API and drives the script through swings, early releases, creature swish keys, armored and unarmored hits, the sounds each weapon and body draws from, the interface and its play handlers:

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
