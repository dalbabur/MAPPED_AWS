import sys
from pathlib import Path

# Make the sibling bin/ scripts importable as plain modules, matching how Nextflow's
# bin/ auto-staging makes them runnable by bare filename inside a process container --
# tests exercise the same import surface.
BIN_DIR = Path(__file__).resolve().parent.parent / "bin"
if str(BIN_DIR) not in sys.path:
    sys.path.insert(0, str(BIN_DIR))
