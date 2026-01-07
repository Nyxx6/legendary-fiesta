# Cryptographic Algorithms Comparison

## Symmetric Encryption

| Algorithm | Key Size | Security Level | Speed | Notes |
|-----------|----------|----------------|-------|-------|
| **AES-128** | 128 bits | ~128-bit | Very fast | Current standard, hardware acceleration |
| **AES-192** | 192 bits | ~192-bit | Very fast | Rarely used |
| **AES-256** | 256 bits | ~256-bit | Very fast | Maximum security, standard for classified |
| **3DES** | 168 bits effective | ~112-bit | Slow | Legacy, deprecated |
| **ChaCha20** | 256 bits | ~256-bit | Very fast | Modern, no hardware needed, used in TLS |
| **Blowfish** | 32-448 bits | ~128-bit | Fast | Legacy, replaced by AES |
| **Twofish** | 128/192/256 | Variable | Fast | AES finalist, less common |

**Security equivalence**: AES-128 ≈ RSA-3072 ≈ ECC-256

## Asymmetric Encryption

| Algorithm | Key Size | Security Level | Speed | Notes |
|-----------|----------|----------------|-------|-------|
| **RSA-1024** | 1024 bits | Broken | Slow | **DO NOT USE** |
| **RSA-2048** | 2048 bits | ~112-bit | Slow | Minimum recommended |
| **RSA-3072** | 3072 bits | ~128-bit | Slower | Equivalent to AES-128 |
| **RSA-4096** | 4096 bits | ~140-bit | Very slow | High security |
| **ECC P-256** | 256 bits | ~128-bit | Fast | Modern, efficient |
| **ECC P-384** | 384 bits | ~192-bit | Fast | High security |
| **Curve25519** | 256 bits | ~128-bit | Very fast | Modern standard (Ed25519, X25519) |
| **ElGamal** | 2048+ bits | Variable | Slow | Rarely used directly |

**Key insight**: ECC provides same security as RSA with much smaller keys

## Hash Functions

| Algorithm | Output Size | Security Level | Speed | Status |
|-----------|-------------|----------------|-------|--------|
| **MD5** | 128 bits | **BROKEN** | Very fast | Collisions practical, avoid |
| **SHA-1** | 160 bits | **BROKEN** | Fast | Collisions found (2017), deprecated |
| **SHA-224** | 224 bits | ~112-bit | Fast | Truncated SHA-256 |
| **SHA-256** | 256 bits | ~128-bit | Fast | Current standard |
| **SHA-384** | 384 bits | ~192-bit | Fast | Truncated SHA-512 |
| **SHA-512** | 512 bits | ~256-bit | Fast (64-bit) | High security |
| **SHA-3-256** | 256 bits | ~128-bit | Moderate | Latest standard, different design |
| **BLAKE2b** | Variable | Up to 256-bit | Very fast | Modern, faster than SHA-2 |
| **BLAKE3** | 256 bits | ~128-bit | Extremely fast | Newest, parallelizable |

**Collision resistance**: Need 2^(n/2) operations for n-bit hash (birthday attack)

## Security Level Equivalence

| Symmetric | Asymmetric RSA | ECC | Hash | Security Bits |
|-----------|----------------|-----|------|---------------|
| AES-128 | RSA-3072 | P-256 | SHA-256 | ~128 |
| AES-192 | RSA-7680 | P-384 | SHA-384 | ~192 |
| AES-256 | RSA-15360 | P-521 | SHA-512 | ~256 |

## Current Recommendations (2024-2026)

**Encryption:**
- Symmetric: AES-256 or ChaCha20
- Asymmetric: RSA-3072+ or ECC P-256+
- Mode: GCM (authenticated encryption)

**Hashing:**
- SHA-256 minimum
- SHA-512 or SHA-3 for higher security
- BLAKE3 for performance

**Digital Signatures:**
- RSA-3072+ with SHA-256
- Ed25519 (modern, preferred)
- ECDSA P-256+ with SHA-256

**Key Exchange:**
- ECDH with Curve25519 (X25519)
- RSA-3072+ (older systems)

## Post-Quantum Considerations

Current algorithms vulnerable to quantum computers:
- RSA - **BROKEN** by Shor's algorithm
- ECC - **BROKEN** by Shor's algorithm
- AES - Weakened (use AES-256)
- SHA-2/3 - Mostly secure

**NIST Post-Quantum Standards (2024):**
- CRYSTALS-Kyber (encryption)
- CRYSTALS-Dilithium (signatures)
- SPHINCS+ (signatures)
