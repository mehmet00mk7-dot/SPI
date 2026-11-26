#!/usr/bin/env python3
# ============================================================================
# check_comment_only.py  -  "Yalnız yorum değişti" kontrolü (VHDL)
#
# İki VHDL dosyasını (eski, yeni) karşılaştırır ve kodun değişmediğini gösterir:
#   1) Token kontrolü : yorumlar ("--" satır sonuna kadar) atılır, kalan metin
#                       token'lara bölünür; iki token dizisi birebir aynı olmalı
#                       (büyük/küçük harf dahil).
#   2) Satır kontrolü : her satırdan yorum kısmı atılır, sağdaki boşluk kırpılır,
#                       boş satırlar atlanır; kalan kod satırları sırasıyla ve
#                       birebir (girinti dahil) aynı olmalı.
# String ("...") ve karakter literal'lerinin ('0') içindeki "--" yorum sayılmaz.
#
# Kullanım: python3 -I check_comment_only.py ESKI.vhd YENI.vhd [ESKI2 YENI2 ...]
# Çıkış kodu: hepsi aynıysa 0, değilse 1.
# ============================================================================
import re, sys


def strip_comment(line):
    """Satırdaki yorumu (string / char literal dışındaki ilk '--') atar."""
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c == '"':                                   # string literal
            j = line.find('"', i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == "'" and i + 2 < n and line[i + 2] == "'":   # karakter literal: 'x'
            i += 3
            continue
        if line.startswith('--', i):
            return line[:i]
        i += 1
    return line


TOKEN = re.compile(r'"[^"]*"|\'.\'|[A-Za-z_][A-Za-z0-9_]*|\d[\d_]*(?:\.\d+)?|<=|=>|:=|/=|>=|\*\*|\S')


def code_lines(path):
    out = []
    for ln in open(path, encoding='utf-8').read().split('\n'):
        c = strip_comment(ln).rstrip()
        if c.strip():
            out.append(c)
    return out


def tokens(lines):
    t = []
    for ln in lines:
        t.extend(TOKEN.findall(ln))
    return t


ok_all = True
args = sys.argv[1:]
for k in range(0, len(args), 2):
    a, b = args[k], args[k + 1]
    la, lb = code_lines(a), code_lines(b)
    ta, tb = tokens(la), tokens(lb)
    tok_ok = ta == tb
    line_ok = la == lb
    ca = sum(1 for l in open(a, encoding='utf-8') if l.strip().startswith('--'))
    cb = sum(1 for l in open(b, encoding='utf-8') if l.strip().startswith('--'))
    print(f'{b}: token {len(ta)}/{len(tb)} {"AYNI" if tok_ok else "FARKLI"} | '
          f'kod satiri {len(la)}/{len(lb)} {"AYNI" if line_ok else "FARKLI"} | '
          f'yorum satiri {ca} -> {cb}')
    if not line_ok:
        for i, (x, y) in enumerate(zip(la, lb)):
            if x != y:
                print(f'   ilk fark (kod satiri {i + 1}):\n     eski: {x!r}\n     yeni: {y!r}')
                break
        else:
            print(f'   kod satiri sayisi farkli: {len(la)} / {len(lb)}')
    ok_all &= tok_ok and line_ok
print('SONUC:', 'YALNIZ YORUM DEGISTI' if ok_all else 'KOD DEGISTI')
sys.exit(0 if ok_all else 1)
