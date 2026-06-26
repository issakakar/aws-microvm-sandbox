# microvm-bench sample — variant: mpl (numpy + matplotlib)
# CONTRACTS §H: numpy linspace + matplotlib sine plot -> savefig(buf, format="png").
# The worker captures the *current* matplotlib figure when wantImage is set, so this
# script only needs to leave a figure on the pyplot stack (no explicit savefig required).
import io

import numpy as np
import matplotlib

matplotlib.use("Agg")  # headless; the only backend shipped in the image
import matplotlib.pyplot as plt

x = np.linspace(0, 2 * np.pi, 512)
y = np.sin(x)

fig, ax = plt.subplots(figsize=(6, 4), dpi=100)
ax.plot(x, y, color="#2563eb", linewidth=2)
ax.set_title("sin(x)")
ax.set_xlabel("x")
ax.set_ylabel("sin(x)")
ax.grid(True, alpha=0.3)

# Demonstrate the savefig path the harness exercises; the worker also auto-captures.
buf = io.BytesIO()
fig.savefig(buf, format="png", bbox_inches="tight")
print(f"rendered sine plot: {buf.tell()} bytes png")
