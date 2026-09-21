#!/usr/bin/env bash
# Admin scenario. Assumes smoke-auth.sh ran (super admin password = newpass123) and smoke-orders.sh ran (merchant/customer exist).
set -u
A=http://127.0.0.1:3000/api
j() { node -pe "const j=JSON.parse(require('fs').readFileSync(0)); $1"; }
post() { curl -s -X POST "$A$1" -H 'content-type: application/json' -H 'x-client: mobile' ${3:+-H "authorization: Bearer $3"} -d "$2"; }
put() { curl -s -X PUT "$A$1" -H 'content-type: application/json' ${3:+-H "authorization: Bearer $3"} -d "$2"; }
get() { curl -s -G "$A$1" -H "authorization: Bearer $2"; }
login() { post /auth/login "{\"phone\":\"$1\",\"password\":\"$2\"}" | j 'j.access_token'; }
S=$(login 770000000 newpass123)
echo "== overview"; get /admin/overview "$S"; echo
echo "== create finance staff with bundle; staff token carries perms; staff cannot create users (403), can list wallet tx"
post /admin/staff '{"phone":"775000001","password":"staff123","name":"محاسب","role":"finance","bundle":"finance"}' "$S" | j '"perms="+j.perms.join(",")'
F=$(login 775000001 staff123); post /auth/change-password '{"new_password":"staff456"}' "$F" -o /dev/null; F=$(login 775000001 staff456)
post /admin/users '{"phone":"776000001","password":"x12345","name":"x","user_type":"customer"}' "$F" -w " %{http_code}\n" | head -c 120; echo
get "/admin/wallets/transactions?status=approved" "$F" | j '"finance sees wallet tx: "+j.length'
get /admin/permissions/catalog "$F" -w " %{http_code}\n" | head -c 80; echo "  <- super-only for staff"
echo "== super creates a merchant user directly (active, store active) and a duplicate -> 409"
post /admin/users '{"phone":"776000001","password":"x12345","name":"تاجر مباشر","user_type":"merchant","business_name":"بقالة النور","city":"عدن"}' "$S" | head -c 80; echo
post /admin/users '{"phone":"776000001","password":"x12345","name":"x","user_type":"customer"}' "$S" -w " %{http_code}\n"
echo "== account requests: register pending customer, list, approve, then login works"
post /auth/register '{"phone":"777000002","password":"secret1","name":"عميل معلق","user_type":"customer"}' >/dev/null
REQ=$(get /admin/account-requests "$S" | j 'j.map(r=>r.p.phone).join(",")'); echo "pending: $REQ"
UID2=$(get /admin/account-requests "$S" | j 'j.find(r=>r.p.phone==="777000002").p.id')
post /admin/account-requests/$UID2/decide '{"approve":true}' "$S" | j 'j.accountStatus'
login 777000002 secret1 | head -c 20; echo "  <- token"
echo "== password reset: request (public), list, approve with temp password, login forces change"
post /auth/password-reset-requests '{"phone":"777000002","reason":"نسيت"}' >/dev/null
RID=$(get "/admin/password-resets?status=pending" "$S" | j 'j[0].id')
post /admin/password-resets/$RID/decide '{"approve":true,"temp_password":"temp123"}' "$S" | j 'j.status'
post /auth/login '{"phone":"777000002","password":"temp123"}' | j '"fpc="+j.user.force_password_change'
echo "== stores: list, set commission 5%, then a new order carries commission"
SID=$(get "/admin/stores?status=active" "$S" | j 'j.find(s=>s.ownerPhone==="773000001").s.id')
post /admin/stores/$SID/commission '{"commission_pct":5}' "$S" | j '"commission_pct="+j.commissionPct'
C=$(login 774000001 secret1); P=$(curl -s $A/stores/$SID/products | j 'j[0].id')
post /orders "{\"store_id\":\"$SID\",\"items\":[{\"product_id\":\"$P\",\"qty\":1}],\"payment_method\":\"cash\",\"location\":{\"landmark\":\"x\"}}" "$C" | j '"order total="+j.total+" commission="+j.commissionAmount+" (5%)"'
echo "== wallets: customer files topup, admin approves via endpoint, balance moves once; second approve -> 409"
post /me/wallet/topups '{"amount":1000,"method":"jeeb","reference":"T2"}' "$C" >/dev/null
TX=$(get "/admin/wallets/transactions?status=pending" "$S" | j 'j[0].t.id'); B0=$(get /me/wallet "$C" | j 'j.balance')
post /admin/wallets/transactions/$TX/respond '{"approve":true}' "$S" | j 'j.status'; post /admin/wallets/transactions/$TX/respond '{"approve":true}' "$S" -w " %{http_code}\n"
echo "balance $B0 -> $(get /me/wallet "$C" | j 'j.balance')"
echo "== grant wallet 250, suspend user -> login 403 account_suspended, reactivate"
post /admin/users/$UID2/wallet-grant '{"amount":250,"note":"ترحيب"}' "$S" | j 'j.type+" "+j.amount'
post /admin/users/$UID2/status '{"status":"suspended","reason":"اختبار"}' "$S" | j 'j.accountStatus'; post /auth/login '{"phone":"777000002","password":"temp123"}' -w " %{http_code}\n"
post /admin/users/$UID2/status '{"status":"active"}' "$S" | j 'j.accountStatus'
echo "== settings, broadcast, oversight"
put /admin/settings/delivery_fee '{"value":200}' "$S" | j 'j.key+"="+JSON.stringify(j.value)'; curl -s $A/settings/public | j 'JSON.stringify(j)'
post /admin/notifications/broadcast '{"segment":"customers","title":"تحديث","body":"نسخة جديدة"}' "$S"; echo
get "/admin/users?kind=merchants" "$S" | j '"merchants="+j.total+" first="+j.items[0].name+" stores="+JSON.stringify(j.items[0].stores)'
get "/admin/audit-logs?limit=5" "$S" | j '"audit total="+j.total+" latest="+j.items.map(a=>a.action).join(",")'
get "/admin/login-sessions?limit=3" "$S" | j '"sessions total="+j.total'
get "/admin/user-files?limit=3" "$S" | j '"user files="+j.total+" first="+j.items[0].userName+" logins="+j.items[0].totalLogins'
get "/admin/notifications?limit=3" "$S" | j '"oversight notifications: "+j.length'
echo "== customer on admin route -> 403"; get /admin/overview "$C"; echo
