# GPG Essential Commands

## Key Generation
```bash
# Generate key pair (interactive)
gpg --full-generate-key

# Quick generate with defaults
gpg --generate-key

# List your keys
gpg --list-keys
gpg --list-secret-keys
```

## Export Keys
```bash
# Export public key (ASCII format)
gpg --armor --export your@email.com > public.key

# Export private key (KEEP SECRET!)
gpg --armor --export-secret-keys your@email.com > private.key

# Export to keyserver
gpg --send-keys KEY_ID
```

## Import Keys
```bash
# Import public key from file
gpg --import someone_public.key

# Import from keyserver
gpg --recv-keys KEY_ID

# Search keyserver
gpg --search-keys email@example.com
```

## Encryption
```bash
# Encrypt file for recipient
gpg --encrypt --recipient recipient@email.com file.txt
# Creates: file.txt.gpg

# Encrypt with ASCII armor (text format)
gpg --armor --encrypt --recipient recipient@email.com file.txt
# Creates: file.txt.asc

# Encrypt for multiple recipients
gpg -e -r alice@email.com -r bob@email.com file.txt
```

## Decryption
```bash
# Decrypt file
gpg --decrypt file.txt.gpg > file.txt

# Decrypt to stdout
gpg --decrypt file.txt.gpg

# Decrypt with output file
gpg --output file.txt --decrypt file.txt.gpg
```

## Digital Signatures
```bash
# Sign file (creates separate signature)
gpg --sign file.txt
# Creates: file.txt.gpg

# Create detached signature
gpg --detach-sign file.txt
# Creates: file.txt.sig

# Sign with ASCII armor
gpg --armor --detach-sign file.txt
# Creates: file.txt.asc

# Clear-sign (signature embedded in text)
gpg --clearsign file.txt
```

## Verification
```bash
# Verify signature
gpg --verify file.txt.sig file.txt

# Verify and extract signed file
gpg --decrypt signed_file.txt.gpg
```

## Sign + Encrypt (Combined)
```bash
# Sign and encrypt
gpg --sign --encrypt --recipient recipient@email.com file.txt

# With ASCII armor
gpg --armor --sign --encrypt -r recipient@email.com file.txt
```

## Key Management
```bash
# Delete public key
gpg --delete-keys email@example.com

# Delete private key
gpg --delete-secret-keys email@example.com

# Edit key (trust, sign, etc.)
gpg --edit-key email@example.com

# Generate revocation certificate
gpg --output revoke.asc --gen-revoke your@email.com

# Sign someone's key (web of trust)
gpg --sign-key their@email.com
```

## Common Options
- `--armor` or `-a`: ASCII output (instead of binary)
- `--output` or `-o`: Specify output file
- `--recipient` or `-r`: Specify recipient
- `--encrypt` or `-e`: Encrypt
- `--decrypt` or `-d`: Decrypt
- `--sign` or `-s`: Sign

## Typical Workflows

**Encrypt file for Alice:**
```bash
gpg --import alice_public.key
gpg -e -r alice@email.com document.pdf
# Send document.pdf.gpg
```

**Decrypt received file:**
```bash
gpg -d encrypted_file.gpg > decrypted.txt
```

**Sign document:**
```bash
gpg --armor --detach-sign report.pdf
# Share report.pdf + report.pdf.asc
```

**Verify signed document:**
```bash
gpg --verify report.pdf.asc report.pdf
```
