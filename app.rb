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

# Push an alert to Klaxon's public JSON ingest when a component breaks.
def notify_klaxon(component, fault)
  url = ENV["KLAXON_INGEST_URL"].to_s
  return if url.empty?

  _, symptom = FAULTS_CATALOG[fault]
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = 4
  http.read_timeout = 8
  req = Net::HTTP::Post.new(uri)
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(
    routing_key: component,
    title: "#{COMPONENTS[component]} sorun yaşıyor",
    summary: "#{symptom} [kaynak: Nimbus canlı site]",
    dedup_key: "nimbus-#{component}")
  http.request(req)
rescue => e
  warn "[Nimbus] Klaxon'a bildirilemedi: #{e.class}: #{e.message}"
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
  halt 503, page("Bir şeyler ters gitti", "<div class='err'>503</div><p>Vitrin şu anda hizmet veremiyor. Ekibimiz durumdan haberdar.</p>") if down?("magaza-vitrin")
  cards = PRODUCTS.map { |id, name, price, emoji|
    "<div class='card'><div class='emoji'>#{emoji}</div><div class='name'>#{name}</div><div class='price'>#{price}</div><form method='post' action='/checkout'><button class='btn'>Satın al</button></form></div>"
  }.join
  page("Nimbus — Vitrin", "<h1>Teknolojiyi yanında taşı.</h1><div class='grid'>#{cards}</div>")
end

post "/checkout" do
  halt 500, page("Ödeme başarısız", "<div class='err'>500</div><p>Ödeme işlemin şu anda tamamlanamıyor. Lütfen birazdan tekrar dene.</p>") if fault_of("magaza-odeme")
  ref = "NMB-#{rand(100_000..999_999)}"
  page("Sipariş alındı", "<div class='ok'>✓</div><h1>Siparişin alındı 🎉</h1><p>Sipariş no: <b>#{ref}</b></p><a class='btn' href='/'>Alışverişe devam</a>")
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
  Thread.new { notify_klaxon(component, fault) } # fire-and-forget so /break returns fast
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

def page(title, body)
  <<~HTML
    <!doctype html><html><head><meta charset="utf-8"><title>#{title}</title>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
      :root{--p:#3062f6;--bg:#eef2f7;--s:#fff;--b:#e2e8f0;--t:#0f172a;--m:#64748b}
      body{margin:0;background:var(--bg);color:var(--t);font-family:system-ui,Segoe UI,Roboto,sans-serif}
      .top{background:var(--s);border-bottom:1px solid var(--b);padding:14px 20px;font-weight:800;font-size:20px}
      .top span{color:var(--p)}
      .wrap{max-width:900px;margin:0 auto;padding:24px 16px}
      h1{font-size:26px;margin:.2em 0 .6em}
      .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:14px}
      .card{background:var(--s);border:1px solid var(--b);border-radius:14px;padding:16px;text-align:center}
      .emoji{font-size:44px}.name{font-weight:600;margin:8px 0 2px}.price{color:var(--p);font-weight:700;margin-bottom:10px}
      .btn{background:var(--p);color:#fff;border:0;border-radius:9px;padding:9px 14px;font-weight:600;cursor:pointer;text-decoration:none;display:inline-block}
      .btn.small{padding:5px 9px;font-size:12px}.btn.ghost{background:#e2e8f0;color:#0f172a}
      table{width:100%;border-collapse:collapse;background:var(--s);border:1px solid var(--b);border-radius:12px;overflow:hidden}
      td{padding:12px;border-bottom:1px solid var(--b);font-size:14px}
      .good{color:#059669;font-weight:600}.bad{color:#dc2626;font-weight:700}
      .err{font-size:52px;font-weight:800;color:#dc2626}.ok{font-size:52px;color:#059669}
      small{color:var(--m)}
    </style></head>
    <body><div class="top"><span>◆</span> Nimbus</div><div class="wrap">#{body}</div></body></html>
  HTML
end
