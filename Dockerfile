# The landing page in site/, served by Caddy. Railway builds this file and sets $PORT.
FROM caddy:2.8-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY site /srv
