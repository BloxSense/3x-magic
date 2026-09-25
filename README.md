# ⚡ 3X-UI Quick Deploy (VLESS Reality + Hysteria2)

Personal automated installer for fast **VLESS Reality** & **Hysteria2** setup via [3x-ui](https://github.com/MHSanaei/3x-ui).

## Supported Linux distributions

![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%2B-E95420?logo=ubuntu&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-11%2B-A81D33?logo=debian&logoColor=white)
![CentOS](https://img.shields.io/badge/CentOS-9%2B-262577?logo=centos&logoColor=white)
![AlmaLinux](https://img.shields.io/badge/AlmaLinux-9%2B-000000?logo=almalinux&logoColor=white)
![Rocky](https://img.shields.io/badge/Rocky_Linux-9%2B-10B981?logo=rockylinux&logoColor=white)

## Install

Before installation, it is strongly recommended to upgrade your system and reboot beforehand.

Run on a clean VPS as root:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/BloxSense/3x-magic/main/3xinstall.sh)
```

After launching, just follow the interactive prompts (SNI choice, client vs. personal install, panel port) — everything else (credentials, keys, inbounds, certificate) is generated automatically.

## Key Features

- 🔒 **VLESS Reality** — TCP transport, `xtls-rprx-vision` flow, `ozon.ru` / `games.mail.ru` SNI
- 🚀 **Hysteria2** — `salamander` UDP-obfuscation, ALPN h3
- 🌐 **Automatic TLS** — Let's Encrypt IP certificate (short-lived, auto-renewed via `acme.sh` cron), falls back to self-signed if issuance fails
- 📶 **TCP BBR** — buffer & congestion control tuning on supported kernels
- 🎲 **100% unique data** — UUIDs, passwords, keys, panel path regenerated on every run
- 💾 **Credential storage** — all links, passwords, and panel access saved to `/root/3x-ui.txt`

## License

MIT
