#!/usr/bin/env python3
# ============================================================================
# gen_drawio.py  -  HI-8436 driver blok diyagramı üretici
#
# Çıktı: docs/hi8436_blok_diyagram.drawio (draw.io / diagrams.net, 6 sayfa)
#   1  Sistem zinciri  : UART Master -> ... -> Driver -> SPI Master -> entegre (her entegre ayrı hatta)
#   2  hi8436_top      : üst seviye bağlantılar, reset yolu, HI-8436 pin'leri
#   3  hi8436_drv      : driver iç blokları ve aralarındaki sinyaller
#   4  FSM             : control FSM (p_ctrl) ve packer FSM (p_pack)
#   5  F8 zamanlaması  : 0xF8 (Read All Banks) okuma çerçevesi, ölçülen değerlerle
#   6  Init politikası : start'ta tam init / kısmi güncelleme / doğrudan okuma
# Altyapı (Page, ortogonal kenarlar, SVG önizleme) AD7923/docs/gen_drawio.py'den alındı.
# Renkler: turuncu = bizim RTL (HI8436), teal = ortak core (common/rtl/async),
# gri = dış dünya / bu çalışmanın dışı, mor = FSM durumu, kırmızı kesikli = reset yolu.
#
# Kullanım: python3 -I docs/gen_drawio.py [--preview DIR]
# ============================================================================
import html
import os
import re
import sys
from xml.sax.saxutils import quoteattr

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hi8436_blok_diyagram.drawio')

# ---------------------------------------------------------------- stiller
_BOX = 'whiteSpace=wrap;html=1;align=center;verticalAlign=top;spacingTop=4;fontSize=11;'
_MID = 'whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=11;'
S_OURS = 'rounded=1;arcSize=6;fillColor=#ffe6cc;strokeColor=#d79b00;' + _BOX
S_HI = 'rounded=1;arcSize=6;fillColor=#ffe6cc;strokeColor=#d79b00;strokeWidth=3;' + _BOX
S_CORE = 'rounded=0;fillColor=#b0e3e6;strokeColor=#0e8088;' + _BOX
S_EXT = 'rounded=0;fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;' + _BOX
S_EXT_HI = 'rounded=0;fillColor=#f5f5f5;strokeColor=#d79b00;strokeWidth=3;fontColor=#333333;' + _BOX
S_RST = 'rounded=1;arcSize=6;fillColor=#ffe6cc;strokeColor=#b85450;' + _BOX
S_GRP = ('rounded=0;fillColor=none;strokeColor=#999999;dashed=1;align=left;verticalAlign=top;'
         'spacingLeft=8;spacingTop=4;whiteSpace=wrap;html=1;fontSize=12;')
S_NOTE = ('shape=note;size=12;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#999999;'
          'align=left;verticalAlign=top;spacingLeft=6;spacingTop=2;fontSize=11;')
S_STATE = ('rounded=1;arcSize=40;whiteSpace=wrap;html=1;fillColor=#e1d5e7;strokeColor=#9673a6;'
           'fontStyle=1;fontSize=11;align=center;verticalAlign=middle;')
S_DEC = 'rhombus;fillColor=#ffe6cc;strokeColor=#d79b00;' + _MID
S_BUS = 'rounded=0;fillColor=#ffffff;strokeColor=#333333;' + _MID + 'fontSize=10;'
S_BUSO = 'rounded=0;fillColor=#ffe6cc;strokeColor=#d79b00;' + _MID + 'fontSize=10;'
S_TEXT = 'text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=11;'
S_TEXTC = 'text;html=1;align=center;verticalAlign=middle;whiteSpace=wrap;fontSize=10;'
S_TITLE = 'text;html=1;align=left;verticalAlign=top;fontSize=18;fontStyle=1;'
S_EDGE = ('edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;endSize=6;'
          'labelBackgroundColor=#ffffff;fontSize=10;')
S_EDGE_RST = S_EDGE + 'strokeColor=#b85450;dashed=1;fontColor=#b85450;'
S_WAVE = 'rounded=0;html=1;endArrow=none;strokeWidth=2;strokeColor=#333333;'
S_DIM = 'rounded=0;html=1;endArrow=open;startArrow=open;endSize=5;startSize=5;strokeColor=#b85450;fontColor=#b85450;fontSize=10;labelBackgroundColor=#ffffff;'


def lab(title, *lines):
    """Kutu etiketi: kalın başlık + küçük satırlar (HTML, metin escape edilir)."""
    t = '<b>' + html.escape(title) + '</b>'
    if lines:
        t += '<br><font style="font-size:10px">' + '<br>'.join(html.escape(l) for l in lines) + '</font>'
    return t


class Page:
    def __init__(self, name, w, h):
        self.name, self.w, self.h = name, w, h
        self.cells = []      # draw.io mxCell XML'leri
        self.boxes = {}      # id -> (x, y, w, h, style, label)
        self.paths = []      # (noktalar, etiket, stil, lpos)
        self.n = 0

    def _id(self):
        self.n += 1
        return f'c{self.n}'

    def box(self, label, x, y, w, h, style):
        cid = self._id()
        self.boxes[cid] = (x, y, w, h, style, label)
        self.cells.append(
            f'<mxCell id="{cid}" value={quoteattr(label)} style={quoteattr(style)} vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        return cid

    def text(self, label, x, y, w, h, style=S_TEXT):
        return self.box(label, x, y, w, h, style)

    def _rel(self, cid, pt):
        x, y, w, h = self.boxes[cid][:4]
        rx, ry = (pt[0] - x) / w, (pt[1] - y) / h
        on_edge = (rx in (0, 1) and 0 <= ry <= 1) or (ry in (0, 1) and 0 <= rx <= 1)
        assert on_edge, f'{self.name}: nokta {pt} kutunun ({x},{y},{w},{h}) kenarında değil'
        return round(rx, 4), round(ry, 4)

    def path(self, src, tgt, pts, label='', style=S_EDGE, lpos=0.0):
        """pts[0] kaynak kutunun, pts[-1] hedef kutunun kenarında; aradakiler köşe noktaları."""
        for a, b in zip(pts, pts[1:]):
            assert a[0] == b[0] or a[1] == b[1], f'{self.name}: orthogonal değil {a} -> {b}'
        ex, ey = self._rel(src, pts[0])
        nx, ny = self._rel(tgt, pts[-1])
        st = style + f'exitX={ex};exitY={ey};exitDx=0;exitDy=0;entryX={nx};entryY={ny};entryDx=0;entryDy=0;'
        mid = ''.join(f'<mxPoint x="{a}" y="{b}"/>' for a, b in pts[1:-1])
        geo = f'<Array as="points">{mid}</Array>' if mid else ''
        val = html.escape(label, quote=False).replace('\n', '<br>')
        cid = self._id()
        self.cells.append(
            f'<mxCell id="{cid}" value={quoteattr(val)} style={quoteattr(st)} edge="1" parent="1" '
            f'source="{src}" target="{tgt}"><mxGeometry x="{lpos}" relative="1" as="geometry">{geo}'
            f'</mxGeometry></mxCell>')
        self.paths.append((pts, label, style, lpos))

    def line(self, pts, style=S_WAVE, label=''):
        """Kutusuz çizgi (dalga şekli / ölçü oku): sourcePoint -> köşeler -> targetPoint."""
        mid = ''.join(f'<mxPoint x="{a}" y="{b}"/>' for a, b in pts[1:-1])
        geo = f'<Array as="points">{mid}</Array>' if mid else ''
        val = html.escape(label, quote=False).replace('\n', '<br>')
        cid = self._id()
        (sx, sy), (tx, ty) = pts[0], pts[-1]
        self.cells.append(
            f'<mxCell id="{cid}" value={quoteattr(val)} style={quoteattr(style)} edge="1" parent="1">'
            f'<mxGeometry relative="1" as="geometry"><mxPoint x="{sx}" y="{sy}" as="sourcePoint"/>'
            f'<mxPoint x="{tx}" y="{ty}" as="targetPoint"/>{geo}</mxGeometry></mxCell>')
        self.paths.append((pts, label, style, 0.0))

    def xml(self, idx):
        return (f'<diagram id="page{idx}" name={quoteattr(self.name)}>'
                f'<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" '
                f'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{self.w}" '
                f'pageHeight="{self.h}" math="0" shadow="0"><root><mxCell id="0"/>'
                f'<mxCell id="1" parent="0"/>{"".join(self.cells)}</root></mxGraphModel></diagram>')


def legend(p, x, y):
    mid = 'verticalAlign=middle;'
    p.box('<b>Açıklama</b>', x, y, 250, 170, S_GRP)
    p.box('bizim RTL (HI8436)', x + 10, y + 30, 230, 22, S_OURS.replace('verticalAlign=top;', mid))
    p.box('ortak core (common/rtl/async)', x + 10, y + 58, 230, 22, S_CORE.replace('verticalAlign=top;', mid))
    p.box('dış dünya / bu işin dışı', x + 10, y + 86, 230, 22, S_EXT.replace('verticalAlign=top;', mid))
    p.box('FSM durumu', x + 10, y + 114, 230, 22, S_STATE)
    p.text('<font color="#b85450">- - - &gt;  reset yolu</font>', x + 14, y + 140, 220, 20)


pages = []

# ============================================================================
# SAYFA 1: sistem zinciri
# ============================================================================
p = Page('1 - Sistem zinciri', 1700, 900)
pages.append(p)
p.text('Sistem zinciri: CPU\'suz FADEC sensör okuma (Microchip PolarFire)', 30, 16, 1200, 30, S_TITLE)
p.text('Board test tarafı driver\'ları düz sinyallerle sürer (start, stop, ayarlar); sonuç düz sinyal olarak '
       'döner (valid pulse + veri, kalıcı register). Driver\'lar AXI değildir. Kalın çerçeve = bu çalışma (HI8436).',
       30, 48, 1500, 22)
uart = p.box(lab('UART Master'), 30, 150, 150, 90, S_EXT)
ic1 = p.box(lab('Interconnect 1'), 220, 150, 150, 90, S_EXT)
seq = p.box(lab('Sequencer', 'start / stop / ayarlar', 'sonuçları toplar'), 410, 150, 150, 90, S_EXT)
ic2 = p.box(lab('Interconnect 2'), 600, 150, 150, 90, S_EXT)
p.box('<b>Bu repo: Driver -&gt; SPI Master</b>  (her entegre kendi SPI hattında, arbiter yok)',
      790, 90, 640, 470, S_GRP)
dad = p.box(lab('ad7923_drv', '(önceki iş, AD7923/)'), 820, 130, 240, 90, S_OURS)
dh1 = p.box(lab('hi8436_drv  #1', 'HI8436/rtl (bu iş)', 'init / doğrulama / F8 okuma / self-test'), 820, 260, 240, 90, S_HI)
dh2 = p.box(lab('hi8436_drv  #2', 'aynı RTL, ikinci instance', '(kartta iki HI-8436)'), 820, 390, 240, 90, S_HI)
sad = p.box(lab('spi_exec  (hat A)', 'common/rtl/async', 'ad7923_top: DATA_WIDTH = 16'), 1180, 130, 220, 90, S_CORE)
sh1 = p.box(lab('spi_exec  (hat B)', 'common/rtl/async', 'hi8436_top: DATA_WIDTH = 8'), 1180, 260, 220, 90, S_CORE)
sh2 = p.box(lab('spi_exec  (hat C)', 'common/rtl/async', 'hi8436_top: DATA_WIDTH = 8'), 1180, 390, 220, 90, S_CORE)
cad = p.box(lab('AD7923', '4 kanal ADC', 'hat A\'daki tek entegre'), 1500, 130, 170, 90, S_EXT)
ch1 = p.box(lab('HI-8436 #1', '32 discrete giriş', 'hat B\'deki tek entegre'), 1500, 260, 170, 90, S_EXT_HI)
ch2 = p.box(lab('HI-8436 #2', '32 discrete giriş', 'hat C\'deki tek entegre'), 1500, 390, 170, 90, S_EXT_HI)
p.path(uart, ic1, [(180, 195), (220, 195)])
p.path(ic1, seq, [(370, 195), (410, 195)])
p.path(seq, ic2, [(560, 195), (600, 195)])
p.path(ic2, dad, [(750, 175), (820, 175)])
p.path(ic2, dh1, [(750, 215), (780, 215), (780, 305), (820, 305)])
p.path(ic2, dh2, [(675, 240), (675, 435), (820, 435)])
p.text('start, stop, ayarlar -&gt;<br>&lt;- sense, valid, err', 560, 500, 200, 34, S_TEXTC)
for d, c, e in [(dad, sad, 175), (dh1, sh1, 305), (dh2, sh2, 435)]:
    p.path(d, c, [(1060, e), (1180, e)], 'cmd / sdo /\nsdi / sync\n(gnt = \'1\')')
for c, e, y in [(sad, cad, 175), (sh1, ch1, 305), (sh2, ch2, 435)]:
    p.path(c, e, [(1400, y), (1500, y)], 'SCK / MOSI\nMISO / nCS')
p.box('<b>Arbiter yok.</b> Kartta üç SPI hattı var; her hatta tek entegre: hat A = AD7923, hat B = HI-8436 #1, '
      'hat C = HI-8436 #2 (K-5 cevabı). Her entegre kendi top\'u ile (driver + spi_exec) kullanılır ve '
      'top\'ta gnt = \'1\'. Driver\'ın req/gnt arayüzü, ileride paylaşılan bir hat olursa arbiter '
      'bağlamak için korunuyor.', 790, 590, 640, 80, S_NOTE)
p.box('<b>Bu çalışmanın kapsamı</b><br>hi8436_drv + hi8436_top (tek entegre, tek hat). Kartta iki HI-8436 var, '
      'her biri ayrı hatta: sistem seviyesinde iki hi8436_top instance\'ı. Datasheet\'in çoklu entegre için '
      'önerdiği ortak SCK/SI/SO bağlantısı (s.14 Fig 9) bu kartta kullanılmıyor.', 30, 300, 520, 130, S_NOTE)
p.box('<b>Driver arayüzü (düz sinyal)</b><br>giriş: start, stop, continuous, period_us, bank_mode, '
      'go/so center+hyst, self_test_req<br>çıkış: sense[31:0] (kalıcı), sense_valid (1 clk), sense_chg, '
      'sense_act, cfg_done, busy, err, err_code, st_done, st_fail', 30, 460, 520, 120, S_NOTE)
legend(p, 30, 620)

# ============================================================================
# SAYFA 2: hi8436_top
# ============================================================================
p = Page('2 - hi8436_top', 1750, 1000)
pages.append(p)
p.text('hi8436_top: HI-8436 okuma bloğu (driver + SPI master)', 30, 16, 1200, 30, S_TITLE)
p.text('1 driver -> 1 spi_exec -> 1 HI-8436, arbiter yok (gnt = \'1\'). 100 MHz tek clock. CLK_DIV = 2 '
       '(SCLK 16,67 MHz <= 20 MHz), CS_T = 1, DATA_WIDTH = 8 (8..32), SDI_DELAY = 0, Mode 0.', 30, 48, 1500, 22)
sysb = p.box(lab('Sistem tarafı', '(sequencer,', 'clk ile senkron)'), 30, 110, 170, 680, S_EXT)
p.box('<b>hi8436_top</b>', 300, 80, 1060, 830, S_GRP)
drv = p.box(lab('u_drv : hi8436_drv',
                'Control FSM (p_ctrl)', 'Paket tanımı (p_dsc)', 'Packer (p_pack, p_cmd)',
                'Timer\'lar: settle 2 us, period, SYNC timeout 10 us, nMR',
                'Init politikası: init_done + shadow (sh_*)', 'Periyodik doğrulama (VERIFY_EVERY = 16)',
                'Çıkış register\'ı (p_out)', '', 'gnt = \'1\' (sabit), req kullanılmaz'),
            420, 140, 320, 420, S_OURS)
spi = p.box(lab('u_spi : spi_exec  (SPI master)',
                'common/rtl/async (dokunulmadı)', 'async reset, ECHO_SCLK = 0', '',
                'NUM_OF_CS = 1, DATA_WIDTH', 'DEFAULT_SPI_CFG = 0 (Mode 0)',
                'DEFAULT_CLK_DIV = CLK_DIV', 'NUM_OF_SDI = 1, SDO_DEFAULT = "0"', 'SDI_DELAY generic', '',
                'sdi_data_ready = \'1\', sync_ready = \'1\'', 'açık: sdo_t, three_wire'),
            1000, 140, 320, 380, S_CORE)
cfg = p.box(lab('Ayar kaynağı (generate)', 'CFG_FROM_GENERIC = false: portlar',
                'true: DEF_* generic\'leri', '(0000, GO 9/5, SO 35/15)'), 420, 640, 320, 120, S_OURS)
crst = p.box(lab('p_core_resetn (flop)', 'rst_n = \'0\' -> core_resetn = \'0\' (async)',
                 'aksi: core_resetn <= not core_rst'), 1020, 660, 280, 100, S_RST)
chip = p.box(lab('HI-8436', '32 kanal GND/Open - Supply/Open', 'SPI Mode 0, <= 20 MHz',
                 'SO yalnız okuma byte\'larında sürülür', 'nMR: dahili pull-up'), 1460, 160, 240, 330, S_EXT_HI)
rsync = p.box(lab('Reset synchronizer', 'async assert, sync deassert', 'PLL lock\'a bağlı'), 30, 830, 220, 80, S_EXT)
p.path(sysb, drv, [(200, 180), (420, 180)], 'start, stop, continuous\nperiod_us[15:0], self_test_req')
p.path(drv, sysb, [(420, 300), (200, 300)], 'sense[31:0], sense_valid\nsense_chg, sense_act')
p.path(drv, sysb, [(420, 420), (200, 420)], 'cfg_done, busy, err\nerr_code[3:0], st_done, st_fail')
p.path(sysb, cfg, [(200, 700), (420, 700)], 'bank_mode[3:0]\ngo/so_center, go/so_hyst')
p.path(cfg, drv, [(580, 640), (580, 560)], 'bm_i, goc/goh/soc/soh_i')
p.path(drv, spi, [(740, 190), (1000, 190)], 'cmd[15:0], cmd_valid\n(<- cmd_ready)')
p.path(drv, spi, [(740, 260), (1000, 260)], 'sdo_data (byte), sdo_valid\n(<- sdo_ready)')
p.path(spi, drv, [(1000, 330), (740, 330)], 'sdi_data ([7:0]), sdi_valid')
p.path(spi, drv, [(1000, 400), (740, 400)], 'sync[7:0], sync_valid')
p.path(drv, crst, [(740, 500), (880, 500), (880, 710), (1020, 710)], 'core_rst\n(senkron, 4 clk)')
p.path(crst, spi, [(1160, 660), (1160, 520)], 'core_resetn -> resetn', S_EDGE_RST)
p.path(spi, chip, [(1320, 200), (1460, 200)], 'spi_sclk (SCK)')
p.path(spi, chip, [(1320, 270), (1460, 270)], 'spi_mosi (SI)')
p.path(spi, chip, [(1320, 340), (1460, 340)], 'spi_cs_n (nCS)')
p.path(chip, spi, [(1460, 410), (1320, 410)], 'spi_miso (SO)')
p.path(drv, chip, [(740, 540), (1400, 540), (1400, 460), (1460, 460)], 'spi_mr_n (nMR, HAS_MR)', lpos=-0.4)
p.path(rsync, drv, [(250, 850), (390, 850), (390, 520), (420, 520)], 'rst_n', S_EDGE_RST, lpos=-0.2)
p.path(rsync, crst, [(250, 890), (1160, 890), (1160, 760)], 'rst_n', S_EDGE_RST)
legend(p, 1460, 520)
p.box('<b>Reset stratejisi</b><br>Async reset olarak yalnız rst_n. u_drv rst_n\'yi doğrudan alır; core\'un '
      'resetn\'i p_core_resetn flop\'undan (rst_n ile async clear, D = not core_rst). rst_n düşünce clock '
      'beklemeden çıkışlar reset değerinde, spi_cs_n = \'1\', spi_mr_n = \'1\'.', 1460, 710, 270, 140, S_NOTE)
p.box('<b>Flop kontrolü</b>: 100 grup / 505 bit, hepsi rst_n\'den async reset; düz posedge clk 0.',
      1460, 870, 270, 60, S_NOTE)

# ============================================================================
# SAYFA 3: hi8436_drv iç blokları
# ============================================================================
p = Page('3 - hi8436_drv', 1750, 1050)
pages.append(p)
p.text('hi8436_drv: iç bloklar', 30, 16, 900, 30, S_TITLE)
p.text('Bütün register\'lar rst_n ile async reset\'li. Soft clear\'lar (settle: yazma SYNC\'i, period: okuma '
       'launch\'ı, core_rst) senkron mantık.', 30, 48, 1300, 22)
inp = p.box(lab('Kontrol girişleri', 'start, stop, continuous', 'period_us[15:0]', 'bank_mode[3:0]',
                'go/so_center, go/so_hyst', 'self_test_req'), 30, 150, 180, 170, S_EXT)
lat = p.box(lab('Ayar latch + shadow', 'start\'ta: bm_r, goc_r, goh_r, soc_r, soh_r',
                'doğrulanan: sh_bm, sh_goc .. sh_soh', 'd_bm / d_go / d_so (fark)', 'start_ok = thr_ok (s.7 Tbl 6)'),
            300, 120, 300, 170, S_OURS)
fsm = p.box(lab('Control FSM (p_ctrl)', 'IDLE, MR_PULSE, MR_WAIT, CFG_WR, CFG_RD,',
                'SETTLE, TEST, READ, PERIOD, CORE_RST', '', 'init_done (= cfg_done), upd[4:0]',
                'err, err_code, err_cnt (ERR_LIMIT)', 'st_pend, st_bad, st_fail, rd_owed',
                'rd_cnt (VERIFY_EVERY), vfy, rb_bad', 'stop_pend, mr_n_r, core_rst_r'),
            300, 360, 300, 300, S_OURS)
dsc = p.box(lab('Paket tanımı (p_dsc, komb.)', 'state / idx ->', 'opcode, veri byte sayısı (1/2/4)',
                'DB1, DB0 (yazma)', 'rb_exp (geri okuma), st_exp (self-test)'), 700, 120, 300, 170, S_OURS)
pk = p.box(lab('Packer (p_pack + p_cmd)', 'PK_IDLE -> PK_CMD (pk_idx 0..7) -> PK_WAIT',
               '2002 2100 2208 11FE, TRANSFER W/R,', '11FF, 30nn (SYNC id)',
               'launch: sdo kuyruğu sq0..sq2, exp_cnt,', 'rx_sh (byte\'lar, [7:0]), to_cnt',
               'req = pk_st /= PK_IDLE'), 1100, 120, 320, 300, S_OURS)
err = p.box(lab('Yapısal hata dedektörü', 'to_hit (SYNC timeout) -> 8', 'sync_err (id / an) -> 9',
                'sdi_unexp -> A, sdi_miss -> B'), 1100, 480, 320, 150, S_OURS)
tmr = p.box(lab('Timer\'lar', 'p_stl: settle (yazma SYNC\'inden 2 us)', 'p_per: period (launch\'tan, C_PER_LAT = 4)',
                'to_cnt: SYNC timeout (10 us)', 'tmr: nMR pulse / bekleme'), 1100, 700, 320, 200, S_OURS)
out = p.box(lab('Çıkış register\'ı (p_out)', 'sense_r <= rx_sh', 'sense_chg_r <= rx_sh xor sense_r',
                'sense_act_r <= rx_sh xor bank modu', 'sense_vld_r: 1 clk'), 300, 760, 300, 170, S_OURS)
core = p.box(lab('spi_exec', '(SPI master,', 'common)', '', 'komut / sdo /', 'sdi / sync', 'valid-ready',
                 'stream\'leri'), 1520, 120, 200, 500, S_CORE)
outs = p.box(lab('Sonuç çıkışları', 'sense, sense_valid', 'sense_chg, sense_act', 'cfg_done, busy',
                 'err, err_code', 'st_done, st_fail', 'mr_n, core_rst'), 30, 760, 180, 170, S_EXT)
p.path(inp, lat, [(210, 200), (300, 200)], 'ayarlar')
p.path(inp, fsm, [(210, 290), (250, 290), (250, 420), (300, 420)], 'start, stop\ncontinuous, ...')
p.path(lat, fsm, [(450, 290), (450, 360)], 'start_ok, d_*')
p.path(lat, dsc, [(600, 180), (700, 180)], 'bm_r .. soh_r')
p.path(fsm, dsc, [(600, 400), (650, 400), (650, 250), (700, 250)], 'state, idx', lpos=0.5)
p.path(dsc, pk, [(1000, 200), (1100, 200)], 'dsc_*')
p.path(fsm, pk, [(600, 460), (1050, 460), (1050, 300), (1100, 300)], 'frm_go, frm_cancel', lpos=-0.4)
p.path(pk, fsm, [(1100, 400), (1070, 400), (1070, 540), (600, 540)], 'pk_ok (SYNC), rx_sh', lpos=0.3)
p.path(dsc, fsm, [(850, 290), (850, 500), (600, 500)], 'rb_exp, st_exp', lpos=0.5)
p.path(err, fsm, [(1100, 600), (600, 600)], 'struct_err, struct_code')
p.path(pk, err, [(1260, 420), (1260, 480)], 'exp_cnt, pk_st, sync_id')
p.path(tmr, err, [(1260, 700), (1260, 630)], 'to_cnt')
p.path(pk, tmr, [(1420, 400), (1460, 400), (1460, 800), (1420, 800)], 'pk_ok,\nfrm_launch')
p.path(tmr, fsm, [(1100, 820), (650, 820), (650, 640), (600, 640)], 'stl_ok, per_ok', lpos=-0.5)
p.path(fsm, out, [(450, 660), (450, 760)], 'rd_done, bm_r')
p.path(pk, out, [(1100, 410), (1080, 410), (1080, 700), (620, 700), (620, 780), (600, 780)], 'rx_sh', lpos=0.2)
p.path(out, outs, [(300, 840), (210, 840)], 'sense*')
p.path(fsm, outs, [(300, 620), (260, 620), (260, 790), (210, 790)], 'cfg_done, busy\nerr, st_*', lpos=0.6)
p.path(pk, core, [(1420, 150), (1520, 150)], 'cmd, cmd_valid')
p.path(pk, core, [(1420, 230), (1520, 230)], 'sdo_data, sdo_valid')
p.path(core, pk, [(1520, 310), (1420, 310)], 'sdi_data, sdi_valid')
p.path(core, pk, [(1520, 390), (1420, 390)], 'sync, sync_valid')
legend(p, 1490, 760)

# ============================================================================
# SAYFA 4: FSM
# ============================================================================
p = Page('4 - FSM', 1750, 1100)
pages.append(p)
p.text('Control FSM (p_ctrl) ve packer FSM (p_pack)', 30, 16, 900, 30, S_TITLE)
p.text('Yapısal hata (8/9/A/B) her durumdan önceliklidir: SYNC timeout -> CORE_RST, diğerleri -> IDLE; '
       'init_done = 0. stop bekletilir ve paket sınırında uygulanır (TEST hariç: test modundan çıkış atomik).',
       30, 48, 1600, 22)
W, H = 170, 56
idle = p.box('ST_IDLE', 60, 160, W, H, S_STATE)
mrp = p.box('ST_MR_PULSE', 420, 100, W, H, S_STATE)
mrw = p.box('ST_MR_WAIT', 420, 240, W, H, S_STATE)
cwr = p.box('ST_CFG_WR', 800, 160, W, H, S_STATE)
crd = p.box('ST_CFG_RD', 1180, 160, W, H, S_STATE)
stl = p.box('ST_SETTLE', 1180, 420, W, H, S_STATE)
tst = p.box('ST_TEST', 800, 420, W, H, S_STATE)
rd = p.box('ST_READ', 1180, 680, W, H, S_STATE)
per = p.box('ST_PERIOD', 800, 680, W, H, S_STATE)
crs = p.box('ST_CORE_RST', 60, 780, W, H, S_STATE)
p.path(idle, mrp, [(230, 175), (325, 175), (325, 128), (420, 128)], 'tam init\n+ HAS_MR', lpos=0.3)
p.path(mrp, mrw, [(505, 156), (505, 240)], 'MR_CLKS')
p.path(mrw, cwr, [(590, 268), (700, 268), (700, 202), (800, 202)], 'MR_WAIT_CLKS', lpos=-0.3)
p.path(idle, cwr, [(145, 160), (145, 70), (885, 70), (885, 160)], 'tam init (HAS_MR = false) ya da kısmi güncelleme (upd)', lpos=0.0)
p.path(cwr, crd, [(970, 188), (1180, 188)], 'upd\'deki yazmalar bitti')
p.path(crd, stl, [(1265, 216), (1265, 420)], 'eşleşti\ninit_done = 1', lpos=-0.2)
p.path(crd, mrp, [(1350, 188), (1400, 188), (1400, 40), (505, 40), (505, 100)], 'uyuşmazlık (< ERR_LIMIT) -> tam init', lpos=0.0)
p.path(idle, stl, [(145, 216), (145, 360), (1220, 360), (1220, 420)], 'init_done = 1, ayarlar aynı (doğrudan)', lpos=-0.2)
p.path(stl, tst, [(1180, 435), (970, 435)], 'stl_ok,\nst_pend')
p.path(stl, rd, [(1300, 476), (1300, 680)], 'stl_ok', lpos=-0.3)
p.path(tst, stl, [(970, 462), (1180, 462)], 'bitti, okuma\ngerek', lpos=0.0)
p.path(tst, idle, [(800, 448), (190, 448), (190, 216)], 'bitti (okuma yok) / st_fail', lpos=-0.3)
p.path(rd, per, [(1180, 708), (970, 708)], 'continuous')
p.path(per, rd, [(885, 736), (885, 800), (1265, 800), (1265, 736)], 'per_ok')
p.path(rd, crd, [(1350, 708), (1450, 708), (1450, 200), (1350, 200)], 'VERIFY_EVERY.\nokuma (vfy)', lpos=0.0)
p.path(per, tst, [(840, 680), (840, 476)], 'per_ok,\nst_pend', lpos=0.0)
p.path(rd, idle, [(1220, 736), (1220, 900), (40, 900), (40, 200), (60, 200)], 'continuous = 0 / stop / doğrulama sonrası (tek okuma)', lpos=-0.1)
p.path(per, idle, [(800, 695), (230, 695), (230, 216)], 'stop', lpos=-0.5)
p.path(crs, idle, [(145, 780), (145, 600), (170, 600), (170, 216)], 'CORE_RST_CLKS', lpos=-0.4)
p.box('<b>Packer FSM (p_pack)</b><br>PK_IDLE --frm_go--&gt; PK_CMD: pk_idx 0..7 '
      '(0 CONFIG clk_div = launch, 1 mode, 2 word length, 3 CS aktif, 4 TRANSFER W, 5 TRANSFER R '
      '(yazmada atlanır), 6 CS pasif, 7 SYNC) --SYNC komutu--&gt; PK_WAIT --doğru id\'li sync_valid--&gt; '
      'PK_IDLE (sync_id + 1). Launch öncesi stop: iptal (frm_cancel). Yapısal hatada PK_IDLE.',
      60, 960, 900, 110, S_NOTE)
p.box('<b>CFG_RD dönüşleri</b><br>eşleşti: vfy = 0 -&gt; SETTLE; vfy = 1 (doğrulama) -&gt; PERIOD '
      '(continuous) / TEST (st_pend) / IDLE.<br>uyuşmazlık: kod 2 (init) ya da 3 (doğrulama), '
      'init_done = 0; ERR_LIMIT\'te IDLE, aksi tam init.', 1000, 960, 700, 110, S_NOTE)
legend(p, 1500, 420)

# ============================================================================
# SAYFA 5: F8 okuma çerçevesi zamanlaması
# ============================================================================
p = Page('5 - F8 okuma zamanlamasi', 1750, 980)
pages.append(p)
p.text('0xF8 (Read All Banks) okuma çerçevesi: 40 SCK, ölçülen değerler (100 MHz, CLK_DIV = 2, CS_T = 1)', 30, 16, 1600, 30, S_TITLE)
p.text('Ölçek: 1 px = 2,5 ns. Değerler simülasyonda FPGA pininde ölçüldü (tb_hi8436_drv, docs/analiz/olcum_sonuc.txt). '
       'Datasheet: s.4-5 Fig 3/7, s.10 Tbl 12, s.19 AC tablo.', 30, 48, 1600, 22)
X0 = 200
def tx(t):
    return X0 + round(t * 0.4)
Y_CS, Y_SCK, Y_SI, Y_SO = 150, 250, 350, 450
for yy, nm in ((Y_CS, 'nCS'), (Y_SCK, 'SCK'), (Y_SI, 'SI (MOSI)'), (Y_SO, 'SO (MISO)')):
    p.text('<b>' + nm + '</b>', 30, yy - 10, 120, 30)
HIGH = -40
T_END = 2580
p.line([(tx(-200), Y_CS + HIGH), (tx(0), Y_CS + HIGH), (tx(0), Y_CS), (tx(T_END), Y_CS),
        (tx(T_END), Y_CS + HIGH), (tx(T_END + 300), Y_CS + HIGH)])
rises = [120 + 60 * k for k in range(8)] + [620 + 60 * k for k in range(32)]
pts = [(tx(-200), Y_SCK)]
for r in rises:
    pts += [(tx(r), Y_SCK), (tx(r), Y_SCK + HIGH), (tx(r + 30), Y_SCK + HIGH), (tx(r + 30), Y_SCK)]
pts.append((tx(T_END + 300), Y_SCK))
p.line(pts, S_WAVE.replace('strokeWidth=2', 'strokeWidth=1'))
bits = '11111000'
for k in range(8):
    p.box(bits[k], tx(rises[k] - 30), Y_SI - 30, tx(rises[k] + 30) - tx(rises[k] - 30), 26, S_BUS)
p.line([(tx(570), Y_SI - 4), (tx(T_END + 300), Y_SI - 4)], S_WAVE.replace('strokeWidth=2', 'strokeWidth=1'),
       '')
p.text('opcode 0xF8 (MSB önce)', tx(120), Y_SI + 2, 200, 20)
p.text('SI = 0 (SDO idle, entegre okumada SI\'yı yok sayar)', tx(700), Y_SI + 2, 400, 20)
falls = [570] + [650 + 60 * k for k in range(32)]
names = ['DB3 = SO<31:24>', 'DB2 = SO<23:16>', 'DB1 = SO<15:8>', 'DB0 = SO<7:0>']
for b in range(4):
    t0 = falls[8 * b]
    t1 = falls[8 * b + 8] if 8 * b + 8 < len(falls) else 2510
    p.box(html.escape(names[b]), tx(t0), Y_SO - 30, tx(t1) - tx(t0), 26, S_BUSO)
p.text('high-Z', tx(0), Y_SO - 26, 120, 20)
p.text('high-Z', tx(T_END) + 6, Y_SO - 26, 120, 20)
dy = 520
p.line([(tx(0), dy), (tx(120), dy)], S_DIM, 'tCES 120 ns (>= 5)')
p.line([(tx(570), dy + 40), (tx(620), dy + 40)], S_DIM, 'TRANSFER W -> R\n+20 ns')
p.line([(tx(2480), dy), (tx(T_END), dy)], S_DIM, 'tCHH 100 (>= 5)')
p.line([(tx(2510), dy + 40), (tx(T_END), dy + 40)], S_DIM, 'tCEH 70 (>= 5)')
p.line([(tx(0), dy + 90), (tx(T_END), dy + 90)], S_DIM, 'CS low 2580 ns (8 + 32 SCK, tCYC 60 ns >= 50)')
p.line([(tx(120), dy + 140), (tx(600), dy + 140)], S_DIM, '8 SCK: opcode')
p.line([(tx(620), dy + 140), (tx(2510), dy + 140)], S_DIM, '32 SCK: DB3 DB2 DB1 DB0 -> sense[31:0]')
p.box('<b>MISO örnekleme</b><br>SO, SCK düşen kenarından t_DV (&lt;= 20 ns) sonra değişir. Core MISO\'yu '
      'SCK yükselen kenarından 1 clk (10 ns) sonra, yani düşen kenar + 40 ns\'de örnekler. Pencere: SO '
      'değişimi &lt; 40 ns (tarama: 39 ns doğru, 40 ns hatalı). Kart + FPGA I/O bütçesi 20 ns. '
      'Testler T_SO = 5 ve 35 ns köşelerinde.', 30, 700, 560, 130, S_NOTE)
p.box('<b>Paket (launch -&gt; SYNC 2760 ns)</b><br>2002 CONFIG clk_div, 2100 CONFIG mode 0, 2208 word '
      'length 8, 11FE CS aktif, 0100 TRANSFER W 1 kelime (opcode), 0203 TRANSFER R 4 kelime, 11FF CS '
      'pasif, 30nn SYNC id.<br>Arka arkaya okuma aralığı 2800 ns (~357 kHz); iki paket arası nCS high '
      '&gt;= 210 ns (tCPH &gt;= 55).', 620, 700, 560, 130, S_NOTE)
p.box('<b>Diğer paketler</b><br>yazma 1 byte (02/04/1E): 0101, 1300 ns, CS 1120<br>yazma 2 byte '
      '(3A/3C, DB1 = hyst, DB0 = center): 0102, 1780 ns, CS 1600<br>okuma 1 byte (82/84/9E): 0100 '
      '0200, 1320 ns<br>okuma 2 byte (BA/BC): 0100 0201, 1800 ns', 1210, 700, 510, 130, S_NOTE)

# ============================================================================
# SAYFA 6: init politikası
# ============================================================================
p = Page('6 - Init politikasi', 1700, 1000)
pages.append(p)
p.text('Init politikası (INIT_EVERY_START = false, varsayılan)', 30, 16, 1200, 30, S_TITLE)
p.text('Driver entegreye son yazdığı ve geri okumayla doğruladığı ayarları shadow register\'larda tutar '
       '(init_done = cfg_done). start\'ta karar:', 30, 48, 1500, 22)
st = p.box(lab('IDLE: start / self_test_req', 'ayarlar latch\'lenir'), 80, 110, 240, 60, S_OURS)
d1 = p.box('eşik kodları<br>geçerli?', 120, 220, 160, 100, S_DEC)
rej = p.box(lab('Reddedilir', 'err = 1, kod 1 (CFG_RANGE)', 'SPI trafiği yok', 'init_done değişmez'), 30, 380, 200, 90, S_OURS)
d2 = p.box('INIT_EVERY_START<br>ya da<br>init_done = 0?', 420, 210, 190, 120, S_DEC)
full = p.box(lab('TAM INIT', 'nMR 200 ns + 1 us (HAS_MR)', '02 04 3A 3C 1E yaz', '82 84 BA BC 9E geri oku',
                 'settle 2 us', 'start -> veri ~ 19,3 us'), 380, 400, 270, 140, S_OURS)
d3 = p.box('ayarlar son<br>yazılandan<br>farklı?', 760, 210, 180, 120, S_DEC)
part = p.box(lab('KISMİ GÜNCELLEME (nMR yok)', 'yalnız değişen: 04 / 3A / 3C yaz', '84 / BA / BC geri oku',
                 'settle 2 us', 'start -> veri 6,2-6,7 us (tek)', '12,8 us (üçü)'), 710, 400, 280, 140, S_OURS)
dirr = p.box(lab('DOĞRUDAN OKUMA', 'yazma yok, nMR yok', 'start -> veri ~ 2,8 us',
                 'hysteresis latch\'leri korunur'), 1080, 220, 240, 100, S_OURS)
rdb = p.box(lab('F8 okuma(lar) / self-test', 'sense, sense_valid, sense_chg, sense_act'), 600, 640, 380, 70, S_OURS)
p.path(st, d1, [(200, 170), (200, 220)])
p.path(d1, rej, [(120, 270), (90, 270), (90, 380)], 'hayır', lpos=-0.3)
p.path(d1, d2, [(280, 270), (420, 270)], 'evet')
p.path(d2, full, [(515, 330), (515, 400)], 'evet')
p.path(d2, d3, [(610, 270), (760, 270)], 'hayır')
p.path(d3, part, [(850, 330), (850, 400)], 'evet')
p.path(d3, dirr, [(940, 270), (1080, 270)], 'hayır')
p.path(full, rdb, [(515, 540), (515, 675), (600, 675)], 'init_done = 1')
p.path(part, rdb, [(850, 540), (850, 640)], 'init_done = 1')
p.path(dirr, rdb, [(1130, 320), (1130, 675), (980, 675)], '')
p.box('<b>init_done = 0 olur</b> (sonraki start tam init yapar):<br>- rst_n<br>- yapısal hata 8 / 9 / A / B<br>'
      '- geri okuma hatası (kod 2), ERR_LIMIT ile durma<br>- periyodik doğrulama uyuşmazlığı (kod 3, POR)<br>'
      '- self-test hatası (kod 4)<br>- bir yazma dizisi başlarken (yarıda kesilirse içerik bilinmez)<br>'
      'Kısmi güncelleme geri okuması tutmazsa: tam init ile yeniden denenir.', 1260, 350, 420, 220, S_NOTE)
p.box('<b>Periyodik doğrulama (VERIFY_EVERY = 16)</b><br>Her 16 F8 okumada bir, okumadan hemen sonra '
      '82 84 BA BC 9E geri okunur. Eşik register\'ları her turda var: geçerli eşik asla 0x00 değil, '
      'POR / besleme kesintisi kesin yakalanır. Sayaç start\'lar arasında sürer (tek okuma kullanımında da '
      'çalışır). Uyuşmazlık: kod 3, init_done = 0, hemen tam init. Tespit gecikmesi &lt;= 16 okuma '
      '(T28: 13, 2, 16 okuma; tek okumada 12. start). VERIFY_EVERY = 0: POR fark edilmez.',
      1260, 590, 420, 200, S_NOTE)
p.box('<b>DS-10</b>: nMR\'ın hysteresis latch\'ine etkisi datasheet\'te açık değil (model: 0x00). '
      'Politika ile nMR yalnız açılışta ve hata sonrasında verilir; normal kullanımda band içindeki kanallar '
      'durumunu korur (T24). INIT_EVERY_START = true: her start\'ta nMR + tam init (eski davranış).',
      30, 780, 900, 90, S_NOTE)
legend(p, 960, 800)


# ---------------------------------------------------------------- çıktı
def write():
    x = ('<?xml version="1.0" encoding="UTF-8"?>\n'
         '<mxfile host="app.diagrams.net" agent="gen_drawio.py" type="device">'
         + ''.join(pg.xml(i + 1) for i, pg in enumerate(pages)) + '</mxfile>\n')
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(x)
    print('yazıldı:', OUT, f'({len(pages)} sayfa)')


# ---------------------------------------------------------------- önizleme
def _label_lines(v):
    v = re.sub(r'<br\s*/?>', '\n', v)
    return [html.unescape(t) for t in re.sub(r'<[^>]+>', '', v).split('\n')]


def preview(d):
    """Kaba SVG önizlemesi: kutular, kenar yolları ve etiketler (draw.io ile aynı noktalar)."""
    os.makedirs(d, exist_ok=True)
    for i, pg in enumerate(pages):
        o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{pg.w}" height="{pg.h}" '
             f'font-family="Helvetica, Arial" font-size="10"><rect width="100%" height="100%" fill="white"/>']
        for (x, y, w, h, sty, label) in pg.boxes.values():
            fill = re.search(r'fillColor=(#\w+|none)', sty)
            fill = fill.group(1) if fill else 'none'
            if sty.startswith('rhombus'):
                o.append(f'<polygon points="{x + w / 2},{y} {x + w},{y + h / 2} {x + w / 2},{y + h} {x},{y + h / 2}" '
                         f'fill="{fill}" stroke="#666"/>')
            elif not sty.startswith('text;'):
                dash = ' stroke-dasharray="5,3"' if 'dashed=1' in sty else ''
                sw = ' stroke-width="3"' if 'strokeWidth=3' in sty else ''
                o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="#666"{dash}{sw}/>')
            lines = _label_lines(label)
            ty = y + (h / 2 - 6 * len(lines) + 10 if 'verticalAlign=middle' in sty else 14)
            for t in lines:
                o.append(f'<text x="{x + 5}" y="{ty}">{html.escape(t)}</text>')
                ty += 12
        for (pts, label, sty, lpos) in pg.paths:
            col = '#b85450' if 'b85450' in sty else '#222'
            o.append('<polyline fill="none" stroke="%s" %s points="%s"/>' % (
                col, 'stroke-dasharray="5,3"' if 'dashed=1' in sty else '',
                ' '.join(f'{a},{b}' for a, b in pts)))
            if 'endArrow=none' not in sty:
                bx, by = pts[-1]
                o.append(f'<circle cx="{bx}" cy="{by}" r="3" fill="{col}"/>')
            if label:
                seg = [abs(a[0] - b[0]) + abs(a[1] - b[1]) for a, b in zip(pts, pts[1:])]
                half, k = sum(seg) * (lpos + 1) / 2, 0
                while k < len(seg) - 1 and half > seg[k]:
                    half -= seg[k]
                    k += 1
                a, b = pts[k], pts[k + 1]
                f = half / seg[k] if seg[k] else 0
                lx, ly = a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f
                lines = label.split('\n')
                wmax = max(len(t) for t in lines) * 5.4
                hh = 12 * len(lines)
                o.append(f'<rect x="{lx - wmax / 2}" y="{ly - hh / 2}" width="{wmax}" height="{hh}" '
                         f'fill="white" opacity="0.85"/>')
                for j, t in enumerate(lines):
                    o.append(f'<text x="{lx}" y="{ly - hh / 2 + 10 + 12 * j}" text-anchor="middle" '
                             f'fill="#0b4f9c">{html.escape(t)}</text>')
        o.append('</svg>')
        with open(os.path.join(d, f'page{i + 1}.svg'), 'w', encoding='utf-8') as f:
            f.write('\n'.join(o))


if __name__ == '__main__':
    write()
    if '--preview' in sys.argv:
        preview(sys.argv[sys.argv.index('--preview') + 1])
