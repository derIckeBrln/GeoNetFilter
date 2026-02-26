# GeoIP Country Blocking (ipset + iptables/ip6tables)

Country-based IP blocking using:

- ipset (atomic updates)
- iptables + ip6tables
- ipdeny.com country CIDR lists
- systemd service + timer
- additive design (existing firewall rules remain untouched)

---

## 🚀 Features

- IPv4 + IPv6 support
- Atomic ipset updates (swap)
- Dynamic country list (single config location)
- Does NOT overwrite existing firewall rules
- Compatible with netfilter-persistent
- Nightly auto-update via systemd timer
- DNS retry logic
- Safe bash defaults (set -euo pipefail)

---

## 📦 Requirements

- Debian / Ubuntu (or compatible)
- iptables
- ip6tables
- ipset
- curl
- systemd
- Optional: netfilter-persistent

Install dependencies:

    apt install iptables ipset curl

---

## 📁 File Structure

    /etc/scripts/geoip-block.sh
    /etc/systemd/system/geoip-block.service
    /etc/systemd/system/geoip-block.timer

---

# 🔧 Configuration

## 1️⃣ Country Selection

Edit the script:

    COUNTRY_CODES=(cn ru sg)

Use ISO-2 lowercase country codes.

This is the only place where countries must be maintained.

---

## 2️⃣ Install Script

    install -m 750 geoip-block.sh /etc/scripts/geoip-block.sh

---

# ⚙️ systemd Service

File: /etc/systemd/system/geoip-block.service

Enable:

    systemctl daemon-reload
    systemctl enable geoip-block.service

---

# ⏱ systemd Timer (Nightly Update)

File: /etc/systemd/system/geoip-block.timer

Enable:

    systemctl daemon-reload
    systemctl enable --now geoip-block.timer

Check:

    systemctl list-timers | grep geoip

---

# 🧠 How It Works

## ipset Design

For each country:

    geo_<cc>4
    geo_<cc>6

Example:

    geo_cn4
    geo_cn6

Update process:

1. Create temporary set
2. Populate it
3. ipset swap
4. Destroy temporary set

Result: no blocking window.

---

## iptables Design

The script:

- Creates chain GEO_BLOCK4 and GEO_BLOCK6
- Flushes only those chains
- Inserts jump at position 1 of INPUT (if not present)

It does NOT:

- Flush INPUT
- Modify unrelated rules
- Touch /etc/iptables/rules.v4 or .v6

Example rule inside chain:

    -m set --match-set geo_cn4 src -j DROP

---

# 🔁 Interaction with netfilter-persistent

Important:

- rules.v4 and rules.v6 remain untouched.
- If netfilter-persistent reloads firewall rules,
  the GEO chains must be re-attached afterward.

That’s why the service runs:

    After=netfilter-persistent.service

Recommendation:
Let the timer handle updates instead of calling the script manually.

---

# 🧪 Manual Run

    systemctl start geoip-block.service

Logs:

    journalctl -u geoip-block.service

---

# 🛡 Safety Notes

The script uses:

    set -euo pipefail

Meaning:

- Abort on errors
- Abort on unset variables
- Abort if any pipeline command fails

This prevents partial firewall states.

---

# 📊 Execution Flow

1. DNS ready check
2. Fetch CIDR list from ipdeny
3. Validate CIDRs
4. Update ipset atomically
5. Ensure chains exist
6. Insert DROP rules
7. Return to INPUT

---

# 🧹 Removal

Disable timer:

    systemctl disable --now geoip-block.timer
    rm /etc/systemd/system/geoip-block.timer
    systemctl daemon-reload
    
Remove service:

    systemctl disable --now geoip-block.service
    rm /etc/systemd/system/geoip-block.service
    systemctl daemon-reload

Remove chains manually:

    iptables -D INPUT -j GEO_BLOCK4
    iptables -F GEO_BLOCK4
    iptables -X GEO_BLOCK4

    ip6tables -D INPUT -j GEO_BLOCK6
    ip6tables -F GEO_BLOCK6
    ip6tables -X GEO_BLOCK6

Destroy ipsets (example):

    ipset destroy geo_cn4
    ipset destroy geo_cn6

Repeat per configured country.

---

# ⚠️ Limitations

- Country blocking is not perfect geolocation
- VPN / cloud providers can bypass
- ipdeny accuracy depends on upstream data

---

# 📜 License

Use at your own risk.  
No warranty.
