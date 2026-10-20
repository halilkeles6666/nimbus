# Nimbus — kurgusal canlı mağaza

Klaxon'un **ayrı ve canlı** olarak izleyip onardığı örnek firma sitesi. Gerçekten
hata üretir; kendi kendini izleyip **telemetri** gönderir; Klaxon telemetriden
anomaliyi (LLM ile) saptar ve kararını `/heal` uç noktasını çağırarak uygular.

## Uç noktalar
- `GET /` — vitrin (vitrin bileşeni çökükse gerçekten **503**)
- `POST /checkout` — ödeme (ödeme bileşeni arızalıysa gerçekten **500**)
- `GET /panel` — arıza enjekte etme paneli (demo)
- `GET /healthz` — bileşen sağlık JSON'ı
- `POST /break` — `component`, `fault` → arıza enjekte eder ve hemen telemetri push eder
- `POST /heal` — `component`, `action` → aksiyon doğru fix ise arızayı giderir; JSON `{healthy}`

Faults → fix: bad_deploy→rollback_deploy · overloaded→scale_up · crashed→restart_service · queue_stuck→clear_queue · primary_down→failover

## Ortam değişkenleri
| Değişken | Açıklama |
|---|---|
| `KLAXON_INGEST_URL` | Klaxon'un alarm ucu, ör. `https://klaxon-wgno.onrender.com/api/alerts`. Telemetri adresi bundan türetilir (`/alerts`→`/telemetry`). |
| `TELEMETRY_INTERVAL` | (ops.) öz-izleme telemetri aralığı, sn (vars. 20). |
| `PORT` | (Render otomatik verir) |

## Yerel çalıştırma
```bash
bundle install
KLAXON_INGEST_URL=http://localhost:3000/api/alerts bundle exec puma -p 4000
```

## Render'a deploy
1. Bu repo'yu GitHub'a push et.
2. Render → New + → Blueprint → bu repo (render.yaml okunur).
3. `KLAXON_INGEST_URL` = Klaxon'un canlı `/api/alerts` adresi.
4. Deploy → verilen `*.onrender.com` adresinden mağazayı aç. `/panel`'den arıza ver.
