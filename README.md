# Nimbus — kurgusal canlı mağaza

Klaxon'un **ayrı ve canlı** olarak izleyip onardığı örnek firma sitesi. Gerçekten
hata üretir; bozulunca Klaxon'a alarm **push eder**; Klaxon kararını `/heal`
uç noktasını çağırarak uygular ve siteyi düzeltir.

## Uç noktalar
- `GET /` — vitrin (vitrin bileşeni çökükse gerçekten **503**)
- `POST /checkout` — ödeme (ödeme bileşeni arızalıysa gerçekten **500**)
- `GET /panel` — arıza enjekte etme paneli (demo)
- `GET /healthz` — bileşen sağlık JSON'ı
- `POST /break` *(token)* — `component`, `fault` → arıza enjekte + Klaxon'a alarm push
- `POST /heal` *(token)* — `component`, `action` → aksiyon doğru fix ise arızayı giderir; JSON `{healthy}`

Faults → fix: bad_deploy→rollback_deploy · overloaded→scale_up · crashed→restart_service · queue_stuck→clear_queue · primary_down→failover

## Ortam değişkenleri
| Değişken | Açıklama |
|---|---|
| `NIMBUS_TOKEN` | `/break` ve `/heal`'i koruyan paylaşılan gizli token. **Klaxon'da da aynı değer** olmalı. |
| `KLAXON_INGEST_URL` | Alarmın gönderileceği Klaxon ucu, ör. `https://klaxon-wgno.onrender.com/api/alerts` |
| `PORT` | (Render otomatik verir) |

## Yerel çalıştırma
```bash
bundle install
NIMBUS_TOKEN=dev-token KLAXON_INGEST_URL=http://localhost:3000/api/alerts bundle exec puma -p 4000
```

## Render'a deploy
1. Bu klasörü kendi GitHub repo'suna push et.
2. Render → New + → Blueprint → bu repo (render.yaml okunur).
3. `NIMBUS_TOKEN` (güçlü bir değer) ve `KLAXON_INGEST_URL` (Klaxon'un canlı `/api/alerts`'ü) gir.
4. Deploy → verilen `*.onrender.com` adresinden mağazayı aç. `/panel`'den arıza ver.
5. Klaxon'da aynı `NIMBUS_TOKEN` ve `NIMBUS_URL` (bu sitenin adresi) env'lerini ayarla.
