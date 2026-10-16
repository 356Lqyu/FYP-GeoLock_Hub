import os
import requests
from dotenv import load_dotenv

load_dotenv()

url = os.environ["TEST_SUPABASE_URL"].rstrip("/")
key = os.environ["TEST_SUPABASE_ANON_KEY"]
email = os.environ["TEST_NGO_EMAIL"]
password = os.environ["TEST_NGO_PASSWORD"]

headers = {
    "apikey": key,
    "Content-Type": "application/json",
}

# Step 1: Sign in as NGO 1.
login = requests.post(
    f"{url}/auth/v1/token",
    params={"grant_type": "password"},
    headers=headers,
    json={
        "email": email,
        "password": password,
    },
    timeout=30,
)

login.raise_for_status()
session = login.json()

access_token = session["access_token"]
expected_user_id = session["user"]["id"]

print("Authentication successful.")
print("Logged-in email:", email)
print("Authenticated user ID:", expected_user_id)

# Step 2: Call the protected RPC using the user's JWT.
rpc = requests.post(
    f"{url}/rest/v1/rpc/test_authenticated_ngo",
    headers={
        **headers,
        "Authorization": f"Bearer {access_token}",
    },
    json={},
    timeout=30,
)

rpc.raise_for_status()
result = rpc.json()

print("RPC result:", result)

# Step 3: Verify the function identifies the correct NGO.
assert len(result) == 1

record = result[0]

assert record["ngo_user_id"] == expected_user_id
assert record["is_valid_ngo"] is True
assert record["message"] == "Authenticated active NGO"

print("G13-A: Authenticated NGO identity — PASS")

# Step 4: Verify anonymous callers cannot execute the RPC.
anonymous = requests.post(
    f"{url}/rest/v1/rpc/test_authenticated_ngo",
    headers=headers,
    json={},
    timeout=30,
)

print("Anonymous RPC HTTP status:", anonymous.status_code)

assert anonymous.status_code in (401, 403)

print("G13-B: Anonymous execution denied — PASS")
print("TOTAL: 2/2 tests passed")