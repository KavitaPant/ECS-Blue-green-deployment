FROM node:20.10.0-alpine
WORKDIR app
COPY . .
RUN npm install
EXPOSE 8000
CMD ["node","app.js"]