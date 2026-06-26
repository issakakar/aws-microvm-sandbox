# microvm-bench sample — variant: sci (pandas + seaborn, on numpy/matplotlib)
# CONTRACTS §H: pandas DataFrame + seaborn barplot/heatmap -> PNG.
# Leaves a figure on the pyplot stack for the worker to capture when wantImage is set.
import io

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")  # headless; the only backend shipped in the image
import matplotlib.pyplot as plt
import seaborn as sns

rng = np.random.default_rng(42)
df = pd.DataFrame(
    {
        "category": list("ABCDEF"),
        "value": rng.integers(10, 100, size=6),
    }
)

sns.set_theme(style="whitegrid")
fig, ax = plt.subplots(figsize=(6, 4), dpi=100)
sns.barplot(data=df, x="category", y="value", hue="category", legend=False, ax=ax)
ax.set_title("seaborn barplot")

buf = io.BytesIO()
fig.savefig(buf, format="png", bbox_inches="tight")
print(df.to_string(index=False))
print(f"rendered barplot: {buf.tell()} bytes png")
