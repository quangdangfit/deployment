# Build FE từ source code trong thư mục web/ của repo goshop.
# Stage 1: build static bundle với Node + Vite.
FROM node:20-alpine AS builder

WORKDIR /app
# package.json + lock đặt ở web/ → build-and-push.sh sẽ COPY từ web/ vào.
COPY package*.json ./
# Dùng `npm ci` để build deterministic; fallback `npm install` nếu chưa có lock.
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

COPY . .
RUN npm run build
# Output mặc định của Vite: dist/

# Stage 2: nginx phục vụ static + proxy /api → BE service.
FROM nginx:1.27-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
# nginx mặc định chạy daemon off khi base image alpine, không cần CMD override.
