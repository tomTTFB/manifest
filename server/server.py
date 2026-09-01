# Serves the repo's Lua files to a CC:Tweaked computer for testing.
from pathlib import Path

from flask import Flask, Response, request

REPO = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent

app = Flask(__name__)


@app.get("/files")
def files():
    names = sorted(p.name for p in REPO.glob("*.lua"))
    return Response("\n".join(names) + "\n", mimetype="text/plain")


@app.get("/install.lua")
def installer():
    src = HERE.joinpath("install.lua").read_text()
    return Response(src.replace("__BASE__", request.host_url.rstrip("/")), mimetype="text/plain")


@app.get("/<name>.lua")
def lua(name):
    path = REPO / f"{name}.lua"
    if not path.exists():
        return "no such file", 404
    return Response(path.read_text(), mimetype="text/plain")


app.run(host="0.0.0.0", port=8080)
