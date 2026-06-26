# microvm-bench sample — variant: base (CPython stdlib only)
# CONTRACTS §H: base prefill. Pure compute, no third-party imports, no figure.
print(sum(i * i for i in range(10_000)))
