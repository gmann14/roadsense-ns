FROM denoland/deno:2.1.4

WORKDIR /app

COPY supabase/functions ./supabase/functions

# Warm Deno's dep cache so cold start doesn't pay the download cost.
RUN deno cache --no-check supabase/functions/server.ts

# Railway sets $PORT; default to 8000 for local docker-run smoke.
ENV PORT=8000
EXPOSE 8000

# Network: postgres-deno + Deno.serve. Env: runtime config. Read scoped to
# the functions dir so a future file-read sink can't escape /app/supabase.
CMD ["deno", "run", \
     "--no-check", \
     "--allow-net", \
     "--allow-env", \
     "--allow-read=/app/supabase/functions", \
     "supabase/functions/server.ts"]
