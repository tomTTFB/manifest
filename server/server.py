# Serves the repo's Lua files to a CC:Tweaked computer for testing, and holds
# the state that computer posts back so a browser can read it.
import threading
import time
from pathlib import Path

from flask import Flask, Response, jsonify, request

REPO = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent

app = Flask(__name__)

# The computer is the only writer. It leaves the item list out of a tick when
# nothing changed, so the last one it sent has to survive here.
state = {"items": [], "stats": {}, "output": None, "at": None}
seen = None
version = 0
pending = []
lock = threading.Condition()


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
    src = path.read_text().replace("__BASE__", request.host_url.rstrip("/"))
    return Response(src, mimetype="text/plain")

@app.post("/tick")
def tick():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return "expected a json object", 400

    global seen, version
    items = body.pop("items", None)

    with lock:
        if items is not None:
            state["items"] = items
        state.update(body)
        seen = time.time()
        version += 1

        commands, pending[:] = list(pending), []
        lock.notify_all()

    return jsonify(commands=commands)


@app.get("/api/state")
def api_state():
    with lock:
        return jsonify(dict(state, version=version, age=None if seen is None else time.time() - seen))


@app.post("/report")
def report():
    HERE.joinpath("report.txt").write_bytes(request.get_data())
    return "ok\n"


app.run(host="0.0.0.0", port=8080)
