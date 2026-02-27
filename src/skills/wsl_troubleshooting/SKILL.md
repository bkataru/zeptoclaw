---
name: wsl-troubleshooting
version: 1.0.0
description: WSL2 troubleshooting — DNS fixes, systemd, Windows interop, networking issues.
metadata: {"zeptoclaw":{"emoji":"🪟"}}
---

# WSL2 Troubleshooting

Baala runs ZeptoClaw in WSL2 on Windows. This skill covers common issues and fixes we've encountered.

## Known Issues & Fixes

### Cloudflare WARP Breaks WSL DNS (Fixed 2026-02-03)

**Symptom:** DNS resolution fails in WSL when Cloudflare WARP is running on Windows.

**Fix:**

```bash
# 1. Disable auto-generated resolv.conf
sudo tee /etc/wsl.conf << 'EOF'
[network]
generateResolvConf = false
EOF

# 2. Remove existing symlink
sudo rm /etc/resolv.conf

# 3. Create static resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# 4. Prevent overwriting
sudo chattr +i /etc/resolv.conf

# 5. Restart WSL from PowerShell
wsl --shutdown
```

### systemd Services

WSL2 supports systemd. Check if enabled:

```bash
# Check if systemd is running
ps -p 1 -o comm=
# Should show: systemd (not init)

# If not enabled, add to /etc/wsl.conf:
[boot]
systemd=true

# Then restart WSL
wsl --shutdown
```

### Windows Interop

Access Windows files from WSL:

```bash
# Windows C: drive
/mnt/c/Users/user/

# Windows D: drive
/mnt/d/

# Windows PowerShell from WSL
powershell.exe -Command "Get-Process"

# Windows CMD from WSL
cmd.exe /c "dir"
```

Access WSL files from Windows:

```powershell
# WSL home directory
\\wsl$\Ubuntu\home\user\

# WSL root
\\wsl$\Ubuntu\
```

### Networking

WSL2 uses a virtual network. Check IP:

```bash
# WSL IP
ip addr show eth0

# Windows host IP from WSL
cat /etc/resolv.conf | grep nameserver

# Port forwarding (from Windows PowerShell)
netsh interface portproxy add v4tov4 listenport=9000 listenaddress=0.0.0.0 connectport=9000 connectaddress=$(wsl hostname -I)
```

## Triggers

command: /wsl-dns-fix
command: /wsl-systemd-check
command: /wsl-network-check
command: /wsl-restart
pattern: *wsl dns*
pattern: *wsl network*

## Configuration

wsl_distro (string): WSL distribution name (default: Ubuntu)
dns_servers (string): DNS servers (default: 8.8.8.8,1.1.1.1)
enable_systemd (boolean): Enable systemd (default: true)

## Usage

### Fix DNS issues
```
/wsl-dns-fix
```

### Check systemd status
```
/wsl-systemd-check
```

### Check network status
```
/wsl-network-check
```

### Restart WSL
```
/wsl-restart
```

## Implementation Notes

This skill provides WSL2 troubleshooting support. It:
1. Fixes DNS issues
2. Manages systemd services
3. Handles Windows interop
4. Debugs networking problems
5. Provides common fixes

## Dependencies

- WSL2
- PowerShell (Windows)
