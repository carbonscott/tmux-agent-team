"""Print one value from config.json. usage: cfg.py db.port"""
import json, os, sys
v = json.load(open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.json")))
for k in sys.argv[1].split("."):
    v = v[k]
print(" ".join(map(str, v)) if isinstance(v, list) else v)
