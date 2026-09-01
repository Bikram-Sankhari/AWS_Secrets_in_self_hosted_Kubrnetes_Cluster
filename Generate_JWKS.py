import base64
import json
import argparse
import os
import subprocess
import sys
import hashlib

try:
    import cryptography
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "cryptography==50.0.1"])

from cryptography.hazmat.primitives import serialization


# Argument parser for command line arguments
parser = argparse.ArgumentParser(description="Generate JWKS from RSA public key")
parser.add_argument("--public-key", required=True, help="Path to the RSA public key file")
parser.add_argument("--output", help="Path to output JWKS file, default is jwks.json in the same directory as the public key")
args = parser.parse_args()

public_key_path = args.public_key
output_path = args.output if args.output else os.path.join(os.path.dirname(public_key_path), "jwks.json")

with open(public_key_path, "rb") as f:
    public_key = serialization.load_pem_public_key(f.read())

    
numbers = public_key.public_numbers()

def b64url(n):
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

n_b64 = b64url(numbers.n)
e_b64 = b64url(numbers.e)

# RFC 7638 JWK Thumbprint: SHA-256 over a canonical, sorted JSON representation
canonical = json.dumps({"e": e_b64, "kty": "RSA", "n": n_b64}, separators=(",", ":"), sort_keys=True)
kid = base64.urlsafe_b64encode(hashlib.sha256(canonical.encode()).digest()).rstrip(b"=").decode()

jwks = json.dumps({
    "keys": [
        {
            "kty": "RSA",
            "use": "sig",
            "alg": "RS256",
            "kid": kid,
            "n": b64url(numbers.n),
            "e": b64url(numbers.e),
        }
    ]
}, indent=2)

print(f"Generated JWKS: {jwks}")
print("-------------------------------")
print(f"Writing JWKS to: {output_path}")

with open(output_path, "w") as f:
    f.write(jwks)
