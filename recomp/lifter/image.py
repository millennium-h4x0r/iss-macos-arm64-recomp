"""Reads the linked guest image (port/scripts link_modules.py output, G3PROBE5) and the
per-module ELF metadata the recompiler needs (unwind tables)."""
import struct
import sys
from pathlib import Path

PORT_SCRIPTS = Path(__file__).resolve().parents[2] / 'port' / 'scripts'
sys.path.insert(0, str(PORT_SCRIPTS))
from prepare import parse_self, read_self  # noqa: E402


class Image:
    def __init__(self, boot_path, game_dir):
        raw = Path(boot_path).read_bytes()
        pos = 0

        def q():
            nonlocal pos
            v = struct.unpack_from('<Q', raw, pos)[0]
            pos += 8
            return v
        magic = raw[:8]
        pos = 8
        if magic != b'G3PROBE5':
            raise ValueError('expected a G3PROBE5 image (link_modules.py)')
        self.size, self.entry, ns, nr, ni = q(), q(), q(), q(), q()
        self.capabilities = q()
        self.procparam = q()
        self.main_tls = [q() for _ in range(4)]
        mc = q()
        self.modules = []
        for _ in range(mc):
            base, size, init, tls_address, tls_memsz, tls_filesz, tls_module = (q() for _ in range(7))
            self.modules.append(dict(base=base, size=size, init=init, tls_address=tls_address,
                                     tls_memsz=tls_memsz, tls_filesz=tls_filesz, tls_module=tls_module))
        nb = q()
        self.bindings = [(q(), q(), q()) for _ in range(nb)]  # (import index, address, kind)
        self.segments = [dict(address=q(), size=q(), flags=q()) for _ in range(ns)]
        self.names = []
        for i in range(ni):
            n = raw[pos:pos + 128]
            self.names.append(n[:n.index(0)].decode())
            pos += 128
        self.relocs = [(q(), q(), q(), q()) for _ in range(nr)]  # target, kind, value, addend
        self.image = raw[pos:pos + self.size]
        assert len(self.image) == self.size and pos + self.size == len(raw)
        self.exec_ranges = sorted((s['address'], s['address'] + s['size'])
                                  for s in self.segments if s['flags'] & 1)
        game = Path(game_dir)
        # Unwind tables: eboot at 0, then each linked module at its base (link_modules.py order).
        self.eh = [(0, self._eh_frame_hdr(game / 'eboot.bin'))]
        files = ['libc.prx', 'libSceFios2.prx']
        for m, f in zip(self.modules, files):
            self.eh.append((m['base'], self._eh_frame_hdr(game / 'sce_module' / f)))

    @staticmethod
    def _eh_frame_hdr(path):
        elf, header, ph, _, _ = parse_self(read_self(path))
        p = next((p for p in ph if p['type'] == 0x6474e550), None)
        return p['vaddr'] if p else None

    def executable(self, a):
        for lo, hi in self.exec_ranges:
            if lo <= a < hi:
                return True
        return False

    def u8(self, a): return self.image[a]
    def u32(self, a): return struct.unpack_from('<I', self.image, a)[0]
    def s32(self, a): return struct.unpack_from('<i', self.image, a)[0]
    def u64(self, a): return struct.unpack_from('<Q', self.image, a)[0]
    def s64(self, a): return struct.unpack_from('<q', self.image, a)[0]

    def fdes(self):
        """(start, length) of every FDE of every module, image offsets."""
        out = {}
        for base, hdr in self.eh:
            if hdr is None:
                continue
            H = base + hdr
            ver, ptr_enc, cnt_enc, tab_enc = self.image[H:H + 4]
            if ver != 1 or tab_enc != 0x3b:
                raise ValueError(f'unsupported eh_frame_hdr at {H:#x}')
            # eh_frame_ptr (pcrel sdata4 typically) then fde_count (udata4)
            n = {0x1b: 4, 0x03: 4, 0x0b: 4}[ptr_enc]
            count = self.u32(H + 4 + n)
            table = H + 4 + n + 4
            for i in range(count):
                start = self.s32(table + i * 8) + H
                fde = self.s32(table + i * 8 + 4) + H
                out[start] = self._fde_range(fde)
        return out

    def _uleb(self, p):
        r = s = 0
        while True:
            b = self.image[p]; p += 1; r |= (b & 0x7f) << s; s += 7
            if b < 0x80:
                return r, p

    def _sleb(self, p):
        r = s = 0
        while True:
            b = self.image[p]; p += 1; r |= (b & 0x7f) << s; s += 7
            if b < 0x80:
                if b & 0x40:
                    r -= 1 << s
                return r, p

    def _fde_range(self, fde):
        cie = fde + 4 - self.u32(fde + 4)
        aug_start = cie + 9
        aug = bytes(self.image[aug_start:aug_start + 16]).split(b'\0')[0]
        enc = 0x1b
        if aug.startswith(b'z'):
            p = aug_start + len(aug) + 1
            _, p = self._uleb(p)
            _, p = self._sleb(p)
            p += 1
            _, p = self._uleb(p)
            for ch in aug[1:]:
                if ch == ord('R'):
                    enc = self.image[p]
                    break
                if ch == ord('L'):
                    p += 1
                elif ch == ord('P'):
                    penc = self.image[p]; p += 1
                    p += {0x0b: 4, 0x03: 4, 0x04: 8, 0x0c: 8, 0x00: 8, 0x1b: 4, 0x9b: 4}[penc & 0x0f if penc & 0x0f else 0]
        size = {0x0b: 4, 0x03: 4, 0x04: 8, 0x0c: 8, 0x00: 8}[enc & 0x0f]
        rng = self.u32(fde + 8 + size) if size == 4 else self.u64(fde + 8 + size)
        return rng
