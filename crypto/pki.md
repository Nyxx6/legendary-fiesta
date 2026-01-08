# PKI with Root CA - OpenSSL Commands

## Root CA Setup

**Create Root CA private key:**
```bash
openssl genrsa -aes256 -out root-ca.key 4096
```

**Create Root CA certificate:**
```bash
openssl req -x509 -new -nodes -key root-ca.key -sha256 -days 3650 \
  -out root-ca.crt -subj "/C=US/ST=State/O=MyOrg/CN=MyRootCA"
```

## Intermediate CA (Optional but Recommended)

**Generate Intermediate CA key:**
```bash
openssl genrsa -aes256 -out intermediate-ca.key 4096
```

**Create CSR for Intermediate CA:**
```bash
openssl req -new -key intermediate-ca.key -out intermediate-ca.csr \
  -subj "/C=US/ST=State/O=MyOrg/CN=MyIntermediateCA"
```

**Root CA signs Intermediate CA:**
```bash
openssl x509 -req -in intermediate-ca.csr -CA root-ca.crt -CAkey root-ca.key \
  -CAcreateserial -out intermediate-ca.crt -days 1825 -sha256 \
  -extfile <(echo "basicConstraints=CA:TRUE")
```

## End-Entity Certificate (Server/User)

**Generate private key:**
```bash
openssl genrsa -out server.key 2048
```

**Create Certificate Signing Request (CSR):**
```bash
openssl req -new -key server.key -out server.csr \
  -subj "/C=US/ST=State/O=MyOrg/CN=example.com"
```

**CA signs the certificate:**
```bash
openssl x509 -req -in server.csr -CA intermediate-ca.crt \
  -CAkey intermediate-ca.key -CAcreateserial -out server.crt \
  -days 365 -sha256
```

## Verification

**Verify certificate chain:**
```bash
openssl verify -CAfile root-ca.crt -untrusted intermediate-ca.crt server.crt
```

**View certificate details:**
```bash
openssl x509 -in server.crt -text -noout
```

**Check certificate dates:**
```bash
openssl x509 -in server.crt -noout -dates
```

## Revocation

**Create Certificate Revocation List (CRL):**
```bash
openssl ca -config openssl.cnf -gencrl -out root-ca.crl
```

**Revoke certificate:**
```bash
openssl ca -config openssl.cnf -revoke server.crt
```

## Bundle Certificates

**Create certificate chain:**
```bash
cat server.crt intermediate-ca.crt root-ca.crt > fullchain.pem
```

## Common Use Cases

**Web server (Apache/Nginx):**
```bash
# Generate key + CSR
openssl req -new -newkey rsa:2048 -nodes -keyout server.key -out server.csr
# Send CSR to CA for signing
# Install: server.key, server.crt, ca-bundle.crt
```

**Client certificate authentication:**
```bash
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -out client.crt
# Convert to PKCS#12 for browsers
openssl pkcs12 -export -out client.p12 -inkey client.key -in client.crt
```

**View CSR contents:**
```bash
openssl req -in server.csr -text -noout
```

**Extract public key from certificate:**
```bash
openssl x509 -in server.crt -pubkey -noout > public.key
```

# Extension File for Certificate Configuration

**Create ext file (server_ext.cnf):**
```bash
cat > server_ext.cnf << EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = example.com
DNS.2 = www.example.com
DNS.3 = *.example.com
IP.1 = 192.168.1.100
EOF
```

**Sign certificate with extensions:**
```bash
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 -sha256 \
  -extfile server_ext.cnf
```

## Common Extension Types

**CA certificate:**
```ini
basicConstraints = CA:TRUE, pathlen:0
keyUsage = keyCertSign, cRLSign
```

**Server certificate:**
```ini
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:example.com, DNS:www.example.com
```

**Client certificate:**
```ini
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
```

**Code signing:**
```ini
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
```

## Key Fields

- **basicConstraints**: CA:TRUE/FALSE, pathlen (chain depth)
- **keyUsage**: What key can do (signing, encryption, etc.)
- **extendedKeyUsage**: Specific purposes (serverAuth, clientAuth, emailProtection)
- **subjectAltName**: Alternative names/IPs for certificate

**Modern requirement**: SAN (subjectAltName) mandatory for HTTPS certificates, even if CN matches.
