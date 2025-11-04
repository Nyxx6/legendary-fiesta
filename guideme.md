# Iterative workflow

1. **Discover surface attack vectors** (services, web, shares, ports).
2. **Enumerate deeply** (credentials, configs, misconfigs, writable locations).
3. **Test escalation paths** (suid, sudo, cron, scheduled tasks, creds, kernel, containers).
4. **Exploit / proof** (get a shell as target user → escalate → capture root).
5. **If stuck:** pivot to post-exam deliverables (notes, screenshots, useful hints for the report).

---

# Fast enumeration checklist (copy/paste these on the lab machine)

### Network & services

* `ip a && ip r` — confirm your IP/gateway.
* `ss -tulpen` or `netstat -tulpen` — listening services.
* `nmap -sC -sV -p- --min-rate 1000 <target>` — full port scan (if allowed).
* `nmap -p <open-ports> -A -sV --script vuln <target>` — lightweight service/enum scripts.

### Web apps

* Check `/robots.txt`, common directories: `/admin`, `/backup`, `/uploads`.
* Try simple fuzzing with a wordlist (if allowed) and look for file upload or RCE points.
* Inspect cookies and auth token formats in browser/devtools.

### SMB / FTP / Services

* `smbclient -L //<host>` and `smbclient //<host>/<share>` — enumerate SMB shares.
* `curl -I http://host:port` — headers; `curl -s http://host:port/path` to probe endpoints.

### Credentials & files (on shell)

* `id && whoami && uname -a` — baseline.
* `cat /etc/passwd` (look for interesting users).
* `sudo -l` — **very important**: shows sudo rights.
* `find / -type f -perm -4000 -exec ls -ld {} \; 2>/dev/null` — SUID binaries.
* `find / -writable -type d 2>/dev/null` and `find / -perm -2 -type f 2>/dev/null` — writable dirs/files.
* `ls -la ~/*` and `cat ~/.ssh/authorized_keys`, `~/.ssh/id_rsa` if present.
* `grep -Ri "password\|passwd\|secret\|key" /etc /home 2>/dev/null` — quick look for creds.
* `crontab -l` and `ls -la /etc/cron.* /etc/cron.d` — scheduled tasks.
* `ps aux` — look for processes running as root with writable binaries or environment variables.

### Capabilities / Containers / AppArmor / SELinux

* `getcap -r / 2>/dev/null` — file capabilities.
* `docker ps -a` and `ls /var/run/docker.sock` — container escape risk.
* `mount | grep overlay` and check `/proc/1/cgroups` for container context.

### Quick privilege checks

* `sudo -l` (again — if you can run anything as root via sudo, escalate).
* `gdb --help` and whether binaries are writable — sometimes you can use SUID+gdb to escalate.
* `python -c 'import pty; pty.spawn("/bin/bash")'` (improve shell).
* `strings /path/to/some/binary | grep -i password` — sometimes creds in binaries.

---

# Common escalation vectors 

* **Sudo misconfigurations**: if `sudo -l` shows a run-as or specific program, research local exploitation (e.g., `sudoedit`, some allowed programs are escape vectors).
* **SUID root binaries**: look up the binary behavior — many have known privesc tricks (`find`, `vi`, `less`, `more`, `perl`, `awk` when SUID).
* **Writable root-owned scripts** run by cron — if root runs a script you can write to, you win.
* **Cron jobs running as root** that use writable directories or config files — modify them.
* **Credentials in files** (`/etc/*`, app configs, backup dirs, Git repos).
* **SSH keys** in home dirs or config — try them.
* **Docker/socket**: if you can access Docker socket, you can spawn a root container.
* **Capabilities** (`cap_*` on binaries) — these can bypass uid checks.
* **Kernel exploits**: only if lab permits — check `uname -r`, look for local exploit availability (last resort).
* **Path hijacking**: if a root process runs a script that calls an executable from PATH and a writable dir is earlier, drop a malicious binary.

---

# If it’s Windows (quick)

* `whoami /all` and `systeminfo`.
* Look for weak service binaries, unquoted service paths, scheduled tasks, accessible shares, cleartext creds in config files, RDP, SMB misconfig.
* Tools: try `whoami`, `net user`, `wmic service`, check for `SeImpersonatePrivilege` or `SeBackupPrivilege`.
* Look for `C:\Users\username\Documents` and `AppData\Roaming` for credential files.

---

# If you fail to get root — what to do right away

* **Don’t panic.** Failure is data. A good report is gold.
* **Save all artifacts**: shell outputs, screenshots, `history`, `dmesg` outputs. Timestamp them.
* **Document exactly what you tried**: commands and outputs, why you tried them, what failed and how (error messages). This shows methodology and competence.
* **Capture the highest privilege you *did* reach** (e.g., user shell, database access, file read) and explain why escalation wasn’t possible (missing writable cron, no sudo rights, kernel patched, etc).
* **Include remediation suggestions** for each vector you explored (e.g., remove SUID, lock down sudoers, restrict writable dirs, rotate keys).
* **Post-mortem**: list follow-up steps you’d try with more time / different tooling (e.g., run linPEAS, LinEnum, GTFOBins checks, kernel exploit DB search).

---

# Tools to have in your toolkit (if allowed by the lab)

* `linpeas.sh`, `LinEnum.sh`, `gtfobins` knowledge.
* Simple net tools: `nmap`, `curl`, `nc`, `smbclient`, `ssh`.
* Local exploitation helpers: `python`, `perl`, `gcc` (if compiling small exploits), `socat`, `awk`, `sed`.

---

