"""Lists indirect jumps that look like switch tables but did not resolve."""
import sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lift import Lifter
from image import Image
from capstone import x86 as X
img = Image(sys.argv[1], sys.argv[2]); L = Lifter(img)
funcs = L.discover()
unres = []
kinds = collections.Counter()
for s, f in funcs.items():
    ins = f['insns']
    for a, i in ins.items():
        if not i or i.mnemonic != 'jmp' or i.operands[0].type != X.X86_OP_REG:
            continue
        if a in f['tables']:
            kinds['table'] += 1; continue
        # look back 64 decoded instructions by address
        prev = [ins[b] for b in sorted(ins) if b < a and ins[b]][-64:]
        if any(p.mnemonic in ('movsxd', 'mov') and len(p.operands) == 2 and p.operands[1].type == X.X86_OP_MEM
               and p.operands[1].mem.scale == 4 and p.operands[1].mem.index for p in prev):
            kinds['table-like unresolved'] += 1; unres.append((s, a))
        else:
            kinds['register tail call'] += 1
print(kinds)
for s, a in unres[:80]: print(hex(s), hex(a))
