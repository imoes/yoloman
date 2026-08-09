FROM node:22-slim AS build

# See bossman/Dockerfile's identical block for why this is needed —
# BuildKit doesn't forward the host's proxy env vars into RUN steps by
# default.
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npx ng build --configuration production

FROM nginx:alpine

COPY --from=build /app/dist/bossman-ui/browser /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# The image asset files (bossman-ui/public/assets/*.jpg) are 0600 on the
# host (a real permission mismatch found by actually loading the page,
# not assumed) — nginx's worker process runs as an unprivileged user and
# can't read root-owned 0600 files, which silently 403'd both mascot
# images. Static content nginx serves must be world-readable.
RUN chmod -R a+rX /usr/share/nginx/html

EXPOSE 80
