FROM denoland/deno:2.1.4

WORKDIR /app

# Cache external deps in a separate layer for faster rebuilds.
COPY supabase/functions/db.ts ./supabase/functions/db.ts
RUN deno cache --no-check supabase/functions/db.ts

COPY supabase/functions ./supabase/functions

# Warm cache for the entrypoint after copying everything else.
RUN deno cache --no-check supabase/functions/server.ts

# Railway sets $PORT; default to 8000 for local docker-run smoke.
ENV PORT=8000
EXPOSE 8000

# Need network for postgres-deno + Deno.serve, and read access to function files.
CMD ["deno", "run", \
     "--no-check", \
     "--allow-net", \
     "--allow-env", \
     "--allow-read", \
     "supabase/functions/server.ts"]
