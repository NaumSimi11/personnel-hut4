# Personnel — one image: the auth/careers service serves the built Vue app.
# Build args carry the two browser-safe values Vite bakes into the bundle;
# every secret is a runtime environment variable (see docs/deployment.md).
FROM node:22-alpine AS build
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_PUBLISHABLE_KEY
WORKDIR /src
COPY shared ./shared
COPY app/package.json app/package-lock.json ./app/
RUN cd app && npm ci
COPY app ./app
RUN cd app && VITE_SUPABASE_URL=$VITE_SUPABASE_URL VITE_SUPABASE_PUBLISHABLE_KEY=$VITE_SUPABASE_PUBLISHABLE_KEY npm run build
COPY server/package.json server/package-lock.json ./server/
RUN cd server && npm ci --omit=dev

FROM node:22-alpine
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080 SERVE_APP_DIR=/srv/app TRUST_PROXY=true
WORKDIR /srv/server
COPY --from=build /src/server/node_modules ./node_modules
COPY server/package.json server/tsconfig.json ./
COPY server/src ./src
COPY shared /srv/shared
COPY --from=build /src/app/dist /srv/app
EXPOSE 8080
USER node
CMD ["node_modules/.bin/tsx", "src/index.ts"]
