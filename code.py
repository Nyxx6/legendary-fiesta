from itertools import cycle
def crypt_string(data, key):
 return ''.join(chr(ord(x) ^ ord(y)) for (x,y) in zip(data, cycle(key)))

import hashlib
salt = "1234"
def hash_password(password):
 m = hashlib.md5()
 m.update((salt + password).encode('utf-8'))
 return m.hexdigest()
