# Holds the state the computer posts, and serves it to a browser. Runs beside
# the install server on the next port, and knows nothing about serving Lua.
import threading
import time

from flask import Flask, jsonify, request

PORT = 8081

app = Flask(__name__)

# The computer is the only writer. It leaves the item list out of a tick when
# nothing changed, so the last one it sent has to survive here.
state = {"items": [], "stats": {}, "output": None, "at": None}
seen = None
version = 0
pending = []
lock = threading.Condition()


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


app.run(host="0.0.0.0", port=PORT)
