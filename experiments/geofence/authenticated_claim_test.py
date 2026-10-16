import os
import uuid
import requests
from dotenv import load_dotenv

load_dotenv()

url = os.environ["TEST_SUPABASE_URL"].rstrip("/")
key = os.environ["TEST_SUPABASE_ANON_KEY"]
email = os.environ["TEST_NGO_EMAIL"]
password = os.environ["TEST_NGO_PASSWORD"]

LISTING_ID = "d16174a9-9e28-452e-be16-08ace6372ae3"
REQUEST_ID = str(uuid.uuid4())

headers = {
    "apikey": key,
    "Content-Type": "application/json",
}

# 1. Authenticate NGO 1.
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

print("Authenticated NGO:", email)
print("User ID:", session["user"]["id"])
print("Listing ID:", LISTING_ID)
print("Request ID:", REQUEST_ID)

auth_headers = {
    **headers,
    "Authorization": f"Bearer {access_token}",
}

payload = {
    "p_listing_id": LISTING_ID,
    "p_request_id": REQUEST_ID,
}

# 2. First claim attempt.
response = requests.post(
    f"{url}/rest/v1/rpc/claim_listing",
    headers=auth_headers,
    json=payload,
    timeout=30,
)

print("\nFirst claim HTTP status:", response.status_code)
print("First claim response:", response.text)

response.raise_for_status()
first = response.json()

assert len(first) == 1
assert first[0]["outcome"] == "SUCCESS"
assert first[0]["claim_id"] is not None

claim_id = first[0]["claim_id"]

print("G14-A: Authenticated claim — PASS")

# 3. Retry with the same request ID.
retry = requests.post(
    f"{url}/rest/v1/rpc/claim_listing",
    headers=auth_headers,
    json=payload,
    timeout=30,
)

print("\nRetry HTTP status:", retry.status_code)
print("Retry response:", retry.text)

retry.raise_for_status()
second = retry.json()

assert len(second) == 1
assert second[0]["outcome"] == "SUCCESS"
assert second[0]["claim_id"] == claim_id

print("G14-B: Idempotent retry — PASS")

# 4. Anonymous execution attempt.
anonymous = requests.post(
    f"{url}/rest/v1/rpc/claim_listing",
    headers=headers,
    json=payload,
    timeout=30,
)

print("\nAnonymous HTTP status:", anonymous.status_code)
assert anonymous.status_code in (401, 403)

print("G14-C: Anonymous claim denied — PASS")

print("\nTOTAL: 3/3 tests passed")
print("Successful claim ID:", claim_id)