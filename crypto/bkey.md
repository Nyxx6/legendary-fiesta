
# concatenate s0 and s1 into a single binary input
cat s0.bin s1.bin > s01.bin

# derive 64 bytes: first 32 -> tmpkey, next 32 -> kA1
openssl kdf -engine default -derive -hkdf -sha256 -in s01.bin -out key_material.bin -len 64

# split the derived key
head -c 32 key_material.bin > tmpkey.bin
tail -c 32 key_material.bin > kA1.bin

# generate a random 12-byte IV
openssl rand -out iv1.bin 12

# encrypt mA1 using AES-256-GCM
openssl enc -aes-256-gcm -in mA1.txt -out cA1.bin -K $(xxd -p kA1.bin) -iv $(xxd -p iv1.bin) -nosalt -p

# generate a new random 12-byte IV
openssl rand -out iv2.bin 12

# encrypt mA2 using AES-256-GCM
openssl enc -aes-256-gcm -in mA2.txt -out cA2.bin -K $(xxd -p kA2.bin) -iv $(xxd -p iv2.bin) -nosalt -p
