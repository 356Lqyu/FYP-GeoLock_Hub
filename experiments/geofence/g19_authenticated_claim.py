
import os
import uuid
import requests
from dotenv import load_dotenv

load_dotenv()

BASE_URL = os.environ["TEST_SUPABASE_URL"].rstrip("/")
ANON_KEY = os.environ["TEST_SUPABASE_ANON_KEY"]

EMAIL = os.environ["TEST_NGO_EMAIL"]
PASSWORD = os.environ["TEST_NGO_PASSWORD"]

LISTING_ID = "6100b124-4b02-4d1a-8105-27256bacdbe9"
REQUEST_ID = str(uuid.uuid4())

# Step 1: Authenticate NGO 1
auth_response = requests.post(
    f"{BASE_URL}/auth/v1/token?grant_type=password",
    headers={
        "apikey": ANON_KEY,
        "Content-Type": "application/json",
    },
    json={
        "email": EMAIL,
        "password": PASSWORD,
    },
    timeout=30,
)

auth_response.raise_for_status()
token = auth_response.json()["access_token"]

print("NGO 1 authenticated successfully")

# Step 2: Submit authenticated claim
claim_response = requests.post(
    f"{BASE_URL}/rest/v1/rpc/claim_listing",
    headers={
        "apikey": ANON_KEY,
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    },
    json={
        "p_listing_id": LISTING_ID,
        "p_request_id": REQUEST_ID,
    },
    timeout=60,
)

claim_response.raise_for_status()

result = claim_response.json()
print("Claim result:", result)
print("Request ID:", REQUEST_ID)

if isinstance(result, list):
    result = result[0]

if result["outcome"] != "SUCCESS":
    raise RuntimeError(
        f"Expected SUCCESS, received {result['outcome']}"
    )

print("G18-5 authenticated claim: PASS")
print("Claim ID:", result["claim_id"])
