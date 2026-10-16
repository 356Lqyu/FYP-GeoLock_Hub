
import os
import uuid
import requests
from dotenv import load_dotenv

load_dotenv()

BASE_URL = os.environ["TEST_SUPABASE_URL"].rstrip("/")
ANON_KEY = os.environ["TEST_SUPABASE_ANON_KEY"]

NGO_EMAIL = "ngo2@test.com"
NGO_PASSWORD = os.environ["TEST_NGO2_PASSWORD"]

LISTING_ID = "17f5b1e6-3384-4a55-9368-bd45a6a76bfa"
REQUEST_ID = str(uuid.uuid4())

# Step 1: Sign in as NGO 2.
login_response = requests.post(
    f"{BASE_URL}/auth/v1/token?grant_type=password",
    headers={
        "apikey": ANON_KEY,
        "Content-Type": "application/json",
    },
    json={
        "email": NGO_EMAIL,
        "password": NGO_PASSWORD,
    },
    timeout=30,
)

login_response.raise_for_status()

access_token = login_response.json()["access_token"]

print("NGO 2 authentication: SUCCESS")
print("Listing ID:", LISTING_ID)
print("Request ID:", REQUEST_ID)

# Step 2: Claim the reopened listing.
rpc_url = f"{BASE_URL}/rest/v1/rpc/claim_listing"

headers = {
    "apikey": ANON_KEY,
    "Authorization": f"Bearer {access_token}",
    "Content-Type": "application/json",
}

payload = {
    "p_listing_id": LISTING_ID,
    "p_request_id": REQUEST_ID,
}

claim_response = requests.post(
    rpc_url,
    headers=headers,
    json=payload,
    timeout=60,
)

claim_response.raise_for_status()

result = claim_response.json()

print("\nFirst claim response:")
print(result)

assert isinstance(result, list) and len(result) == 1
assert isinstance(result, list) and len(result) == 1

assert result[0]["outcome"] == "CONFLICT", (
    f"Expected CONFLICT, received {result[0]['outcome']}"
)

assert result[0]["claim_id"] is None, (
    "Blocked claim must not create a new claim ID"
)

print("\nPASS: NGO 2 cannot claim the protected G18 listing")
print("G18-12 blocked authenticated claim: PASS")