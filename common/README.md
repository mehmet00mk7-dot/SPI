# common: ortak SPI master core (spi_exec)

Bütün entegre driver'ları (AD7923, HI8436, …) aynı SPI master core'unu kullanır. Core
ADI HDL `hdl_2026_r1` (commit `b62abef`) `spi_engine_execution`'ın VHDL çevirisidir.
Çeviri, async reset sürümü ve doğrulamanın ayrıntısı: `../AD7923/README.md`
(core ilk olarak AD7923 işinde yazıldı; dosyalar oradan buraya değiştirilmeden taşındı).

**Bu klasördeki core dosyalarına dokunulmaz** (CLAUDE.md kural 1). Her işin başında ve
sonunda `sim/run_sha_check.sh` koşulur ve çıktısı rapora konur.

| Klasör | İçerik |
|---|---|
| `vendor/adi/` | Orijinal ADI Verilog (read-only, SHA-256 kontrollü) |
| `rtl/async/` | **Kullanılan core.** `spi_exec.vhd`, `spi_exec_shiftreg.vhd` (async reset, aktif-düşük `resetn`) |
| `rtl/p1/` | Birebir çeviri (sync reset). Yalnız core lockstep doğrulaması için |
| `tb/` | `tb_lockstep.v`: orijinal Verilog ↔ P1 ↔ async, her clock bütün çıkışlar |
| `sim/` | `run_lockstep.sh`, `run_matrix.sh`, `run_mutation.sh`, `run_sha_check.sh`, `hash/sha256_core.txt`, `SONUCLAR.txt`, `log/` |

| Dosya | SHA-256 |
|---|---|
| vendor/adi/spi_engine_execution.v | f18ed3e82b865d2ab0b4a897d0a0d03584cf5bad0c0ee0422f0dd81d0c83ac86 |
| vendor/adi/spi_engine_execution_shiftreg.v | 70868cc989cda94ffe54bed3e99fa86520bc812980564003c7f64621c9233460 |

Driver'dan kullanım: driver'ın sim script'i core'u `../../common/rtl/async/` yolundan analiz eder
(örnek: `AD7923/sim/run_ad7923_drv_vhdl.sh`, `CORE` değişkeni).

## Çalıştırma

```
cd common/sim
./run_sha_check.sh                            # core değişmezlik kontrolü
./run_lockstep.sh 16 1 1 0 2 2 1 1 200000     # DW CS SDI DELAY CFG DIV SDO_DEF SEED CYCLES
./run_matrix.sh 1000000 "1 2 3"               # 8 konfigürasyon x 3 seed (log/ altına)
RST_MODE=1 ./run_matrix.sh 500000 "11 12"     # kısa async reset modu
./run_mutation.sh                             # 5 mutation, hepsi YAKALANDI olmalı
```
Gerekenler: GHDL ≥ 4 (`--synth`), Icarus Verilog ≥ 12, Python 3.
