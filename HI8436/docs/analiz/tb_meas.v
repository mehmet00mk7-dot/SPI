`timescale 1ns/100ps
// ============================================================================
// tb_meas.v - ANALİZ ÖLÇÜMÜ (RTL değil, test değil): common/rtl/async/spi_exec
// netlist'ini ANALIZ.md'de önerilen HI-8436 paketleriyle sürer ve SPI zamanlamasını
// ölçer: CS low süresi, SCK sayısı, tCES/tCHH/tCEH, SCK high/low, ardışık paketler
// arası tCPH, MOSI tDS/tDH, paket launch -> SYNC süresi. Slave basit bir HI-8436
// benzeridir (Mode 0; opcode yükselen kenarda, SO düşen kenardan SO_DLY sonra).
// SO_DLY taranarak MISO örnekleme penceresi bulunur (run_olcum.sh).
// Datasheet: DS8436 Rev. L, Table 2 (s.3), Fig. 5-7 (s.5), AC tablo (s.19).
// ============================================================================
module tb_meas;
  parameter CS_T = 1;
  parameter real SO_DLY = 15.0;   // SCK düşen kenarından SO değişimine (tDV)
  parameter DW = 8;
  reg clk=0, rstn=0; always #5 clk=~clk;
  reg [15:0] cmd; reg cmd_valid=0; wire cmd_ready;
  reg [DW-1:0] sdo_data; reg sdo_valid=0; wire sdo_ready;
  wire sdi_valid; wire [DW-1:0] sdi_data; wire sync_valid; wire [7:0] sync;
  wire sclk, mosi, sdo_t, tw; wire [0:0] cs; reg miso=1'bz;
  spi_exec u(.clk(clk),.resetn(rstn),.cmd_ready(cmd_ready),.cmd_valid(cmd_valid),.cmd(cmd),
    .sdo_data_valid(sdo_valid),.sdo_data_ready(sdo_ready),.sdo_data(sdo_data),
    .sdi_data_ready(1'b1),.sdi_data_valid(sdi_valid),.sdi_data(sdi_data),
    .sync_ready(1'b1),.sync_valid(sync_valid),.sync(sync),.echo_sclk(1'b0),
    .sclk(sclk),.sdo(mosi),.sdo_t(sdo_t),.sdi(miso),.cs(cs),.three_wire(tw));
  // ---- slave: opcode'u yükselen kenarda al, okuma ise SO'yu düşen kenarda sür
  reg [7:0] op; integer bitc; reg [31:0] rd; integer nrd; reg rdmode;
  reg [31:0] SENSE = 32'hA5C3_0F96;
  always @(negedge cs[0]) begin bitc=0; op=0; rdmode=0; miso <= #20 1'bz; end
  always @(posedge cs[0]) begin miso <= #20 1'bz; end
  always @(posedge sclk) if(!cs[0]) begin
    if (bitc<8) op = {op[6:0],mosi};
    bitc=bitc+1;
  end
  always @(negedge sclk) if(!cs[0]) begin
    if (bitc==8 && op[7]) begin rdmode=1; rd = (op==8'hF8)? SENSE : {8'h5A,8'h3C,16'h0}; nrd=0; end
    if (rdmode && bitc>=8) begin miso <= #(SO_DLY) rd[31-nrd]; nrd=nrd+1; end
  end
  // ---- ölçümler
  real t_csf, t_csr, t_lastrise, t_lastfall, t_firstrise, t_prev_csr; integer nsck;
  real tmin_hi, tmin_lo, t_r, t_f; real tcph_min; real tds_min, tdh_min, t_mosi;
  initial begin tcph_min=1e9; tmin_hi=1e9; tmin_lo=1e9; tds_min=1e9; tdh_min=1e9; t_prev_csr=-1; end
  always @(negedge cs[0]) begin t_csf=$realtime; nsck=0; t_firstrise=-1;
     if (t_prev_csr>0 && t_csf-t_prev_csr<tcph_min) tcph_min=t_csf-t_prev_csr; end
  always @(posedge cs[0]) if ($realtime>1) begin t_csr=$realtime; t_prev_csr=t_csr;
     $display("  CS low %0.1f ns | SCK=%0d | tCES=%0.1f tCHH=%0.1f tCEH=%0.1f", t_csr-t_csf, nsck,
        t_firstrise-t_csf, t_csr-t_lastrise, t_csr-t_lastfall); end
  always @(posedge sclk) if(!cs[0]) begin nsck=nsck+1; if(t_firstrise<0) t_firstrise=$realtime; t_lastrise=$realtime;
     t_r=$realtime; if(t_f>0 && t_r-t_f<tmin_lo) tmin_lo=t_r-t_f;
     if ($realtime - t_mosi < tds_min) tds_min=$realtime-t_mosi; end
  always @(negedge sclk) if(!cs[0]) begin t_lastfall=$realtime; t_f=$realtime;
     if(t_f-t_r<tmin_hi) tmin_hi=t_f-t_r; end
  always @(mosi) begin t_mosi=$realtime; if (!cs[0] && $realtime-t_r < tdh_min) tdh_min=$realtime-t_r; end
  // ---- komut sürücü
  task send(input [15:0] c); begin cmd<=c; cmd_valid<=1; @(posedge clk); while(!cmd_ready) @(posedge clk); cmd_valid<=0; end endtask
  reg [7:0] sq [0:7]; integer sn, si;
  always @(posedge clk) if (sdo_valid && sdo_ready) begin si=si+1; if (si<sn) sdo_data<=sq[si]; else sdo_valid<=0; end
  task load(input integer n, input [7:0] a, input [7:0] b, input [7:0] c); begin
    sq[0]=a; sq[1]=b; sq[2]=c; sn=n; si=0; sdo_data<=a; sdo_valid<=1; end endtask
  real t_l; reg [31:0] got; integer nw;
  always @(posedge clk) if (sdi_valid) begin got={got[23:0],sdi_data[7:0]}; nw=nw+1; end
  task pkt(input integer kind, input [7:0] id); begin  // 0: read F8, 1: write 2 data byte, 2: write 1 data byte, 3: read 1 byte, 4: read 2 byte
    nw=0; got=0;
    if (kind==0) load(1,8'hF8,0,0); else if (kind==1) load(3,8'h3A,8'h0A,8'h14);
    else if (kind==2) load(2,8'h04,8'h05,0); else if (kind==3) load(1,8'h84,0,0); else load(1,8'hBA,0,0);
    t_l=$realtime;   // launch: ilk komutun kabulü (aşağıdaki send içinde)
    send(16'h2002); t_l=$realtime-10; send(16'h2100); send(16'h2208); send(16'h1000|(CS_T<<8)|16'h00FE);
    if (kind==0) begin send(16'h0100); send(16'h0203); end
    else if (kind==1) send(16'h0102); else if (kind==2) send(16'h0101);
    else if (kind==3) begin send(16'h0100); send(16'h0200); end
    else begin send(16'h0100); send(16'h0201); end
    send(16'h1000|(CS_T<<8)|16'h00FF); send(16'h3000|id);
    @(posedge clk); while(!sync_valid) @(posedge clk);
    $display("  kind=%0d launch->SYNC %0.1f ns, okunan=%h (kelime %0d)", kind, $realtime-t_l, got, nw);
  end endtask
  initial begin
    repeat(5) @(posedge clk); rstn<=1; repeat(5) @(posedge clk);
    $display("CS_T=%0d SO_DLY=%0.1f", CS_T, SO_DLY);
    pkt(1,1); pkt(2,2); pkt(3,3); pkt(4,6); pkt(0,4); pkt(0,5);
    $display("  SCK high min %0.1f low min %0.1f | tCPH min (ardışık paket) %0.1f | MOSI tDS min %0.1f tDH min %0.1f",
       tmin_hi, tmin_lo, tcph_min, tds_min, tdh_min);
    if (got !== SENSE) $display("RESULT FAIL"); else $display("RESULT OK");
    $finish;
  end
endmodule
