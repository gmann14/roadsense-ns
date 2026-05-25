FROM denoland/deno:2.3.1

WORKDIR /app

COPY . .

RUN deno cache api/railway/main.ts

CMD ["run", "--allow-net", "--allow-env", "api/railway/main.ts"]
