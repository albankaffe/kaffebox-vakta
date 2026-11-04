# Kaffebox-vakta

Følger nettbutikken til kaffebox.no: nye produkter, prisendringer, anslått salg
(ut fra lagerantall), bestselgere og tilbud.

- `hent.sh` henter alle produkter fra butikkens åpne WooCommerce-API, sammenligner
  med forrige kjøring og bygger siden i `_site/index.html`.
- `mal.html` er selve siden; dataene settes inn der det står `__KAFFEBOX_DATA__`.
- `events.json` er historikken (nye produkter, prisendringer, salg, påfyll).
- `snapshots/` holder de tre siste øyeblikksbildene; bare det siste trengs.
- `bilder/` er krympede produktbilder som bygges inn i siden.

GitHub Actions (`.github/workflows/oppdater.yml`) kjører skriptet hver morgen,
lagrer historikken her og publiserer siden på GitHub Pages. Under fanen
**Actions** kan arbeidsflyten også startes for hånd med **Run workflow**.

Lokalt (krever `curl` og `jq`):

```bash
bash hent.sh
```
