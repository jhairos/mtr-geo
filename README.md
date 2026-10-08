# mtr-geo

> **Powered mtr-geo by Jairo — Cada salto cuenta 🌎**
> A wrapper around `mtr` that adds **AS**, **organization** and **geolocation** to every hop, so a path can be read with ownership context, not only latency.

## What it does

- Runs `mtr` (IPv4/IPv6) and summarizes each hop as `AS | ORG | GEO | RTTavg`.
- Normalizes organization names (e.g. "Cloudflare", "Google").
- Uses MaxMind GeoLite2 databases (City / ASN / Country) with a fallback lookup method.
- Does not store credentials in the code: they are read from environment variables.

## Security use

Plain `mtr` shows loss and latency per hop, but not who owns each hop. mtr-geo adds that ownership column, which helps to:

- Notice a path that suddenly crosses an unexpected AS or country (a possible route leak or hijack).
- Confirm which network a degradation belongs to before escalating (local edge, transit or destination).
- Keep a per-destination baseline of the AS path and compare new traces against it.

**Limitation:** geolocation reflects where an address block is registered, not where the equipment physically is. Use the GEO column to detect changes, not to prove where traffic goes.

## Quick install (Debian/Ubuntu)

```bash
git clone https://github.com/jhairos/mtr-geo.git
cd mtr-geo

# MaxMind GeoLite2 credentials (free account), read by the installer
export ACCOUNT_ID="<your-maxmind-account-id>"
export LICENSE_KEY="<your-maxmind-license-key>"

# Installs packages, downloads GeoLite2 databases and copies the binary to /usr/local/bin/mtr-geo
sudo -E bash install_mtr_geo.sh
```

## Usage

```bash
mtr-geo 8.8.8.8
mtr-geo example.com
```

The output shows the standard `mtr` report followed by a summary table with AS, organization, geolocation and average RTT per hop.

## Author

MSc. Medardo Jairo Suntaxi Cocanguilla, C|EH — Ecuador.

## License

MIT — see [LICENSE.md](LICENSE.md).
