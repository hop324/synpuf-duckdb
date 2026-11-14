"""Download CMS DE-SynPUF sample 2 (2008-2010) into data/raw/ and unzip the CSVs.

DE-SynPUF is a *synthetic* Medicare claims file built for training and software
testing. Each of the 20 samples is a random 1/20 of synthetic beneficiaries
(about 116k people). Sample 2 is used because sample 1's 2010 beneficiary file
link on the CMS site is broken.

Usage:  uv run python src/01_fetch_data.py      (~380 MB download)
"""

import zipfile
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
CMS = "https://www.cms.gov/research-statistics-data-and-systems/downloadable-public-use-files/synpufs/downloads/"
DL = "http://downloads.cms.gov/files/"
FILES = [
    CMS + "de1_0_2008_beneficiary_summary_file_sample_2.zip",
    CMS + "de1_0_2009_beneficiary_summary_file_sample_2.zip",
    CMS + "de1_0_2010_beneficiary_summary_file_sample_2.zip",
    CMS + "de1_0_2008_to_2010_inpatient_claims_sample_2.zip",
    CMS + "de1_0_2008_to_2010_outpatient_claims_sample_2.zip",
    DL + "DE1_0_2008_to_2010_Carrier_Claims_Sample_2A.zip",
    DL + "DE1_0_2008_to_2010_Carrier_Claims_Sample_2B.zip",
    DL + "DE1_0_2008_to_2010_Prescription_Drug_Events_Sample_2.zip",
]


def download(url: str, zpath: Path, tries: int = 8) -> None:
    """Stream to a .part file, resuming with HTTP Range after stalls or drops
    (downloads.cms.gov is slow and sometimes stops sending)."""
    tmp = zpath.with_suffix(".part")
    for attempt in range(1, tries + 1):
        have = tmp.stat().st_size if tmp.exists() else 0
        headers = {"Range": f"bytes={have}-"} if have else {}
        try:
            with requests.get(url, stream=True, timeout=(30, 60), headers=headers) as r:
                if r.status_code == 416:  # already complete
                    break
                r.raise_for_status()
                mode = "ab" if have and r.status_code == 206 else "wb"
                with open(tmp, mode) as f:
                    for chunk in r.iter_content(1 << 20):
                        f.write(chunk)
            break
        except (requests.ConnectionError, requests.Timeout) as e:
            print(f"  {zpath.name}: attempt {attempt} stalled at "
                  f"{tmp.stat().st_size / 1e6:.0f} MB ({type(e).__name__}); resuming")
    else:
        raise SystemExit(f"could not download {url}")
    tmp.rename(zpath)


def fetch(url: str) -> None:
    zpath = RAW / url.rsplit("/", 1)[1]
    if not zpath.exists():
        download(url, zpath)
        print(f"downloaded {zpath.name} ({zpath.stat().st_size / 1e6:.0f} MB)")
    with zipfile.ZipFile(zpath) as z:
        for name in z.namelist():
            if name.lower().endswith(".csv") and not (RAW / Path(name).name).exists():
                (RAW / Path(name).name).write_bytes(z.read(name))
                print(f"  unzipped {Path(name).name}")


if __name__ == "__main__":
    RAW.mkdir(parents=True, exist_ok=True)
    for u in FILES:
        fetch(u)
