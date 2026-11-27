# 早押しの部屋作成・招待の HTTP 経路（#767）。実サーバに対して実行する:
#   PORT=4123 gleam run &
#   hurl --test --variable base=http://localhost:4123 test/http/buzzer-invite.hurl
# 部屋の作成・参加そのものは WebSocket（/ws）で行うので、ここで見るのは
# ページを返す経路だけ。WebSocket 側は websocket_integration_test.gleam が見る。

# トップは部屋を作る導線のあるページ。
GET {{base}}/
HTTP 200
[Asserts]
header "Content-Type" == "text/html; charset=utf-8"
header "X-Content-Type-Options" == "nosniff"
header "Referrer-Policy" == "no-referrer"
body contains "部屋を作る"

# 招待 URL は同じページを返す。部屋の有無はここでは見ない（無ければ参加時に
# room_not_found）。ページに token は埋め込まれていない。
GET {{base}}/r/K7M2QX
HTTP 200
[Asserts]
header "Content-Type" == "text/html; charset=utf-8"
header "Referrer-Policy" == "no-referrer"
body contains "部屋を作る"
body not contains "resume-secret"

HEAD {{base}}/r/K7M2QX
HTTP 200

# 招待パスの下に余計な階層があれば 404、GET/HEAD 以外は 405。
GET {{base}}/r/K7M2QX/extra
HTTP 404

POST {{base}}/r/K7M2QX
HTTP 405
[Asserts]
header "Allow" == "GET, HEAD"

# 招待 URL を開いただけでは部屋は作られない。
GET {{base}}/health
HTTP 200
[Asserts]
body startsWith "ok buzzer_rooms=0 "
