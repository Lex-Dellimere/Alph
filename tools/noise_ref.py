"""Reference Noise_XXpsk3_25519_ChaChaPoly_SHA256 handshake with fixed keys.

Prints the three handshake messages and one transport message from each side
as hex, for tests/t_noise.mettle to compare against. Needs the `cryptography`
package. Run: python3 -I tools/noise_ref.py
"""
import hashlib, hmac
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives import serialization

RAW = serialization.Encoding.Raw, serialization.PublicFormat.Raw

def key(seed):
    return X25519PrivateKey.from_private_bytes(bytes([seed]) * 32)

def pub(k):
    return k.public_key().public_bytes(*RAW)

def hkdf(ck, ikm, n):
    t = hmac.new(ck, ikm, hashlib.sha256).digest()
    outs, prev = [], b""
    for i in range(1, n + 1):
        prev = hmac.new(t, prev + bytes([i]), hashlib.sha256).digest()
        outs.append(prev)
    return outs

class Sym:
    def __init__(self):
        name = b"Noise_XXpsk3_25519_ChaChaPoly_SHA256"
        self.h = hashlib.sha256(name).digest()
        self.ck = self.h
        self.k, self.n = None, 0
        self.mix_hash(b"")
    def mix_hash(self, d):
        self.h = hashlib.sha256(self.h + d).digest()
    def mix_key(self, ikm):
        self.ck, self.k = hkdf(self.ck, ikm, 2)
        self.n = 0
    def mix_key_and_hash(self, ikm):
        self.ck, th, self.k = hkdf(self.ck, ikm, 3)
        self.n = 0
        self.mix_hash(th)
    def nonce(self):
        return b"\0" * 4 + self.n.to_bytes(8, "little")
    def enc_hash(self, pt):
        ct = ChaCha20Poly1305(self.k).encrypt(self.nonce(), pt, self.h) if self.k else pt
        if self.k: self.n += 1
        self.mix_hash(ct)
        return ct
    def dec_hash(self, ct):
        pt = ChaCha20Poly1305(self.k).decrypt(self.nonce(), ct, self.h) if self.k else ct
        if self.k: self.n += 1
        self.mix_hash(ct)
        return pt
    def split(self):
        return hkdf(self.ck, b"", 2)

psk = bytes(range(32))
si, sr, ei, er = key(1), key(2), key(3), key(4)
I, R = Sym(), Sym()

def dh(a, b): return a.exchange(b)
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
def P(b): return X25519PublicKey.from_public_bytes(b)

# -> e
m1 = pub(ei); I.mix_hash(pub(ei)); I.mix_key(pub(ei)); m1 += I.enc_hash(b"")
re = m1[:32]; R.mix_hash(re); R.mix_key(re); R.dec_hash(m1[32:])
# <- e, ee, s, es
m2 = pub(er); R.mix_hash(pub(er)); R.mix_key(pub(er))
R.mix_key(dh(er, P(re)))
m2 += R.enc_hash(pub(sr))
R.mix_key(dh(sr, P(re)))
m2 += R.enc_hash(b"")
rei = m2[:32]; I.mix_hash(rei); I.mix_key(rei); I.mix_key(dh(ei, P(rei)))
rs = I.dec_hash(m2[32:80]); I.mix_key(dh(ei, P(rs))); I.dec_hash(m2[80:])
# -> s, se, psk
m3 = I.enc_hash(pub(si)); I.mix_key(dh(si, P(rei))); I.mix_key_and_hash(psk); m3 += I.enc_hash(b"")
rsi = R.dec_hash(m3[:48]); R.mix_key(dh(er, P(rsi))); R.mix_key_and_hash(psk); R.dec_hash(m3[48:])
i_send, i_recv = I.split()
t1 = ChaCha20Poly1305(i_send).encrypt(b"\0" * 12, b"hello", b"")
t2 = ChaCha20Poly1305(i_recv).encrypt(b"\0" * 12, b"world", b"")
for name, v in (("m1", m1), ("m2", m2), ("m3", m3), ("t1", t1), ("t2", t2)):
    print(name, v.hex())
