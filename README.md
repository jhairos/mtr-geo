# mtr-geo

> **Powered mtr-geo by Jairo — Cada salto cuenta 🌍**  
> Wrapper de `mtr` que añade **ASN**, **Organización (ISP)** y **Geo** por hop, para leer rutas con contexto real (no solo latencia).

---

## ✨ ¿Qué hace?
- Ejecuta `mtr` (IPv4/IPv6) y **resume cada hop** con: `AS | ORG | GEO | RTTavg`.
- Normaliza nombres de organizaciones (p. ej., “Cloudflare”, “Google”).
- Soporta bases **MaxMind GeoLite2** (City/ASN/Country) y *fallback* a métodos legacy.
- **No expone datos sensibles**: credenciales vía variables de entorno.

---

## 📦 Instalación rápida (Debian/Ubuntu)

```bash
git clone https://github.com/<TU-USUARIO>/mtr-geo.git
cd mtr-geo

# Exporta tus credenciales de MaxMind (no quedan en el repo):
export MAXMIND_ACCOUNT_ID="TU_ID"
export MAXMIND_LICENSE_KEY="TU_KEY"

# Instalador genérico (paquetes + bases GeoIP + binario /usr/local/bin/mtr-geo)
sudo -E bash install_mtr_geo.sh
