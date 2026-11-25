FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile --ignore-scripts
COPY . .
RUN --mount=type=secret,id=tmdb_key \
    VITE_APP_TMDB_V3_API_KEY="$(cat /run/secrets/tmdb_key)" \
    VITE_APP_API_ENDPOINT_URL="https://api.themoviedb.org/3" \
    yarn build

FROM nginxinc/nginx-unprivileged:stable-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
USER 101
EXPOSE 8080
