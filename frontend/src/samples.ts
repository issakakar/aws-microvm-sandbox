// CONTRACTS §H — variant sample code (prefilled in editor)
import type { Variant } from "./types.js";

export const SAMPLES: Record<Variant, string> = {
  base: `# Base Python — stdlib only
result = sum(i * i for i in range(10_000))
print(f"sum of squares 0..9999 = {result}")
`,

  mpl: `# Matplotlib + NumPy — sine wave plot
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

x = np.linspace(0, 2 * np.pi, 400)
y = np.sin(x) * np.exp(-x / 8)

fig, ax = plt.subplots(figsize=(6, 3))
ax.plot(x, y, linewidth=1.5, color="#3b82f6")
ax.set_title("Damped sine — microvm-bench", fontsize=11)
ax.set_xlabel("x")
ax.set_ylabel("sin(x)·e^(-x/8)")
ax.grid(True, alpha=0.3)
fig.tight_layout()
print(f"x range: [{x[0]:.2f}, {x[-1]:.2f}], peak y: {y.max():.4f}")
`,

  sci: `# Pandas + Seaborn — category bar + heatmap
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns

rng = np.random.default_rng(42)
cats = ["cold-create", "warm-resume", "hot"]
df = pd.DataFrame({
    "regime": cats * 4,
    "latency_ms": rng.uniform(50, 2000, 12),
    "variant": (["base"] * 3 + ["mpl"] * 3 + ["sci"] * 3 + ["base"] * 3),
})

fig, axes = plt.subplots(1, 2, figsize=(9, 3))

# bar chart
sns.barplot(data=df, x="regime", y="latency_ms", hue="variant", ax=axes[0])
axes[0].set_title("Latency by regime & variant")
axes[0].set_ylabel("ms")

# heatmap
pivot = df.pivot_table(index="regime", columns="variant", values="latency_ms", aggfunc="mean")
sns.heatmap(pivot, annot=True, fmt=".0f", cmap="YlOrRd", ax=axes[1])
axes[1].set_title("Mean latency (ms)")

fig.tight_layout()
print(df.groupby(["regime", "variant"])["latency_ms"].mean().to_string())
`,
};
