"""
pokegym shim - redirects imports to zgbc.pokegym_env

This allows code that does `from pokegym import Environment` to
automatically use zgbc instead, with no code changes needed.

Install zgbc's Python bindings AFTER pokegym to override it,
or uninstall pokegym and use this shim.
"""

from zgbc.pokegym_env import Environment, ACTIONS

__all__ = ["Environment", "ACTIONS"]

