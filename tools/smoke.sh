#!/usr/bin/env sh
set -eu

command -v curl >/dev/null 2>&1 || { echo "curl не найден"; exit 1; }

BASE="http://localhost:8080"
API="$BASE/api"

echo "1) HEALTH CHECKS"
curl -fsS "$API/healthz" | tee .out_api.json >/dev/null
curl -fsS "$BASE/runner/healthz" | tee .out_runner.json >/dev/null
grep -q '"status":"ok"' .out_api.json
grep -q '"status":"ok"' .out_runner.json
echo "✔ /api/healthz и /runner/healthz — OK"

echo "2) LOGIN (admin/admin123)"
LOGIN_JSON="$(curl -fsS -X POST "$API/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}')"
TOKEN="$(printf '%s' "$LOGIN_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"
[ -n "$TOKEN" ] || { echo "Не удалось извлечь access_token из ответа: $LOGIN_JSON"; exit 1; }
echo "✔ токен получен: $(printf '%s' "$TOKEN" | cut -c1-16)..."

echo "3) ME"
ME_JSON="$(curl -fsS "$API/auth/me" -H "Authorization: Bearer $TOKEN")"
printf '%s\n' "$ME_JSON" > .out_me.json
USER_ID="$(python3 -c 'import json; print(json.load(open(".out_me.json"))["id"])')"
[ -n "$USER_ID" ] || { echo "Не удалось извлечь user id из /auth/me: $ME_JSON"; exit 1; }
echo "✔ /auth/me — OK (user id: $USER_ID)"

echo "4) CREATE PROJECT"
PNAME="Test Project $(date +%s)"
CREATE_JSON="$(curl -fsS -X POST "$API/projects" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$PNAME\"}")"
printf '%s\n' "$CREATE_JSON" > .out_project_create.json
PID="$(python3 -c 'import json; print(json.load(open(".out_project_create.json"))["id"])')"
[ -n "$PID" ] || { echo "Не удалось извлечь project id: $CREATE_JSON"; exit 1; }
echo "✔ проект создан (id: $PID, name: $PNAME)"

echo "5) LIST PROJECTS"
curl -fsS "$API/projects" -H "Authorization: Bearer $TOKEN" | tee .out_projects.json >/dev/null
grep -q "$PID" .out_projects.json && echo "✔ проект виден в списке"

echo "6) UPDATE PROJECT NAME"
UPDNAME="$PNAME (upd)"
curl -fsS -X PATCH "$API/projects/$PID" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$UPDNAME\"}" | tee .out_project_update.json >/dev/null
grep -q "$UPDNAME" .out_project_update.json && echo "✔ имя проекта обновлено"

echo "7) LIST MEMBERS"
curl -fsS "$API/projects/$PID/members" -H "Authorization: Bearer $TOKEN" | tee .out_members.json >/dev/null
echo "✔ список участников получен"

echo "8) CHANGE MEMBER ROLE (admin → Editor)"
curl -fsS -X POST "$API/projects/$PID/members" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","role":"Editor"}' | tee .out_member_add.json >/dev/null
echo "✔ роль участника обновлена"

echo "9) REMOVE MEMBER (optional)"
curl -fsS -X DELETE "$API/projects/$PID/members/$USER_ID" \
  -H "Authorization: Bearer $TOKEN" | tee .out_member_del.json >/dev/null
echo "✔ участник удалён (глобальный Admin всё равно имеет доступ)"

echo "10) AUDIT (admin only)"
curl -fsS "$API/audit?limit=10" -H "Authorization: Bearer $TOKEN" | tee .out_audit.json >/dev/null
echo "✔ аудит получен"

echo "11) NEGATIVE CHECK: без токена"
HTTP_NOAUTH="$(curl -s -o /dev/null -w "%{http_code}" "$API/projects")"
[ "$HTTP_NOAUTH" = "401" ] || { echo "Ожидали 401, получили $HTTP_NOAUTH"; exit 1; }
echo "✔ без токена — 401"

echo ""
echo "✅ ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
