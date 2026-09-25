# Combat Sounds Overhaul Overhauled

A replacement script for [Combat Sounds Overhaul](https://www.nexusmods.com/morrowind/mods/53859) (CSO) by Jyggalagpuff. Swings and armor hits still play CSO's sounds, but:

- The sounds are picked for the weapon and for what it hits, rather than at random.
- It reacts to attacks and hits as they happen, rather than checking every actor for sounds every frame.

## Install

- Requires **OpenMW 0.51** or newer.
- Requires **[Combat Sounds Overhaul](https://www.nexusmods.com/morrowind/mods/53859) 2.0**. Keep it installed, because its sounds are played from there.
- Load this mod **below** CSO. There's nothing new to enable: CSO's plugin loads the replaced script.
- Remove the [CSO Optimization Patch](https://www.nexusmods.com/morrowind/mods/58744) if you have it. It replaces the same file.

New to OpenMW mods? [Read this first](https://modding-openmw.com/tips/installing-mods/).

## Settings

**Options → Scripts → Combat Sounds Overhaul Overhauled** has **Hit Volume** and **Swing Volume**, each from 0 to 1.

## What it does

- Weapon swishes and armor hit sounds are replaced with CSO's, at a slightly random pitch. Fists and creatures' claws and bites keep the vanilla swish.
- Hits that land on no armor get a CSO impact on top of the body hit.

**Swings:**

- **Daggers:** sharp metallic and ringing blade, 30% plain.
- **One-handed swords:** ringing blade and metallic blade, 30% plain.
- **Two-handed swords:** metallic blade, 30% plain.
- **Axes:** heavy metallic, 30% plain.
- **Maces, warhammers:** heavy metallic 50%, plain 50%.
- **Staves, spear chops and slashes:** plain 50%, metallic blade 40%, heavy metallic 10%.
- **Spear thrusts:** metallic blade and ringing blade, 30% plain.
- **Thrown weapons:** sharp metallic and plain.

**Hits:**

- **Flesh, light armor:** flesh impacts for the weapon, with slices for daggers, stabs for swords, thrusts and arrows, and punchy metallic ones for all but fists and arrows.
- **Medium and heavy armor:** an armor impact with the wearer's flesh sound under it, or a punchy metallic impact.
- **Dwemer machines:** heavy armor impacts.
- **Skeletons:** pure cuts, stabs or blunt hits, with bone hits.
- **Ghosts:** pure cuts, stabs or blunt hits.

Blades, axes, maces and warhammers also ring on top of a quarter of their hits, except thrusts.

## Creature sounds

Sounds in `Sound/Fx/Item/CSOOCreature/<Class>/`, from this or any later mod, play on top of every hit a creature of that class takes. The classes are:

- `Ghost`, `Skeleton` or `Metal`, from the creature's body.
- `Creatures`, `Daedra`, `Undead` or `Humanoid`, from its record.

When a creature has two classes, the one from its body is used if its folder has sounds. The folders start out empty.

## For developers

Every actor has `I.CombatSoundsOO`. It's per actor, so call it from a script attached after this one, on every actor it should affect.

```lua
local cso = I.CombatSoundsOO

cso.emit('Heavy Armor Hit', { weapon = someMace })  -- swap a vanilla sound, as CSO does when it catches one
cso.playSwing(cso.WEAPON.AxeTwoHanded, 0.8)         -- weapon, volume
cso.playHit(cso.ARMOR.Heavy, 1, cso.WEAPON.Blunt)   -- armor, volume, weapon, attack type

cso.setWeaponKind('my_katana', cso.WEAPON.LongBladeTwoHanded)  -- nil to undo
cso.addSwingGroupsHandler(function(recordId)
    if recordId == 'my_katar' then return { cso.SWING_GROUPS.sharpMetal } end
end)
cso.addOnPlayHandler(function(info)
    if info.weaponId == 'my_katar' then info.volume = info.volume * 0.75 end
    if info.file:find('hit69') then return false end  -- stop this one
end)
```

- `emit(tag, options)`: `tag` is one of `TAGS`, the vanilla sound ids CSO answers. `options` can hold `weapon`, `attacker`, `attackType`, `volume`, `pitch`, and `force` to play even when no group fits. It returns the file played, or `nil`. `pickFile(tag, options)` returns the file without playing it.
- `playSwing(weapon, volume, attackType)` and `playHit(armor, volume, weapon, attackType)` play a sound with no vanilla sound to replace. `WEAPON` and `ARMOR` are enums of names, and a misspelled name is an error.
- `setWeaponKind(recordId, weapon)` makes a weapon sound like another kind of `WEAPON`.
- `addSwingGroupsHandler(handler)` lets a weapon keep its kind but swing with other groups. The handler gets the weapon's record id and returns a list of `SWING_GROUPS`, or `nil` to leave the weapon to its kind. An empty list keeps the vanilla swish.
- `addOnPlayHandler(handler)` is called with `info` before every sound. `file`, `volume` and `pitch` can be changed. The volume settings apply on top. It also has `kind` ('swing' or 'hit'), `tag`, `weapon`, `weaponId`, `armor`, `attackType`, `category`, `layered`, `underneath` and `via`. Return `false` to stop the sound. The vanilla one stays stopped.
- `getBody()` and `getCreatureClasses()` say what the actor counts as. `setDebug(true)` logs every sound it plays.
- Global scripts can send the actor these events: `CombatSoundsOO_Emit` (`tag` plus `emit`'s options), `_PlaySwing`, `_PlayHit` and `_SetWeaponKind`, with the same arguments as fields.

To try it, click an NPC in the console, type `luas`, then run `I.CombatSoundsOO.emit('Heavy Armor Hit')`.

<!-- nexus-skip-section -->
## Working on the mod

Tests stub the OpenMW Lua API:

```sh
luajit tools/tests/test.lua
CSO_DIR="<path to>/CSO2.0" luajit tools/tests/test.lua   # with a real CSO install's sounds
```

The sound groups are `SWING_CATEGORIES` and `HIT_CATEGORIES` in `Scripts/CSO/SoundManager.lua`. To sort them by ear:

```sh
python3 tools/sound_sorting.py export   # copies into sorting/<swing|hit>/<group>/
python3 tools/sound_sorting.py import   # writes the folders back into the tables
```

A new group still needs adding to a `*_SOUNDS` table before it plays. `sorting/` is git-ignored.

A push to `main` runs the tests. A commit message starting with `[nexus]` also uploads to Nexus, as the first `version = ...` in the script. Before the first release, fill in the Nexus ids in `.github/workflows/nexus-release.yml` and add the `NEXUSMODS_API_KEY` secret. Enable the README → BBCode hook with `git config core.hooksPath .githooks`.

## Credits

[Combat Sounds Overhaul](https://www.nexusmods.com/morrowind/mods/53859) and its sounds are by Jyggalagpuff, made from Impact Sounds. The script is by Max Yari.
