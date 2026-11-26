#!/usr/bin/env python3
# ============================================================================
# gen_drawio.py  -  AD7923 driver + SPI master (spi_exec) blok diyagramı üretici
#
# Çıktı: docs/ad7923_spi_blok_diyagram.drawio (draw.io / diagrams.net, 5 sayfa)
#   1  ad7923_top        : üst seviye bağlantılar, reset yolu, AD7923 pin'leri
#   2  ad7923_drv        : driver iç blokları ve aralarındaki sinyaller
#   3  FSM               : control FSM (p_ctrl) ve command packer FSM (p_pack)
#   4  spi_exec          : SPI master control path
#   5  spi_exec_shiftreg : SPI master data path
# İçerik rtl/drv ve rtl/async'in güncel kaynağından çıkarılmıştır; blokların
# üzerinde ilgili process / sinyal adları yazılıdır.
#
# Her kenar, kaynak kutunun kenarındaki bir noktadan hedef kutunun kenarındaki
# bir noktaya giden açık (orthogonal) bir yol olarak tanımlanır; böylece draw.io
# çizimi ile önizleme aynıdır ve otomatik yönlendirme kutuların içinden geçmez.
#
# Kullanım: python3 -I docs/gen_drawio.py [--preview DIR]
#   --preview: her sayfanın SVG önizlemesini DIR'e yazar (yerleşim kontrolü için).
# ============================================================================
import html
import os
import re
import sys
from xml.sax.saxutils import quoteattr

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ad7923_spi_blok_diyagram.drawio')

# ---------------------------------------------------------------- stiller
_BOX = 'whiteSpace=wrap;html=1;align=center;verticalAlign=top;spacingTop=4;fontSize=11;'
S_REG = 'rounded=1;arcSize=6;fillColor=#dae8fc;strokeColor=#6c8ebf;' + _BOX
S_COMB = 'rounded=1;arcSize=6;fillColor=#fff2cc;strokeColor=#d6b656;' + _BOX
S_INST = 'rounded=0;fillColor=#d5e8d4;strokeColor=#82b366;' + _BOX
S_EXT = 'rounded=0;fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;' + _BOX
S_RST = 'rounded=1;arcSize=6;fillColor=#f8cecc;strokeColor=#b85450;' + _BOX
S_GRP = ('rounded=0;fillColor=none;strokeColor=#999999;dashed=1;align=left;verticalAlign=top;'
         'spacingLeft=8;spacingTop=4;whiteSpace=wrap;html=1;fontSize=12;')
S_NOTE = ('shape=note;size=12;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#999999;'
          'align=left;verticalAlign=top;spacingLeft=6;spacingTop=2;fontSize=11;')
S_STATE = ('rounded=1;arcSize=40;whiteSpace=wrap;html=1;fillColor=#e1d5e7;strokeColor=#9673a6;'
           'fontStyle=1;fontSize=11;align=center;verticalAlign=middle;')
S_TEXT = 'text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=11;'
S_TITLE = 'text;html=1;align=left;verticalAlign=top;fontSize=18;fontStyle=1;'
S_EDGE = ('edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;endSize=6;'
          'labelBackgroundColor=#ffffff;fontSize=10;')
S_EDGE_RST = S_EDGE + 'strokeColor=#b85450;dashed=1;fontColor=#b85450;'


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
        self.paths = []      # (noktalar, etiket, stil)
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
        """Kutunun kenarındaki mutlak noktayı (0..1) bağıl konuma çevirir."""
        x, y, w, h = self.boxes[cid][:4]
        rx, ry = (pt[0] - x) / w, (pt[1] - y) / h
        on_edge = (rx in (0, 1) and 0 <= ry <= 1) or (ry in (0, 1) and 0 <= rx <= 1)
        assert on_edge, f'{self.name}: nokta {pt} kutunun ({x},{y},{w},{h}) kenarında değil'
        return round(rx, 4), round(ry, 4)

    def path(self, src, tgt, pts, label='', style=S_EDGE, lpos=0.0):
        """pts[0] kaynak kutunun, pts[-1] hedef kutunun kenarında; aradakiler köşe noktaları.
        lpos: etiketin yol üzerindeki yeri (-1 kaynak ucu, 0 orta, 1 hedef ucu)."""
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

    def xml(self, idx):
        return (f'<diagram id="page{idx}" name={quoteattr(self.name)}>'
                f'<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" '
                f'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{self.w}" '
                f'pageHeight="{self.h}" math="0" shadow="0"><root><mxCell id="0"/>'
                f'<mxCell id="1" parent="0"/>{"".join(self.cells)}</root></mxGraphModel></diagram>')


def legend(p, x, y):
    mid = 'verticalAlign=middle;'
    p.box('<b>Açıklama</b>', x, y, 250, 170, S_GRP)
    p.box('register / clocked process', x + 10, y + 30, 230, 22, S_REG.replace('verticalAlign=top;', mid))
    p.box('kombinasyonel mantık', x + 10, y + 58, 230, 22, S_COMB.replace('verticalAlign=top;', mid))
    p.box('entity instance', x + 10, y + 86, 230, 22, S_INST.replace('verticalAlign=top;', mid))
    p.box('dış blok / dış dünya', x + 10, y + 114, 230, 22, S_EXT.replace('verticalAlign=top;', mid))
    p.text('<font color="#b85450">- - - &gt;  reset yolu</font>', x + 14, y + 140, 220, 20)


pages = []

# ============================================================================
# SAYFA 1: ad7923_top
# ============================================================================
p = Page('1 - ad7923_top', 1750, 1000)
pages.append(p)
p.text('ad7923_top: AD7923 okuma bloğu (driver + kanal register\'ları + SPI master)', 30, 16, 1200, 30, S_TITLE)
p.text('1 driver -> 1 spi_exec -> 1 AD7923, arbiter yok (gnt = \'1\'). 100 MHz tek clock. '
       'Generic\'ler: CLK_DIV = 2 (SCLK = 100 MHz / (2 x (CLK_DIV + 1)) = 16,7 MHz), CS_T = 1.',
       30, 48, 1400, 22)
sysb = p.box(lab('Sistem tarafı', '(FPGA fabric,', 'clk ile senkron)'), 30, 110, 170, 640, S_EXT)
p.box('<b>ad7923_top</b>', 300, 80, 1060, 830, S_GRP)
drv = p.box(lab('u_drv : ad7923_drv',
                'Control FSM (p_ctrl)', 'Timer\'lar: cycle 5 us, power-up 1 us,',
                'SYNC timeout 10 us, period', 'Channel selector', 'Command packer (p_pack)',
                'Expectation FIFO (p_fifo)', 'RX checker + output register (p_out)',
                '', 'gnt = \'1\' (sabit), req kullanılmaz'),
            420, 140, 320, 380, S_INST)
spi = p.box(lab('u_spi : spi_exec  (SPI master)',
                'ADI spi_engine_execution VHDL çevirisi', 'async reset, ECHO_SCLK = 0', '',
                'NUM_OF_CS = 1, DATA_WIDTH = 16', 'DEFAULT_SPI_CFG = 2 (Mode 2)',
                'DEFAULT_CLK_DIV = CLK_DIV', 'NUM_OF_SDI = 1, SDO_DEFAULT = "1"', 'SDI_DELAY = "00"', '',
                'sabit girişler: sdi_data_ready = \'1\',', 'sync_ready = \'1\', echo_sclk = \'0\'',
                'açık çıkışlar: sdo_t, three_wire'),
            1000, 140, 320, 380, S_INST)
regs = p.box(lab('u_regs : ad7923_ch_regs', 'p_regs: kanal başına sonuç register\'ları',
                 'chN_data / chN_valid / scan_done', 'data_valid -> chN_valid: 1 clk'),
             420, 640, 320, 150, S_INST)
crst = p.box(lab('p_core_resetn (flop)', 'rst_n = \'0\' -> core_resetn = \'0\' (async)',
                 'aksi: core_resetn <= not core_rst'), 1020, 660, 280, 100, S_RST)
adc = p.box(lab('AD7923', '4 kanal, 12 bit, 200 kSPS SAR ADC', 'SPI Mode 2 (CPOL = 1, CPHA = 0)'),
            1460, 160, 240, 300, S_EXT)
rsync = p.box(lab('Reset synchronizer', 'async assert, sync deassert', 'PLL lock\'a bağlı'),
              30, 830, 220, 80, S_RST)

p.path(sysb, drv, [(200, 200), (420, 200)], 'start, stop, continuous\nch_mask[3:0], period_us[15:0]\nrange_sel, coding_sel')
p.path(drv, sysb, [(420, 330), (200, 330)], 'busy, err')
p.path(drv, sysb, [(420, 450), (200, 450)], 'data_valid, data_ch[1:0]\ndata[11:0]')
p.path(regs, sysb, [(420, 700), (200, 700)], 'ch0..3_data[11:0]\nch0..3_valid, scan_done')
p.path(drv, regs, [(580, 520), (580, 640)], 'data_valid, data_ch[1:0]\ndata[11:0], data_last')
p.path(drv, spi, [(740, 190), (1000, 190)], 'cmd[15:0], cmd_valid\n(<- cmd_ready)')
p.path(drv, spi, [(740, 260), (1000, 260)], 'sdo_data[15:0], sdo_valid\n(<- sdo_ready)')
p.path(spi, drv, [(1000, 330), (740, 330)], 'sdi_data[15:0], sdi_valid')
p.path(spi, drv, [(1000, 400), (740, 400)], 'sync[7:0], sync_valid')
p.path(drv, crst, [(740, 480), (880, 480), (880, 710), (1020, 710)], 'core_rst\n(senkron, 4 clk)')
p.path(crst, spi, [(1160, 660), (1160, 520)], 'core_resetn -> resetn', S_EDGE_RST)
p.path(spi, adc, [(1320, 200), (1460, 200)], 'spi_sclk')
p.path(spi, adc, [(1320, 270), (1460, 270)], 'spi_mosi (DIN)')
p.path(spi, adc, [(1320, 340), (1460, 340)], 'spi_cs_n (cs(0))')
p.path(adc, spi, [(1460, 410), (1320, 410)], 'spi_miso (DOUT)')
p.path(rsync, drv, [(250, 850), (390, 850), (390, 500), (420, 500)], 'rst_n', S_EDGE_RST, lpos=-0.2)
p.path(rsync, regs, [(250, 870), (405, 870), (405, 760), (420, 760)], '', S_EDGE_RST)
p.path(rsync, crst, [(250, 890), (1160, 890), (1160, 760)], 'rst_n', S_EDGE_RST)
legend(p, 1460, 490)
p.box('<b>Reset stratejisi</b><br>Async reset olarak yalnız rst_n kullanılır. u_drv ve u_regs rst_n\'yi '
      'doğrudan alır; core\'un resetn\'i p_core_resetn flop\'undan gelir (rst_n ile async assert, '
      'core_rst ile bir clock gecikmeli ve senkron). rst_n düşünce clock beklemeden bütün çıkışlar '
      'reset değerinde, spi_cs_n = \'1\'.', 1460, 680, 260, 150, S_NOTE)
p.box('<b>AD7923 frame</b> = 7 komutluk paket<br>CONFIG clk_div, CONFIG mode, CONFIG word length, '
      'CS on, TRANSFER (16 bit R/W), CS off, SYNC(id).<br>CS low 1,12 us; frame 1,3 us; '
      'CS düşen kenarları arası &gt;= 5 us.', 1460, 845, 260, 130, S_NOTE)

# ============================================================================
# SAYFA 2: ad7923_drv iç blokları
# ============================================================================
p = Page('2 - ad7923_drv', 1750, 1220)
pages.append(p)
p.text('ad7923_drv: iç bloklar', 30, 16, 900, 30, S_TITLE)
p.text('Bütün register\'lar rst_n ile async reset\'li (reset değerleri 0 / ST_IDLE / PK_IDLE). '
       'Soft clear\'lar (fifo_clr, per_rst, frm_launch, ST_PWR_WAIT dışı) senkron.', 30, 48, 1300, 22)

inp = p.box(lab('Kontrol girişleri', 'start, stop', 'continuous', 'ch_mask[3:0]', 'period_us[15:0]',
                'range_sel, coding_sel'), 30, 300, 180, 120, S_EXT)
outs = p.box(lab('Sonuç çıkışları', 'data_valid, data_ch[1:0]', 'data[11:0], data_last', 'busy, err'),
             30, 900, 180, 100, S_EXT)
core = p.box(lab('spi_exec', '(SPI master)', '', 'komut / sdo /', 'sdi / sync', 'valid-ready', 'stream\'leri'),
             1620, 260, 120, 600, S_EXT)
sel = p.box(lab('Channel selector (comb)', 'first_ch(mask_cur) -> sel_first',
                'next_ch(mask_cur, cur_ch) -> sel_next, sel_last'), 310, 90, 320, 80, S_COMB)
ctrl = p.box(lab('Control FSM  (p_ctrl)', 'state: ST_IDLE ... ST_CORE_RST (sayfa 3)',
                 'mask_cur, period_cur, cur_ch', 'chip_sel, chip_sel_vld, pwr_done',
                 'stop_pend, err_r, err_scan, err_cnt', 'rst_cnt, core_rst_r', '',
                 'frame isteği: frm_go, frm_pend, frm_dummy,', 'frm_disc, frm_wch, frm_ech, frm_last,',
                 'frm_derr', '', 'çıkışlar: busy, err, core_rst, fifo_clr,', 'per_rst'),
             310, 260, 320, 320, S_REG)
tmr = p.box('<b>Timer\'lar</b>', 310, 660, 320, 200, S_GRP)
p.box(lab('p_cyc: cycle timer', 'launch\'ta 0; 500 clk (5 us) -> cyc_ok'), 325, 690, 290, 46, S_REG)
p.box(lab('p_pwr: power-up timer', 'ST_PWR_WAIT\'te 100 clk (1 us) -> pwr_ok'), 325, 744, 290, 46, S_REG)
p.box(lab('p_per: period timer', 'us prescaler + us sayacı -> per_ok'), 325, 798, 290, 46, S_REG)
se = p.box(lab('struct_err (comb)', 'to_hit or sync_err or fifo_unf'), 840, 90, 320, 70, S_COMB)
pack = p.box(lab('Command packer  (p_pack)', 'pk_st: PK_IDLE / PK_CMD / PK_WAIT',
                 'pk_idx 0..6, pk_dummy, pk_wch', 'sync_id (frame başına + 1)',
                 'sdo_r, sdo_valid_r (launch\'ta kurulur)', 'to_cnt: SYNC timeout (1000 clk) -> to_hit', '',
                 'comb: cmd_i mux (7 komut), cmd_valid_i,', 'cmd_hs, frm_launch, frm_done, sync_err,',
                 'frm_cancel, pk_launched, req'),
             840, 260, 320, 320, S_REG)
fifo = p.box(lab('Expectation FIFO  (p_fifo)', '2 kayıt: {frm_last, frm_disc, frm_ech}',
                 'push: frm_launch, pop: sdi_valid', 'fifo_clr: senkron temizleme',
                 'çıkış: exp_last, exp_disc, exp_ch', 'fifo_unf: FIFO boşken sdi_valid'),
             840, 660, 320, 160, S_REG)
rx = p.box(lab('RX checker (comb)', 'rx_take = sdi_valid and', 'not exp_disc',
               'rx_lead_ok: sdi_data[15:14] = "00"', 'rx_addr_ok: sdi_data[13:12] = exp_ch'),
           1250, 660, 280, 110, S_COMB)
outr = p.box(lab('Output register  (p_out)', 'data_valid_r, data_ch_r, data_r,', 'data_last_r',
                 'rx_err_p (format / adres hatası, 1 clk)'), 1250, 880, 280, 90, S_REG)

p.path(inp, ctrl, [(210, 330), (310, 330)], 'start, stop\ncontinuous\nch_mask\nperiod_us')
p.path(inp, pack, [(120, 300), (120, 245), (900, 245), (900, 260)], 'range_sel, coding_sel', lpos=-0.3)
p.path(ctrl, sel, [(400, 260), (400, 170)], 'mask_cur, cur_ch')
p.path(sel, ctrl, [(540, 170), (540, 260)], 'sel_first, sel_next,\nsel_last')
p.path(ctrl, pack, [(630, 300), (840, 300)], 'frm_go, frm_dummy, frm_wch')
p.path(pack, ctrl, [(840, 400), (630, 400)], 'frm_done, frm_cancel')
p.path(se, ctrl, [(860, 160), (860, 210), (600, 210), (600, 260)], 'struct_err, to_hit')
p.path(se, pack, [(1000, 160), (1000, 260)], 'struct_err')
p.path(pack, se, [(1100, 260), (1100, 160)], 'to_hit\nsync_err')
p.path(fifo, se, [(1160, 690), (1200, 690), (1200, 125), (1160, 125)], 'fifo_unf')
p.path(ctrl, fifo, [(630, 540), (700, 540), (700, 740), (840, 740)], 'frm_last\nfrm_disc\nfrm_ech\nfifo_clr', lpos=0.1)
p.path(pack, fifo, [(1000, 580), (1000, 660)], 'frm_launch')
p.path(pack, tmr, [(870, 580), (870, 610), (660, 610), (660, 700), (630, 700)], 'frm_launch', lpos=-0.33)
p.path(tmr, pack, [(630, 820), (780, 820), (780, 630), (920, 630), (920, 580)], 'cyc_ok')
p.path(ctrl, tmr, [(400, 580), (400, 660)], 'state, per_rst')
p.path(tmr, ctrl, [(540, 660), (540, 580)], 'pwr_ok, per_ok')
p.path(fifo, rx, [(1160, 720), (1250, 720)], 'exp_disc\nexp_ch\nexp_last')
p.path(rx, outr, [(1390, 770), (1390, 880)], 'rx_take, rx_lead_ok,\nrx_addr_ok', lpos=0.2)
p.path(outr, ctrl, [(1250, 910), (270, 910), (270, 540), (310, 540)], 'rx_err_p', lpos=-0.4)
p.path(outr, outs, [(1250, 950), (210, 950)], 'data_valid, data_ch, data, data_last', lpos=0.3)
p.path(ctrl, outs, [(330, 580), (330, 620), (120, 620), (120, 900)], 'busy, err')
p.path(pack, core, [(1160, 290), (1620, 290)], 'cmd[15:0], cmd_valid', lpos=0.3)
p.path(core, pack, [(1620, 340), (1160, 340)], 'cmd_ready', lpos=-0.3)
p.path(pack, core, [(1160, 400), (1620, 400)], 'sdo_data[15:0], sdo_valid', lpos=0.3)
p.path(core, pack, [(1620, 460), (1160, 460)], 'sdo_ready, sync[7:0], sync_valid', lpos=-0.3)
p.path(pack, core, [(1160, 540), (1620, 540)], 'req  (gnt = \'1\' sabit)', lpos=0.3)
p.path(core, rx, [(1620, 700), (1530, 700)], 'sdi_data[15:0]\nsdi_valid')
p.path(core, fifo, [(1620, 800), (1160, 800)], 'sdi_valid (pop)', lpos=-0.5)
p.path(ctrl, core, [(630, 560), (730, 560), (730, 1080), (1680, 1080), (1680, 860)],
       'core_rst  (ad7923_top: p_core_resetn)')
p.box('<b>Bir frame\'in akışı</b><br>1) FSM frm_go ile frame ister.<br>2) Packer 7 komutu sırayla verir; '
      'ilk komut cyc_ok (5 us) ve gnt bekler. Kabulü = launch: sdo kelimesi kurulur, FIFO\'ya beklenti '
      'yazılır, SYNC timeout başlar.<br>3) MISO kelimesi gelir (sdi_valid): FIFO\'dan beklenti okunur, '
      'RX checker kontrol eder, p_out data_valid verir.<br>4) SYNC(id) gelir: frm_done, FSM sonraki adıma geçer.',
      1250, 80, 340, 170, S_NOTE)
legend(p, 30, 1030)

# ============================================================================
# SAYFA 3: FSM'ler
# ============================================================================
p = Page('3 - FSM', 1750, 1100)
pages.append(p)
p.text('ad7923_drv: Control FSM (p_ctrl) ve Command packer FSM (p_pack)', 30, 16, 1200, 30, S_TITLE)
p.text('<b>Control FSM (p_ctrl)</b>', 60, 80, 400, 24)
W, H = 170, 56
st = {}
for name, x, y in [('ST_IDLE', 60, 330), ('ST_PWR_DUMMY', 330, 130), ('ST_PWR_WAIT', 640, 130),
                   ('ST_SCAN_START', 950, 330), ('ST_PERIOD_WAIT', 640, 430), ('ST_SELECT', 950, 640),
                   ('ST_MEAS', 640, 640), ('ST_SCAN_END', 330, 640), ('ST_CORE_RST', 60, 880)]:
    st[name] = p.box(name, x, y, W, H, S_STATE)
anys = p.box(lab('her durum (ST_CORE_RST hariç)', 'to_hit -> ST_CORE_RST',
                 'sync_err / fifo_unf -> ST_IDLE', '(err <= 1, pwr_done <= 0)'),
             330, 860, 230, 96, 'rounded=1;dashed=1;fillColor=#ffffff;strokeColor=#9673a6;' + _BOX)
p.path(st['ST_IDLE'], st['ST_PWR_DUMMY'], [(145, 330), (145, 158), (330, 158)], 'start, mask /= 0\npwr_done = 0')
p.path(st['ST_IDLE'], st['ST_SCAN_START'], [(230, 350), (950, 350)], 'start, mask /= 0, pwr_done = 1')
p.path(st['ST_PWR_DUMMY'], st['ST_PWR_WAIT'], [(500, 158), (640, 158)], 'frm_done\n(dummy bitti)')
p.path(st['ST_PWR_WAIT'], st['ST_SCAN_START'], [(810, 158), (1035, 158), (1035, 330)], 'pwr_ok (1 us)')
p.path(st['ST_SCAN_START'], st['ST_SELECT'], [(1035, 386), (1035, 640)], 'chip_sel_vld = 0 veya\nchip_sel /= sel_first')
p.path(st['ST_SCAN_START'], st['ST_MEAS'], [(980, 386), (980, 560), (760, 560), (760, 640)], 'select gerekmez')
p.path(st['ST_SELECT'], st['ST_MEAS'], [(950, 668), (810, 668)], 'frm_done\n(chip_sel <= ilk)')
p.path(st['ST_MEAS'], st['ST_MEAS'], [(690, 696), (690, 760), (760, 760), (760, 696)],
       'frm_done, son kanal değil (cur_ch <= sonraki)')
p.path(st['ST_MEAS'], st['ST_SCAN_END'], [(640, 668), (500, 668)], 'frm_done ve\n(son kanal veya\nveri hatası)')
p.path(st['ST_SCAN_END'], st['ST_PERIOD_WAIT'], [(415, 640), (415, 458), (640, 458)], 'continuous,\nstop yok, mask /= 0')
p.path(st['ST_PERIOD_WAIT'], st['ST_SCAN_START'], [(810, 458), (900, 458), (900, 370), (950, 370)], 'per_ok')
p.path(st['ST_SCAN_END'], st['ST_IDLE'], [(330, 680), (200, 680), (200, 386)],
       'continuous = 0 / stop /\nmask = 0 / ERR_LIMIT')
p.path(st['ST_CORE_RST'], st['ST_IDLE'], [(100, 880), (100, 386)], 'rst_cnt =\nCORE_RST_CLKS - 1')
p.path(anys, st['ST_CORE_RST'], [(330, 908), (230, 908)], 'to_hit')
p.box('<b>Notlar</b><br><b>stop:</b> stop_now (stop veya stop_pend) ile ST_PWR_DUMMY, ST_PWR_WAIT, '
      'ST_SCAN_START, ST_SELECT, ST_MEAS, ST_PERIOD_WAIT -&gt; ST_IDLE. Frame durumlarında yalnız '
      'frm_pend = 0 iken veya frm_cancel (launch öncesi) ile; launch olmuş frame SYNC\'e kadar tamamlanır.'
      '<br><b>Frame isteği:</b> frm_pend = 0: frm_go + parametreler; frm_pend = 1: frm_done veya '
      'frm_cancel beklenir.<br><b>ST_SCAN_END:</b> err_scan ise err_cnt + 1, değilse 0; err_cnt = '
      'ERR_LIMIT - 1 iken hatalı tarama: pwr_done <= 0, ST_IDLE. Yeni mask / period burada örneklenir.',
      640, 830, 520, 200, S_NOTE)

p.text('<b>Command packer FSM (p_pack)</b>', 1250, 120, 400, 24)
pk = {}
for name, x, y in [('PK_IDLE', 1300, 200), ('PK_CMD', 1300, 420), ('PK_WAIT', 1300, 640)]:
    pk[name] = p.box(name, x, y, W, H, S_STATE)
p.path(pk['PK_IDLE'], pk['PK_CMD'], [(1360, 256), (1360, 420)], 'frm_go')
p.path(pk['PK_CMD'], pk['PK_IDLE'], [(1440, 420), (1440, 256)], 'frm_cancel')
p.path(pk['PK_CMD'], pk['PK_CMD'], [(1470, 437), (1530, 437), (1530, 459), (1470, 459)], 'cmd_hs,\npk_idx < 6')
p.path(pk['PK_CMD'], pk['PK_WAIT'], [(1385, 476), (1385, 640)], 'cmd_hs, pk_idx = 6')
p.path(pk['PK_WAIT'], pk['PK_IDLE'], [(1300, 668), (1240, 668), (1240, 228), (1300, 228)], 'sync_valid\n(sync_id + 1)')
p.box('<b>Paket</b> (pk_idx)<br>0 CONFIG clk_div (launch: cyc_ok + gnt)<br>1 CONFIG mode<br>'
      '2 CONFIG word length<br>3 CS on<br>4 TRANSFER 16 bit R/W<br>5 CS off<br>6 SYNC(sync_id)<br><br>'
      'struct_err: her durumdan PK_IDLE (o anda sync_valid varsa sync_id + 1)', 1240, 760, 330, 210, S_NOTE)

# ============================================================================
# SAYFA 4: spi_exec (control path)
# ============================================================================
p = Page('4 - spi_exec', 1750, 1180)
pages.append(p)
p.text('spi_exec: SPI master control path (ADI spi_engine_execution VHDL çevirisi, async reset)', 30, 16,
       1300, 30, S_TITLE)
p.text('Komutlar tek tek yürütülür; cmd_ready = idle. Bütün register\'lar resetn ile async reset\'li; '
       'idle ile yapılan temizlemeler senkron.', 30, 48, 1300, 22)
cin = p.box(lab('Komut stream\'i', 'cmd[15:0], cmd_valid', '-> cmd_ready'), 30, 120, 170, 80, S_EXT)
syo = p.box(lab('SYNC', 'sync[7:0], sync_valid', '<- sync_ready'), 30, 670, 170, 80, S_EXT)
sin = p.box(lab('SDO stream\'i', 'sdo_data[DW-1:0]', 'sdo_data_valid', '-> sdo_data_ready'), 30, 880, 170, 90, S_EXT)
sout = p.box(lab('SDI stream\'i', 'sdi_data, sdi_data_valid', '<- sdi_data_ready'), 30, 1000, 170, 80, S_EXT)
pins = p.box(lab('SPI pin\'leri', '', 'sclk', 'sdo', 'sdo_t', 'cs', 'three_wire', '', '<- sdi'),
             1620, 100, 110, 860, S_EXT)
dec = p.box(lab('Komut çözücü (comb)', 'inst = cmd[14:12]', 'exec_cmd = cmd_valid and idle',
                'exec_transfer / chipselect /', 'write / misc / cs_inv / sync'), 280, 100, 260, 120, S_COMB)
cmdd = p.box(lab('p_cmd_d1', 'cmd_d1: yürütülen komut', 'inst_d1 = cmd_d1[14:12]'), 280, 280, 260, 70, S_REG)
cfg = p.box(lab('p_config (WRITE)', 'cpha, cpol, three_wire_r, sdo_idle_state,', 'clk_div, word_length, left_aligned',
                'p_last_bit_count: word_length - 1', 'giriş: exec_write_cmd, cmd'), 280, 410, 260, 110, S_REG)
ena = p.box(lab('p_enables', 'sdo_enabled = cmd(8) (write)', 'sdi_enabled = cmd(9) (read)',
                'giriş: exec_transfer_cmd'), 280, 570, 260, 80, S_REG)
idl = p.box(lab('Idle FSM  (p_idle)', 'TRANSFER / CHIPSELECT / MISC kabul: idle <= 0',
                'bitiş: transfer_done / CS bekleme sonu /', 'SLEEP süresi / sync_ready -> idle <= 1'),
            640, 100, 300, 100, S_REG)
clkd = p.box(lab('Clock divider', 'p_clk_div_last: clk_div_last', 'p_clk_div: clk_div_counter, trigger',
                 'trigger_tx / trigger_rx (ntx_rx\'e göre)', 'yarı periyot = clk_div + 1 clk',
                 'giriş: clk_div, idle, wait_for_io'), 640, 280, 300, 120, S_REG)
cnt = p.box(lab('p_counters', 'ntx_rx (yarı periyot: tx / rx)', 'bit_counter, transfer_counter',
                'sleep_counter, sleep_counter_increment', 'comb: last_bit, end_of_word, first_bit,',
                'sleep_counter_compare'), 640, 460, 300, 130, S_REG)
syn = p.box(lab('p_sync', 'sync_valid_r (SYNC komutu)', 'sync = cmd_d1[7:0]'), 640, 670, 300, 70, S_REG)
xfer = p.box(lab('Transfer kontrolü', 'p_transfer: transfer_active, wait_for_io',
                 'p_last_transfer, p_transfer_done', 'p_pending: pending_sdi_data_valid',
                 'comb: io_ready1, io_ready2, sdo_enabled_io'), 1040, 100, 300, 130, S_REG)
csg = p.box(lab('CS generator', 'comb: cs_gen, cs_sleep_counter_compare,', 'cs_sleep_early_exit',
                'p_cs_sleep_repeat: öncesi / sonrası bekleme', 'p_cs_inv: cs_inv_mask_reg (CS_INV)',
                'p_cs: cs_r = cmd_d1 xor cs_inv_mask_reg', 'p_cs_activate: yeni CS -> SDI temizliği'),
            1040, 290, 300, 150, S_REG)
sclk = p.box(lab('p_sclk_int', 'transfer: cpol xor cpha xor ntx_rx', 'boşta: cpol'), 1040, 520, 300, 70, S_REG)
sdot = p.box(lab('p_sdo_t', 'transfer ve sdo_enabled: \'0\', aksi \'1\''), 1040, 630, 300, 60, S_REG)
outp = p.box(lab('p_out', 'pin register\'ları:', 'sclk, sdo, sdo_t', 'reset: CPOL /', 'SDO_DEFAULT / \'1\''),
             1400, 520, 150, 110, S_REG)
shr = p.box(lab('u_shiftreg : spi_exec_shiftreg  (data path, sayfa 5)',
                'SDO buffer, aligner, SDO shift register, RX delay line, SDI shift register',
                'kontrol girişleri: trigger_tx, trigger_rx, transfer_active, first_bit, cs_activate, '
                'sdo/sdi_enabled, cmd_d1, word_length, left_aligned, sdo_idle_state'),
            280, 880, 1060, 80, S_INST)

p.path(cin, dec, [(200, 160), (280, 160)])
p.path(dec, cmdd, [(410, 220), (410, 280)], 'cmd (kabulde)')
p.path(dec, idl, [(540, 130), (640, 130)], 'exec_transfer /\nchipselect / misc')
p.path(idl, dec, [(640, 180), (540, 180)], 'idle\n(cmd_ready)')
p.path(dec, cfg, [(280, 200), (250, 200), (250, 465), (280, 465)], 'exec_*')
p.path(dec, ena, [(280, 200), (250, 200), (250, 610), (280, 610)])
p.path(cmdd, csg, [(540, 300), (590, 300), (590, 240), (980, 240), (980, 330), (1040, 330)], 'cmd_d1')
p.path(cfg, clkd, [(540, 430), (600, 430), (600, 340), (640, 340)], 'clk_div')
p.path(cfg, cnt, [(540, 500), (640, 500)], 'word_length')
p.path(clkd, cnt, [(720, 400), (720, 460)], 'clk_div_last')
p.path(cnt, clkd, [(860, 460), (860, 400)], 'ntx_rx')
p.path(cnt, xfer, [(940, 480), (1010, 480), (1010, 200), (1040, 200)], 'last_bit\nend_of_word')
p.path(xfer, idl, [(1040, 130), (940, 130)], 'transfer_done')
p.path(cnt, csg, [(940, 540), (1025, 540), (1025, 420), (1040, 420)], 'sleep_counter')
p.path(dec, syn, [(540, 210), (570, 210), (570, 705), (640, 705)], 'exec_sync_cmd', lpos=0.66)
p.path(syn, syo, [(640, 725), (200, 725)], 'sync[7:0], sync_valid')
p.path(csg, pins, [(1340, 370), (1620, 370)], 'cs (cs_r)')
p.path(cnt, sclk, [(940, 555), (1040, 555)], 'ntx_rx')
p.path(sclk, outp, [(1340, 555), (1400, 555)], 'sclk_int')
p.path(sdot, outp, [(1340, 660), (1380, 660), (1380, 610), (1400, 610)], 'sdo_t_int')
p.path(outp, pins, [(1550, 575), (1620, 575)], 'sclk\nsdo\nsdo_t')
p.path(cnt, shr, [(640, 580), (610, 580), (610, 880)], 'kontrol', lpos=0.6)
p.path(shr, xfer, [(1300, 880), (1300, 860), (1370, 860), (1370, 215), (1340, 215)], 'sdo_io_ready', lpos=-0.55)
p.path(shr, outp, [(1340, 920), (1475, 920), (1475, 630)], 'sdo_int')
p.path(sin, shr, [(200, 925), (280, 925)])
p.path(shr, sout, [(280, 950), (240, 950), (240, 1040), (200, 1040)])
p.path(pins, shr, [(1675, 960), (1675, 990), (1340, 990), (1340, 960)], 'sdi')
p.box('<b>SPI zamanlaması</b><br>Bir SCLK periyodu = 2 yarı periyot x (clk_div + 1) clk.<br>'
      'ntx_rx = 0: trigger_tx, SDO\'ya yeni bit.<br>ntx_rx = 1: trigger_rx, SDI örneklemesi '
      '(SDI_DELAY + 1 clk sonra).<br>AD7923: clk_div = 2 -&gt; 16,7 MHz, Mode 2.', 280, 1020, 420, 110, S_NOTE)
p.box('<b>Komutlar</b> (cmd[14:12])<br>000 TRANSFER: [9] R, [8] W, [7:0] n - 1<br>001 CHIPSELECT: [9:8] bekleme, '
      'CS seviyeleri<br>010 WRITE: [9:8] clk_div / config / word length<br>011 MISC: [8] 0 SYNC(id), 1 SLEEP<br>'
      '100 CS_INV: maske', 730, 1020, 400, 120, S_NOTE)
legend(p, 1460, 1000)

# ============================================================================
# SAYFA 5: spi_exec_shiftreg (data path)
# ============================================================================
p = Page('5 - spi_exec_shiftreg', 1750, 920)
pages.append(p)
p.text('spi_exec_shiftreg: SPI master data path', 30, 16, 900, 30, S_TITLE)
p.text('Bütün register\'lar resetn ile async reset\'li. SDO shift register reset değeri SDO_DEFAULT; '
       'SDI shift register reset\'te 0, cs_activate ile senkron temizlenir.', 30, 48, 1400, 22)
sdin = p.box(lab('sdo_data stream\'i', 'sdo_data[DW-1:0]', 'sdo_data_valid'), 30, 140, 170, 80, S_EXT)
ctl = p.box(lab('Control path (spi_exec)', 'transfer_active, trigger_tx,', 'trigger_rx, first_bit,',
                'sdo_enabled, sdi_enabled,', 'current_cmd (cmd_d1),', 'sdo_idle_state, left_aligned,',
                'word_length, cs_activate'), 30, 330, 200, 170, S_EXT)
miso = p.box(lab('sdi', 'MISO pin(ler)i'), 30, 690, 170, 60, S_EXT)
buf = p.box(lab('p_sdo_buffer: SDO buffer', 'sdo_data_reg, data_sdo_v',
                'sdo_data_ready = boş veya sdo_toshiftreg', 'sdo_io_ready = data_sdo_v'), 290, 130, 280, 100, S_REG)
ali = p.box(lab('p_aligner', 'aligned_sdo_data =', 'sdo_data_reg << left_aligned', '(kısa kelime MSB\'ye)'),
            650, 130, 240, 100, S_REG)
sds = p.box(lab('p_sdo_shift: SDO shift register', 'data_sdo_shift (MSB önce)',
                'first_bit: yükle, trigger_tx: kaydır', 'SDO kapalı / TRANSFER dışı: sdo_idle_state',
                'sdo_int = MSB'), 970, 130, 300, 110, S_REG)
pin = p.box(lab('p_out (spi_exec)', 'sdo pin register\'ı'), 1370, 140, 180, 70, S_EXT)
rxd = p.box(lab('p_rx_delay: RX delay line', 'trigger_rx_d[SDI_D+1:0]', 'trigger_rx_s = trigger_rx,',
                'SDI_DELAY + 1 clk gecikmeli'), 290, 540, 280, 100, S_REG)
sdi = p.box(lab('g_sdi / p_sdi_shift: SDI shift register', '(MISO hattı başına)',
                'trigger_rx_s: sdi(i) içeri kayar', 'cs_activate: temizlenir', 'sdi_data = data_sdi_shift'),
            650, 540, 300, 110, S_REG)
scn = p.box(lab('p_sdi_counter', 'sdi_counter', 'last_sdi_bit: sdi_counter = word_length - 1'),
            650, 720, 300, 80, S_REG)
sdv = p.box(lab('p_sdi_valid', 'sdi_data_valid_r', 'kelime sonu (sdi_enabled): \'1\'', 'sdi_data_ready: \'0\''),
            1040, 710, 260, 100, S_REG)
sdout = p.box(lab('sdi_data stream\'i', 'sdi_data, sdi_data_valid', '<- sdi_data_ready'), 1370, 560, 200, 80, S_EXT)

p.path(sdin, buf, [(200, 180), (290, 180)])
p.path(buf, ali, [(570, 180), (650, 180)], 'sdo_data_reg')
p.path(ali, sds, [(890, 185), (970, 185)], 'aligned_\nsdo_data')
p.path(sds, pin, [(1270, 175), (1370, 175)], 'sdo_int')
p.path(sds, buf, [(1120, 240), (1120, 280), (430, 280), (430, 230)], 'sdo_toshiftreg')
p.path(buf, ctl, [(330, 230), (330, 300), (130, 300), (130, 330)], 'sdo_io_ready')
p.path(ctl, ali, [(230, 350), (770, 350), (770, 230)], 'left_aligned')
p.path(ctl, sds, [(230, 390), (1200, 390), (1200, 240)], 'trigger_tx, first_bit, sdo_enabled,\ncurrent_cmd, sdo_idle_state')
p.path(ctl, rxd, [(150, 500), (150, 570), (290, 570)], 'trigger_rx')
p.path(ctl, sdi, [(200, 500), (200, 520), (720, 520), (720, 540)], 'cs_activate')
p.path(rxd, sdi, [(570, 575), (650, 575)], 'trigger_rx_s')
p.path(rxd, scn, [(430, 640), (430, 760), (650, 760)], 'trigger_rx_s')
p.path(miso, sdi, [(200, 720), (620, 720), (620, 630), (650, 630)], 'sdi')
p.path(sdi, sdout, [(950, 590), (1370, 590)], 'sdi_data')
p.path(scn, sdv, [(950, 760), (1040, 760)], 'last_sdi_bit')
p.path(sdv, sdout, [(1300, 740), (1330, 740), (1330, 620), (1370, 620)], 'sdi_data_valid')
p.path(ctl, sdv, [(230, 480), (260, 480), (260, 860), (1170, 860), (1170, 810)], 'sdi_enabled')
p.path(ctl, scn, [(230, 460), (245, 460), (245, 785), (650, 785)], 'word_length')
legend(p, 1370, 700)


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
            if not sty.startswith('text;'):
                dash = ' stroke-dasharray="5,3"' if 'dashed=1' in sty else ''
                o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="#666"{dash}/>')
            ty = y + 14
            for t in _label_lines(label):
                o.append(f'<text x="{x + 5}" y="{ty}">{html.escape(t)}</text>')
                ty += 12
        for (pts, label, sty, lpos) in pg.paths:
            col = '#b85450' if 'b85450' in sty else '#222'
            o.append('<polyline fill="none" stroke="%s" %s points="%s"/>' % (
                col, 'stroke-dasharray="5,3"' if 'dashed=1' in sty else '',
                ' '.join(f'{a},{b}' for a, b in pts)))
            (ax, ay), (bx, by) = pts[-2], pts[-1]
            o.append(f'<circle cx="{bx}" cy="{by}" r="3" fill="{col}"/>')
            if label:
                seg = [abs(a[0] - b[0]) + abs(a[1] - b[1]) for a, b in zip(pts, pts[1:])]
                half, k = sum(seg) * (lpos + 1) / 2, 0
                while half > seg[k]:
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
