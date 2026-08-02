
# ⚡ 3X-UI Quick Deploy (VLESS Reality + Hysteria 2)

Personal automated scripts for fast **VLESS Reality** & **Hysteria 2** setup via **3X-UI** with optional **Cloudflare WARP** integration.

> 🛠️ **Forked & Enhanced** from [YukiKras/vless-scripts](https://github.com/YukiKras/vless-scripts)

---

## 🚀 Usage & Quick Start

Run the desired command directly on your clean Linux VPS (Ubuntu / Debian / CentOS):

### 1️⃣ Basic Install
> Installs 3X-UI with auto-configured VLESS Reality (`ozon.ru`) and Hysteria 2.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/BloxSense/3x-magic/main/3xinstall.sh)

```

---

### 2️⃣ Install with Cloudflare WARP

> Routes VLESS Reality inbound traffic through **Cloudflare WARP** for ChatGPT/geo-lock bypass while keeping Hysteria 2 direct.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/BloxSense/3x-magic/main/3xinstall.sh) --warp

```

---

### 3️⃣ Extended Setup

> Allows setting a **custom panel port** and configuring additional options.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/BloxSense/3x-magic/main/3xinstall.sh) --extend --warp

```

---

## ✨ Key Features

* 🔒 **VLESS Reality**: Pre-configured with `RAW` transport, `xtls-rprx-vision` flow & `ozon.ru` SNI.
* 🚀 **Hysteria 2**: Configured with `Salamander` UDP-obfuscation & local SSL certificates.
* 🌀 **WARP Integration**: Automated SOCKS5 proxy routing (`127.0.0.1:40000`).
* 🎲 **100% Unique Data**: Automatically generates unique UUIDs, passwords, keys, and panel paths on every run.
* 📊 **Credential Storage**: Saves all generated access links, passwords, and QR codes to `/root/3x-ui.txt`.

```

```
