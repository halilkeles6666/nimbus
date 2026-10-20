# Nimbus — a standalone fake company store (its own app, deployed separately).
# It genuinely faults; when broken it PUSHES an alert to Klaxon, and exposes a
# token-protected /heal endpoint that Klaxon calls to actually fix it.
require "sinatra"
require "json"
require "net/http"
require "uri"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4000)

# ---- live fault state (in-memory; a demo doesn't need persistence) ----------
FAULTS = {}            # component => fault name
FAULT_LOCK = Mutex.new

COMPONENTS = {
  "magaza-vitrin"  => "Nimbus Vitrin",
  "magaza-katalog" => "Nimbus Katalog",
  "magaza-odeme"   => "Nimbus Ödeme",
  "magaza-db"      => "Nimbus Veritabanı"
}.freeze

# fault => (remediation that fixes it, human symptom for the pushed alert)
FAULTS_CATALOG = {
  "bad_deploy"   => [ "rollback_deploy", "Son dağıtımdan hemen sonra hata oranı fırladı; kaynak ve gecikme normal." ],
  "overloaded"   => [ "scale_up",        "Trafik birkaç katına çıktı; işlemciler doygun, kod değişmedi." ],
  "crashed"      => [ "restart_service", "Süreç yanıt vermiyor (health check FAIL); bellek tavan yaptı." ],
  "queue_stuck"  => [ "clear_queue",     "İş kuyruğu onbinlere birikti, disk dolmak üzere." ],
  "primary_down" => [ "failover",        "Birincil veritabanı düğümü erişilemez; replika sağlıklı." ]
}.freeze

def fault_of(component) = FAULT_LOCK.synchronize { FAULTS[component] }
def set_fault(component, fault) = FAULT_LOCK.synchronize { FAULTS[component] = fault }
def clear_fault(component) = FAULT_LOCK.synchronize { FAULTS.delete(component) }

def authorized?
  expected = ENV["NIMBUS_TOKEN"].to_s
  expected.empty? || params[:token].to_s == expected ||
    request.env["HTTP_X_NIMBUS_TOKEN"].to_s == expected
end

# ---- telemetry the store reports to Klaxon (self-monitoring) ----------------

# Realistic metrics per component given its (hidden) fault.
def metrics_for(fault)
  case fault
  when "bad_deploy"   then { error_rate: rand(18..26), p95: rand(120..220), count: rand(40..80) }
  when "overloaded"   then { error_rate: rand(1..4),   p95: rand(1800..3000), count: rand(60..120) }
  when "crashed", "primary_down" then { error_rate: 100, p95: rand(10..60), count: rand(30..60) }
  when "queue_stuck"  then { error_rate: rand(1..3),   p95: rand(300..800), count: rand(40..80) }
  else { error_rate: (rand * 0.4).round(2), p95: rand(90..170), count: rand(40..80) }
  end
end

# Snapshot of every component: measured metrics + a log-derived context line.
def telemetry_snapshot
  COMPONENTS.keys.to_h do |component|
    fault = fault_of(component)
    log = fault ? "#{FAULTS_CATALOG[fault][1]} [kaynak: Nimbus logları]" : "normal"
    [ component, metrics_for(fault).merge(log: log) ]
  end
end

def klaxon_telemetry_url
  explicit = ENV["KLAXON_TELEMETRY_URL"].to_s
  return explicit unless explicit.empty?
  ENV["KLAXON_INGEST_URL"].to_s.sub("/alerts", "/telemetry")
end

def push_telemetry
  url = klaxon_telemetry_url
  return if url.empty?
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = 4
  http.read_timeout = 8
  req = Net::HTTP::Post.new(uri)
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(components: telemetry_snapshot)
  http.request(req)
rescue => e
  warn "[Nimbus] telemetri gönderilemedi: #{e.class}: #{e.message}"
end

# ---- storefront (genuinely errors when faulted) -----------------------------

PRODUCTS = [
  [ 1, "Nimbus Kablosuz Kulaklık", "1.299 ₺", "🎧" ],
  [ 2, "Nimbus Akıllı Saat", "2.499 ₺", "⌚" ],
  [ 3, "Nimbus Bluetooth Hoparlör", "899 ₺", "🔊" ],
  [ 4, "Nimbus Taşınabilir Şarj", "449 ₺", "🔋" ]
].freeze

def down?(component)
  %w[crashed primary_down].include?(fault_of(component))
end

get "/" do
  if down?("magaza-vitrin")
    halt 503, error_page(503, "Vitrin şu anda açılamıyor",
      "Mağaza geçici olarak hizmet veremiyor. Ekibimiz durumdan haberdar; lütfen birazdan tekrar dene.")
  end
  cards = PRODUCTS.map { |_id, name, price, emoji|
    <<~CARD
      <article class="card">
        <div class="thumb">#{emoji}</div>
        <div class="card-body">
          <h3>#{name}</h3>
          <div class="price">#{price}</div>
          <form method="post" action="/checkout"><button class="btn btn-block">Sepete ekle</button></form>
        </div>
      </article>
    CARD
  }.join
  hero = <<~HERO
    <section class="hero">
      <div class="hero-text">
        <span class="badge">✨ Yeni sezon</span>
        <h1>Teknolojiyi<br>yanında taşı.</h1>
        <p>Nimbus seçkisiyle en sevilen cihazlar; ücretsiz kargo, 2 yıl garanti ve kapıda ödeme ile.</p>
        <a href="#urunler" class="btn btn-lg">Alışverişe başla</a>
      </div>
      <div class="hero-art">☁️</div>
    </section>
  HERO
  page("Nimbus — Online Mağaza",
    "#{hero}<h2 id='urunler' class='section-title'>Öne çıkanlar</h2><div class='grid'>#{cards}</div>")
end

post "/checkout" do
  if fault_of("magaza-odeme")
    halt 500, error_page(500, "Ödeme tamamlanamadı",
      "Ödeme işlemin şu anda gerçekleştirilemiyor. Kartından ücret alınmadı; lütfen birazdan tekrar dene.")
  end
  ref = "NMB-#{rand(100_000..999_999)}"
  body = <<~DONE
    <section class="centerbox">
      <div class="success-ring">✓</div>
      <h1>Siparişin alındı 🎉</h1>
      <p class="muted">Sipariş numaran <b>#{ref}</b>. Kargo bilgisi e-postana gönderildi.</p>
      <a class="btn btn-lg" href="/">Alışverişe devam et</a>
    </section>
  DONE
  page("Sipariş alındı", body)
end

# ---- control + health + remediation API -------------------------------------

get "/panel" do
  rows = COMPONENTS.map { |key, name|
    f = fault_of(key)
    buttons = FAULTS_CATALOG.keys.map { |fault|
      "<form method='post' action='/break' style='display:inline'><input type='hidden' name='component' value='#{key}'><input type='hidden' name='fault' value='#{fault}'><input type='hidden' name='token' value='#{params[:token]}'><button class='btn small'>#{fault}</button></form>"
    }.join(" ")
    heal = "<form method='post' action='/heal' style='display:inline'><input type='hidden' name='component' value='#{key}'><input type='hidden' name='action' value='#{f ? FAULTS_CATALOG[f][0] : ''}'><input type='hidden' name='token' value='#{params[:token]}'><button class='btn small ghost'>düzelt</button></form>"
    "<tr><td><b>#{name}</b><br><small>#{key}</small></td><td>#{f ? "<span class='bad'>#{f}</span> #{heal}" : "<span class='good'>sağlıklı</span>"}</td><td>#{buttons}</td></tr>"
  }.join
  token_warn = ENV["NIMBUS_TOKEN"].to_s.empty? || !params[:token].to_s.empty? ? "" : "<p style='color:#dc2626'>⚠️ Arıza vermek için önce token gir.</p>"
  token_box = "<form method='get' action='/panel' style='margin:0 0 14px'><input name='token' value='#{params[:token]}' placeholder='token' style='padding:8px;border:1px solid #e2e8f0;border-radius:8px;min-width:280px'> <button class='btn small'>Uygula</button></form>"
  page("Nimbus — Panel", "<h1>Durum paneli</h1><p>Bir bileşene arıza ver; site gerçekten bozulur ve Klaxon'a alarm gider.</p>#{token_box}#{token_warn}<table>#{rows}</table>")
end

post "/break" do
  halt 401, "unauthorized" unless authorized?
  component = params[:component]
  fault = params[:fault]
  halt 400, "bad component/fault" unless COMPONENTS.key?(component) && FAULTS_CATALOG.key?(fault)
  set_fault(component, fault)
  Thread.new { push_telemetry } # report immediately (self-monitor also reports on a timer)
  if request.accept?("application/json")
    content_type :json
    JSON.generate(ok: true, component: component, fault: fault)
  else
    redirect "/panel?token=#{params[:token]}"
  end
end

# Klaxon calls this to remediate. Clearing happens only if the action matches
# the fault's real fix — so a wrong remediation leaves the site broken.
post "/heal" do
  halt 401, "unauthorized" unless authorized?
  component = params[:component]
  action = params[:action].to_s
  current = fault_of(component)
  clear_fault(component) if current && action == FAULTS_CATALOG[current][0]
  content_type :json
  JSON.generate(component: component, action: action, healthy: fault_of(component).nil?)
end

get "/healthz" do
  content_type :json
  JSON.generate(components: COMPONENTS.keys.to_h { |c| [ c, { faulted: !fault_of(c).nil?, fault: fault_of(c) } ] })
end

# ---- layout -----------------------------------------------------------------

def error_page(code, heading, message)
  body = <<~ERR
    <section class="centerbox">
      <div class="error-ring">!</div>
      <div class="error-code">HTTP #{code}</div>
      <h1>#{heading}</h1>
      <p class="muted">#{message}</p>
      <a class="btn btn-lg" href="/">Vitrine dön</a>
    </section>
  ERR
  page("Bir sorun oluştu", body)
end

def page(title, body)
  <<~HTML
    <!doctype html><html lang="tr"><head>
    <meta charset="utf-8"><title>#{title}</title>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      :root{--brand:#4f46e5;--brand2:#7c3aed;--ink:#0f172a;--muted:#64748b;--bg:#f6f7fb;--line:#e8ebf2}
      body{font-family:Inter,system-ui,Segoe UI,sans-serif;background:var(--bg);color:var(--ink);line-height:1.55}
      a{color:inherit}
      .wrap{max-width:1040px;margin:0 auto;padding:0 20px}
      header{background:#fff;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:10}
      .nav{display:flex;align-items:center;justify-content:space-between;height:66px}
      .brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:21px;text-decoration:none;letter-spacing:-.01em}
      .brand .logo{width:30px;height:30px;border-radius:9px;background:linear-gradient(135deg,var(--brand),var(--brand2));display:grid;place-items:center;color:#fff;font-size:15px}
      .nav a.link{color:var(--muted);text-decoration:none;font-weight:500;margin-left:22px}
      .nav a.link:hover{color:var(--brand)}
      main{min-height:calc(100vh - 136px)}
      .hero{display:grid;grid-template-columns:1.3fr .7fr;gap:20px;align-items:center;background:linear-gradient(135deg,#eef2ff,#faf5ff);border:1px solid var(--line);border-radius:24px;padding:42px;margin:28px 0}
      .hero h1{font-size:44px;line-height:1.08;letter-spacing:-.025em;margin:12px 0 12px}
      .hero p{color:var(--muted);max-width:430px;margin-bottom:22px}
      .hero-art{font-size:120px;text-align:center}
      .badge{display:inline-block;background:#fff;border:1px solid var(--line);color:var(--brand);font-weight:600;font-size:13px;padding:5px 12px;border-radius:999px}
      .section-title{font-size:22px;margin:10px 0 16px}
      .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:18px;padding-bottom:44px}
      .card{background:#fff;border:1px solid var(--line);border-radius:18px;overflow:hidden;transition:transform .15s,box-shadow .15s}
      .card:hover{transform:translateY(-4px);box-shadow:0 14px 34px rgba(79,70,229,.13)}
      .thumb{font-size:66px;text-align:center;padding:26px 0;background:linear-gradient(135deg,#f8fafc,#eef2ff)}
      .card-body{padding:16px}
      .card-body h3{font-size:15px;font-weight:600;margin-bottom:6px}
      .price{color:var(--brand);font-weight:800;font-size:18px;margin-bottom:12px}
      .btn{display:inline-block;background:linear-gradient(135deg,var(--brand),var(--brand2));color:#fff;border:0;border-radius:11px;padding:11px 18px;font-weight:600;font-size:14px;cursor:pointer;text-decoration:none;font-family:inherit}
      .btn:hover{filter:brightness(1.07)}
      .btn-block{width:100%}.btn-lg{padding:13px 24px;font-size:15px}
      .btn.small{padding:6px 11px;font-size:12px;border-radius:9px}
      .btn.ghost{background:#eef2f7;color:var(--ink)}
      .centerbox{max-width:470px;margin:64px auto;text-align:center;background:#fff;border:1px solid var(--line);border-radius:22px;padding:48px 32px}
      .success-ring,.error-ring{width:86px;height:86px;border-radius:50%;display:grid;place-items:center;margin:0 auto 18px;font-size:44px;font-weight:800}
      .success-ring{background:#dcfce7;color:#16a34a}
      .error-ring{background:#fee2e2;color:#dc2626}
      .error-code{font-size:13px;font-weight:700;color:#dc2626;letter-spacing:.18em;margin-bottom:6px}
      .centerbox h1{font-size:24px;margin-bottom:8px}
      .muted{color:var(--muted);margin-bottom:22px}
      table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:16px;overflow:hidden;margin-top:12px}
      td,th{padding:13px 14px;border-bottom:1px solid var(--line);font-size:14px;text-align:left}
      th{background:#f8fafc;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
      tr:last-child td{border-bottom:0}
      h1{font-size:26px;margin:.1em 0 .5em}
      .good{color:#16a34a;font-weight:600}.bad{color:#dc2626;font-weight:700}
      small{color:var(--muted)}
      footer{border-top:1px solid var(--line);background:#fff;color:var(--muted);font-size:13px;padding:22px 0;text-align:center}
      @media(max-width:720px){.hero{grid-template-columns:1fr;padding:28px}.hero h1{font-size:34px}.hero-art{display:none}}
    </style></head>
    <body>
      <header><div class="wrap nav">
        <a class="brand" href="/"><span class="logo">☁</span> Nimbus</a>
        <nav><a class="link" href="/">Vitrin</a><a class="link" href="/panel">Durum paneli</a></nav>
      </div></header>
      <main><div class="wrap">#{body}</div></main>
      <footer><div class="wrap">Nimbus · online mağaza · <small>Klaxon demosu için kurgusal bir firmadır</small></div></footer>
    </body></html>
  HTML
end

# ---- self-monitoring loop: periodically report telemetry to Klaxon ----------
unless ENV["NIMBUS_NO_MONITOR"] == "1"
  Thread.new do
    interval = ENV.fetch("TELEMETRY_INTERVAL", "20").to_i
    loop do
      sleep interval
      push_telemetry
    end
  end
end
