#!/bin/bash
# Henter alle produkter fra kaffebox.no, lagrer et øyeblikksbilde og
# logger nye produkter, fjernede produkter og prisendringer siden forrige kjøring.
# Bygger deretter kaffebox.html (mal.html + data).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SNAP="$DIR/snapshots"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$SNAP"

BASE="https://www.kaffebox.no/wp-json"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%Y-%m-%dT%H:%M:%S)"

fetch_pages() { # $1 = url uten page-param, $2 = filprefiks
  local page=1 total=1
  while [ "$page" -le "$total" ]; do
    curl -sf --retry 3 -D "$TMP/h" "$1&page=$page" -o "$TMP/$2-$(printf %03d "$page").json"
    total=$(grep -i '^x-wp-totalpages:' "$TMP/h" | tr -dc '0-9')
    page=$((page + 1))
  done
}

echo "Henter produkter…"
# Sortert etter popularitet (WooCommerce total_sales), så rekkefølgen gir bestselgerplassering
fetch_pages "$BASE/wc/store/v1/products?per_page=100&orderby=popularity&order=desc" store
echo "Henter publiseringsdatoer…"
fetch_pages "$BASE/wp/v2/product?per_page=100&_fields=id,date,modified" dates

jq -s 'add | map({key: (.id|tostring), value: {date, modified}}) | from_entries' "$TMP"/dates-*.json > "$TMP/dates.json"

# qty: handlekurvens maksantall er lik lagerantallet når butikken teller lager
# (9999 = ubegrenset/ikke telt). Utsolgt regnes som 0.
jq -s --slurpfile d "$TMP/dates.json" '
  def kr: if . == null or . == "" then null else (tonumber / 100) end;
  add | to_entries | map(.key as $i | .value | {
    id, name, url: .permalink, type,
    rank: ($i + 1),
    qty: (if .is_in_stock | not then 0
          elif (.add_to_cart.maximum // 9999) < 9999 then .add_to_cart.maximum
          else null end),
    price: (.prices.price | kr),
    regular: (.prices.regular_price | kr),
    min: (.prices.price_range.min_amount | kr),
    max: (.prices.price_range.max_amount | kr),
    sale: .on_sale,
    stock: .is_in_stock,
    brand: (.brands[0].name // ([.attributes[]? | select(.name == "Brand") | .terms[].name] | first)),
    cats: [.categories[].name],
    img: (.images[0].thumbnail // .images[0].src),
    date: $d[0][(.id|tostring)].date,
    modified: $d[0][(.id|tostring)].modified
  }) | sort_by(.id)' "$TMP"/store-*.json > "$TMP/now.json"

COUNT=$(jq length "$TMP/now.json")
[ "$COUNT" -gt 100 ] || { echo "Fikk bare $COUNT produkter – avbryter." >&2; exit 1; }

PREV="$(ls "$SNAP"/*.json 2>/dev/null | tail -1 || true)"
EVENTS="$DIR/events.json"
[ -f "$EVENTS" ] || echo '[]' > "$EVENTS"

if [ -n "$PREV" ]; then
  echo "Sammenligner med $(basename "$PREV")…"
  jq -n --slurpfile a "$PREV" --slurpfile b "$TMP/now.json" --arg t "$NOW" '
    def key: (.price // .min);
    ($a[0] | map({key: (.id|tostring), value: .}) | from_entries) as $old
    | ($b[0] | map({key: (.id|tostring), value: .}) | from_entries) as $new
    | [ ($new | to_entries[] | .value as $p | $old[.key] as $o
          | if $o == null then {at: $t, kind: "ny", id: $p.id, name: $p.name, to: ($p|key)}
            elif ($o.price != $p.price or $o.min != $p.min or $o.max != $p.max) then
              {at: $t, kind: "pris", id: $p.id, name: $p.name,
               from: ($o|key), to: ($p|key), fromMax: $o.max, toMax: $p.max,
               fromRegular: $o.regular, toRegular: $p.regular}
            elif ($o.stock != $p.stock) then
              {at: $t, kind: (if $p.stock then "paa_lager" else "utsolgt" end), id: $p.id, name: $p.name}
            else empty end),
        # Endring i lagerantall: nedgang = antatt solgt, oppgang = påfyll
        ($new | to_entries[] | .value as $p | $old[.key] as $o
          | select($o != null and $o.qty != null and $p.qty != null and $o.qty != $p.qty)
          | if $p.qty < $o.qty
            then {at: $t, kind: "solgt", id: $p.id, name: $p.name, n: ($o.qty - $p.qty)}
            else {at: $t, kind: "paafyll", id: $p.id, name: $p.name, n: ($p.qty - $o.qty)} end),
        ($old | to_entries[] | select($new[.key] == null) | .value
          | {at: $t, kind: "fjernet", id, name, from: key, url, img}) ]' > "$TMP/new-events.json"
  jq -s 'add' "$EVENTS" "$TMP/new-events.json" > "$TMP/events.json"
  mv "$TMP/events.json" "$EVENTS"
  echo "$(jq length "$TMP/new-events.json") nye hendelser."
else
  echo "Første kjøring – lagrer utgangspunkt for prissporing."
fi

# saleSince: når produktet ble sett på tilbud første gang. Arves fra siste
# øyeblikksbilde (dagens, hvis skriptet allerede har kjørt i dag). null betyr
# at tilbudet startet før sporingen begynte.
REF="$SNAP/$TODAY.json"
[ -f "$REF" ] || REF="$PREV"
if [ -n "$REF" ]; then
  jq --slurpfile r "$REF" --arg t "$NOW" '
    ($r[0] | map({key: (.id|tostring), value: .}) | from_entries) as $old
    | map(. as $p | $old[($p.id|tostring)] as $o
      | . + {saleSince: (if ($p.sale | not) then null
                         elif $o == null then $t
                         elif $o.sale then $o.saleSince
                         else $t end)})' "$TMP/now.json" > "$TMP/now2.json"
  mv "$TMP/now2.json" "$TMP/now.json"
else
  jq 'map(. + {saleSince: null})' "$TMP/now.json" > "$TMP/now2.json" && mv "$TMP/now2.json" "$TMP/now.json"
fi

cp "$TMP/now.json" "$SNAP/$TODAY.json"
# Startdatoen for sporingen lagres for seg, så gamle øyeblikksbilder kan slettes
[ -s "$DIR/sporing-startet.txt" ] || basename "$(ls "$SNAP"/*.json | head -1)" .json > "$DIR/sporing-startet.txt"
FIRST="$(cat "$DIR/sporing-startet.txt")"
# Behold bare de tre nyeste øyeblikksbildene (bare det siste trengs for sammenligning)
ls "$SNAP"/*.json | sort -r | tail -n +4 | while read -r f; do rm -f "$f"; done

# Produktbilder: siden kan ikke laste bilder fra kaffebox.no, så de lastes ned,
# krympes og bygges inn. Bare for produkter som vises i listene, og hver fil
# lastes ned én gang (mappen bilder/ fungerer som mellomlager).
IMG="$DIR/bilder"
mkdir -p "$IMG"
# macOS (BSD date, sips) og Linux/GitHub Actions (GNU date, ImageMagick)
CUTOFF="$(date -v-365d +%Y-%m-%d 2>/dev/null || date -d '365 days ago' +%Y-%m-%d)"
if command -v sips >/dev/null; then
  RESIZE='sips -s format jpeg -s formatOptions 60 --resampleHeightWidthMax 112 "$0/$1.orig" --out "$0/$1.jpg"'
else
  RESIZE='convert "$0/$1.orig[0]" -resize 112x112 -quality 60 "$0/$1.jpg"'
fi
jq -r --arg cut "$CUTOFF" --slurpfile e "$EVENTS" '
  ($e[0] | map(.id) | unique) as $ev
  | .[] | select(.img != null)
  | select(.date >= $cut or .rank <= 200 or .sale or (.id as $id | $ev | index($id)))
  | "\(.id) \(.img)"' "$TMP/now.json" > "$TMP/img-list.txt"
echo "Henter bilder ($(wc -l < "$TMP/img-list.txt" | tr -d ' ') produkter, nye lastes ned)…"
while read -r id url; do
  [ -s "$IMG/$id.jpg" ] || echo "$id $url"
done < "$TMP/img-list.txt" | xargs -P 8 -n 2 sh -c '
  curl -sf --retry 2 "$2" -o "$0/$1.orig" && '"$RESIZE"' >/dev/null 2>&1
  rm -f "$0/$1.orig"' "$IMG"
{
  printf '{'
  sep=""
  while read -r id url; do
    [ -s "$IMG/$id.jpg" ] || continue
    printf '%s"%s":"data:image/jpeg;base64,%s"' "$sep" "$id" "$(base64 < "$IMG/$id.jpg" | tr -d '\n')"
    sep=","
  done < "$TMP/img-list.txt"
  printf '}'
} > "$TMP/images.json"

# Bygg selvstendig HTML: mal.html med dataene satt inn
jq -n --slurpfile p "$TMP/now.json" --slurpfile e "$EVENTS" --slurpfile i "$TMP/images.json" \
      --arg updated "$NOW" --arg since "$FIRST" \
  '{updated: $updated, trackingSince: $since, images: $i[0],
    products: ($p[0] | map(del(.img))), events: $e[0]}' \
  | sed 's#</#<\\/#g' > "$TMP/data.json"
awk -v data="$TMP/data.json" '
  /__KAFFEBOX_DATA__/ { while ((getline line < data) > 0) printf "%s", line; next }
  { print }' "$DIR/mal.html" > "$DIR/kaffebox.html"

# Frittstående versjon for GitHub Pages: samme side i et vanlig HTML-dokument
mkdir -p "$DIR/_site"
{
  printf '%s\n' '<!doctype html>' '<html lang="nb">' '<head>' '<meta charset="utf-8">' \
    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' \
    '<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>' \
    '</head>' '<body>'
  cat "$DIR/kaffebox.html"
  printf '%s\n' '</body>' '</html>'
} > "$DIR/_site/index.html"

echo "Ferdig: $COUNT produkter → kaffebox.html og _site/index.html"
