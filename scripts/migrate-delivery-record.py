#!/usr/bin/env python3
"""Forwarder → the delivery-ops plugin's scripts/migrate-delivery-record.py.

Deliberately empty of logic. The implementation is shared across projects and
lives in the plugin; this file only exists so the ~two dozen call sites that say
`python3 scripts/migrate-delivery-record.py` keep working unchanged.
See _delivery_ops_shim.py for why, and for how the plugin is located.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _delivery_ops_shim import forward  # noqa: E402

forward("migrate-delivery-record.py")
