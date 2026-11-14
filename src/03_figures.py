"""Draw README figures from outputs/tables/*.csv into outputs/figures/.

Usage:  uv run python src/03_figures.py
"""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TAB, FIG = ROOT / "outputs" / "tables", ROOT / "outputs" / "figures"
BLUE, ORANGE, GRAY = "#2a78d6", "#eb6834", "#b9b8b2"
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e6e5e0"
plt.rcParams.update({
    "font.size": 10, "axes.edgecolor": INK2, "axes.labelcolor": INK2, "xtick.color": INK2,
    "ytick.color": INK2, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True,
    "figure.dpi": 150, "savefig.bbox": "tight", "figure.facecolor": "white",
})


def monthly():
    m = pd.read_csv(TAB / "monthly_claims.csv", parse_dates=["month"])
    m = m[m.month <= "2010-12-01"]
    fig, ax = plt.subplots(figsize=(9, 3.4))
    base = m[(m.month >= "2008-03-01") & (m.month <= "2009-12-01")].ip_admissions.mean()
    ax.axvspan(pd.Timestamp("2008-03-01"), pd.Timestamp("2009-12-31"), color=BLUE, alpha=0.08, lw=0)
    ax.plot(m.month, 100 * m.ip_admissions / base, color=BLUE, lw=2, marker="o", ms=4)
    ax.set_ylabel("Inpatient admissions\n(% of Mar 2008-Dec 2009 average)")
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.text(pd.Timestamp("2008-03-15"), 20, "complete-data window\nused for the analysis",
            color=BLUE, fontsize=9)
    ax.set_ylim(0, 125)
    ax.set_title("SynPUF claims ramp up in early 2008 and trail off through 2010",
                 color=INK, fontsize=11, loc="left")
    fig.savefig(FIG / "monthly_volume.png")
    plt.close(fig)


def chronic():
    c = pd.read_csv(TAB / "pmpy_by_chronic.csv", dtype={"chronic_conditions": str})
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.6))
    axes[0].bar(c.chronic_conditions, c.medical_pmpy, color=BLUE, width=0.7)
    for x, v in zip(c.chronic_conditions, c.medical_pmpy):
        axes[0].text(x, v, f"${v:,.0f}", ha="center", va="bottom", fontsize=8.5, color=INK2)
    axes[0].set_ylabel("Medical $ per member per year")
    axes[0].set_xlabel("Number of chronic conditions (of 11 tracked)")
    axes[0].set_title("Cost per member rises steeply with chronic conditions",
                      color=INK, fontsize=10, loc="left")
    x = np.arange(len(c))
    axes[1].bar(x - 0.18, c.pct_of_members, width=0.36, color=GRAY, label="% of members")
    axes[1].bar(x + 0.18, c.pct_of_spend, width=0.36, color=BLUE, label="% of medical spend")
    axes[1].set_xticks(x, c.chronic_conditions)
    axes[1].set_xlabel("Number of chronic conditions")
    axes[1].set_ylabel("%")
    axes[1].legend(frameon=False)
    axes[1].set_title("A quarter of members (5+ conditions) drive ~60% of spend",
                      color=INK, fontsize=10, loc="left")
    fig.suptitle("2009, fee-for-service member-years", x=0.01, ha="left", color=INK2, fontsize=9)
    fig.savefig(FIG / "pmpy_by_chronic.png")
    plt.close(fig)


def oe():
    a = pd.read_csv(TAB / "hospital_oe.csv")
    s = pd.read_csv(TAB / "hospital_oe_shuffled.csv")
    bins = np.linspace(0.5, 1.6, 45)
    fig, ax = plt.subplots(figsize=(8, 3.8))
    ax.hist(s.oe_ratio, bins=bins, density=True, color=GRAY, alpha=0.8,
            label="Hospitals shuffled at random (20 shuffles)")
    ax.hist(a.oe_ratio, bins=bins, density=True, histtype="step", lw=2, color=BLUE,
            label=f"Actual hospitals (n = {len(a)})")
    ax.axvline(1, color=INK2, lw=0.8, ls=":")
    ax.set_xlabel("Observed / expected inpatient cost (1.0 = paid like peers for the same DRGs)")
    ax.set_ylabel("Density")
    ax.legend(frameon=False, loc="upper left")
    ax.set_title("Hospital cost variation is about what chance alone produces",
                 color=INK, fontsize=11, loc="left")
    fig.savefig(FIG / "hospital_oe_vs_noise.png")
    plt.close(fig)


if __name__ == "__main__":
    FIG.mkdir(parents=True, exist_ok=True)
    monthly()
    chronic()
    oe()
    print("figures ->", sorted(p.name for p in FIG.glob("*.png")))
