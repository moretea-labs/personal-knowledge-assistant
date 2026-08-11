#!/usr/bin/env bash
set -euo pipefail

CLI="${PKS_NOTION_CLI:-/opt/homebrew/bin/ntn}"
OUT="${PKS_NOTION_SNAPSHOT:-$HOME/.pks/notion-metadata.json}"
WORKSPACE_ID="${PKS_NOTION_WORKSPACE_ID:-}"

if [[ -z "$WORKSPACE_ID" && -f "$HOME/.config/notion/config.json" ]]; then
  WORKSPACE_ID="$(python3 - "$HOME/.config/notion/config.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print((d.get('defaultWorkspaceIds') or {}).get('prod') or '')
except Exception:
    print('')
PY
)"
fi

[[ -n "$WORKSPACE_ID" ]] || { echo 'No Notion workspace ID. Run ntn login first.' >&2; exit 2; }
[[ -x "$CLI" ]] || { echo "Notion CLI not executable: $CLI" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pks-notion.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
results="$tmpdir/results.json"
echo '[]' > "$results"
cursor=''
page=0

while :; do
  page=$((page+1))
  body="$(python3 - "$cursor" <<'PY'
import json,sys
b={'page_size':100}
if sys.argv[1]: b['start_cursor']=sys.argv[1]
print(json.dumps(b,separators=(',',':')))
PY
)"
  response="$tmpdir/page-$page.json"
  NOTION_WORKSPACE_ID="$WORKSPACE_ID" "$CLI" api v1/search -X POST --notion-version 2026-03-11 --data "$body" > "$response"
  state="$(python3 - "$results" "$response" <<'PY'
import json,sys
agg_path,page_path=sys.argv[1:]
agg=json.load(open(agg_path)); page=json.load(open(page_path))
agg.extend(page.get('results') or [])
with open(agg_path,'w') as f: json.dump(agg,f,separators=(',',':'))
print(json.dumps({'hasMore':bool(page.get('has_more')),'nextCursor':page.get('next_cursor') or ''},separators=(',',':')))
PY
)"
  has_more="$(python3 -c 'import json,sys;print("1" if json.loads(sys.argv[1])["hasMore"] else "0")' "$state")"
  cursor="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["nextCursor"])' "$state")"
  [[ "$has_more" == '1' && -n "$cursor" ]] || break
done

workspace_name="$(python3 - "$HOME/.config/notion/workspaces.json" "$WORKSPACE_ID" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print((((d.get('environments') or {}).get('prod') or {}).get(sys.argv[2]) or {}).get('name') or '')
except Exception:
    print('')
PY
)"

tmpout="$tmpdir/notion-metadata.json"
python3 - "$results" "$tmpout" "$WORKSPACE_ID" "$workspace_name" <<'PY'
import json,sys,datetime
results,out,workspace_id,workspace_name=sys.argv[1:]
raw=json.load(open(results))
def title(page):
    for value in (page.get('properties') or {}).values():
        if value.get('type')=='title':
            return ''.join(x.get('plain_text') or '' for x in value.get('title') or []).strip()
    return ''
pages=[]
for page in raw:
    if page.get('object')!='page': continue
    pages.append({'object':'page','id':page.get('id'),'title':title(page),'created_time':page.get('created_time'),'last_edited_time':page.get('last_edited_time'),'url':page.get('url'),'parent':page.get('parent')})
data={'schemaVersion':1,'mode':'metadata','workspaceId':workspace_id,'workspaceName':workspace_name,'fetchedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'results':pages}
with open(out,'w') as f: json.dump(data,f,ensure_ascii=False,separators=(',',':'))
PY
chmod 600 "$tmpout"
mv "$tmpout" "$OUT"
count="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get("results") or []))' "$OUT")"
echo "Notion metadata snapshot refreshed: $count objects -> $OUT"
