#!/usr/bin/env python3
# ============================================================================
# check_flops.py  -  GHDL synth netlist'inde flop yapısı kontrolü (ad7923_top altı)
#
# Her "always @(posedge clk ...)" bloğu bir flop grubudur. Kontroller:
#   * Düz "always @(posedge clk)" (reset'siz) flop kalmamalı (onaylı istisna listesi boş).
#   * Her async reset ("posedge clk or posedge X") X'in kaynağı, net'ler, inverter'lar ve
#     port bağlantıları üzerinden geriye izlenir:
#       - driver / ch_regs / p_core_resetn flop'ları: X = ~rst_n (top port), arada başka
#         mantık yok  -> "rst_n (doğrudan)"
#       - core (spi_exec) flop'ları: X = ~core_resetn, core_resetn = p_core_resetn flop'u,
#         o flop'un async reset'i ~rst_n -> "rst_n -> p_core_resetn flop'u" (kural 5'teki
#         onaylı istisna; flop çıkışı, kombinasyonel türetme yok)
#   * Başka edge-sensitive blok (negedge, başka clock) olmamalı.
# Kullanım: python3 -I check_flops.py NETLIST.v [TOP]
# ============================================================================
import re, sys

net_file = sys.argv[1]
top = sys.argv[2] if len(sys.argv) > 2 else 'ad7923_top'
src = open(net_file).read()

mods = {}
for m in re.finditer(r'^module\s+(\w+)(.*?)^endmodule', src, re.M | re.S):
    mods[m.group(1)] = m.group(2)

def parse(body):
    ports = set(re.findall(r'^\s*(?:input|output)\s+(?:\[[^\]]*\]\s*)?(\w+)', body, re.M))
    widths = {}
    for w in re.finditer(r'^\s*(?:reg|wire|input|output)\s+(?:\[(\d+):(\d+)\]\s*)?(\w+)', body, re.M):
        widths[w.group(3)] = (int(w.group(1)) - int(w.group(2)) + 1) if w.group(1) else 1
    assigns = {}
    for a in re.finditer(r'^\s*assign\s+(\w+)\s*=\s*(.*?);', body, re.M):
        assigns[a.group(1)] = a.group(2).strip()
    flops = []      # (sens, q, reset_net or None, line)
    for f in re.finditer(r'always\s*@\(([^)]*)\)\s*\n?\s*(?:if\s*\((\w+)\)\s*\n?\s*)?(\w+)\s*<=', body):
        sens = f.group(1).strip()
        if sens == '*':
            continue
        flops.append((sens, f.group(3), f.group(2)))
    other = [s for s in re.findall(r'always\s*@\(([^)]*)\)', body) if s.strip() != '*']
    insts = []      # (module, inst, {port: net})
    for i in re.finditer(r'^\s*(\w+)\s+(\w+)\s*\(\s*\n(.*?)\);', body, re.M | re.S):
        if i.group(1) in mods:
            conn = dict(re.findall(r'\.(\w+)\((\w+)\)', i.group(3)))
            insts.append((i.group(1), i.group(2), conn))
    return dict(ports=ports, widths=widths, assigns=assigns, flops=flops, other=other, insts=insts)

P = {k: parse(v) for k, v in mods.items()}

# hiyerarşi: instance yolu -> (modül, parent yolu, port bağlantıları)
inst_tab = {top: (top, None, {})}
def walk(path, mod):
    for (cm, ci, conn) in P[mod]['insts']:
        p = path + '.' + ci
        inst_tab[p] = (cm, path, conn)
        walk(p, cm)
walk(top, top)

def flop_of(mod, q):
    for (sens, fq, rst) in P[mod]['flops']:
        if fq == q:
            return sens, rst
    return None

def trace(path, net):
    """async reset net'inin kaynağını geriye izler.
    Dönüş: (imza, zincir). imza:
      '~rst_n'                       : top port rst_n'nin tersi (aktif-düşük, doğrudan)
      'flop<Q>(~rst_n)|inv=k'        : bir flop çıkışı (k: aradaki inverter sayısı), o flop'un
                                       async reset'i de ayrıca izlenir
      başka her şey                  : HATA (kombinasyonel türetme, bağlantısız port, ...)"""
    chain = []; inv = 0
    while True:
        mod = inst_tab[path][0]; pm = P[mod]
        if net in pm['assigns']:
            rhs = pm['assigns'][net]
            m = re.fullmatch(r'~\s*(\w+)', rhs)
            if m:
                inv += 1; chain.append(f'{path}:{net}=~{m.group(1)}'); net = m.group(1); continue
            m = re.fullmatch(r'(\w+)(\s*//.*)?', rhs)
            if m:
                chain.append(f'{path}:{net}={m.group(1)}'); net = m.group(1); continue
            return ('KOMBINASYONEL(' + rhs + ')', chain)
        if net in pm['ports']:
            if path == top:
                return (('~' if inv % 2 else '') + net if inv <= 1 else f'{net}|inv={inv}', chain)
            cm, parent, conn = inst_tab[path]
            if net not in conn:
                return ('BAGLANTISIZ(' + net + ')', chain)
            chain.append(f'{path}.{net} <- {parent}:{conn[net]}')
            path, net = parent, conn[net]; continue
        fl = flop_of(mod, net)
        if fl:
            sens, rst = fl
            if rst is None:
                return (f'RESETSIZ_FLOP({path}:{net})', chain)
            sig, ch2 = trace(path, rst)
            return (f'flop<{path}:{net}>({sig})|inv={inv}', chain + ['[' + ' ; '.join(ch2) + ']'])
        return ('BILINMEYEN(' + net + ')', chain)

rows = []; plain = []; bad = []; other_bad = []
for path, (mod, parent, conn) in inst_tab.items():
    pm = P[mod]
    for s in pm['other']:
        if not re.fullmatch(r'posedge clk( or posedge \w+)?', s.strip()):
            other_bad.append((path, s))
    for (sens, q, rst) in pm['flops']:
        w = pm['widths'].get(q, 1)
        if rst is None or 'or' not in sens:
            plain.append((path, q, w)); continue
        desc, chain = trace(path, rst)
        if desc == '~rst_n':
            kind = 'rst_n (doğrudan, ~rst_n)'
        elif re.fullmatch(r'flop<' + re.escape(top) + r':\w+>\(~rst_n\)\|inv=1', desc):
            kind = "rst_n -> p_core_resetn flop'u (" + desc.split('<')[1].split('>')[0] + ")"
        else:
            kind = 'HATA'
        if kind == 'HATA':
            bad.append((path, q, desc, chain))
        rows.append((path, mod, q, w, kind, sens))

# özet: instance yolu x reset tipi
from collections import OrderedDict
summ = OrderedDict()
for (path, mod, q, w, kind, sens) in rows:
    k = (path, kind)
    n, b = summ.get(k, (0, 0))
    summ[k] = (n + 1, b + w)
print(f'Netlist: {net_file} | top: {top}')
print(f'{"instance":28s} {"flop grubu":>10s} {"bit":>5s}  async reset kaynağı')
tot_g = tot_b = 0
for (path, kind), (n, b) in summ.items():
    print(f'{path:28s} {n:10d} {b:5d}  posedge clk or posedge <{kind}>')
    tot_g += n; tot_b += b
print(f'{"TOPLAM":28s} {tot_g:10d} {tot_b:5d}')
print(f'Düz "always @(posedge clk)" (reset\'siz) flop: {len(plain)} grup, {sum(w for _,_,w in plain)} bit'
      + ('' if not plain else ' -> ' + ', '.join(f'{p}:{q}' for p, q, _ in plain)))
print(f'Onaylı reset\'siz register: yok')
print(f'Kaynağı rst_n\'ye izlenemeyen / türetilmiş async reset: {len(bad)}')
for b in bad:
    print('   ', b)
print(f'Başka edge-sensitive blok: {len(other_bad)}', other_bad if other_bad else '')
# driver ve ch_regs'te reset kaynağı yalnız doğrudan rst_n olmalı
drv_bad = [r for r in rows if (r[0].endswith('u_drv') or r[0].endswith('u_regs') or r[0] == top) and r[4] != 'rst_n (doğrudan, ~rst_n)']
print(f'Driver / ch_regs / top flop\'larında doğrudan rst_n dışı async reset: {len(drv_bad)}')
ok = not plain and not bad and not other_bad and not drv_bad and tot_g > 0
print('YAPISAL KONTROL:', 'BASARILI' if ok else 'BASARISIZ')
sys.exit(0 if ok else 1)
