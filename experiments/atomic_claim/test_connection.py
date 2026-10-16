
import os
import psycopg
from dotenv import load_dotenv

load_dotenv()

database_url = os.getenv("TEST_DATABASE_URL")

if not database_url:
    raise RuntimeError("TEST_DATABASE_URL is missing")

with psycopg.connect(
    database_url,
    connect_timeout=15
) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT current_database(), current_user;")
        result = cur.fetchone()

        print("Database connection successful!")
        print("Database:", result[0])
        print("User:", result[1])
