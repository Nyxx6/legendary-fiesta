
### 1) Créer une bi-clé de signature (Ed25519)

```bash
openssl genpkey -algorithm ed25519 -out NAME.key
```

### 2) Extraire et publier la clé publique (pNAME)

```bash
openssl pkey -in NAME.key -pubout -out pNAME.pub
```

### 3) Preuve de possession de la clé secrète

On signe un message clair qui vous identifie. Exemple :

```bash
echo "Je suis NAME et je prouve la possession de ma clé privée" > preuve.txt
```

Signer le message :

```bash
openssl pkeyutl -sign -inkey NAME.key -in preuve.txt -out preuve.sig
```

### 4) Vérification de la signature

```bash
openssl pkeyutl -verify -pubin -inkey pNAME.pub -in preuve.txt -sigfile preuve.sig
```

### À publier dans le chat

* Le contenu de `pNAME.pub`
* Le message signé (`preuve.txt`)
* La signature (`preuve.sig` en base64 si demandé) :

```bash
base64 preuve.sig
```
