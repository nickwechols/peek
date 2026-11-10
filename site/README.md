# Peek landing page

The site at [peekmac.xyz](https://peekmac.xyz). A single static page, no build step.

Preview locally:

```sh
cd site && python3 -m http.server 8000
```

## Deploy

The repo root has a `Dockerfile` and `Caddyfile` that serve this folder. Railway builds the Dockerfile on every deploy:

```sh
railway up
```

The Download buttons point at the latest GitHub Release (`releases/latest/download/Peek.dmg`), and `peekmac.xyz/download` redirects there too.
