#!/usr/bin/env python3
"""Sort CSO's sounds by ear as folders of copies, and write the result back into the script.

    python3 tools/sound_sorting.py export [--cso PATH]   # copy CSO's sounds into sorting/, one folder per category
    python3 tools/sound_sorting.py import                # read sorting/ back into SWING_CATEGORIES / HIT_CATEGORIES

sorting/swing/<category>/SwingN.wav and sorting/hit/<category>/HitN.wav are copies to move between folders; the
number in the name is what counts. A new folder is a new category, and _unused holds the files in none, which
never play. When a category's folder is renamed, split or merged, the *_SOUNDS, *_CHANCES and *_SHARES tables are
pointed at wherever its files went, and each change is printed to check. The game never reads sorting/, and git
ignores it: the script keeps playing CSO's own files, picked by the categories import writes into
Scripts/CSO/SoundManager.lua. A category's comment there is kept, and a new one
is added at the end of its table, so it still has to be put in a *_SOUNDS table to be heard.

--cso is CSO's data folder (the one with Sound/Fx/Item/CSOHit); without it, a folder next to this mod that has one
is used.
"""

import argparse
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, 'Scripts', 'CSO', 'SoundManager.lua')
TESTS = os.path.join(ROOT, 'tools', 'tests', 'test.lua')
SORTING = os.path.join(ROOT, 'sorting')
UNUSED = '_unused'
KINDS = {  # sorting/ folder -> (CSO folder, file prefix, Lua table)
    'swing': ('CSOSwing', 'swing', 'SWING_CATEGORIES'),
    'hit': ('CSOHit', 'hit', 'HIT_CATEGORIES'),
}
# Categories the script fills from elsewhere, e.g. the vanilla swing sounds, so they have no folder
BUILTIN = {'swing': {'vanilla'}, 'hit': set()}
SOUND = re.compile(r'^(swing|hit)(\d+)\.(wav|mp3|ogg|flac)$', re.I)
CATEGORY_LINE = re.compile(r'^(\s*)([A-Za-z_]\w*) = \{(.*)\},(\s*)(--.*)?$')


def table_span(lines, table):
    start = next(i for i, l in enumerate(lines) if l.startswith(f'local {table} = {{'))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith('}'))
    return start, end


def parse_entries(text):
    numbers = set()
    for a, b in re.findall(r'\{\s*(\d+)\s*,\s*(\d+)\s*\}', text):
        numbers.update(range(int(a), int(b) + 1))
    for n in re.findall(r'\d+', re.sub(r'\{[^{}]*\}', '', text)):
        numbers.add(int(n))
    return numbers


def format_entries(numbers):
    runs, out = [], []
    for n in sorted(numbers):
        if runs and n == runs[-1][1] + 1:
            runs[-1][1] = n
        else:
            runs.append([n, n])
    for a, b in runs:
        if b - a >= 2:
            out.append(f'{{ {a}, {b} }}')
        else:
            out.extend(str(n) for n in range(a, b + 1))
    return '{ ' + ', '.join(out) + ' }'


def read_categories(lines, table):
    start, end = table_span(lines, table)
    categories = {}
    for line in lines[start + 1:end]:
        m = CATEGORY_LINE.match(line)
        if m:
            categories[m.group(2)] = parse_entries(m.group(3))
    return categories


def find_cso(given):
    if given:
        return given
    parent = os.path.dirname(ROOT)
    for name in sorted(os.listdir(parent)):
        if 'combat sounds overhaul' not in name.lower() or os.path.join(parent, name) == ROOT:
            continue
        for dirpath, dirnames, _ in os.walk(os.path.join(parent, name)):
            if os.path.basename(dirpath).lower() == 'csohit':
                return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(dirpath))))
    sys.exit('Could not find Combat Sounds Overhaul next to this mod, pass --cso <its data folder>')


def cso_files(cso, folder):
    """number -> path of CSO's sounds in Sound/Fx/Item/<folder>, whatever the case of the path"""
    here = cso
    for part in ('sound', 'fx', 'item', folder.lower()):
        match = [d for d in os.listdir(here) if d.lower() == part]
        if not match:
            sys.exit(f'No {folder} folder under {cso}')
        here = os.path.join(here, match[0])
    files = {}
    for name in os.listdir(here):
        m = SOUND.match(name)
        if m:
            files[int(m.group(2))] = os.path.join(here, name)
    return files


def export(cso):
    if os.path.isdir(SORTING) and any(os.scandir(SORTING)):
        sys.exit(f'{SORTING} is not empty - move it away first, so no sorting is lost')
    lines = open(SCRIPT, encoding='utf-8').read().split('\n')
    for kind, (folder, _, table) in KINDS.items():
        categories = read_categories(lines, table)
        files = cso_files(cso, folder)
        placed = set()
        for category, numbers in categories.items():
            for n in sorted(numbers):
                if n not in files:
                    print(f'warning: {table}.{category} lists {n}, which CSO has no file for')
                    continue
                dest = os.path.join(SORTING, kind, category)
                os.makedirs(dest, exist_ok=True)
                shutil.copy2(files[n], dest)
                placed.add(n)
        for n in sorted(set(files) - placed):
            dest = os.path.join(SORTING, kind, UNUSED)
            os.makedirs(dest, exist_ok=True)
            shutil.copy2(files[n], dest)
        print(f'{kind}: {len(files)} files, {len(categories)} categories, {len(set(files) - placed)} in {UNUSED}')


def read_sorting(kind):
    base = os.path.join(SORTING, kind)
    if not os.path.isdir(base):
        sys.exit(f'No {base} - run export first')
    categories, seen = {}, {}
    for category in sorted(os.listdir(base)):
        path = os.path.join(base, category)
        if not os.path.isdir(path):
            continue
        for name in os.listdir(path):
            m = SOUND.match(name)
            if not m:
                continue
            n = int(m.group(2))
            seen.setdefault(n, []).append(category)
            if category != UNUSED:
                categories.setdefault(category, set()).add(n)
        if category != UNUSED and not re.match(r'^[A-Za-z_]\w*$', category):
            sys.exit(f'{path}: a category folder needs a name Lua can use (letters, digits, _)')
    return categories, seen


def follow(old, categories):
    """old category that has no folder now -> the categories holding its files now, most of them first"""
    moved = {}
    for name in set(old) - set(categories):
        counts = {new: len(old[name] & numbers) for new, numbers in categories.items()}
        moved[name] = sorted((n for n, c in counts.items() if c), key=lambda n: (-counts[n], n))
    return moved


def renamed(old, categories, moved):
    """new category -> the old one it's a rename of: that old one's files all went there and make most of it"""
    renames = {}
    for name, into in moved.items():
        if len(into) == 1 and into[0] not in old and len(old[name] & categories[into[0]]) * 2 > len(categories[into[0]]):
            renames.setdefault(into[0], name)
    return renames


def rewrite(lines, table, categories, renames):
    start, end = table_span(lines, table)
    out, written = [], set()
    old_to_new = {o: n for n, o in renames.items()}
    for line in lines[start + 1:end]:
        m = CATEGORY_LINE.match(line)
        if not m:
            out.append(line)
            continue
        indent, name, _, gap, comment = m.groups()
        if name in old_to_new:
            # renamed: same place, but the comment described the old name
            name, comment = old_to_new[name], None
        elif name not in categories:
            continue
        code = f'{indent}{name} = {format_entries(categories[name])},'
        if comment:
            column = len(line) - len(comment)
            code = code + ' ' * max(1, column - len(code)) + comment
        out.append(code)
        written.add(name)
    indent = next((CATEGORY_LINE.match(l).group(1) for l in lines[start + 1:end] if CATEGORY_LINE.match(l)), '    ')
    for name in sorted(set(categories) - written):
        out.append(f'{indent}{name} = {format_entries(categories[name])},')
    return lines[:start + 1] + out + lines[end:]


SOUNDS_TABLE = re.compile(r'^local (\w+_SOUNDS) = \{')
SOUNDS_LINE = re.compile(r"^(\s*)(\w+) = \{([^{}]*)\},(\s*--.*)?$")
CHANCES_TABLE = re.compile(r'^local (\w+_CHANCES) = \{')
CHANCES_LINE = re.compile(r'^(\s*)(\w+) = ([\d.]+),(\s*--.*)?$')
SHARES_TABLE = re.compile(r'^local (\w+_SHARES) = \{')
SHARES_LINE = re.compile(r'^(\s*)(\w+) = \{([^{}]*)\},(\s*--.*)?$')
SHARE = re.compile(r'(\w+) = ([\d.]+)')


def follow_shares(key, body, moved, table):
    """A *_SHARES line's groups where they went: a split's share is divided between its parts"""
    shares = []
    for name, share in SHARE.findall(body):
        into = moved.get(name, [name])
        if into != [name]:
            print(f'  {table}.{key}.{name} -> {", ".join(into) or "nothing"}')
        for new in into:
            shares.append((new, round(float(share) / len(into), 3)))
    return shares


def follow_references(lines, moved_by_kind):
    """Point the *_SOUNDS tables at where the categories they name went, and the *_CHANCES and *_SHARES ones too"""
    out, table, chances, shares = [], None, None, None
    for line in lines:
        m = SHARES_TABLE.match(line)
        if m:
            shares = m.group(1)
        elif shares and line.startswith('}'):
            shares = None
        m = SHARES_LINE.match(line) if shares else None
        if m:
            indent, key, body, comment = m.groups()
            moved = moved_by_kind['swing' if shares.startswith('SWING') else 'hit']
            after = follow_shares(key, body, moved, shares)
            inner = ', '.join(f'{n} = {v:g}' for n, v in after)
            out.append(f'{indent}{key} = {{ {inner} }},' + (comment or '') if after else f'{indent}{key} = {{}},' + (comment or ''))
            continue
        m = CHANCES_TABLE.match(line)
        if m:
            chances = m.group(1)
        elif chances and line.startswith('}'):
            chances = None
        m = CHANCES_LINE.match(line) if chances else None
        if m:
            indent, name, chance, comment = m.groups()
            moved = moved_by_kind['swing' if chances.startswith('SWING') else 'hit']
            into = moved.get(name, [name])
            if into != [name]:
                print(f'  {chances}.{name} -> {", ".join(into) or "nothing"}')
            for new in into:
                out.append(f'{indent}{new} = {chance},' + (comment or ''))
            continue
        m = SOUNDS_TABLE.match(line)
        if m:
            table = m.group(1)
        elif table and line.startswith('}'):
            table = None
        m = SOUNDS_LINE.match(line) if table else None
        if not m:
            out.append(line)
            continue
        indent, key, names, comment = m.groups()
        moved = moved_by_kind['swing' if table == 'SWING_SOUNDS' else 'hit']
        before = re.findall(r"'(\w+)'", names)
        after = []
        for name in before:
            for new in moved.get(name, [name]):
                if new not in after:
                    after.append(new)
        if after == before:
            out.append(line)
            continue
        print(f'  {table}.{key}: {", ".join(before)} -> {", ".join(after) or "nothing"}')
        code = f"{indent}{key} = {{ {', '.join(repr(n) for n in after)} }}," if after else f'{indent}{key} = {{}},'
        out.append(code + (comment or ''))
    return out


def used_categories(lines):
    """kind -> the category names the *_SOUNDS tables use"""
    used, table = {'swing': set(), 'hit': set()}, None
    for line in lines:
        m = SOUNDS_TABLE.match(line)
        if m:
            table = m.group(1)
        elif table and line.startswith('}'):
            table = None
        elif table:
            used['swing' if table == 'SWING_SOUNDS' else 'hit'].update(re.findall(r"'(\w+)'", line))
    return used


def import_():
    lines = open(SCRIPT, encoding='utf-8').read().split('\n')
    before = list(lines)
    moved_by_kind, sorted_by_kind, all_renames = {}, {}, {}
    for kind, (_, prefix, table) in KINDS.items():
        categories, seen = read_sorting(kind)
        sorted_by_kind[kind] = categories
        for n, where in sorted(seen.items()):
            if len(where) > 1:
                print(f'  {prefix.capitalize()}{n} is in {", ".join(where)}' +
                      (' - it will be in all of those' if UNUSED not in where else f' - and in {UNUSED}, which it ignores'))
        old = read_categories(lines, table)
        moved = follow(old, categories)
        renames = renamed(old, categories, moved)
        all_renames.update({o: n for n, o in renames.items()})
        moved_by_kind[kind] = moved
        for name in sorted(set(old) & set(categories)):
            added, removed = categories[name] - old[name], old[name] - categories[name]
            if added or removed:
                print(f'  {table}.{name}:' + (f' + {sorted(added)}' if added else '') + (f' - {sorted(removed)}' if removed else ''))
        for name, into in sorted(moved.items()):
            if name in renames.values():
                new = next(n for n, o in renames.items() if o == name)
                extra = categories[new] - old[name]
                gone = old[name] - categories[new]
                print(f'  {table}.{name} renamed {new}' + (f', + {sorted(extra)}' if extra else '') +
                      (f', - {sorted(gone)}' if gone else ''))
            elif into:
                print(f'  {table}.{name}: its files went to {", ".join(into)}')
            else:
                print(f'  {table}.{name}: all its files are in {UNUSED}, gone')
        lines = rewrite(lines, table, categories, renames)
    lines = follow_references(lines, moved_by_kind)
    used = used_categories(lines)
    for kind, categories in sorted_by_kind.items():
        for name in sorted(set(categories) - used[kind]):
            print(f'  {name} ({kind}) is in no *_SOUNDS table, so nothing plays it yet')
        for name in sorted(used[kind] - set(categories) - BUILTIN[kind]):
            print(f'  warning: a *_SOUNDS table uses {name} ({kind}), which has no folder')
    if lines == before:
        print('No changes')
        return
    open(SCRIPT, 'w', encoding='utf-8').write('\n'.join(lines))
    print(f'Wrote {os.path.relpath(SCRIPT, ROOT)}')
    # A rename changes nothing that plays, so the tests follow it too. Splits and merges do, and are left to a person.
    if all_renames and os.path.exists(TESTS):
        tests = open(TESTS, encoding='utf-8').read()
        renamed_tests = re.sub(r"'(\w+)'", lambda m: "'" + all_renames.get(m.group(1), m.group(1)) + "'", tests)
        if renamed_tests != tests:
            open(TESTS, 'w', encoding='utf-8').write(renamed_tests)
            print(f'Renamed them in {os.path.relpath(TESTS, ROOT)} too')


def main():
    ap = argparse.ArgumentParser(description='Sort CSO sounds as folders, and write the folders back as categories.')
    ap.add_argument('command', choices=['export', 'import'])
    ap.add_argument('--cso', help="Combat Sounds Overhaul's data folder, the one with Sound/Fx/Item/CSOHit")
    args = ap.parse_args()
    if args.command == 'export':
        export(find_cso(args.cso))
    else:
        import_()


if __name__ == '__main__':
    main()
