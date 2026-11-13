"""Create one unprivileged Postgres role per agent. Run once with the harness venv (setup.sh does this)."""
import json
import os
import psycopg
from psycopg import sql

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = json.load(open(R + "/config.json"))
pw = json.load(open(R + "/harness/secrets/db.json"))
db = cfg["db"]

with psycopg.connect(host=db["host"], port=db["port"], dbname=db["name"],
                     user="postgres", password=pw["admin"], autocommit=True) as c:
    c.execute("DO $$ BEGIN CREATE ROLE agents NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$")
    for a in cfg["agents"]:
        ident = sql.Identifier(a)
        exists = c.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (a,)).fetchone()
        verb = "ALTER" if exists else "CREATE"
        c.execute(sql.SQL(verb + " ROLE {} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD {}")
                  .format(ident, sql.Literal(pw[a])))
        c.execute(sql.SQL("GRANT agents TO {}").format(ident))
        c.execute(sql.SQL("ALTER ROLE {} SET statement_timeout = '5s'").format(ident))
    c.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
    c.execute("GRANT USAGE ON SCHEMA public TO agents")
    c.execute("GRANT CREATE ON SCHEMA public TO lead")
    # Tables the lead creates are readable/writable (not deletable) by every agent.
    c.execute("ALTER DEFAULT PRIVILEGES FOR ROLE lead IN SCHEMA public "
              "GRANT SELECT, INSERT, UPDATE ON TABLES TO agents")
    c.execute("ALTER DEFAULT PRIVILEGES FOR ROLE lead IN SCHEMA public "
              "GRANT USAGE, SELECT ON SEQUENCES TO agents")
    print("roles:", [r[0] for r in c.execute(
        "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1").fetchall()])
