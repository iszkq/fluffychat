FROM node:24-alpine

WORKDIR /app
COPY server/push-gateway/server.mjs ./server.mjs

ENV PORT=3000
EXPOSE 3000
USER node

CMD ["node", "server.mjs"]
