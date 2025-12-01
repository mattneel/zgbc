"""
Pokemon Red RAM map functions - ported from pokegym.

All functions take a numpy array `ram` instead of `game` object.
This eliminates FFI overhead - all reads are pure numpy indexing.
"""

import numpy as np

# RAM addresses
HP_ADDR = [0xD16C, 0xD198, 0xD1C4, 0xD1F0, 0xD21C, 0xD248]
MAX_HP_ADDR = [0xD18D, 0xD1B9, 0xD1E5, 0xD211, 0xD23D, 0xD269]
PARTY_SIZE_ADDR = 0xD163
PARTY_ADDR = [0xD164, 0xD165, 0xD166, 0xD167, 0xD168, 0xD169]
PARTY_LEVEL_ADDR = [0xD18C, 0xD1B8, 0xD1E4, 0xD210, 0xD23C, 0xD268]
X_POS_ADDR = 0xD362
Y_POS_ADDR = 0xD361
MAP_N_ADDR = 0xD35E
BADGE_1_ADDR = 0xD356
WCUTTILE = 0xCD4D

# Reward weights
GYM_LEADER = 5
GYM_TRAINER = 2
GYM_TASK = 2
TRAINER = 1
HM = 5
TM = 2
TASK = 2
POKEMON = 3
ITEM = 5
BILL_CAPT = 5
RIVAL = 3
QUEST = 5
EVENT = 1
BAD = -1


def read_bit(ram: np.ndarray, addr: int, bit: int) -> bool:
    return bool((ram[addr] >> bit) & 1)


def read_uint16(ram: np.ndarray, addr: int) -> int:
    return int(ram[addr]) * 256 + int(ram[addr + 1])


def bit_count(val: int) -> int:
    return bin(val).count("1")


def position(ram: np.ndarray):
    r = int(ram[Y_POS_ADDR])
    c = int(ram[X_POS_ADDR])
    m = int(ram[MAP_N_ADDR])
    return min(max(r, 0), 444), min(max(c, 0), 444), min(max(m, -1), 247)


def party(ram: np.ndarray):
    size = int(ram[PARTY_SIZE_ADDR])
    levels = [int(ram[a]) for a in PARTY_LEVEL_ADDR if ram[a] > 0]
    return size, levels


def hp(ram: np.ndarray) -> float:
    party_hp = [read_uint16(ram, a) for a in HP_ADDR]
    party_max = [read_uint16(ram, a) for a in MAX_HP_ADDR]
    total = sum(party_max)
    return sum(party_hp) / total if total > 0 else 1.0


def badges(ram: np.ndarray) -> int:
    return bit_count(int(ram[BADGE_1_ADDR]))


def used_cut(ram: np.ndarray) -> int:
    return int(ram[WCUTTILE])


def get_items_in_bag(ram: np.ndarray):
    first_item = 0xD31E
    items = []
    for i in range(0, 40, 2):
        item_id = int(ram[first_item + i])
        if item_id == 0 or item_id == 0xFF:
            break
        items.append(item_id)
    return items


def get_hm_count(ram: np.ndarray) -> int:
    hm_ids = {0xC4, 0xC5, 0xC6, 0xC7, 0xC8}
    return len(hm_ids & set(get_items_in_bag(ram)))


# Event flags - all return weighted sums
def silph_co(ram: np.ndarray) -> int:
    return sum([
        TRAINER * int(read_bit(ram, 0xD825, i)) for i in range(2, 6)
    ] + [
        QUEST * int(read_bit(ram, 0xD826, 5)),
        QUEST * int(read_bit(ram, 0xD826, 6)),
        TRAINER * int(read_bit(ram, 0xD827, 2)),
        TRAINER * int(read_bit(ram, 0xD827, 3)),
        QUEST * int(read_bit(ram, 0xD828, 0)),
        QUEST * int(read_bit(ram, 0xD828, 1)),
        *[TRAINER * int(read_bit(ram, 0xD829, i)) for i in range(2, 5)],
        QUEST * int(read_bit(ram, 0xD82A, 0)),
        QUEST * int(read_bit(ram, 0xD82A, 1)),
        *[TRAINER * int(read_bit(ram, 0xD82B, i)) for i in range(2, 6)],
        *[QUEST * int(read_bit(ram, 0xD82C, i)) for i in range(3)],
        TRAINER * int(read_bit(ram, 0xD82D, 6)),
        TRAINER * int(read_bit(ram, 0xD82D, 7)),
        TRAINER * int(read_bit(ram, 0xD82E, 0)),
        QUEST * int(read_bit(ram, 0xD82E, 7)),
        *[TRAINER * int(read_bit(ram, 0xD82F, i)) for i in range(5, 8)],
        TRAINER * int(read_bit(ram, 0xD830, 0)),
        *[QUEST * int(read_bit(ram, 0xD830, i)) for i in range(4, 7)],
        *[TRAINER * int(read_bit(ram, 0xD831, i)) for i in range(2, 5)],
        QUEST * int(read_bit(ram, 0xD832, 0)),
        *[TRAINER * int(read_bit(ram, 0xD833, i)) for i in range(2, 5)],
        *[QUEST * int(read_bit(ram, 0xD834, i)) for i in range(4)],
        TRAINER * int(read_bit(ram, 0xD835, 1)),
        TRAINER * int(read_bit(ram, 0xD835, 2)),
        QUEST * int(read_bit(ram, 0xD836, 0)),
        TRAINER * int(read_bit(ram, 0xD837, 4)),
        TRAINER * int(read_bit(ram, 0xD837, 5)),
        QUEST * int(read_bit(ram, 0xD838, 0)),
        ITEM * int(read_bit(ram, 0xD838, 5)),
        GYM_LEADER * int(read_bit(ram, 0xD838, 7)),
        TASK * int(read_bit(ram, 0xD7B9, 7)),
    ])


def rock_tunnel(ram: np.ndarray) -> int:
    return sum([
        *[TRAINER * int(read_bit(ram, 0xD7D2, i)) for i in range(1, 8)],
        *[TRAINER * int(read_bit(ram, 0xD87D, i)) for i in range(1, 8)],
        TRAINER * int(read_bit(ram, 0xD87E, 0)),
    ])


def ssanne(ram: np.ndarray) -> int:
    return sum([
        TRAINER * int(read_bit(ram, 0xD7FF, 4)),
        TRAINER * int(read_bit(ram, 0xD7FF, 5)),
        *[BILL_CAPT * int(read_bit(ram, 0xD803, i)) for i in range(1, 6)],
        *[TRAINER * int(read_bit(ram, 0xD805, i)) for i in range(1, 5)],
        *[TRAINER * int(read_bit(ram, 0xD807, i)) for i in range(1, 5)],
        *[TRAINER * int(read_bit(ram, 0xD809, i)) for i in range(1, 7)],
    ])


def mtmoon(ram: np.ndarray) -> int:
    return sum([
        *[TRAINER * int(read_bit(ram, 0xD7F5, i)) for i in range(1, 8)],
        TRAINER * int(read_bit(ram, 0xD7F6, 1)),
        *[TRAINER * int(read_bit(ram, 0xD7F6, i)) for i in range(2, 6)],
        TASK * int(read_bit(ram, 0xD7F6, 6)),
        TASK * int(read_bit(ram, 0xD7F6, 7)),
    ])


def routes(ram: np.ndarray) -> int:
    total = 0
    # Route 3
    total += sum(TRAINER * int(read_bit(ram, 0xD7C3, i)) for i in range(2, 8))
    total += sum(TRAINER * int(read_bit(ram, 0xD7C4, i)) for i in range(2))
    # Route 4
    total += TRAINER * int(read_bit(ram, 0xD7C5, 2))
    # Route 24
    total += sum(TRAINER * int(read_bit(ram, 0xD7EF, i)) for i in range(1, 8))
    # Route 25
    total += sum(TRAINER * int(read_bit(ram, 0xD7F1, i)) for i in range(1, 8))
    total += sum(TRAINER * int(read_bit(ram, 0xD7F2, i)) for i in range(2))
    # Route 9
    total += sum(TRAINER * int(read_bit(ram, 0xD7CF, i)) for i in range(1, 8))
    total += sum(TRAINER * int(read_bit(ram, 0xD7D0, i)) for i in range(2))
    # Route 6
    total += sum(TRAINER * int(read_bit(ram, 0xD7C9, i)) for i in range(1, 7))
    # Route 11
    total += sum(TRAINER * int(read_bit(ram, 0xD7D5, i)) for i in range(1, 8))
    total += sum(TRAINER * int(read_bit(ram, 0xD7D6, i)) for i in range(3))
    # Route 8
    total += sum(TRAINER * int(read_bit(ram, 0xD7CD, i)) for i in range(1, 8))
    total += sum(TRAINER * int(read_bit(ram, 0xD7CE, i)) for i in range(2))
    # Route 10
    total += sum(TRAINER * int(read_bit(ram, 0xD7D1, i)) for i in range(1, 7))
    # Route 12
    total += sum(TRAINER * int(read_bit(ram, 0xD7D7, i)) for i in range(2, 8))
    total += TRAINER * int(read_bit(ram, 0xD7D8, 0))
    # Routes 13-21 (simplified)
    for base in [0xD7D9, 0xD7DB, 0xD7DD, 0xD7DF, 0xD7E1, 0xD7E3, 0xD7E5, 0xD7E7, 0xD7E9]:
        total += sum(TRAINER * int(read_bit(ram, base, i)) for i in range(1, 8))
    return total


def misc(ram: np.ndarray) -> int:
    return sum([
        TASK * int(read_bit(ram, 0xD7C6, 7)),
        TASK * int(read_bit(ram, 0xD747, 3)),
        TASK * int(read_bit(ram, 0xD74A, 2)),
        TASK * int(read_bit(ram, 0xD754, 1)),
        TASK * int(read_bit(ram, 0xD771, 1)),
        TASK * int(read_bit(ram, 0xD77E, 2)),
        TASK * int(read_bit(ram, 0xD77E, 3)),
        TASK * int(read_bit(ram, 0xD77E, 4)),
        TASK * int(read_bit(ram, 0xD783, 0)),
        TASK * int(read_bit(ram, 0xD7BF, 0)),
        TASK * int(read_bit(ram, 0xD7D6, 7)),
        TASK * int(read_bit(ram, 0xD7DD, 0)),
        TASK * int(read_bit(ram, 0xD7E0, 7)),
        TASK * int(read_bit(ram, 0xD85F, 1)),
        TASK * int(read_bit(ram, 0xD769, 7)),
    ])


def snorlax(ram: np.ndarray) -> int:
    return sum([
        POKEMON * int(read_bit(ram, 0xD7D8, 6)),
        POKEMON * int(read_bit(ram, 0xD7D8, 7)),
        POKEMON * int(read_bit(ram, 0xD7E0, 0)),
        POKEMON * int(read_bit(ram, 0xD7E0, 1)),
    ])


def hmtm(ram: np.ndarray) -> int:
    return sum([
        HM * int(read_bit(ram, 0xD803, 0)),
        HM * int(read_bit(ram, 0xD7E0, 6)),
        HM * int(read_bit(ram, 0xD857, 0)),
        HM * int(read_bit(ram, 0xD78E, 0)),
        HM * int(read_bit(ram, 0xD7C2, 0)),
        TM * int(read_bit(ram, 0xD755, 6)),
        TM * int(read_bit(ram, 0xD75E, 6)),
        TM * int(read_bit(ram, 0xD777, 0)),
        TM * int(read_bit(ram, 0xD778, 4)),
        TM * int(read_bit(ram, 0xD778, 5)),
        TM * int(read_bit(ram, 0xD778, 6)),
        TM * int(read_bit(ram, 0xD778, 7)),
        TM * int(read_bit(ram, 0xD77C, 0)),
        TM * int(read_bit(ram, 0xD792, 0)),
        TM * int(read_bit(ram, 0xD773, 6)),
        TM * int(read_bit(ram, 0xD7BD, 0)),
        TM * int(read_bit(ram, 0xD7AF, 0)),
        TM * int(read_bit(ram, 0xD7A1, 7)),
        TM * int(read_bit(ram, 0xD826, 7)),
        TM * int(read_bit(ram, 0xD79A, 0)),
        TM * int(read_bit(ram, 0xD751, 0)),
        TM * int(read_bit(ram, 0xD74C, 1)),
        TM * int(read_bit(ram, 0xD7B3, 0)),
        TM * int(read_bit(ram, 0xD7D7, 0)),
    ])


def bill(ram: np.ndarray) -> int:
    return sum([
        BILL_CAPT * int(read_bit(ram, 0xD7F1, 0)),
        BILL_CAPT * int(read_bit(ram, 0xD7F2, 3)),
        BILL_CAPT * int(read_bit(ram, 0xD7F2, 4)),
        BILL_CAPT * int(read_bit(ram, 0xD7F2, 5)),
        BILL_CAPT * int(read_bit(ram, 0xD7F2, 6)),
        BILL_CAPT * int(read_bit(ram, 0xD7F2, 7)),
    ])


def oak(ram: np.ndarray) -> int:
    return sum([
        TASK * int(read_bit(ram, 0xD74B, 7)),
        TASK * int(read_bit(ram, 0xD747, 0)),
        TASK * int(read_bit(ram, 0xD74B, 1)),
        TASK * int(read_bit(ram, 0xD74B, 2)),
        TASK * int(read_bit(ram, 0xD74B, 0)),
        QUEST * int(read_bit(ram, 0xD74B, 5)),
        QUEST * int(read_bit(ram, 0xD74E, 1)),
        QUEST * int(read_bit(ram, 0xD747, 6)),
        QUEST * int(read_bit(ram, 0xD74E, 0)),
        TASK * int(read_bit(ram, 0xD74B, 4)),
        TASK * int(read_bit(ram, 0xD74B, 6)),
    ])


def towns(ram: np.ndarray) -> int:
    return sum([
        TASK * int(read_bit(ram, 0xD74A, 0)),
        TASK * int(read_bit(ram, 0xD74A, 1)),
        TRAINER * int(read_bit(ram, 0xD7F3, 2)),
        TRAINER * int(read_bit(ram, 0xD7F3, 3)),
        TRAINER * int(read_bit(ram, 0xD7F3, 4)),
        TASK * int(read_bit(ram, 0xD7EF, 0)),
        TASK * int(read_bit(ram, 0xD7F0, 1)),
        TRAINER * int(read_bit(ram, 0xD75B, 7)),
        QUEST * int(read_bit(ram, 0xD75F, 0)),
        TASK * int(read_bit(ram, 0xD771, 6)),
        TASK * int(read_bit(ram, 0xD771, 7)),
        QUEST * int(read_bit(ram, 0xD76C, 0)),
    ])


def lab(ram: np.ndarray) -> int:
    return sum([
        TASK * int(read_bit(ram, 0xD7A3, i)) for i in range(3)
    ])


def mansion(ram: np.ndarray) -> int:
    return sum([
        TRAINER * int(read_bit(ram, 0xD847, 1)),
        TRAINER * int(read_bit(ram, 0xD849, 1)),
        TRAINER * int(read_bit(ram, 0xD849, 2)),
        TRAINER * int(read_bit(ram, 0xD84B, 1)),
        TRAINER * int(read_bit(ram, 0xD84B, 2)),
        QUEST * int(read_bit(ram, 0xD796, 0)),
        TRAINER * int(read_bit(ram, 0xD798, 1)),
    ])


def safari(ram: np.ndarray) -> int:
    return sum([
        QUEST * int(read_bit(ram, 0xD78E, 1)),
        EVENT * int(read_bit(ram, 0xD790, 6)),
        EVENT * int(read_bit(ram, 0xD790, 7)),
    ])


def dojo(ram: np.ndarray) -> int:
    return sum([
        BAD * int(read_bit(ram, 0xD7B1, 0)),
        GYM_LEADER * int(read_bit(ram, 0xD7B1, 1)),
        *[TRAINER * int(read_bit(ram, 0xD7B1, i)) for i in range(2, 6)],
        POKEMON * int(read_bit(ram, 0xD7B1, 6)),
        POKEMON * int(read_bit(ram, 0xD7B1, 7)),
    ])


def hideout(ram: np.ndarray) -> int:
    return sum([
        *[GYM_TRAINER * int(read_bit(ram, 0xD815, i)) for i in range(1, 6)],
        GYM_TRAINER * int(read_bit(ram, 0xD817, 1)),
        GYM_TRAINER * int(read_bit(ram, 0xD819, 1)),
        GYM_TRAINER * int(read_bit(ram, 0xD819, 2)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD81B, i)) for i in range(2, 5)],
        QUEST * int(read_bit(ram, 0xD81B, 5)),
        QUEST * int(read_bit(ram, 0xD81B, 6)),
        GYM_LEADER * int(read_bit(ram, 0xD81B, 7)),
        QUEST * int(read_bit(ram, 0xD77E, 1)),
    ])


def poke_tower(ram: np.ndarray) -> int:
    return sum([
        *[TRAINER * int(read_bit(ram, 0xD765, i)) for i in range(1, 4)],
        *[TRAINER * int(read_bit(ram, 0xD766, i)) for i in range(1, 4)],
        *[TRAINER * int(read_bit(ram, 0xD767, i)) for i in range(2, 6)],
        *[TRAINER * int(read_bit(ram, 0xD768, i)) for i in range(1, 4)],
        QUEST * int(read_bit(ram, 0xD768, 7)),
        *[TRAINER * int(read_bit(ram, 0xD769, i)) for i in range(1, 4)],
    ])


def gym1(ram: np.ndarray) -> int:
    return GYM_LEADER * int(read_bit(ram, 0xD755, 7)) + GYM_TRAINER * int(read_bit(ram, 0xD755, 2))


def gym2(ram: np.ndarray) -> int:
    return sum([
        GYM_LEADER * int(read_bit(ram, 0xD75E, 7)),
        GYM_TRAINER * int(read_bit(ram, 0xD75E, 2)),
        GYM_TRAINER * int(read_bit(ram, 0xD75E, 3)),
    ])


def gym3(ram: np.ndarray) -> int:
    return sum([
        GYM_TASK * int(read_bit(ram, 0xD773, 1)),
        GYM_TASK * int(read_bit(ram, 0xD773, 0)),
        GYM_LEADER * int(read_bit(ram, 0xD773, 7)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD773, i)) for i in range(2, 5)],
    ])


def gym4(ram: np.ndarray) -> int:
    return sum([
        GYM_LEADER * int(read_bit(ram, 0xD792, 1)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD77C, i)) for i in range(2, 8)],
        GYM_TRAINER * int(read_bit(ram, 0xD77D, 0)),
    ])


def gym5(ram: np.ndarray) -> int:
    return sum([
        GYM_LEADER * int(read_bit(ram, 0xD7B3, 1)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD792, i)) for i in range(2, 8)],
    ])


def gym6(ram: np.ndarray) -> int:
    return sum([
        GYM_LEADER * int(read_bit(ram, 0xD7B3, 1)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD7B3, i)) for i in range(2, 8)],
        GYM_TRAINER * int(read_bit(ram, 0xD7B4, 0)),
    ])


def gym7(ram: np.ndarray) -> int:
    return sum([
        GYM_LEADER * int(read_bit(ram, 0xD79A, 1)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD79A, i)) for i in range(2, 8)],
        GYM_TRAINER * int(read_bit(ram, 0xD79B, 0)),
    ])


def gym8(ram: np.ndarray) -> int:
    return sum([
        GYM_TASK * int(read_bit(ram, 0xD74C, 0)),
        GYM_LEADER * int(read_bit(ram, 0xD751, 1)),
        *[GYM_TRAINER * int(read_bit(ram, 0xD751, i)) for i in range(2, 8)],
        GYM_TRAINER * int(read_bit(ram, 0xD752, 0)),
        GYM_TRAINER * int(read_bit(ram, 0xD752, 1)),
    ])


def rival(ram: np.ndarray) -> int:
    return sum([
        RIVAL * int(read_bit(ram, 0xD74B, 3)),
        RIVAL * int(read_bit(ram, 0xD7EB, 0)),
        RIVAL * int(read_bit(ram, 0xD7EB, 1)),
        RIVAL * int(read_bit(ram, 0xD7EB, 5)),
        RIVAL * int(read_bit(ram, 0xD7EB, 6)),
        RIVAL * int(read_bit(ram, 0xD75A, 0)),
        RIVAL * int(read_bit(ram, 0xD764, 6)),
        RIVAL * int(read_bit(ram, 0xD764, 7)),
        RIVAL * int(read_bit(ram, 0xD7EB, 7)),
        RIVAL * int(read_bit(ram, 0xD82F, 0)),
    ])


def all_events(ram: np.ndarray) -> int:
    """Sum of all event rewards."""
    return sum([
        silph_co(ram), rock_tunnel(ram), ssanne(ram), mtmoon(ram), routes(ram),
        misc(ram), snorlax(ram), hmtm(ram), bill(ram), oak(ram), towns(ram),
        lab(ram), mansion(ram), safari(ram), dojo(ram), hideout(ram),
        poke_tower(ram), gym1(ram), gym2(ram), gym3(ram), gym4(ram),
        gym5(ram), gym6(ram), gym7(ram), gym8(ram), rival(ram),
    ])

