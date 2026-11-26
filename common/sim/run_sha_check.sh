#!/usr/bin/env bash
# Core değişmezlik kontrolü (CLAUDE.md kural 1): common/vendor/adi, common/rtl/async ve
# common/rtl/p1 dosyalarının SHA-256'sı sim/hash/sha256_core.txt ile birebir aynı olmalı.
# Orijinal ADI dosyaları ayrıca CLAUDE.md'deki sabit değerlerle karşılaştırılır.
# Her işin başında ve sonunda koşulur, çıktısı rapora konur.
#   ./run_sha_check.sh
set -e
cd "$(dirname "$0")/.."
rc=0
echo "SHA-256 (common/):"
find vendor/adi rtl/async rtl/p1 -type f | sort | xargs sha256sum | tee sim/build_sha_now.txt
if diff sim/hash/sha256_core.txt sim/build_sha_now.txt; then
  echo "sha256_core.txt ile: AYNI"
else
  echo "sha256_core.txt ile: FARKLI"; rc=1
fi
rm -f sim/build_sha_now.txt
for p in "f18ed3e82b865d2ab0b4a897d0a0d03584cf5bad0c0ee0422f0dd81d0c83ac86  vendor/adi/spi_engine_execution.v" \
         "70868cc989cda94ffe54bed3e99fa86520bc812980564003c7f64621c9233460  vendor/adi/spi_engine_execution_shiftreg.v"; do
  if echo "$p" | sha256sum -c --quiet -; then echo "ADI orijinal: ${p##* } AYNI"; else rc=1; fi
done
if [ $rc -eq 0 ]; then echo "SONUC: BASARILI"; else echo "SONUC: BASARISIZ"; fi
exit $rc
