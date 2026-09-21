#!/usr/bin/env bash
# Auth smoke test against a running wasl-api on :3000 with the seeded super admin (password still initial).
A=http://127.0.0.1:3000/api
j() { node -pe "const j=JSON.parse(require('fs').readFileSync(0)); $1"; }
echo "health: $(curl -s $A/health)"
echo "--- login (mobile client)"
R=$(curl -s -X POST $A/auth/login -H 'content-type: application/json' -H 'x-client: mobile' -d '{"phone":"770000000","password":"change-me-now"}')
echo "$R" | head -c 240; echo
AT=$(echo "$R" | j 'j.access_token'); RT=$(echo "$R" | j 'j.refresh_token')
echo "--- me (allowed during force_password_change)"; curl -s $A/auth/me -H "authorization: Bearer $AT" | head -c 260; echo
echo "--- protected route while fpc -> 403 force_password_change"; curl -s $A/me/profile -H "authorization: Bearer $AT" -w " %{http_code}\n"
echo "--- change password without current (fpc) -> 204"; curl -s -X POST $A/auth/change-password -H "authorization: Bearer $AT" -H 'content-type: application/json' -d '{"new_password":"newpass123"}' -o /dev/null -w "%{http_code}\n"
echo "--- old refresh token revoked by password change -> 401"; curl -s -X POST $A/auth/refresh -H 'content-type: application/json' -H 'x-client: mobile' -d "{\"refresh_token\":\"$RT\"}" -w " %{http_code}\n"
echo "--- login with new password; rotate; replay old -> 401 token_reused; rotated one dead too"
R2=$(curl -s -X POST $A/auth/login -H 'content-type: application/json' -H 'x-client: mobile' -d '{"phone":"770000000","password":"newpass123"}')
RT2=$(echo "$R2" | j 'j.refresh_token'); AT2=$(echo "$R2" | j 'j.access_token')
echo "$R2" | j '"fpc="+j.user.force_password_change+" super="+j.user.super+" roles="+j.user.roles'
R3=$(curl -s -X POST $A/auth/refresh -H 'content-type: application/json' -H 'x-client: mobile' -d "{\"refresh_token\":\"$RT2\"}"); RT3=$(echo "$R3" | j 'j.refresh_token')
echo "rotate1 ok: $([ -n "$RT3" ] && [ "$RT3" != "undefined" ] && echo yes || echo NO)"
curl -s -X POST $A/auth/refresh -H 'content-type: application/json' -H 'x-client: mobile' -d "{\"refresh_token\":\"$RT2\"}" -w " %{http_code}\n"
curl -s -X POST $A/auth/refresh -H 'content-type: application/json' -H 'x-client: mobile' -d "{\"refresh_token\":\"$RT3\"}" -w " %{http_code} (family revoked)\n"
echo "--- wrong password -> 401; bad phone -> 400 validation"
curl -s -X POST $A/auth/login -H 'content-type: application/json' -d '{"phone":"770000000","password":"nope"}' -w " %{http_code}\n"
curl -s -X POST $A/auth/login -H 'content-type: application/json' -d '{"phone":"123","password":"nope"}' -w " %{http_code}\n" | head -c 160; echo
echo "--- web client login sets cookie"; curl -s -X POST $A/auth/login -H 'content-type: application/json' -d '{"phone":"770000000","password":"newpass123"}' -D - -o /dev/null | grep -i "set-cookie" | head -c 140; echo
echo "--- register customer -> 201 pending; login -> 403 account_pending; duplicate -> 409"
curl -s -X POST $A/auth/register -H 'content-type: application/json' -d '{"phone":"771234567","password":"secret1","name":"عميل تجريبي","user_type":"customer","city":"صنعاء"}' -w " %{http_code}\n"
curl -s -X POST $A/auth/login -H 'content-type: application/json' -d '{"phone":"771234567","password":"secret1"}' -w " %{http_code}\n"
curl -s -X POST $A/auth/register -H 'content-type: application/json' -d '{"phone":"771234567","password":"secret1","name":"x","user_type":"customer"}' -w " %{http_code}\n"
echo "--- merchant registration without business_name -> 400"
curl -s -X POST $A/auth/register -H 'content-type: application/json' -d '{"phone":"779999999","password":"secret1","name":"تاجر","user_type":"merchant"}' -w " %{http_code}\n" | head -c 200; echo
echo "--- me/profile + locations + favorites + notifications + sessions with the admin token"
curl -s $A/me/profile -H "authorization: Bearer $AT2" | head -c 160; echo
L=$(curl -s -X POST $A/me/locations -H "authorization: Bearer $AT2" -H 'content-type: application/json' -d '{"label":"البيت","landmark_text":"جوار مسجد النور","lat":15.37,"lng":44.19}'); echo "$L" | head -c 120; echo
LID=$(echo "$L" | j 'j.id'); curl -s -X DELETE $A/me/locations/$LID -H "authorization: Bearer $AT2" -w "delete location %{http_code}\n"
curl -s $A/me/notifications -H "authorization: Bearer $AT2"; echo
S=$(curl -s -X POST $A/me/sessions -H "authorization: Bearer $AT2" -H 'content-type: application/json' -d '{}'); echo "$S"
SID=$(echo "$S" | j 'j.id'); BT=$(echo "$S" | j 'j.beacon_token')
curl -s -X POST $A/me/sessions/$SID/close -H 'content-type: application/json' -d "{\"beacon_token\":\"$BT\",\"close_type\":\"pagehide\"}" -w "beacon close %{http_code}\n"
echo "--- no token on protected route -> 401"; curl -s $A/me/profile -w " %{http_code}\n"
echo "--- openapi paths"; curl -s $A/docs-json | j 'Object.keys(j.paths).join(" ")'
