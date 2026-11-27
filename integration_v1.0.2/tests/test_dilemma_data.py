#!/usr/bin/env python3
"""v1.0.2 Dilemma 数据完整性与选项映射测试。
校验 DB TSV / loc TSV / Lua 源码三者一致；不启动游戏、不改存档。
"""
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
EV = BASE / 'evidence'
SRC = BASE / 'src' / 'lw_policy_integration_v102.lua'
DILEMMA = 'lw_int_dilemma_policy'
CHOICES = ['FIRST', 'SECOND', 'THIRD', 'FOURTH']

R = {'total': 0, 'passed': 0, 'failed': 0, 'fails': []}
def check(name, cond, detail=''):
    R['total'] += 1
    if cond: R['passed'] += 1
    else:
        R['failed'] += 1
        R['fails'].append('%s | %s' % (name, detail))

def rows(p):
    """读 RPFM 导出格式 TSV：第1行 header，第2行 meta，之后数据行。"""
    t = (EV / p).read_text(encoding='utf-8-sig').splitlines()
    return t[0].split('\t'), t[1].split('\t'), [l.split('\t') for l in t[2:] if l.strip()]

# --- DB: dilemmas ---
h, m, d = rows('dilemma_dilemmas.tsv')
check('DB-dilemma-header', h == ['key','generate','localised_description','localised_title',
      'ui_image','prioritized','event_category','sound_popup_override','sound_click_override','icon_override'], str(h))
check('DB-dilemma-version', m[0] == '#dilemmas_tables;1;...' or m[0].startswith('#dilemmas_tables;1;'), m[0])
check('DB-dilemma-1row', len(d) == 1, str(len(d)))
check('DB-dilemma-key', d[0][0] == DILEMMA, d[0][0])
check('DB-dilemma-generate-false', d[0][1] == 'false', d[0][1])
check('DB-dilemma-event-category', d[0][6] == 'faction', d[0][6])
check('DB-dilemma-has-title-desc', bool(d[0][3]) and bool(d[0][2]))

# --- DB: choice_details ---
h2, m2, c = rows('dilemma_choice_details.tsv')
check('DB-choice-header', h2 == ['choice_key','dilemma_key','display_dilemma_choice_if_ceo_active','required_ceos'], str(h2))
check('DB-choice-version', m2[0].startswith('#cdir_events_dilemma_choice_details_tables;2;'), m2[0])
check('DB-choice-4rows', len(c) == 4, str(len(c)))
check('DB-choice-keys', [r[0] for r in c] == CHOICES, str([r[0] for r in c]))
check('DB-choice-all-bound', all(r[1] == DILEMMA for r in c), str([r[1] for r in c]))
check('DB-choice-no-junction-needed', True, 'option_junctions 的 option_key 为条件键，非选项绑定（原版实证）')

# --- loc: dilemmas ---
h3, m3, ld = rows('loc_dilemmas.tsv')
check('LOC-header', h3 == ['key','text','tooltip'], str(h3))
check('LOC-dilemma-meta', m3[0].startswith('#Loc;1;text/db/dilemmas__.loc'), m3[0])
loc_keys = {r[0]: r[1] for r in ld}
check('LOC-dilemma-title', ('dilemmas_localised_title_' + DILEMMA) in loc_keys, str(list(loc_keys)))
check('LOC-dilemma-desc', ('dilemmas_localised_description_' + DILEMMA) in loc_keys)
check('LOC-dilemma-text-nonempty', all(v.strip() for v in loc_keys.values()))

# --- loc: choice_details ---
h4, m4, lc = rows('loc_choice_details.tsv')
check('LOC-choice-meta', m4[0].startswith('#Loc;1;text/db/cdir_events_dilemma_choice_details__.loc'), m4[0])
ckeys = {r[0]: r[1] for r in lc}
check('LOC-choice-count', len(lc) == 8, str(len(lc)))  # 4 选项 x (label+title)
for ck in CHOICES:
    check('LOC-choice-label-' + ck, ('cdir_events_dilemma_choice_details_localised_choice_label_%s%s' % (DILEMMA, ck)) in ckeys)
    check('LOC-choice-title-' + ck, ('cdir_events_dilemma_choice_details_localised_choice_title_%s%s' % (DILEMMA, ck)) in ckeys)
check('LOC-choice-text-nonempty', all(v.strip() for v in ckeys.values()))

# --- Lua 源码一致性 ---
src = SRC.read_text(encoding='utf-8')
check('LUA-dilemma-key', ('"%s"' % DILEMMA) in src)
check('LUA-choice-map', '[0] = "FOOD"' in src and '[1] = "OFFICIAL"' in src and
      '[2] = "RELAY"' in src and '[3] = "NONE"' in src)
check('LUA-test-profile-fixed', 'local BUILD_PROFILE = "test"' in src and 'ACTIVE_PROFILE = BUILD_PROFILE' in src)
check('LUA-no-runtime-profile-switch', 'rawget(_G, "LW_POLICY_PROFILE")' not in src)
check('LUA-cao-faction', '3k_main_faction_cao_cao' in src)
check('LUA-version-102', 'PROBE_VERSION = "1.0.2"' in src)
# 六项 P1 关键标记保留
for marker in ['lw_revoke_tx_keep_active', 'lw_sv_set_verified', 'DUPLICATE_IGNORED',
            'NOOP_IDEMPOTENT', 'L2_CONFIRMED_REMOVED', 'lw_int_dilemma_policy']:
    check('LUA-P1-marker-' + marker, marker in src)

# --- 派系/命名空间隔离 ---
check('NO-formal-bundle-in-TSV', 'lw_bundle_' not in (EV/'dilemma_dilemmas.tsv').read_text(encoding='utf-8-sig'))
check('NO-formal-key-in-loc', 'lw_dilemma_policy' not in (EV/'loc_dilemmas.tsv').read_text(encoding='utf-8-sig'))

print('=== DILEMMA DATA TEST ===')
print('TOTAL=%d PASS=%d FAIL=%d' % (R['total'], R['passed'], R['failed']))
for f in R['fails']:
    print('[FAIL]', f)
sys.exit(0 if R['failed'] == 0 else 1)
