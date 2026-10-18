"""One-time, hash-pinned cleanup of entries reviewed by the operator.

Unknown and subsequently changed entries survive. Previous bytes are privately
backed up by clean-memory.py. Only reviewed obsolete content is removed; new
curated facts summarize verified environment and owner preferences.
"""
import hashlib

REVIEWED = {
    ('head-coordinator', 'MEMORY.md'): {
        '02cffc5a5c4d75b974151338f0efb28d0258008e3f5031136b318e7a4ede706d': 'Workstation: the desktop runs Void Linux with runit. Server: NixHomeServer runs NixOS with systemd.',
    },
    ('head-coordinator', 'USER.md'): {
        '8b61d47f959b99a6f0f00bbef0722f740059263ff1cc53632512674789949082': 'The owner prefers expensive builds and validation on the server to reduce workstation resource pressure.',
        'eec2d94cb5e79a241dd8ecbd8460989a95a00b1474e85b69303ef50a4d7de9bc': 'The owner values evidence-backed completion reports that distinguish active changes, pending work and remaining blockers.',
        '352996987750d81f08f4639ed2a3c653604fb3b050f76c6b01ae09dbf76d5749': 'The owner prefers checking for safe parallel work when queues are long, while preserving real dependencies and approval gates.',
        'cacd747239a3317e3b872727c68214fc4e8869e3d298500d58bc3b564d7ad952': 'The owner prefers clear feature-level progress visibility, with specifications, evidence, blockers and next steps consolidated.',
        '17b25af9747e53f8deca60f746db181684391abbe182aba7413147bcd30fdf67': 'The owner prefers option references to name the subject, chosen option and exact scope unless immediately clear from context.',
        '5ac90c12abb0f5f82b2fdf66a6991602ffdf523058edc6b7c3f5bd35bf48443f': None,
    },
    ('board-steward', 'MEMORY.md'): {
        'c8b7e9d3452349e82df9fe7d2c527ea1af09984afd67b55334c75ae2b42b30ce': 'Workstation: the active boards are nixhomeserver (~/Projects/NixOS) and pcops (~/pc-ops).',
        '5dcef1134d4c222d9b76b492e016a015f2b891c2f3eff935d2ad2e91ced0bea5': None,
        'ba384b6bae7d64b6a9519b71c890e86231f4449493ca301f8bd9311092c01a35': None,
        'e3f32b57adcba34bd671934bc0e1b2d18ada4ab24a19f6c06c3ef222e83a50e8': None,
        '3125f770f7f279cd038343e6157524fb45649ee69b761e9b2e7f2b9ccc9acce4': None,
        '5f8a3578a85f606d3238d6c86b2826351970a7cfd1435a5a232a0215f6663c7d': None,
    },
    ('board-steward', 'USER.md'): {
        '16044ed9b0ed462faa245ba2fef35a812fdaa3db2bfb444e3ce89fe350b1cb39': 'The owner prefers concise, complete answers addressing every part of a bundled request.',
        '43469adbe5eeec878641e69b1e2c609c4241912a359323b4dbfd27cae0219fa8': 'The owner prefers explicit statements of blockers and actions that remain unperformed.',
        '6d8de4f8bc486dde7cb7a967c696e03ef6262ef586893a6feee0b0a3d38964da': 'The owner expects claims to be checked against evidence and uncertainty stated clearly.',
        '585dff75f0d70bf8ff6d02bd48b4af3f872c7660090538dc17f6eeee5fe7855e': None,
        '0a5086832c0a568f3de037ce6c6be4137c50eb41f9bef10cfcb0e009164c5454': 'The owner values continued progress on independent work when another chain is blocked.',
    },
    ('feature-reviewer', 'MEMORY.md'): {
        '41d31e7c22c76ec1c7d0f7bf8627d54c4dea40bc72f9fdb07773b381d32a22fc': None,
        '386bf24725bef53aaec943c91e2ddb6432458141a2842ba150199f530e29b4eb': None,
        '8e8155c021c2df396f7df4b8e863e24486e76df0c0355e01dd55e21544790993': None,
        '827c7cdb56bd762d6909333494690f9892593a3ed8050f0bcb88b2cce0fb0d7e': None,
        '25284d857c021f256fd45732ec776931a593e0b0977b74a120ec3b00d65ad888': None,
    },
    ('standard-implementer', 'MEMORY.md'): {
        '88de63ce0f72ea0118419be4460af9b6f95eca829b4cbe52311794de3a88e344': None,
        '0d2c987cfae93cbc7853f44b34097e6aebc6aa382c1498f566c5d48e6c8dc41d': 'Workstation: the desktop runs Void Linux with runit. Server: NixHomeServer runs NixOS with systemd.',
        '453cd08a10947fef70d96f419158a7325481f0f965d4b3e4cfccd0abde211d4c': None,
        'b217c750c81e0a03288d9536cf9a0e098b7922612af046b88875c86378f07804': 'Server: the NixHomeServer SSH destination is dsaw@192.168.8.12.',
        '4571be11e9d78389873abfc5ed85f557e04e57dd6f875131be241fab622ac1ee': None,
        '57ef373556b51ffc6fcd2a4624ed70891ad56b715bea9177851be3623030b589': 'Workstation: PC Ops is ~/pc-ops, a plain directory. NixOS source is ~/Projects/NixOS.',
        'e4ba9e85832bbbafb0de9ac17bee2e3ffc4140ec82aa38d9258221b29bb43a03': None,
        '5a49249672d3ddb02d81d90852bc038b019b824284507665dd882ae12cf8206f': None,
    },
}


def clean(profile, filename, text):
    rules = REVIEWED.get((profile, filename), {})
    entries = text.strip().split('\n§\n') if text.strip() else []
    updated = []
    for entry in entries:
        key = hashlib.sha256(entry.encode()).hexdigest()
        value = rules[key] if key in rules else entry
        if value and value not in updated:
            updated.append(value)
    return '\n§\n'.join(updated)
