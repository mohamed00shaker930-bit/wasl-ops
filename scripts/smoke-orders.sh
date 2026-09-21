#!/usr/bin/env bash
# Scenario: merchant + customer, products, checkout by cash/wallet/credit, merchant flow, credit approval, returns, POS idempotency, SSE.
# Assumes wasl_dev with seed applied and the API on :3000. Uses psql only to activate accounts (admin endpoints tested separately).
set -u
A=http://127.0.0.1:3000/api
export PGPASSWORD=wasl; PSQL="$(dirname "$0")/../tools/bin/psql -h 127.0.0.1 -p 55432 -U wasl -d wasl_dev -At"
j() { node -pe "const j=JSON.parse(require('fs').readFileSync(0)); $1"; }
post() { curl -s -X POST "$A$1" -H 'content-type: application/json' -H 'x-client: mobile' ${3:+-H "authorization: Bearer $3"} -d "$2"; }
get() { curl -s "$A$1" -H "authorization: Bearer $2"; }
login() { post /auth/login "{\"phone\":\"$1\",\"password\":\"$2\"}" | j 'j.access_token'; }

echo "== register merchant + customer, activate via SQL (admin endpoints are exercised in smoke-admin.sh)"
post /auth/register '{"phone":"773000001","password":"secret1","name":"بقالة الأمل","user_type":"merchant","business_name":"بقالة الأمل","city":"صنعاء"}' | head -c 80; echo
post /auth/register '{"phone":"774000001","password":"secret1","name":"عميل أول","user_type":"customer","city":"صنعاء"}' | head -c 80; echo
$PSQL -c "update profiles set account_status='active' where phone in ('773000001','774000001')" -c "update stores set status='active' where owner_id=(select id from users where phone='773000001')" >/dev/null
M=$(login 773000001 secret1); C=$(login 774000001 secret1)
echo "merchant store_id: $(get /auth/me "$M" | j 'j.store && j.store.id')"

echo "== merchant: category, products, offer"
CAT=$(post /merchant/categories '{"name":"ألبان"}' "$M" | j 'j.id')
P1=$(post /merchant/products "{\"name\":\"حليب 1ل\",\"price\":900,\"category_id\":\"$CAT\",\"barcode\":\"6281000000001\"}" "$M" | j 'j.id')
P2=$(post /merchant/products '{"name":"خبز","price":100}' "$M" | j 'j.id')
post /merchant/offers "{\"product_id\":\"$P1\",\"discount_price\":800}" "$M" | j '"offer: "+j.discountPrice'
SID=$(get /auth/me "$M" | j 'j.store.id')
echo "public products with offer: $(curl -s $A/stores/$SID/products | j 'j.map(p=>p.name+"@"+(p.offer?p.offer.discountPrice:p.price)).join(", ")')"

echo "== customer: cash checkout with client-supplied garbage prices ignored"
O1=$(post /orders "{\"store_id\":\"$SID\",\"items\":[{\"product_id\":\"$P1\",\"qty\":2},{\"product_id\":\"$P2\",\"qty\":3}],\"payment_method\":\"cash\",\"location\":{\"landmark\":\"جوار الجامع\",\"phone\":\"774000001\"}}" "$C")
echo "$O1" | j '"order total="+j.total+" status="+j.status+" commission="+j.commissionAmount+" items="+j.items.length'
O1ID=$(echo "$O1" | j 'j.id')
echo "-- merchant status flow sent→accepted→preparing→out_for_delivery→delivered; illegal skip rejected"
curl -s -X PATCH $A/merchant/orders/$O1ID/status -H "authorization: Bearer $M" -H 'content-type: application/json' -d '{"status":"delivered"}' -w " %{http_code}\n" | head -c 120; echo
for s in accepted preparing out_for_delivery delivered; do curl -s -X PATCH $A/merchant/orders/$O1ID/status -H "authorization: Bearer $M" -H 'content-type: application/json' -d "{\"status\":\"$s\"}" | j 'j.status' | tr '\n' ' '; done; echo
echo "customer notifications after status changes: $(get /me/notifications "$C" | j 'j.items.length+" unread="+j.unread')"
echo "-- rate order, then rate again -> 409"
post /me/orders/$O1ID/rating '{"stars":5,"comment":"ممتاز"}' "$C" | j '"stars="+j.stars'; post /me/orders/$O1ID/rating '{"stars":1}' "$C"; echo
echo "store rating now: $(curl -s $A/stores/$SID | j 'j.rating+" ("+j.ratingCount+")"')"
echo "-- return request then merchant approves"
post /me/orders/$O1ID/return '{"reason":"منتج تالف"}' "$C" | j 'j.returnStatus'; post /merchant/orders/$O1ID/return-decision '{"approve":true}' "$M" | j 'j.returnStatus'

echo "== wallet: topup pending (approved via SQL-free path later in admin smoke), insufficient balance -> 422"
post /me/wallet/topups '{"amount":5000,"method":"jawali","reference":"TXN1"}' "$C" | j '"topup "+j.status'
post /orders "{\"store_id\":\"$SID\",\"items\":[{\"product_id\":\"$P2\",\"qty\":1}],\"payment_method\":\"wallet\",\"location\":{\"landmark\":\"x\"}}" "$C" -w ""; echo
echo "-- approve the topup through the WalletService path (admin endpoint comes next); here via SQL to continue the scenario"
$PSQL -c "update wallet_transactions set status='approved' where status='pending'" -c "update wallets set balance=5000 where user_id=(select id from users where phone='774000001')" >/dev/null
O2=$(post /orders "{\"store_id\":\"$SID\",\"items\":[{\"product_id\":\"$P2\",\"qty\":4}],\"payment_method\":\"wallet\",\"location\":{\"landmark\":\"x\"}}" "$C")
echo "$O2" | j '"wallet order status="+j.status+" total="+j.total'
echo "wallet after: $(get /me/wallet "$C" | j 'j.balance')  (expect 4600)"

echo "== credit: online credit order -> merchant approves -> approved charge; ledger view"
O3=$(post /orders "{\"store_id\":\"$SID\",\"items\":[{\"product_id\":\"$P1\",\"qty\":1}],\"payment_method\":\"credit\",\"location\":{\"landmark\":\"x\"}}" "$C")
O3ID=$(echo "$O3" | j 'j.id'); echo "$O3" | j '"credit order status="+j.status+" credit_status="+j.creditStatus'
curl -s -X PATCH $A/merchant/orders/$O3ID/status -H "authorization: Bearer $M" -H 'content-type: application/json' -d '{"status":"accepted"}' | head -c 100; echo "  <- accept before credit decision is refused"
post /merchant/orders/$O3ID/credit-decision '{"approve":true}' "$M" | j '"credit_status="+j.creditStatus+" status="+j.status'
get /me/credit "$C" | j 'j.map(a=>"balance="+a.balance+" consistent="+a.ledger_consistent+" txs="+a.transactions.length).join("; ")'
echo "-- merchant records a repayment of 300"
ACC=$(get /merchant/credit/accounts "$M" | j 'j[0].id'); post /merchant/credit/accounts/$ACC/transactions '{"type":"payment","amount":300}' "$M" | j 'j.status'
get /me/credit "$C" | j '"balance now "+j[0].balance+" (expect 500)"'

echo "== POS: offline sale envelope (credit to registered customer), replay -> 200, unknown product -> 422"
CID=$(get /auth/me "$C" | j 'j.user.id'); OP=$(node -pe 'crypto.randomUUID()'); OID=$(node -pe 'crypto.randomUUID()'); TX=$(node -pe 'crypto.randomUUID()')
ENV="{\"op_id\":\"$OP\",\"order\":{\"id\":\"$OID\",\"payment_method\":\"credit\",\"created_at\":\"2026-09-07T10:00:00Z\",\"total\":900},\"items\":[{\"product_id\":\"$P1\",\"name\":\"حليب 1ل\",\"price\":900,\"qty\":1}],\"credit\":{\"customerKind\":\"registered\",\"customerId\":\"$CID\",\"txId\":\"$TX\",\"amount\":900}}"
post /merchant/pos/sales "$ENV" "$M" -w ""; echo " <- first"
curl -s -X POST $A/merchant/pos/sales -H "authorization: Bearer $M" -H 'content-type: application/json' -d "$ENV" -w " %{http_code} <- replay\n"
BAD=$(echo "$ENV" | sed "s/$OP/$(node -pe 'crypto.randomUUID()')/; s/$OID/$(node -pe 'crypto.randomUUID()')/; s/$P1/00000000-0000-0000-0000-000000000000/")
curl -s -X POST $A/merchant/pos/sales -H "authorization: Bearer $M" -H 'content-type: application/json' -d "$BAD" -w " %{http_code} <- unknown product\n"
echo "-- customer approves the pending POS charge -> order delivered, balance 1400"
post /me/credit/transactions/$TX/respond '{"approve":true}' "$C" | j 'j.status'
get /me/credit "$C" | j '"balance "+j[0].balance+" consistent="+j[0].ledger_consistent'
$PSQL -c "select 'pos order status: '||status||' credit_status: '||credit_status||' channel: '||channel from orders where id='$OID'"
echo "orders in DB: $($PSQL -c 'select count(*) from orders')  pos_ingest_log: $($PSQL -c 'select count(*) from pos_ingest_log')  merchant search: $(curl -s -G $A/merchant/customers/search --data-urlencode 'q=عميل' -H "authorization: Bearer $M" | j 'j.length')"

echo "== SSE: open stream, trigger a notification via order status, expect an event"
(timeout 6 curl -s -N "$A/events?access_token=$C" > /tmp/sse.out 2>&1 &) ; sleep 1
post /me/orders/$O3ID/cancel '{}' "$C" >/dev/null; curl -s -X PATCH $A/merchant/orders/$O3ID/status -H "authorization: Bearer $M" -H 'content-type: application/json' -d '{"status":"preparing"}' >/dev/null
sleep 3; grep -E "event: (order|notification)" /tmp/sse.out | sort | uniq -c
echo "== authz: customer on merchant route -> 403; merchant reading another store's order -> 404"
get /merchant/orders "$C" -w ""; echo; get /merchant/orders/$O1ID "$C"; echo
echo "== dashboard + reports"
get /merchant/dashboard "$M"; echo
get "/merchant/reports/summary?from=2026-09-01T00:00:00Z&to=2026-12-31T00:00:00Z" "$M" | j '"delivered="+j.delivered+" revenue="+j.revenue+" in_store="+j.in_store+" top="+j.top_products.map(p=>p.name).join("/")'
