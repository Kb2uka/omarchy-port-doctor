#!/usr/bin/python3 -I
"""Run the bundled scanner from this installed plugin only."""
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from port_doctor.scanner import main

if __name__ == "__main__":
    raise SystemExit(main())
